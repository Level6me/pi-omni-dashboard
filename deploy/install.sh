#!/bin/bash
# Install script for Pi Omni Dashboard

ACTUAL_USER=${SUDO_USER:-$(whoami)}
ACTUAL_HOME=$(eval echo ~$ACTUAL_USER)
ACTUAL_GROUP=$(id -gn $ACTUAL_USER)
DEPLOY_DIR="$ACTUAL_HOME/pi_omni"

echo ">>> 正在停止旧服务..."
sudo systemctl stop piomni 2>/dev/null
sudo fuser -k 5000/tcp 2>/dev/null

echo ">>> 准备部署目录: $DEPLOY_DIR"
mkdir -p "$DEPLOY_DIR/templates"
mkdir -p "$DEPLOY_DIR/static"

# 获取脚本所在根目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( dirname "$SCRIPT_DIR" )"

echo ">>> 复制文件至部署目录..."
cp "$PROJECT_DIR/app.py" "$DEPLOY_DIR/app.py"
cp "$PROJECT_DIR/templates/index.html" "$DEPLOY_DIR/templates/index.html"

# 安装依赖
echo ">>> 正在安装 Python 依赖项..."
sudo pip3 install -r "$PROJECT_DIR/requirements.txt" || pip3 install -r "$PROJECT_DIR/requirements.txt" --break-system-packages 2>/dev/null || true

echo ">>> 动态生成 systemd 服务配置文件..."
sed -e "s|{{USER}}|$ACTUAL_USER|g" \
    -e "s|{{GROUP}}|$ACTUAL_GROUP|g" \
    -e "s|{{DIR}}|$DEPLOY_DIR|g" \
    "$PROJECT_DIR/deploy/piomni.service" | sudo tee /etc/systemd/system/piomni.service > /dev/null

sudo systemctl daemon-reload
sudo systemctl enable --now piomni.service

echo ">>> Pi Omni Dashboard 已成功启动 (端口 5000)"
echo ">>> 访问: http://$(hostname -I | awk '{print $1}'):5000"
