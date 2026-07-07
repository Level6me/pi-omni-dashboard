#!/bin/bash
# Pi Omni v38 - 定时任务管理 (Cron + Systemd Timer 可视化 - 全面优化版)

# 动态确定执行用户及其 Home 目录以修复权限问题
ACTUAL_USER=${SUDO_USER:-$(whoami)}
ACTUAL_HOME=$(eval echo ~$ACTUAL_USER)

sudo systemctl stop piomni 2>/dev/null
sudo fuser -k 5000/tcp 2>/dev/null

mkdir -p "$ACTUAL_HOME/pi_omni/templates"
mkdir -p "$ACTUAL_HOME/pi_omni/static"
cd "$ACTUAL_HOME/pi_omni"

# ==================== 后端 (v38) ====================
cat <<'EOPY' > app.py
import psutil, os, subprocess, time, socket, threading, re, json
from flask import Flask, render_template, jsonify, request, Response

app = Flask(__name__)

# 全局变量
last_net = psutil.net_io_counters()
last_disk = psutil.disk_io_counters()
last_time = time.time()
GLOBAL_DOCKER_CACHE = []
mem_history = []

psutil.cpu_percent(percpu=True)

CONFIG_FILE = '/boot/firmware/config.txt' if os.path.exists('/boot/firmware/config.txt') else '/boot/config.txt'

def run_cmd(cmd):
    try: return subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT).decode().strip()
    except: return ""

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

def get_wifi():
    try:
        raw = run_cmd("iwconfig wlan0 | grep -E 'ESSID|Signal'")
        ssid = raw.split('ESSID:"')[1].split('"')[0] if 'ESSID' in raw else "N/A"
        dbm = raw.split('level=')[1].split(' ')[0] if 'level=' in raw else "0"
        return {"ssid": ssid, "dbm": dbm}
    except: return {"ssid": "N/A", "dbm": "0"}

def get_gateway():
    try: return run_cmd("ip route list match 0/0 | awk '{print $3}'") or "1.1.1.1"
    except: return "1.1.1.1"

def check_ping(host):
    try:
        start = time.time()
        res = subprocess.run(["ping", "-c", "1", "-W", "1", host], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if res.returncode == 0:
            return int((time.time() - start) * 1000)
        return -1
    except: return -1

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

def get_boot_state():
    try: return "enabled" if "enabled" in subprocess.check_output("systemctl is-enabled piomni.service", shell=True).decode() else "disabled"
    except: return "disabled"

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

# 优化后：轻量级实时状态数据接口（删除了庞大的 dockers 和 processes 数组）
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
    
    services = {}
    for s in ["ssh", "vncserver-x11-serviced", "docker", "cron"]:
        real = "wayvnc" if s == "vncserver-x11-serviced" and "not-found" in run_cmd("systemctl status vncserver-x11-serviced") else s
        services[s] = "running" if run_cmd(f"systemctl is-active {real}") == "active" else "stopped"

    gw = get_gateway()
    pings = {"gateway": check_ping(gw), "baidu": check_ping("baidu.com"), "github": check_ping("github.com"), "google": check_ping("google.com")}
    
    ssd_temp = get_ssd_temp()

    return jsonify({
        "cpu": {"p": psutil.cpu_percent(), "cores": psutil.cpu_percent(percpu=True), "temp": run_cmd("vcgencmd measure_temp").replace("temp=","").replace("'C",""), "freq": int(int(run_cmd("vcgencmd measure_clock arm").split("=")[1])/1000000)},
        "mem": {"p": mem_p, "history": mem_history},
        "net": {"up": up, "down": down, "ip": run_cmd("hostname -I").split()[0] if run_cmd("hostname -I") else "N/A", "pings": pings},
        "wifi": get_wifi(),
        "disk": {"p": psutil.disk_usage('/').percent, "r": dr, "w": dw},
        "load": os.getloadavg(),
        "uptime": run_cmd("uptime -p").replace("up ",""),
        "hostname": run_cmd("hostname"),
        "services": services,
        "boot": get_boot_state(),
        "ssd_temp": ssd_temp
    })

# 优化后：独立 Docker 数据接口，避免高频调用
@app.route('/api/dockers')
def get_dockers():
    global GLOBAL_DOCKER_CACHE
    return jsonify({"dockers": GLOBAL_DOCKER_CACHE})

# 优化后：独立进程管理数据接口，避免高频调用
@app.route('/api/processes')
def get_processes():
    return jsonify({"processes": get_process_list()})

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
    # 防御路径穿越与命令注入
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

# 优化后：安全参数化调用系统指令，避免 Shell 注入
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
    app.run(host='0.0.0.0', port=5000)
EOPY

# ==================== 前端 (v38 - 优化 API 数据请求模式) ====================
cat <<'EOH' > templates/index.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
    <meta name="theme-color" content="#f2f2f7" media="(prefers-color-scheme: light)">
    <meta name="theme-color" content="#000000" media="(prefers-color-scheme: dark)">
    <title>Pi Omni v38</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://code.jquery.com/jquery-3.6.0.min.js"></script>
    <style>
        :root { --bg: #f2f2f7; --card: #ffffff; --text: #000; --text-sec: #8e8e93; --accent: #007aff; --danger: #ff3b30; --success: #34c759; --dock: rgba(255,255,255,0.85); }
        @media (prefers-color-scheme: dark) { :root { --bg: #000; --card: #1c1c1e; --text: #fff; --text-sec: #98989d; --dock: rgba(28,28,30,0.85); } }
        body { background: var(--bg); color: var(--text); font-family: -apple-system, sans-serif; margin: 0; padding-bottom: 120px; }
        .container { padding: 20px 16px; max-width: 600px; margin: 0 auto; padding-top: max(20px, env(safe-area-inset-top)); }
        .header { margin: 20px 0; display: flex; justify-content: space-between; align-items: flex-end; }
        .title { font-size: 34px; font-weight: 700; }
        .subtitle { font-size: 13px; color: var(--text-sec); font-weight: 500; margin: 30px 0 10px 10px; }
        .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
        .card { background: var(--card); border-radius: 18px; padding: 18px; margin-bottom: 14px; box-shadow: 0 4px 12px rgba(0,0,0,0.03); }
        .val-big { font-size: 28px; font-weight: 700; font-variant-numeric: tabular-nums; }
        .val-sub { font-size: 14px; color: var(--text-sec); font-weight: 500; }
        .chart-mini { height: 90px; width: 100%; margin-top: 15px; }
        .list-item { padding: 16px 0; border-bottom: 0.5px solid rgba(128,128,128,0.2); display: flex; justify-content: space-between; align-items: center; }
        .list-item:last-child { border-bottom: none; }
        .ping-row { display: flex; justify-content: space-between; margin-top: 15px; }
        .ping-item { display: flex; flex-direction: column; align-items: center; gap: 5px; font-size: 10px; color: var(--text-sec); }
        .ping-dot { width: 10px; height: 10px; border-radius: 50%; background: #eee; transition: 0.3s; }
        .ping-dot.ok { background: var(--success); box-shadow: 0 0 8px rgba(52, 199, 89, 0.4); }
        .ping-dot.bad { background: var(--danger); }
        .dk-head { display: flex; justify-content: space-between; width: 100%; margin-bottom: 6px; }
        .dk-name { font-weight: 600; font-size: 15px; }
        .dk-stats { display: flex; gap: 8px; font-size: 11px; color: var(--text-sec); }
        .dk-ctrls { display: flex; gap: 10px; margin-top: 8px; justify-content: flex-end; }
        .dk-btn { width: 32px; height: 32px; border-radius: 50%; border: none; background: rgba(128,128,128,0.1); display: flex; align-items: center; justify-content: center; cursor: pointer; }
        .proc-table { width: 100%; border-collapse: collapse; font-size: 12px; }
        .proc-table th { text-align: left; color: var(--text-sec); font-weight: 600; padding-bottom: 10px; cursor: pointer; }
        .proc-table th.active { color: var(--accent); }
        .proc-table td { padding: 10px 0; border-bottom: 1px solid rgba(128,128,128,0.1); }
        .proc-name { font-weight: 600; max-width: 80px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; display: block; }
        .proc-pid { color: var(--text-sec); font-size: 10px; }
        .core-row { display: flex; align-items: center; margin-bottom: 12px; }
        .core-label { font-size: 12px; font-weight: 600; width: 30px; color: var(--text-sec); }
        .core-track { flex-grow: 1; height: 8px; background: rgba(128,128,128,0.15); border-radius: 4px; overflow: hidden; margin: 0 10px; }
        .core-fill { height: 100%; background: var(--accent); transition: width 0.3s; }
        .core-val { font-size: 12px; font-weight: 600; width: 35px; text-align: right; }
        .toggle-switch { position: relative; width: 50px; height: 30px; }
        .toggle-switch input { opacity: 0; width: 0; height: 0; }
        .slider { position: absolute; cursor: pointer; top: 0; left: 0; right: 0; bottom: 0; background-color: rgba(120,120,128,0.2); border-radius: 34px; transition: .3s; }
        .slider:before { position: absolute; content: ""; height: 26px; width: 26px; left: 2px; bottom: 2px; background-color: white; border-radius: 50%; transition: .3s; }
        input:checked + .slider { background-color: var(--success); }
        input:checked + .slider:before { transform: translateX(20px); }
        select { border:none; background:transparent; text-align:right; font-size:16px; color:var(--accent); outline:none; font-weight:500; }
        .pwr-btn { display: flex; align-items: center; justify-content: center; gap: 8px; padding: 16px; border-radius: 16px; border: none; font-weight: 600; flex: 1; cursor: pointer; }
        .dock { position: fixed; bottom: 25px; left: 50%; transform: translateX(-50%); width: 380px; height: 65px; background: var(--dock); backdrop-filter: blur(25px); border-radius: 35px; display: flex; justify-content: space-evenly; align-items: center; box-shadow: 0 10px 30px rgba(0,0,0,0.15); z-index: 1000; }
        .dock-btn { border: none; background: none; width: 44px; height: 44px; border-radius: 12px; display: flex; align-items: center; justify-content: center; transition: 0.2s; color: var(--text-sec); }
        .dock-btn.active { color: var(--accent); background: rgba(0,122,255,0.1); }
        .dock-btn svg { width: 24px; height: 24px; fill: currentColor; }
        .page { display: none; } .page.active { display: block; }
        .modal-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.4); backdrop-filter: blur(8px); display: none; align-items: center; justify-content: center; z-index: 2000; }
        .modal-card { background: var(--card); width: 85%; max-width: 450px; border-radius: 24px; padding: 24px; max-height: 80vh; display: flex; flex-direction: column; }
        .log-box { background: var(--bg); padding: 14px; border-radius: 12px; font-family: monospace; font-size: 11px; white-space: pre-wrap; margin-top: 15px; overflow-y: auto; flex-grow: 1; }
        .btn { padding: 14px; border-radius: 14px; border: none; font-weight: 600; font-size: 16px; cursor: pointer; width: 100%; margin-top: 15px; }
        .cron-item { padding: 14px 0; border-bottom: 0.5px solid rgba(128,128,128,0.2); display: flex; align-items: center; gap: 12px; }
        .cron-item:last-child { border-bottom: none; }
        .cron-icon { font-size: 20px; width: 32px; text-align: center; }
        .cron-info { flex: 1; }
        .cron-name { font-weight: 600; font-size: 15px; }
        .cron-time { font-size: 12px; color: var(--text-sec); }
        .cron-cmd { font-size: 10px; color: var(--text-sec); font-family: monospace; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 180px; }
        .cron-type-badge { font-size: 9px; padding: 2px 6px; border-radius: 6px; background: rgba(128,128,128,0.1); color: var(--text-sec); }
    </style>
</head>
<body>
<div class="container">
    <div class="header">
        <div><div style="font-size:12px; color:var(--text-sec)" id="date-now">...</div><div class="title" id="page-title">仪表盘</div></div>
        <div style="text-align:right"><div style="font-size:12px; color:var(--success)">● 运行中</div><div style="font-size:11px; opacity:0.5" id="uptime">--</div></div>
    </div>

    <!-- 仪表盘页面 -->
    <div id="p-dash" class="page active">
        <div class="grid">
            <div class="card">
                <div class="val-sub" style="color:var(--danger)">CPU 温度</div>
                <div class="val-big" id="v-cpu-temp">--</div>
                <div class="val-sub" id="v-freq">-- MHz</div>
            </div>
            <div class="card">
                <div class="val-sub" style="color:#ff9500">SSD 温度</div>
                <div class="val-big" id="v-ssd-temp">--</div>
                <div class="val-sub">smartctl 检测</div>
            </div>
        </div>
        
        <div class="card">
            <div style="display:flex; justify-content:space-between; margin-bottom:5px;">
                <span class="val-sub">内存使用率</span>
                <span class="val-big" id="v-mem">--</span>
            </div>
            <div class="chart-mini"><canvas id="memChart"></canvas></div>
        </div>

        <div class="card">
            <div style="display:flex; justify-content:space-between; margin-bottom:5px;">
                <span class="val-sub">网络</span>
                <span style="font-size:12px; font-weight:600" id="v-wifi">WiFi: --</span>
            </div>
            <div style="display:flex; justify-content:space-between; font-size:13px; font-weight:600">
                <span style="color:#34c759">↓ <span id="txt-down">0</span></span>
                <span style="color:#007aff">↑ <span id="txt-up">0</span></span>
            </div>
            <div class="chart-mini"><canvas id="netChart"></canvas></div>
            <div class="ping-row">
                <div class="ping-item"><div class="ping-dot" id="p-gw"></div>网关</div>
                <div class="ping-item"><div class="ping-dot" id="p-bd"></div>百度</div>
                <div class="ping-item"><div class="ping-dot" id="p-gh"></div>GitHub</div>
                <div class="ping-item"><div class="ping-dot" id="p-gg"></div>Google</div>
            </div>
        </div>

        <div class="card">
            <div style="display:flex; justify-content:space-between; margin-bottom:5px;">
                <span class="val-sub">CPU 历史</span>
                <span style="font-size:12px; font-weight:600; color:#ff3b30" id="txt-cpu">0%</span>
            </div>
            <div class="chart-mini"><canvas id="cpuChart"></canvas></div>
        </div>

        <div class="card">
            <div style="display:flex; justify-content:space-between; margin-bottom:5px;">
                <span class="val-sub">磁盘监控</span>
                <span style="font-size:12px; color:var(--accent); cursor:pointer" onclick="showDiskXray()">📊 分析</span>
            </div>
            <div style="display:flex; justify-content:space-between; font-size:13px; font-weight:600">
                <span>占用：<span id="v-disk-p">--</span></span>
                <span><span style="color:#ff9500">R</span> / <span style="color:#af52de">W</span></span>
            </div>
            <div class="chart-mini"><canvas id="diskChart"></canvas></div>
        </div>
    </div>

    <!-- 服务页面 -->
    <div id="p-serv" class="page">
        <div class="subtitle">Docker 指挥台</div>
        <div class="card" id="docker-list" style="padding:0 20px"><div style="padding:20px;text-align:center;color:#8e8e93">Loading...</div></div>
        <div class="subtitle">系统服务</div>
        <div class="card" id="serv-list" style="padding:0 20px"></div>
        <div class="subtitle">SSH 审计</div>
        <div class="card" id="ssh-list" style="padding:0 20px"><div style="padding:20px;text-align:center;color:#8e8e93">Loading...</div></div>
    </div>

    <!-- 定时任务页面 -->
    <div id="p-cron" class="page">
        <div class="subtitle">🕐 Crontab 定时任务</div>
        <div class="card" id="cron-list" style="padding:0 20px"><div style="padding:20px;text-align:center;color:#8e8e93">Loading...</div></div>
        <div class="subtitle">⏰ Systemd Timer</div>
        <div class="card" id="timer-list" style="padding:0 20px"><div style="padding:20px;text-align:center;color:#8e8e93">Loading...</div></div>
    </div>

    <!-- 控制中心页面 -->
    <div id="p-ctrl" class="page">
        <div class="subtitle">网络工具箱</div>
        <div class="grid">
            <div class="card clickable" style="text-align:center; padding:20px" onclick="runStreamTool('speedtest')">
                <div style="font-size:24px">⚡</div><div class="proc-name">一键测速</div>
            </div>
            <div class="card clickable" style="text-align:center; padding:20px" onclick="runTool('lan')">
                <div style="font-size:24px">🕸️</div><div class="proc-name">局域网扫描</div>
            </div>
        </div>
        <div class="subtitle">基础控制</div>
        <div class="card" style="padding:0 20px">
            <div class="list-item"><span>SSH 服务</span><label class="toggle-switch"><input type="checkbox" id="tg-ssh" onchange="toggleSSH(this)"><span class="slider"></span></label></div>
            <div class="list-item"><span>HDMI 输出</span><label class="toggle-switch"><input type="checkbox" id="tg-hdmi" onchange="toggleHDMI(this)"><span class="slider"></span></label></div>
            <div class="list-item"><span>开机自启</span><label class="toggle-switch"><input type="checkbox" id="tg-boot" onchange="toggleBoot(this)"><span class="slider"></span></label></div>
        </div>
        <div class="subtitle">维护</div>
        <div class="card" style="padding:0 20px">
            <div class="list-item"><span>软件源</span><select onchange="changeSource(this.value)"><option value="official">官方源</option><option value="tuna">清华源</option><option value="aliyun">阿里源</option><option value="ustc">中科大</option></select></div>
            <div class="list-item" onclick="askUpdate()"><span>系统更新</span><span style="color:var(--accent);font-weight:600">Update</span></div>
            <div class="list-item" onclick="askAction('clean_log', '清空日志')"><span>日志清理</span><span style="color:var(--accent);font-weight:600">Truncate</span></div>
        </div>
        <div class="subtitle">电源</div>
        <div class="grid">
            <button class="pwr-btn" style="background:var(--card); color:var(--accent)" onclick="askAction('reboot','重启')">重启</button>
            <button class="pwr-btn" style="background:var(--card); color:var(--danger)" onclick="askAction('shutdown','关机')">关机</button>
        </div>
    </div>

    <!-- 进程管理页面 -->
    <div id="p-proc" class="page">
        <div class="subtitle">CPU Cores</div>
        <div class="card" id="core-list"></div>
        <div class="subtitle">Process List</div>
        <div class="card" style="overflow:hidden">
            <table class="proc-table">
                <thead><tr><th style="padding-left:15px; width:40%" onclick="setSort('name')">Name</th><th style="width:15%" onclick="setSort('cpu')">CPU</th><th style="width:15%" onclick="setSort('mem')">Mem</th><th style="width:15%" onclick="setSort('disk')">Disk</th><th style="padding-right:15px; width:15%" onclick="setSort('pid')">PID</th></tr></thead>
                <tbody id="proc-body"></tbody>
            </table>
        </div>
    </div>
</div>

<div class="dock">
    <button class="dock-btn active" onclick="nav('dash', this)"><svg viewBox="0 0 24 24"><path d="M3 13h8V3H3v10zm0 8h8v-6H3v6zm10 0h8V11h-8v10zm0-18v6h8V3h-8z"/></svg></button>
    <button class="dock-btn" onclick="nav('serv', this)"><svg viewBox="0 0 24 24"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58a.49.49 0 0 0 .12-.61l-1.92-3.32a.488.488 0 0 0-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54a.484.484 0 0 0-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58a.49.49 0 0 0-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.58 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/></svg></button>
    <button class="dock-btn" onclick="nav('cron', this)"><svg viewBox="0 0 24 24"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z"/></svg></button>
    <button class="dock-btn" onclick="nav('ctrl', this)"><svg viewBox="0 0 24 24"><path d="M3 17v2h6v-2H3zM3 5v2h10V5H3zm10 16v-2h8v-2h-8v-2h-2v6h2zM7 9v2H3v2h4v2h2V9H7zm14 4v-2H11v2h10zm-6-4h2V7h4V5h-4V3h-2v6z"/></svg></button>
    <button class="dock-btn" onclick="nav('proc', this)"><svg viewBox="0 0 24 24"><path d="M4 4h16v16H4V4zm2 2v4h12V6H6zm0 6v6h6v-6H6zm8 0v6h4v-6h-4z"/></svg></button>
</div>

<div class="modal-overlay" id="modal">
    <div class="modal-card">
        <h3 id="modal-title" style="margin:0"></h3>
        <div class="log-box" id="modal-content"></div>
        <button class="btn" id="btn-close-main" style="background:var(--accent); color:white" onclick="closeModal()">关闭</button>
        <div id="confirm-row" style="display:none; margin-top:10px">
            <button class="btn" style="background:#eee; color:#000; flex:1" onclick="closeModal()">取消</button>
            <button class="btn" id="btn-confirm" style="background:var(--accent); color:white; flex:1"></button>
        </div>
    </div>
</div>

<script>
    let first=true, blockSync=false, sortKey='cpu', sortOrd=-1, cronLoaded=false, activeTab='dash', tick=0;
    
    function nav(id, el) { 
        $('.page').removeClass('active'); 
        $('#p-'+id).addClass('active'); 
        $('.dock-btn').removeClass('active'); 
        $(el).addClass('active'); 
        $('#page-title').text({dash:'仪表盘',serv:'服务',cron:'定时任务',ctrl:'控制中心',proc:'进程管理'}[id]); 
        activeTab = id;
        if(id==='cron' && !cronLoaded) loadCron(); 
        if(id==='serv') updateDockers();
        if(id==='proc') updateProcesses();
    }
    
    // 定时任务加载
    function loadCron() {
        $.getJSON('/api/cron/list', d => {
            // Cron jobs
            let cH = '';
            if (d.cron.length === 0) {
                cH = '<div style="padding:20px;text-align:center;color:#8e8e93">无 Crontab 任务</div>';
            } else {
                d.cron.forEach(j => {
                    let icon = j.name.includes('gold') ? '🥇' : j.name.includes('oil') ? '⛽' : j.name.includes('daily') || j.name.includes('monitor') ? '📊' : j.name.includes('xiaomi') ? '📈' : j.name.includes('memory') ? '🧠' : j.name.includes('self-improvement') || j.name.includes('extract') ? '🎯' : '📋';
                    cH += `<div class="cron-item">
                        <div class="cron-icon">${icon}</div>
                        <div class="cron-info">
                            <div class="cron-name">${j.name} <span class="cron-type-badge">cron</span></div>
                            <div class="cron-time">${j.time_desc}</div>
                            <div class="cron-cmd">${j.command}</div>
                        </div>
                        <label class="toggle-switch">
                            <input type="checkbox" ${j.enabled?'checked':''} onchange="toggleCron('${j.id}', this.checked)">
                            <span class="slider"></span>
                        </label>
                    </div>`;
                });
            }
            $('#cron-list').html(cH);

            // Timer jobs
            let tH = '';
            if (d.timers.length === 0) {
                tH = '<div style="padding:20px;text-align:center;color:#8e8e93">无 Systemd Timer</div>';
            } else {
                d.timers.forEach(j => {
                    let icon = j.name.includes('camera') ? '📷' : j.name.includes('backup') ? '💾' : '⏰';
                    tH += `<div class="cron-item">
                        <div class="cron-icon">${icon}</div>
                        <div class="cron-info">
                            <div class="cron-name">${j.name} <span class="cron-type-badge">timer</span></div>
                            <div class="cron-time">${j.time_desc}</div>
                            <div class="cron-cmd">${j.command}</div>
                        </div>
                        <label class="toggle-switch">
                            <input type="checkbox" ${j.enabled?'checked':''} onchange="toggleCron('${j.id}', this.checked)">
                            <span class="slider"></span>
                        </label>
                    </div>`;
                });
            }
            $('#timer-list').html(tH);
            cronLoaded = true;
        });
    }

    function toggleCron(id, enable) {
        $.ajax({url:'/api/cron/toggle', type:'POST', contentType:'application/json', 
                data: JSON.stringify({id: id, enable: enable}),
                success: d => { if(!d.success) alert('操作失败: ' + (d.msg || '')); },
                error: () => alert('操作失败') });
    }
    
    // 内存图表
    const memChart = new Chart(document.getElementById('memChart'), { 
        type: 'line', 
        data: { labels: Array(30).fill(''), datasets: [{borderColor: '#007aff', borderWidth:2, data:Array(30).fill(0), pointRadius:0, tension:0.4}] }, 
        options: { responsive:true, maintainAspectRatio:false, animation:false, plugins:{legend:{display:false}}, scales:{x:{display:false},y:{}} } 
    });
    const netChart = new Chart(document.getElementById('netChart'), { 
        type: 'line', 
        data: { labels: Array(30).fill(''), datasets: [{borderColor: '#34c759', borderWidth:2, data:Array(30).fill(0), pointRadius:0, tension:0.4},{borderColor: '#007aff', borderWidth:2, data:Array(30).fill(0), pointRadius:0, tension:0.4}] }, 
        options: { responsive:true, maintainAspectRatio:false, animation:false, plugins:{legend:{display:false}}, scales:{x:{display:false},y:{display:false}} } 
    });
    const cpuChart = new Chart(document.getElementById('cpuChart'), { 
        type: 'line', 
        data: { labels: Array(30).fill(''), datasets: [{borderColor: '#ff3b30', borderWidth:2, data:Array(30).fill(0), pointRadius:0, tension:0.4}] }, 
        options: { responsive:true, maintainAspectRatio:false, animation:false, plugins:{legend:{display:false}}, scales:{x:{display:false},y:{min:0,max:100}} } 
    });
    const diskChart = new Chart(document.getElementById('diskChart'), { 
        type: 'line', 
        data: { labels: Array(30).fill(''), datasets: [{borderColor: '#ff9500', borderWidth:2, data:Array(30).fill(0), pointRadius:0, tension:0.4},{borderColor: '#af52de', borderWidth:2, data:Array(30).fill(0), pointRadius:0, tension:0.4}] }, 
        options: { responsive:true, maintainAspectRatio:false, animation:false, plugins:{legend:{display:false}}, scales:{x:{display:false},y:{display:false}} } 
    });
    
    function fmtSpeed(kb) { return kb >= 1024 ? (kb/1024).toFixed(2) + ' MB/s' : Math.round(kb) + ' KB/s'; }
    function fmtDisk(b) { return b >= 1024*1024 ? (b/1024/1024).toFixed(1)+'M' : (b/1024).toFixed(0)+'K'; }

    function update() {
        tick++;
        $.getJSON('/api/data', d => {
            $('#v-cpu-temp').text(d.cpu.temp+'°C'); 
            $('#v-freq').text(d.cpu.freq+' MHz');
            $('#v-ssd-temp').text(d.ssd_temp ? d.ssd_temp+'°C' : '--');
            $('#v-mem').text(d.mem.p+'%'); 
            $('#txt-down').text(fmtSpeed(d.net.down)); 
            $('#txt-up').text(fmtSpeed(d.net.up)); 
            $('#txt-cpu').text(d.cpu.p + '%');
            $('#v-disk-p').text(d.disk.p+'%');
            $('#uptime').text('UP: '+d.uptime); 
            $('#date-now').text(new Date().toLocaleTimeString());
            
            for(let k in d.net.pings) { 
                $(`#p-${k=='gateway'?'gw':(k=='baidu'?'bd':(k=='github'?'gh':'gg'))}`).removeClass('ok bad').addClass(d.net.pings[k]>-1?'ok':'bad'); 
            }

            memChart.data.datasets[0].data.push(d.mem.p);
            if(memChart.data.datasets[0].data.length > 30) memChart.data.datasets[0].data.shift();
            memChart.update();

            netChart.data.datasets[0].data.push(d.net.down); 
            netChart.data.datasets[0].data.shift();
            netChart.data.datasets[1].data.push(d.net.up); 
            netChart.data.datasets[1].data.shift(); 
            netChart.update();
            
            cpuChart.data.datasets[0].data.push(d.cpu.p); 
            cpuChart.data.datasets[0].data.shift(); 
            cpuChart.update();
            
            diskChart.data.datasets[0].data.push(d.disk.r); 
            diskChart.data.datasets[0].data.shift();
            diskChart.data.datasets[1].data.push(d.disk.w); 
            diskChart.data.datasets[1].data.shift(); 
            diskChart.update();

            if (activeTab === 'serv') {
                let sH=''; for(let s in d.services) sH+=`<div class="list-item clickable" onclick="showLog('${s}')"><span>${s}</span><span style="color:${d.services[s]=='running'?'#34c759':'#8e8e93'}">● ${d.services[s]}</span></div>`; 
                $('#serv-list').html(sH);
            }
            
            if (activeTab === 'proc') {
                let total = d.cpu.p;
                let tColor = total > 80 ? '#ff3b30' : (total > 50 ? '#ff9500' : '#34c759');
                let cH = `<div class="core-row"><div class="core-label">ALL</div><div class="core-track"><div class="core-fill" style="width:${total}%; background:${tColor}"></div></div><div class="core-val">${total}%</div></div><hr style="border:0; border-bottom:1px solid rgba(128,128,128,0.1)">`;
                d.cpu.cores.forEach((c, i) => { 
                    let color = c > 80 ? '#ff3b30' : (c > 50 ? '#ff9500' : '#34c759'); 
                    cH += `<div class="core-row"><div class="core-label">C${i}</div><div class="core-track"><div class="core-fill" style="width:${c}%; background:${color}"></div></div><div class="core-val">${c}%</div></div>`; 
                }); 
                $('#core-list').html(cH);
            }

            if(!blockSync) { 
                $('#tg-ssh').prop('checked', d.services.ssh === 'running'); 
                $('#tg-boot').prop('checked', d.boot === 'enabled'); 
            }
            if(first){ 
                $.getJSON('/api/tool/ssh_log', d=>{ 
                    let h=''; d.data.forEach(l=>h+=`<div class="list-item"><span>${l.user} @ ${l.ip}</span><span style="font-size:12px;color:#8e8e93">${l.time}</span></div>`); 
                    $('#ssh-list').html(h||'<div style="text-align:center;padding:10px;color:#8e8e93">No records</div>'); 
                });
                first=false; 
            }
        });

        // 慢速加载数据：活跃状态下每 3 秒刷新一次
        if (activeTab === 'serv' && tick % 3 === 0) {
            updateDockers();
        }
        if (activeTab === 'proc' && tick % 3 === 0) {
            updateProcesses();
        }
    }

    function updateDockers() {
        $.getJSON('/api/dockers', d => {
            let dH = ''; 
            if(d.dockers && d.dockers.length > 0) {
                d.dockers.forEach(c => {
                    let st = c.state == 'running';
                    dH += `<div class="list-item" style="display:block;padding:12px 0">
                    <div class="dk-head"><div class="dk-name">${c.name}</div><div style="color:${st?'#34c759':'#ff3b30'}">● ${c.state}</div></div>
                    <div class="dk-stats"><span>CPU ${c.cpu}</span><span>MEM ${c.mem}</span><span>UP ${c.uptime}</span></div>
                    <div style="font-size:10px;color:#8e8e93;margin-top:4px">${c.image}</div>
                    <div class="dk-ctrls"><button class="dk-btn" onclick="dkAct('${c.id}','start')">▶</button><button class="dk-btn" onclick="dkAct('${c.id}','stop')">⏹</button><button class="dk-btn" onclick="dkAct('${c.id}','restart')">🔄</button></div></div>`;
                });
            } else dH='<div style="padding:20px;text-align:center;color:#8e8e93">No Containers</div>';
            $('#docker-list').html(dH);
        });
    }

    function updateProcesses() {
        $.getJSON('/api/processes', d => {
            if (!d.processes) return;
            let procs = d.processes.sort((a,b) => { 
                let valA = a[sortKey], valB = b[sortKey]; 
                return (valA < valB ? -1 : 1) * sortOrd; 
            });
            let pH = ''; procs.forEach(p => { 
                pH += `<tr><td style="padding-left:15px"><span class="proc-name">${p.name}</span><span class="proc-pid">${p.user}</span></td><td>${p.cpu.toFixed(1)}%</td><td>${p.mem}%</td><td>${fmtDisk(p.disk)}</td><td>${p.pid}</td></tr>`; 
            }); 
            $('#proc-body').html(pH);
        });
    }

    function toggleSSH(el) { blockSync=true; askConfig('ssh', el.checked?'on':'off'); setTimeout(()=>{blockSync=false}, 2000); }
    function toggleHDMI(el) { askConfig('hdmi', el.checked?'on':'off'); }
    function toggleBoot(el) { blockSync=true; askConfig('autostart', el.checked?'on':'off'); setTimeout(()=>{blockSync=false}, 2000); }
    function dkAct(id, op) { $.ajax({url:'/api/action', type:'POST', contentType:'application/json', data:JSON.stringify({cmd:'docker', id:id, val:op}), success: d=>alert(d.log || d.error || 'Done')}); }
    function setSort(key) { if(sortKey === key) sortOrd *= -1; else { sortKey = key; sortOrd = -1; } $('.proc-table th').removeClass('active'); $(`.proc-table th[onclick="setSort('${key}')"]`).addClass('active'); updateProcesses(); }

    function runTool(t) {
        openModal(t=='lan'?'扫描中...':'执行中...', '请稍后...');
        $.getJSON('/api/tool/'+t, d => {
            if(t=='lan'){
                let h=''; d.data.forEach(x=>h+=`<div class="list-item" style="display:block"><div class="proc-name">${x.ip}</div><div style="font-size:12px;color:#8e8e93">${x.vendor} • ${x.mac}</div></div>`);
                $('#modal-content').html(h || 'No devices found');
            } else { $('#modal-content').text(d.log); }
        });
    }
    
    function runStreamTool(t) {
        openModal(t=='speedtest'?'正在测速...':'执行中...', '正在连接...\n');
        const evt = new EventSource('/stream/'+t);
        evt.onmessage = e => { 
            if(e.data=='CLOSE'){evt.close(); return;} 
            $('#modal-content').append(e.data+'\n'); 
            document.getElementById('modal-content').scrollTop = 9999;
        };
    }

    function showDiskXray() {
        openModal('磁盘透视', 'Loading...');
        $.getJSON('/api/tool/disk_xray', d => {
            let h = ''; d.data.forEach(p => { 
                h += `<div style="margin-bottom:15px"><div style="display:flex;justify-content:space-between;font-size:13px;font-weight:600"><span>${p.mount}</span><span>${p.used} / ${p.total}</span></div><div style="height:6px;background:rgba(128,128,128,0.15);border-radius:3px;margin-top:5px"><div style="height:100%;background:var(--accent);border-radius:3px;width:${p.p}%"></div></div></div>`; 
            });
            $('#modal-content').html(h);
        });
    }

    function openModal(t, c) { 
        $('#modal-title').text(t); 
        $('#modal-content').html(c); 
        $('#modal').css('display','flex'); 
        $('#confirm-row').hide(); 
        $('#btn-close-main').show();
    }
    
    function closeModal() { $('#modal').hide(); }
    
    function askAction(c, n, v=null) { 
        $('#modal-title').text('确认'); 
        $('#modal-content').text('确定要'+n+'?'); 
        $('#modal').css('display','flex'); 
        $('#btn-close-main').hide();
        $('#confirm-row').show(); 
        $('#btn-confirm').text('确认').off('click').on('click', ()=>{ 
            $.ajax({url:'/api/action', type:'POST', contentType:'application/json', data:JSON.stringify({cmd:c, val:v}), success: d=>{ closeModal(); alert(d.log || d.error || 'Done'); }}); 
        }); 
    }
    
    function askConfig(c, v) { $.ajax({url:'/api/action', type:'POST', contentType:'application/json', data:JSON.stringify({cmd:c, val:v})}); }
    
    function askUpdate() { 
        openModal('系统更新', '流量预警！确认执行 apt update？'); 
        $('#btn-close-main').hide();
        $('#confirm-row').show(); 
        $('#btn-confirm').text('确认').off('click').on('click', startUpdate); 
    }
    
    function changeSource(v) { 
        openModal('切换软件源', '切换后将自动更新'); 
        $('#btn-close-main').hide();
        $('#confirm-row').show(); 
        $('#btn-confirm').text('确认').off('click').on('click', ()=>{ 
            $.ajax({url:'/api/action', type:'POST', contentType:'application/json', data:JSON.stringify({cmd:'ch_source', val:v}), success: d=>{ if(d.log=='source_changed') startUpdate(); }}); 
        }); 
    }
    
    function startUpdate() { 
        $('#confirm-row').hide(); 
        $('#btn-close-main').show();
        $('#modal-content').text('Connecting...\n'); 
        const evt = new EventSource('/stream/update'); 
        evt.onmessage = e => { if(e.data=='CLOSE'){evt.close(); return;} $('#modal-content').append(e.data+'\n'); document.getElementById('modal-content').scrollTop = 9999; }; 
    }
    
    function showLog(n) { openModal(n+' 日志', 'Loading...'); $.getJSON('/api/service_log/'+n, d=>$('#modal-content').text(d.log)); }

    setInterval(update, 1000); 
    update();
</script>
</body>
</html>
EOH

# ==================== 部署 ====================
echo ">>> 创建 systemd 服务..."
sudo tee /etc/systemd/system/piomni.service > /dev/null << EOSVC
[Unit]
Description=Pi Omni Monitor Dashboard v38
After=network.target

[Service]
Type=simple
User=$ACTUAL_USER
Group=$(id -gn $ACTUAL_USER)
WorkingDirectory=$ACTUAL_HOME/pi_omni
ExecStart=/usr/bin/python3 $ACTUAL_HOME/pi_omni/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOSVC

sudo systemctl daemon-reload
sudo systemctl enable --now piomni.service
echo ">>> Pi Omni v38 已启动 (端口 5000)"
echo ">>> 访问: http://\$(hostname -I | awk '{print \$1}'):5000"
