#!/bin/bash
# Install script for Pi Omni Dashboard (Venv + Systemd)

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

echo ">>> 复制项目文件至部署目录..."
cp "$PROJECT_DIR/app.py" "$DEPLOY_DIR/app.py"
cp "$PROJECT_DIR/templates/index.html" "$DEPLOY_DIR/templates/index.html"

# 1. 部署架构优化：创建 Python 虚拟环境 (venv)
echo ">>> 正在创建 Python 虚拟环境..."
python3 -m venv "$DEPLOY_DIR/venv"

echo ">>> 正在虚拟环境中安装依赖包..."
# 提升 pip 自身版本并安装 requirements.txt 内包
"$DEPLOY_DIR/venv/bin/pip" install --upgrade pip
"$DEPLOY_DIR/venv/bin/pip" install -r "$PROJECT_DIR/requirements.txt"

# 确保部署目录的所有者正确
sudo chown -R "$ACTUAL_USER:$ACTUAL_GROUP" "$DEPLOY_DIR"

echo ">>> 动态生成 systemd 服务配置文件..."
sed -e "s|{{USER}}|$ACTUAL_USER|g" \
    -e "s|{{GROUP}}|$ACTUAL_GROUP|g" \
    -e "s|{{DIR}}|$DEPLOY_DIR|g" \
    "$PROJECT_DIR/deploy/piomni.service" | sudo tee /etc/systemd/system/piomni.service > /dev/null

sudo systemctl daemon-reload
sudo systemctl enable --now piomni.service

echo ">>> Pi Omni Dashboard 已成功启动 (端口 5000)"
echo ">>> 访问: http://$(hostname -I | awk '{print $1}'):5000"
