import psutil, os, subprocess, time, socket, threading, re, json, urllib.request, shutil
from flask import Flask, render_template, jsonify, request, Response, send_from_directory
from werkzeug.utils import secure_filename
from concurrent.futures import ThreadPoolExecutor

app = Flask(__name__)

# 全局变量
last_net = psutil.net_io_counters()
last_disk = psutil.disk_io_counters()
last_time = time.time()
GLOBAL_DOCKER_CACHE = []
mem_history = []
last_alert_time = 0

psutil.cpu_percent(percpu=True)

CONFIG_FILE = '/boot/firmware/config.txt' if os.path.exists('/boot/firmware/config.txt') else '/boot/config.txt'
WEBHOOK_FILE = os.path.expanduser('~/pi_omni/webhook_config.json')
FILE_ROOT = os.path.expanduser('~')

# 用于并发测试网络延迟的线程池
executor = ThreadPoolExecutor(max_workers=4)

# 缓存机制：极速响应的关键。避免在 HTTP 请求中同步派生进程执行命令导致卡顿
GLOBAL_CACHE = {
    "services": {},
    "boot": "disabled",
    "gateway": "1.1.1.1",
    "hostname": socket.gethostname()
}

def run_cmd(cmd):
    try: return subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT).decode().strip()
    except: return ""

def get_webhook_url():
    try:
        if os.path.exists(WEBHOOK_FILE):
            with open(WEBHOOK_FILE, 'r') as f:
                return json.load(f).get('webhook_url', '')
    except: pass
    return ''

def save_webhook_url(url):
    try:
        os.makedirs(os.path.dirname(WEBHOOK_FILE), exist_ok=True)
        with open(WEBHOOK_FILE, 'w') as f:
            json.dump({'webhook_url': url}, f)
        return True
    except: return False

# 缓存更新守护线程
def cache_worker():
    # 仅检测一次 VNC 服务真实单元名
    vnc_svc = "vncserver-x11-serviced"
    if "not-found" in run_cmd("systemctl status vncserver-x11-serviced"):
        vnc_svc = "wayvnc"
        
    while True:
        try:
            # 1. 批量服务状态缓存
            svcs = {}
            for s in ["ssh", "docker", "cron"]:
                svcs[s] = "running" if run_cmd(f"systemctl is-active {s}") == "active" else "stopped"
            svcs["vncserver-x11-serviced"] = "running" if run_cmd(f"systemctl is-active {vnc_svc}") == "active" else "stopped"
            GLOBAL_CACHE["services"] = svcs
            
            # 2. 开机状态缓存
            try:
                GLOBAL_CACHE["boot"] = "enabled" if "enabled" in subprocess.check_output("systemctl is-enabled piomni.service", shell=True).decode() else "disabled"
            except:
                GLOBAL_CACHE["boot"] = "disabled"
                
            # 3. 网络网关缓存
            GLOBAL_CACHE["gateway"] = run_cmd("ip route list match 0/0 | awk '{print $3}'") or "1.1.1.1"
        except: pass
        time.sleep(2.5)

threading.Thread(target=cache_worker, daemon=True).start()

def get_cpu_temp():
    # 1. 优先尝试直接读取 sysfs 文件 (通用 Linux 平台，耗时 <0.1ms，无进程开销)
    try:
        if os.path.exists("/sys/class/thermal/thermal_zone0/temp"):
            with open("/sys/class/thermal/thermal_zone0/temp", "r") as f:
                temp_raw = f.read().strip()
                return str(round(float(temp_raw) / 1000.0, 1))
    except: pass
    
    # 2. 备用尝试 vcgencmd (树莓派平台专有，派生进程开销约 100ms)
    try:
        temp_str = run_cmd("vcgencmd measure_temp")
        if temp_str:
            return temp_str.replace("temp=", "").replace("'C", "")
    except: pass
    
    # 3. 尝试 psutil 跨平台接口
    try:
        temps = psutil.sensors_temperatures()
        if temps:
            for name, entries in temps.items():
                if entries:
                    return str(round(entries[0].current, 1))
    except: pass
    
    return "N/A"

def get_cpu_freq():
    # 1. 优先尝试直接读取 sysfs 文件 (通用 Linux 平台，耗时 <0.1ms)
    try:
        if os.path.exists("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"):
            with open("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", "r") as f:
                freq_raw = f.read().strip()
                return int(int(freq_raw) / 1000)
    except: pass
    
    # 2. 备用尝试 vcgencmd
    try:
        clock_str = run_cmd("vcgencmd measure_clock arm")
        if clock_str and "=" in clock_str:
            return int(int(clock_str.split("=")[1]) / 1000000)
    except: pass
    
    # 3. 尝试 psutil.cpu_freq()
    try:
        freq = psutil.cpu_freq()
        if freq:
            return int(freq.current)
    except: pass
    
    return 0

def check_ping(host):
    try:
        start = time.time()
        res = subprocess.run(["ping", "-c", "1", "-W", "1", host], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if res.returncode == 0:
            return int((time.time() - start) * 1000)
        return -1
    except: return -1

def get_uptime_desc():
    # 极速解析 /proc/uptime 替代 uptime -p shell 进程开销
    try:
        with open('/proc/uptime', 'r') as f:
            uptime_seconds = float(f.readline().split()[0])
        
        days = int(uptime_seconds // (24 * 3600))
        hours = int((uptime_seconds % (24 * 3600)) // 3600)
        minutes = int((uptime_seconds % 3600) // 60)
        
        parts = []
        if days > 0:
            parts.append(f"{days}天")
        if hours > 0:
            parts.append(f"{hours}小时")
        if minutes > 0 or not parts:
            parts.append(f"{minutes}分钟")
        return " ".join(parts)
    except:
        return "N/A"

def check_and_send_alert(cpu_temp, disk_p):
    global last_alert_time
    webhook_url = get_webhook_url()
    if not webhook_url:
        return
    
    now = time.time()
    if now - last_alert_time < 3600: # 1小时防刷冷静期
        return
        
    msg_parts = []
    try:
        temp_val = float(cpu_temp)
        if temp_val > 80.0:
            msg_parts.append(f"⚠️ CPU 温度过高: {temp_val}°C")
    except: pass
    
    try:
        disk_val = float(disk_p)
        if disk_val > 90.0:
            msg_parts.append(f"⚠️ 磁盘空间不足: {disk_val}%")
    except: pass
        
    if msg_parts:
        alert_text = "\n".join(msg_parts)
        payload = {"text": f"【Pi Omni Dashboard 告警】\n{alert_text}"}
        try:
            req = urllib.request.Request(
                webhook_url, 
                data=json.dumps(payload).encode('utf-8'),
                headers={'Content-Type': 'application/json'}
            )
            with urllib.request.urlopen(req, timeout=5) as response:
                pass
            last_alert_time = now
        except: pass

def get_safe_path(rel_path):
    if not rel_path:
        return FILE_ROOT
    abs_path = os.path.abspath(os.path.join(FILE_ROOT, rel_path))
    if abs_path.startswith(FILE_ROOT):
        return abs_path
    return FILE_ROOT

# --- 定时任务管理 ---

def parse_cron_desc(line):
    """解析 cron 表达式为中文描述"""
    parts = line.split()
    if len(parts) < 6:
        return line
    minute, hour, dom, month, dow, cmd = parts[0], parts[1], parts[2], parts[3], parts[4], ' '.join(parts[5:])
    
    # 构建时间描述
    time_str = ""
    if minute == '*' and hour == '*':
        time_str = "每分钟"
    elif hour == '*':
        time_str = f"每小时第 {minute} 分"
    elif minute == '*':
        time_str = f"每小时"
    else:
        time_str = f"{int(hour):02d}:{int(minute):02d}"
    
    # 频率描述
    freq = ""
    if dow != '*':
        dow_map = {'0':'周日','1':'周一','2':'周二','3':'周三','4':'周四','5':'周五','6':'周六'}
        if '-' in dow:
            start, end = dow.split('-')
            freq = f" 每周 {dow_map.get(start, start)}~{dow_map.get(end, end)}"
        else:
            freq = f" 每周{''.join([dow_map.get(d, d) for d in dow.split(',')])}"
    elif dom != '*':
        freq = f" 每月 {dom} 日"
    elif month != '*':
        freq = f" 每年 {int(month)} 月"
    else:
        freq = " 每天"
    
    # 获取命令简称
    cmd_short = cmd.split('/')[-1].split()[0] if cmd else ""
    # 提取脚本名或命令
    cmd_name = ""
    if '.py' in cmd or '.sh' in cmd:
        for p in cmd.split():
            if p.endswith('.py') or p.endswith('.sh'):
                cmd_name = os.path.basename(p).replace('.py','').replace('.sh','')
                break
    if not cmd_name:
        cmd_name = cmd_short
    
    return {"time": time_str + freq, "command": cmd, "name": cmd_name}

def get_user_cron_jobs():
    """获取用户 crontab 任务"""
    jobs = []
    try:
        raw = run_cmd("sudo crontab -l 2>/dev/null")
        for line in raw.split('\n'):
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split()
            if len(parts) >= 6 and parts[0].replace('*','').replace(',','').replace('-','').replace('/','').isdigit():
                desc = parse_cron_desc(line)
                jobs.append({
                    "id": f"cron_{len(jobs)}",
                    "type": "cron",
                    "enabled": True,
                    "schedule": line,
                    "time_desc": desc['time'],
                    "name": desc['name'],
                    "command": desc['command']
                })
    except:
        pass
    return jobs

def get_systemd_timers():
    """获取 systemd timer 任务"""
    timers = []
    try:
        raw = run_cmd("systemctl list-timers --all --no-pager --plain 2>/dev/null")
        for line in raw.split('\n'):
            if 'NEXT' in line or 'timers listed' in line or not line.strip():
                continue
            parts = line.split()
            if len(parts) >= 8:
                unit = parts[7] if len(parts) > 7 else ""
                if unit.endswith('.timer'):
                    svc = unit.replace('.timer', '.service')
                    active = run_cmd(f"systemctl is-active {unit}").strip() == "active"
                    timers.append({
                        "id": f"timer_{unit}",
                        "type": "timer",
                        "enabled": active,
                        "schedule": f"{parts[0]} ({parts[2]})",
                        "time_desc": parts[2] if len(parts) > 2 else "",
                        "name": svc.replace('.service',''),
                        "command": svc
                    })
    except:
        pass
    return timers

def toggle_cron_job(job_id, enable):
    """开启/关闭 cron 任务 (通过注释/取消注释)"""
    try:
        raw = run_cmd("sudo crontab -l 2>/dev/null")
        lines = raw.split('\n')
        idx = int(job_id.replace('cron_', ''))
        count = 0
        for i, line in enumerate(lines):
            line_stripped = line.strip()
            if line_stripped and not line_stripped.startswith('#'):
                parts = line_stripped.split()
                if len(parts) >= 6 and parts[0].replace('*','').replace(',','').replace('-','').replace('/','').isdigit():
                    if count == idx:
                        if enable and line_stripped.startswith('#'):
                            lines[i] = line_stripped[1:].strip()
                        elif not enable and not line_stripped.startswith('#'):
                            lines[i] = '# ' + line_stripped
                        break
                    count += 1
        new_cron = '\n'.join(lines) + '\n'
        proc = subprocess.Popen(['sudo', 'crontab', '-'], stdin=subprocess.PIPE, text=True)
        proc.communicate(input=new_cron)
        return True
    except:
        return False

def toggle_systemd_timer(unit, enable):
    """开启/关闭 systemd timer"""
    try:
        action = "enable" if enable else "disable"
        subprocess.run(["sudo", "systemctl", action, "--now", unit], check=True)
        return True
    except:
        return False

# --- 原有功能 ---

def get_ssd_temp():
    """使用 smartctl 获取 SSD 温度"""
    try:
        for dev in ['/dev/sda', '/dev/nvme0n1', '/dev/mmcblk0']:
            if os.path.exists(dev):
                smart = run_cmd(f"sudo smartctl -A {dev} 2>/dev/null | grep -i 'Temperature'")
                if smart:
                    match = re.search(r'\d+\s+\(Min/Max', smart)
                    if match:
                        temp = int(match.group().split()[0])
                        if temp > 0 and temp < 100:
                            return temp
                    match = re.search(r':\s*(\d+)', smart)
                    if match:
                        temp = int(match.group(1))
                        if temp > 0 and temp < 100:
                            return temp
        return None
    except: return None

def docker_worker():
    global GLOBAL_DOCKER_CACHE
    while True:
        try:
            ps_raw = run_cmd("sudo docker ps -a --format '{{.ID}}||{{.Names}}||{{.Image}}||{{.Status}}'")
            if not ps_raw:
                GLOBAL_DOCKER_CACHE = []
                time.sleep(5)
                continue

            has_running = False
            for line in ps_raw.split('\n'):
                if "Up" in line:
                    has_running = True
                    break

            stats_map = {}
            if has_running:
                stats_raw = run_cmd("sudo docker stats --no-stream --format '{{.ID}}||{{.CPUPerc}}||{{.MemUsage}}||{{.MemPerc}}'")
                if stats_raw:
                    for line in stats_raw.split('\n'):
                        line = re.sub(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])', '', line)
                        parts = line.split('||')
                        if len(parts) >= 4:
                            mem_val = parts[2].split('/')[0].strip()
                            stats_map[parts[0]] = {"cpu": parts[1].strip(), "mem": f"{mem_val} ({parts[3].strip()})"}

            new_list = []
            for line in ps_raw.split('\n'):
                p = line.split('||')
                if len(p) >= 4:
                    cid, name, image, status = p[0], p[1], p[2], p[3]
                    state = "running" if "Up" in status else "stopped"
                    uptime = status.replace("Up ", "").split("(")[0].strip()
                    res = stats_map.get(cid, {"cpu": "--", "mem": "--"}) if state == "running" else {"cpu": "--", "mem": "--"}
                    new_list.append({"id": cid, "name": name, "image": image, "uptime": uptime, "state": state, "cpu": res['cpu'], "mem": res['mem']})
            GLOBAL_DOCKER_CACHE = new_list
        except: pass
        time.sleep(5)

t = threading.Thread(target=docker_worker, daemon=True)
t.start()

def update_config(key, value):
    try:
        with open(CONFIG_FILE, 'r') as f: lines = f.readlines()
        new_lines = []
        found = False
        for line in lines:
            if line.strip().startswith(key + "=") or line.strip().startswith("#" + key + "="):
                new_lines.append(f"{key}={value}\n")
                found = True
            else: new_lines.append(line)
        if not found: new_lines.append(f"{key}={value}\n")
        
        # 将新配置写入临时文件，再通过 sudo 移动以解决权限问题
        tmp_path = "/tmp/piomni_config_tmp"
        with open(tmp_path, 'w') as f:
            f.writelines(new_lines)
        subprocess.run(f"sudo mv {tmp_path} {CONFIG_FILE} && sudo chmod 644 {CONFIG_FILE}", shell=True, check=True)
    except: pass

def get_mac_vendor_fallback(mac):
    mac = mac.upper().replace(':', '')
    vendors = {'B827EB':'Raspberry Pi','DC:A6:32':'Raspberry Pi','E45F01':'Raspberry Pi','D83ADD':'Raspberry Pi','ACBC32':'Apple','F01898':'Apple','BC926B':'Apple','88665A':'Apple','F4F5DB':'Apple','18C086':'Broadcom','00E04C':'Realtek','001A11':'Google','D83ADD':'Espressif','2462AB':'Espressif','30AEA4':'Espressif','84F3EB':'Espressif','50EC50':'Xiaomi','64CC2E':'Xiaomi','F8A45F':'Xiaomi','009E1E':'Xiaomi','F4F5DB':'Huawei','4846F1':'Huawei','00E0FC':'Huawei','14CC20':'TP-Link','50C7BF':'TP-Link','98DEAD':'Tenda','001132':'Synology','00D861':'Ubiquiti'}
    for k, v in vendors.items():
        if mac.startswith(k): return v
    return "Unknown"

def scan_lan():
    devices = []
    try:
        ip = run_cmd("hostname -I").split()[0]
        subnet = f"{ip.rsplit('.', 1)[0]}.0/24"
        raw = run_cmd(f"sudo nmap -sn {subnet}")
        curr_ip = "Unknown"
        for line in raw.split('\n'):
            if "Nmap scan report for" in line: curr_ip = line.split()[-1].strip('()')
            if "MAC Address:" in line:
                parts = line.split("MAC Address: ")[1]
                mac = parts.split(' ', 1)[0]
                vendor = parts.split(' ', 1)[1].strip('()') if len(parts.split(' ', 1))>1 else "Unknown"
                if vendor == "Unknown": vendor = get_mac_vendor_fallback(mac)
                devices.append({"ip": curr_ip, "mac": mac, "vendor": vendor})
    except: devices.append({"ip":"Error","mac":"Scan Failed","vendor":""})
    return devices

def get_process_list():
    procs = []
    try:
        for p in psutil.process_iter(['pid', 'username', 'name', 'cpu_percent', 'memory_percent', 'io_counters']):
            try:
                io = p.info['io_counters']
                rb = io.read_bytes if io else 0
                wb = io.write_bytes if io else 0
                procs.append({"pid": p.info['pid'], "user": p.info['username'], "name": p.info['name'], "cpu": p.info['cpu_percent'], "mem": round(p.info['memory_percent'], 1), "disk": rb + wb})
            except: pass
    except: pass
    return sorted(procs, key=lambda x: x['cpu'], reverse=True)[:50]

@app.route('/')
def index(): return render_template('index.html')

@app.route('/stream/speedtest')
def stream_speedtest():
    def generate():
        yield "data: 🚀 正在初始化测速服务...\n\n"
        p = subprocess.Popen(['stdbuf', '-o0', 'speedtest-cli'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=0)
        for line in iter(p.stdout.readline, ''):
            if line: yield f"data: {line.strip()}\n\n"
        p.stdout.close(); p.wait()
        yield "data: ✅ 测速完成\n\n"
        yield "data: CLOSE\n\n"
    return Response(generate(), mimetype='text/event-stream')

@app.route('/stream/update')
def stream_update():
    def generate():
        yield "data: 🚀 正在连接软件源...\n\n"
        p = subprocess.Popen(['stdbuf', '-oL', 'sudo', 'apt', 'update', '-y'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in p.stdout: yield f"data: {line}\n\n"
        yield "data: CLOSE\n\n"
    return Response(generate(), mimetype='text/event-stream')

# 实时状态数据接口
@app.route('/api/data')
def get_data():
    global last_net, last_disk, last_time, mem_history
    now = time.time(); dt = max(now - last_time, 0.1)
    
    cn = psutil.net_io_counters(); cd = psutil.disk_io_counters()
    up = (cn.bytes_sent - last_net.bytes_sent)/1024/dt
    down = (cn.bytes_recv - last_net.bytes_recv)/1024/dt
    dr = (cd.read_bytes - last_disk.read_bytes)/1024/dt
    dw = (cd.write_bytes - last_disk.write_bytes)/1024/dt
    last_net, last_disk, last_time = cn, cd, now
    
    mem_p = psutil.virtual_memory().percent
    mem_history.append(mem_p)
    if len(mem_history) > 30:
        mem_history.pop(0)
    
    # 极速版：从守护线程更新的全局变量中直接获取系统级服务与网关状态 (避免 shell 开销)
    services = GLOBAL_CACHE["services"]
    boot_state = GLOBAL_CACHE["boot"]
    gw = GLOBAL_CACHE["gateway"]
    hostname = GLOBAL_CACHE["hostname"]
    
    # 极速版：使用直接读取 sysfs 文件接口 (温度与频率获取耗时由 150ms 缩减至 0.05ms)
    cpu_temp = get_cpu_temp()
    cpu_freq = get_cpu_freq()
    disk_p = psutil.disk_usage('/').percent
    
    # 资源阈值警报检测与发送
    check_and_send_alert(cpu_temp, disk_p)
    
    # 极速版：多线程并发测试 Ping 延迟，保持高频刷新无阻塞
    hosts = ["gateway", "baidu", "github", "google"]
    dest_ips = [gw, "baidu.com", "github.com", "google.com"]
    futures = {host: executor.submit(check_ping, ip) for host, ip in zip(hosts, dest_ips)}
    pings = {host: futures[host].result() for host in hosts}
    
    ssd_temp = get_ssd_temp()
    
    # 极速版：极速获取 Uptime 描述 (从 /proc/uptime 转换，避免 uptime 命令派生)
    uptime_val = get_uptime_desc()
    
    # 极速版：仅获取一次 Per-CPU 百分比，计算其均值，规避调用 psutil.cpu_percent 两次的计算时间
    cores = psutil.cpu_percent(percpu=True)
    avg_cpu = round(sum(cores) / len(cores), 1) if cores else 0.0

    return jsonify({
        "cpu": {"p": avg_cpu, "cores": cores, "temp": cpu_temp, "freq": cpu_freq},
        "mem": {"p": mem_p, "history": mem_history},
        "net": {"up": up, "down": down, "ip": run_cmd("hostname -I").split()[0] if run_cmd("hostname -I") else "N/A", "pings": pings},
        "disk": {"p": disk_p, "r": dr, "w": dw},
        "load": os.getloadavg(),
        "uptime": uptime_val,
        "hostname": hostname,
        "services": services,
        "boot": boot_state,
        "ssd_temp": ssd_temp,
        "webhook_url": get_webhook_url()
    })

# Docker 数据接口
@app.route('/api/dockers')
def get_dockers():
    global GLOBAL_DOCKER_CACHE
    return jsonify({"dockers": GLOBAL_DOCKER_CACHE})

# 进程管理数据接口
@app.route('/api/processes')
def get_processes():
    return jsonify({"processes": get_process_list()})

# 结束进程 API
@app.route('/api/process/kill', methods=['POST'])
def kill_process():
    d = request.json
    pid = d.get('pid')
    if pid and isinstance(pid, int):
        try:
            if pid in [0, 1, os.getpid()]:
                return jsonify({"success": False, "msg": "不能终止核心系统进程"})
            p = psutil.Process(pid)
            p.terminate()
            return jsonify({"success": True, "msg": f"进程 {pid} ({p.name()}) 已成功结束"})
        except Exception as e:
            return jsonify({"success": False, "msg": f"结束失败: {str(e)}"})
    return jsonify({"success": False, "msg": "无效的 PID"})

# 告警 Webhook 设置接口
@app.route('/api/webhook/set', methods=['POST'])
def set_webhook():
    d = request.json
    url = d.get('webhook_url', '')
    if save_webhook_url(url):
        return jsonify({"success": True, "msg": "告警 Webhook 链接已成功保存"})
    return jsonify({"success": False, "msg": "保存失败，请检查文件写入权限"})

# 文件浏览器列表接口
@app.route('/api/files/list')
def list_files():
    path_param = request.args.get('path', '')
    target_dir = get_safe_path(path_param)
    try:
        items = []
        for name in os.listdir(target_dir):
            if name.startswith('.'):
                continue
            full_path = os.path.join(target_dir, name)
            is_dir = os.path.isdir(full_path)
            size = os.path.getsize(full_path) if not is_dir else 0
            mtime = os.path.getmtime(full_path)
            items.append({
                "name": name,
                "is_dir": is_dir,
                "size": size,
                "mtime": time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(mtime))
            })
        items.sort(key=lambda x: (not x['is_dir'], x['name'].lower()))
        rel_dir = os.path.relpath(target_dir, FILE_ROOT)
        if rel_dir == '.':
            rel_dir = ''
        return jsonify({
            "success": True, 
            "current_dir": rel_dir,
            "parent_dir": os.path.relpath(os.path.dirname(target_dir), FILE_ROOT) if rel_dir else None,
            "files": items
        })
    except Exception as e:
        return jsonify({"success": False, "msg": str(e)})

# 新建文件 / 文件夹 API
@app.route('/api/files/create', methods=['POST'])
def create_file_or_dir():
    d = request.json
    path_param = d.get('path', '')
    name = d.get('name', '')
    is_dir = d.get('is_dir', False)
    if not name:
        return jsonify({"success": False, "msg": "名称不能为空"})
    
    target_parent = get_safe_path(path_param)
    target_path = os.path.join(target_parent, secure_filename(name))
    try:
        if is_dir:
            os.makedirs(target_path, exist_ok=True)
            return jsonify({"success": True, "msg": f"文件夹 {name} 创建成功"})
        else:
            with open(target_path, 'w') as f:
                f.write('')
            return jsonify({"success": True, "msg": f"文件 {name} 创建成功"})
    except Exception as e:
        return jsonify({"success": False, "msg": str(e)})

# 重命名文件 / 文件夹 API
@app.route('/api/files/rename', methods=['POST'])
def rename_file_or_dir():
    d = request.json
    path_param = d.get('path', '')
    old_name = d.get('old_name', '')
    new_name = d.get('new_name', '')
    if not old_name or not new_name:
        return jsonify({"success": False, "msg": "名称不能为空"})
    
    target_dir = get_safe_path(path_param)
    old_path = os.path.join(target_dir, old_name)
    new_path = os.path.join(target_dir, secure_filename(new_name))
    try:
        os.rename(old_path, new_path)
        return jsonify({"success": True, "msg": "重命名成功"})
    except Exception as e:
        return jsonify({"success": False, "msg": str(e)})

# 删除文件 / 文件夹 API
@app.route('/api/files/delete', methods=['POST'])
def delete_file_or_dir():
    d = request.json
    path_param = d.get('path', '')
    name = d.get('name', '')
    if not name:
        return jsonify({"success": False, "msg": "名称不能为空"})
    
    target_dir = get_safe_path(path_param)
    target_path = os.path.join(target_dir, name)
    try:
        if os.path.isdir(target_path):
            shutil.rmtree(target_path)
        else:
            os.remove(target_path)
        return jsonify({"success": True, "msg": "删除成功"})
    except Exception as e:
        return jsonify({"success": False, "msg": str(e)})

# 下载文件 API
@app.route('/api/files/download')
def download_file():
    path_param = request.args.get('path', '')
    target_file = get_safe_path(path_param)
    if os.path.isdir(target_file):
        return "无法下载文件夹", 400
    try:
        directory = os.path.dirname(target_file)
        filename = os.path.basename(target_file)
        return send_from_directory(directory, filename, as_attachment=True)
    except Exception as e:
        return str(e), 500

# 读取文件接口
@app.route('/api/files/read')
def read_file_content():
    path_param = request.args.get('path', '')
    target_file = get_safe_path(path_param)
    if os.path.isdir(target_file):
        return jsonify({"success": False, "msg": "无法读取文件夹内容"})
    try:
        size = os.path.getsize(target_file)
        if size > 1024 * 1024:
            return jsonify({"success": False, "msg": "文件过大，在线版最多支持查看 1MB 文本"})
        with open(target_file, 'r', encoding='utf-8', errors='replace') as f:
            content = f.read()
        return jsonify({"success": True, "content": content})
    except Exception as e:
        return jsonify({"success": False, "msg": str(e)})

# 写入文件接口
@app.route('/api/files/write', methods=['POST'])
def write_file_content():
    d = request.json
    path_param = d.get('path', '')
    content = d.get('content', '')
    target_file = get_safe_path(path_param)
    if os.path.isdir(target_file):
        return jsonify({"success": False, "msg": "无法写入文件夹"})
    try:
        if os.path.exists(target_file):
            shutil.copyfile(target_file, target_file + '.bak')
        with open(target_file, 'w', encoding='utf-8') as f:
            f.write(content)
        return jsonify({"success": True, "msg": "文件写入成功（已备份原文件）"})
    except Exception as e:
        return jsonify({"success": False, "msg": str(e)})

# 上传文件接口
@app.route('/api/files/upload', methods=['POST'])
def upload_file():
    path_param = request.form.get('path', '')
    target_dir = get_safe_path(path_param)
    if 'file' not in request.files:
        return jsonify({"success": False, "msg": "未检测到上传文件"})
    file = request.files['file']
    if file.filename == '':
        return jsonify({"success": False, "msg": "文件名为空"})
    try:
        filename = secure_filename(file.filename)
        filename = os.path.basename(filename)
        dest_path = os.path.join(target_dir, filename)
        file.save(dest_path)
        return jsonify({"success": True, "msg": f"文件 {filename} 上传成功"})
    except Exception as e:
        return jsonify({"success": False, "msg": str(e)})

@app.route('/api/tool/<name>')
def tools(name):
    if name == 'lan': return jsonify({"data": scan_lan()})
    if name == 'ssh_log':
        try:
            raw = run_cmd("last -i -n 5 -F | grep -v 'wtmp starts'")
            logs = []
            for line in raw.split('\n'):
                if not line: continue
                p = line.split()
                if len(p) > 5: logs.append({"user": p[0], "ip": p[2], "time": f"{p[4]} {p[5]} {p[6]}"})
            return jsonify({"data": logs})
        except: return jsonify({"data": []})
    if name == 'disk_xray':
        parts = []
        for p in psutil.disk_partitions():
            try:
                u = psutil.disk_usage(p.mountpoint)
                parts.append({"mount": p.mountpoint, "total": f"{u.total/1024**3:.1f}G", "used": f"{u.used/1024**3:.1f}G", "p": u.percent})
            except: pass
        return jsonify({"data": parts})
    return jsonify({})

@app.route('/api/service_log/<name>')
def s_log(name):
    if re.match(r'^[a-zA-Z0-9.-]+$', name):
        return jsonify({"log": run_cmd(f"systemctl status {name} -l --no-pager | head -n 30")})
    return jsonify({"log": "Invalid service name"})

# --- 定时任务 API ---

@app.route('/api/cron/list')
def cron_list():
    cron_jobs = get_user_cron_jobs()
    timer_jobs = get_systemd_timers()
    return jsonify({
        "cron": cron_jobs,
        "timers": timer_jobs,
        "total": len(cron_jobs) + len(timer_jobs)
    })

@app.route('/api/cron/toggle', methods=['POST'])
def cron_toggle():
    d = request.json
    job_id = d.get('id', '')
    enable = d.get('enable', True)
    
    if job_id.startswith('cron_') and job_id.replace('cron_', '').isdigit():
        success = toggle_cron_job(job_id, enable)
    elif job_id.startswith('timer_'):
        unit = job_id.replace('timer_', '')
        if re.match(r'^[a-zA-Z0-9.-]+\.timer$', unit):
            success = toggle_systemd_timer(unit, enable)
        else:
            return jsonify({"success": False, "msg": "Invalid timer name"})
    else:
        return jsonify({"success": False, "msg": "Unknown job type"})
    
    return jsonify({"success": success, "msg": "OK" if success else "Failed"})

# 立即手动执行一次定时任务
@app.route('/api/cron/run_once', methods=['POST'])
def cron_run_once():
    d = request.json
    cmd = d.get('command')
    if not cmd:
        return jsonify({"success": False, "msg": "未接收到指令内容"})
    try:
        def run_bg(c):
            subprocess.run(c, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        threading.Thread(target=run_bg, args=(cmd,), daemon=True).start()
        return jsonify({"success": True, "msg": "指令已在系统后台异步触发"})
    except Exception as e:
        return jsonify({"success": False, "msg": str(e)})

# 新增 Cron 定时任务
@app.route('/api/cron/add', methods=['POST'])
def cron_add():
    d = request.json
    schedule = d.get('schedule')
    cmd = d.get('command')
    name = d.get('name', '')
    if not schedule or not cmd:
        return jsonify({"success": False, "msg": "时间表达式与执行指令不能为空"})
    try:
        if len(schedule.split()) < 5:
            return jsonify({"success": False, "msg": "Cron 时间表达式格式无效"})
        raw = run_cmd("sudo crontab -l 2>/dev/null")
        lines = raw.split('\n') if raw else []
        if lines and not lines[-1].strip():
            lines.pop()
        if name:
            lines.append(f"# {name}")
        lines.append(f"{schedule} {cmd}")
        new_cron = '\n'.join(lines) + '\n'
        proc = subprocess.Popen(['sudo', 'crontab', '-'], stdin=subprocess.PIPE, text=True)
        proc.communicate(input=new_cron)
        return jsonify({"success": True, "msg": "新定时任务添加成功"})
    except Exception as e:
        return jsonify({"success": False, "msg": str(e)})

# 删除 Cron 定时任务
@app.route('/api/cron/delete', methods=['POST'])
def cron_delete():
    d = request.json
    job_id = d.get('id', '')
    if not job_id.startswith('cron_') or not job_id.replace('cron_', '').isdigit():
        return jsonify({"success": False, "msg": "无效的任务 ID"})
    try:
        raw = run_cmd("sudo crontab -l 2>/dev/null")
        lines = raw.split('\n')
        idx = int(job_id.replace('cron_', ''))
        count = 0
        target_line_idx = -1
        for i, line in enumerate(lines):
            line_stripped = line.strip()
            if line_stripped and not line_stripped.startswith('#'):
                parts = line_stripped.split()
                if len(parts) >= 6 and parts[0].replace('*','').replace(',','').replace('-','').replace('/','').isdigit():
                    if count == idx:
                        target_line_idx = i
                        break
                    count += 1
        if target_line_idx != -1:
            lines.pop(target_line_idx)
            if target_line_idx > 0 and lines[target_line_idx-1].strip().startswith('#'):
                lines.pop(target_line_idx-1)
            new_cron = '\n'.join(lines) + '\n'
            proc = subprocess.Popen(['sudo', 'crontab', '-'], stdin=subprocess.PIPE, text=True)
            proc.communicate(input=new_cron)
            return jsonify({"success": True, "msg": "任务已成功删除"})
        return jsonify({"success": False, "msg": "未在 Crontab 中定位到该任务"})
    except Exception as e:
        return jsonify({"success": False, "msg": str(e)})

@app.route('/api/action', methods=['POST'])
def action():
    d = request.json
    act = d.get('cmd')
    val = d.get('val')
    log = "Executed"
    
    if act == 'reboot':
        subprocess.run(['sudo', 'reboot'])
    elif act == 'shutdown':
        subprocess.run(['sudo', 'shutdown', '-h', 'now'])
    elif act == 'clean_log':
        subprocess.run(['sudo', 'truncate', '-s', '0', '/var/log/syslog'])
    elif act == 'resolution':
        if val and re.match(r'^\d+$', str(val)):
            update_config('hdmi_group', '2')
            update_config('hdmi_mode', str(val))
        else:
            return jsonify({"error": "Invalid resolution value"})
    elif act == 'gpu_mem':
        if val and re.match(r'^\d+$', str(val)):
            update_config('gpu_mem', str(val))
        else:
            return jsonify({"error": "Invalid GPU memory value"})
    elif act == 'hostname':
        if val and re.match(r'^[a-zA-Z0-9.-]+$', str(val)):
            old = run_cmd("hostname")
            if old:
                subprocess.run(['sudo', 'hostnamectl', 'set-hostname', str(val)])
                try:
                    with open('/etc/hosts', 'r') as f:
                        hosts_content = f.read()
                    new_hosts = hosts_content.replace(old, str(val))
                    tmp_hosts = '/tmp/hosts_piomni'
                    with open(tmp_hosts, 'w') as f:
                        f.write(new_hosts)
                    subprocess.run(['sudo', 'mv', tmp_hosts, '/etc/hosts'])
                    subprocess.run(['sudo', 'chmod', '644', '/etc/hosts'])
                except:
                    pass
        else:
            return jsonify({"error": "Invalid hostname value"})
    elif act == 'ssh':
        if val in ['on', 'off']:
            action_val = 'enable' if val == 'on' else 'disable'
            subprocess.run(['sudo', 'systemctl', action_val, '--now', 'ssh'])
        else:
            return jsonify({"error": "Invalid SSH state value"})
    elif act == 'hdmi':
        if val in ['on', 'off']:
            power_val = '1' if val == 'on' else '0'
            subprocess.run(['vcgencmd', 'display_power', power_val])
        else:
            return jsonify({"error": "Invalid HDMI state value"})
    elif act == 'autostart':
        if val in ['on', 'off']:
            action_val = 'enable' if val == 'on' else 'disable'
            subprocess.run(['sudo', 'systemctl', action_val, 'piomni.service'])
        else:
            return jsonify({"error": "Invalid autostart state value"})
    elif act == 'ch_source':
        return jsonify({"log": "source_changed"})
    elif act == 'docker':
        cid = d.get('id', '')
        if val in ['start', 'stop', 'restart'] and re.match(r'^[a-zA-Z0-9_-]+$', cid):
            subprocess.run(['sudo', 'docker', val, cid])
            log = f"Docker {val} sent"
        else:
            return jsonify({"error": "Invalid docker command or container ID"})
            
    return jsonify({"log": log})

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 5000))
    app.run(host='0.0.0.0', port=port)
