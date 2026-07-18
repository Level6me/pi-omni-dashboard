#!/bin/bash
set -e

ACTION=${1:-install}
DEPLOY_DIR="$HOME/pi_omni"
REPO_DIR="/tmp/pi-omni-dashboard-repo"
REPO_URL="https://github.com/Level6me/pi-omni-dashboard.git"
SERVICE_NAME="piomni.service"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

function do_install() {
    echo -e "${YELLOW}>>> 开始安装 Pi Omni Dashboard...${NC}"
    
    # 检查环境
    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}未检测到 python3，请先执行 sudo apt install python3 -y${NC}"
        exit 1
    fi
    if ! command -v git &> /dev/null; then
        echo -e "${RED}未检测到 git，请先执行 sudo apt install git -y${NC}"
        exit 1
    fi

    # 清理并拉取最新代码
    rm -rf "$REPO_DIR"
    echo ">>> 正在拉取源码..."
    git clone "$REPO_URL" "$REPO_DIR"
    
    # 执行原生安装脚本
    cd "$REPO_DIR"
    chmod +x deploy/install.sh
    ./deploy/install.sh 5000
    
    rm -rf "$REPO_DIR"
    echo -e "${GREEN}================ 安装完成 ==================${NC}"
    echo -e "若需更新代码，请执行: ${YELLOW}bash <(curl -sL https://raw.githubusercontent.com/Level6me/pi-omni-dashboard/main/install.sh) update${NC}"
    echo -e "若需完全卸载，请执行: ${YELLOW}bash <(curl -sL https://raw.githubusercontent.com/Level6me/pi-omni-dashboard/main/install.sh) uninstall${NC}"
}

function do_update() {
    echo -e "${YELLOW}>>> 正在更新 Pi Omni Dashboard...${NC}"
    if [ ! -d "$DEPLOY_DIR" ]; then
        echo -e "${RED}未找到部署目录 $DEPLOY_DIR，请先使用 install 命令进行安装。${NC}"
        exit 1
    fi
    
    rm -rf "$REPO_DIR"
    git clone "$REPO_URL" "$REPO_DIR"
    
    echo ">>> 正在覆盖最新的核心文件..."
    cp "$REPO_DIR/app.py" "$DEPLOY_DIR/app.py"
    cp "$REPO_DIR/templates/index.html" "$DEPLOY_DIR/templates/index.html"
    if [ -f "$REPO_DIR/project_info.json" ]; then
        cp "$REPO_DIR/project_info.json" "$DEPLOY_DIR/project_info.json"
    fi
    
    echo ">>> 同步最新依赖包..."
    "$DEPLOY_DIR/venv/bin/pip" install -r "$REPO_DIR/requirements.txt"
    
    echo ">>> 正在重启系统服务..."
    sudo systemctl restart $SERVICE_NAME
    
    rm -rf "$REPO_DIR"
    echo -e "${GREEN}================ 更新成功 ==================${NC}"
}

function do_uninstall() {
    echo -e "${YELLOW}>>> 正在卸载 Pi Omni Dashboard...${NC}"
    sudo systemctl stop $SERVICE_NAME || true
    sudo systemctl disable $SERVICE_NAME || true
    sudo rm -f /etc/systemd/system/$SERVICE_NAME
    sudo systemctl daemon-reload
    
    echo ">>> 正在删除文件目录..."
    rm -rf "$DEPLOY_DIR"
    echo -e "${GREEN}================ 卸载成功 ==================${NC}"
    echo -e "所有服务及残留文件均已清除。"
}

case "$ACTION" in
    install)
        do_install
        ;;
    update)
        do_update
        ;;
    uninstall)
        do_uninstall
        ;;
    *)
        echo -e "${RED}未知命令: $ACTION。可用命令: install, update, uninstall${NC}"
        exit 1
        ;;
esac
