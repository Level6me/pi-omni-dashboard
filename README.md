# Pi Omni Dashboard

基于 Flask 和 Chart.js 构建的树莓派系统状态与定时任务管理看板。

## 项目特点

1. **安全增强**：采用 `subprocess.run(shell=False)` 并对参数进行正则校验，彻底防御了 Shell 命令注入等风险。
2. **轻量高性能**：通过 API 拆分及前端按需轮询机制，精简了网络载荷，并优化了 Docker 监控的 CPU 负载。
3. **系统兼容**：部署脚本可动态识别当前执行用户及家目录，自动替换参数生成 systemd 服务，彻底解决权限越界引发的启动问题。
4. **功能全面**：集成了温度监控、磁盘/网络吞吐展示、真实 ICMP Ping 测试、Docker 运行操纵、系统服务与进程监控、Crontab/Systemd Timer 开关等。

## 文件结构

```
pi-omni-dashboard/
├── app.py                 # Flask 后端核心服务
├── requirements.txt       # Python 依赖依赖项
├── templates/
│   └── index.html         # 前端 iOS 风格监控页面
├── deploy/
│   ├── piomni.service     # systemd 服务模板
│   └── install.sh         # 安装与自动部署脚本
└── README.md              # 项目使用说明书
```

## 部署与安装

在终端执行以下指令即可一键部署并启动服务：

```bash
chmod +x deploy/install.sh
sudo ./deploy/install.sh
```
