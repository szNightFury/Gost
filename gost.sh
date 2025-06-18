#!/bin/bash

# ==============================================================================
# Gost 脚本 (安装/管理/卸载)
# 版本：v1.1
#
# 功能：
# - 一键安装/更新 Gost 程序
# - 配置端口转发规则（TCP/UDP）
# - 启动、停止、重启、查看状态、日志
# - 卸载 Gost 服务及程序
#
# 使用方法:
#   chmod +x gost-helper.sh
#   sudo ./gost-helper.sh
# ==============================================================================

# --- 配置 ---
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
NC="\033[0m" # No Color
SERVICE_FILE="/etc/systemd/system/gost.service"

# --- 函数定义 ---

# 检查是否以 root 权限运行
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本必须以 root 权限运行。请使用 'sudo ./gost-helper.sh'${NC}"
        exit 1
    fi
}

# 检查服务文件是否存在
check_service_file() {
    if [ ! -f "$SERVICE_FILE" ]; then
        echo -e "${YELLOW}Gost 服务尚未安装。请先选择 '1' 来安装服务。${NC}"
        return 1
    fi
    return 0
}

# 1. 安装或更新服务
install_or_update_service() {
    echo -e "${YELLOW}--- 开始安装或更新 Gost 转发服务 ---${NC}"

    # 步骤 1: 安装 Gost 程序
    if ! command -v gost &> /dev/null; then
        echo "Gost 程序未找到，正在下载最新版本..."
        ARCH=$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')
        gost_version_tag=$(wget -qO- "https://api.github.com/repos/go-gost/gost/releases/latest" | grep -oP '"tag_name": "\K(v[0-9.]*)')
        if [[ -z "$gost_version_tag" ]]; then echo -e "${RED}从 GitHub API 获取 Gost 版本失败。${NC}"; exit 1; fi
        gost_version=${gost_version_tag#v}
        
        echo "正在下载 Gost v${gost_version} for ${ARCH}..."
        wget --no-check-certificate -O gost.tar.gz "https://github.com/go-gost/gost/releases/download/${gost_version_tag}/gost_${gost_version}_linux_${ARCH}.tar.gz" || { echo -e "${RED}下载 Gost 失败。${NC}"; exit 1; }
        
        tar -zxvf gost.tar.gz
        mv gost /usr/local/bin/
        chmod +x /usr/local/bin/gost
        rm gost.tar.gz
        echo -e "${GREEN}Gost 程序安装成功! 版本: $(gost -V)${NC}"
    else
        echo -e "${GREEN}Gost 程序已安装。${NC}"
    fi

    # 步骤 2: 配置内核参数
    echo "正在配置内核转发参数..."
    if ! grep -q "^net.ipv4.ip_forward=1$" /etc/sysctl.conf; then echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf; fi
    if ! grep -q "^net.ipv6.conf.all.forwarding=1$" /etc/sysctl.conf; then echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf; fi
    sysctl -p > /dev/null
    echo -e "${GREEN}内核参数配置完成。${NC}"

    # 步骤 3: 获取用户输入
    echo ""
    read -p "请输入目标服务器的域名或 IP 地址: " TARGET_HOST
    if [[ -z "$TARGET_HOST" ]]; then echo -e "${RED}错误: 目标地址不能为空。${NC}"; return; fi

    echo "请输入端口转发规则 (多条规则用空格分开, 例如: 80:8080 443:8443 10001-10005:30001-30005"
    read -p "请输入规则: " -a PORT_RULES
    if [ ${#PORT_RULES[@]} -eq 0 ]; then echo -e "${RED}错误: 未输入任何规则。${NC}"; return; fi

    GOST_ARGS=""
    for rule in "${PORT_RULES[@]}"; do
        local_port="${rule%%:*}"; target_port="${rule##*:}"
        GOST_ARGS+="-L tcp://:${local_port}/${TARGET_HOST}:${target_port} "
        GOST_ARGS+="-L udp://:${local_port}/${TARGET_HOST}:${target_port} "
    done

    # 步骤 4: 创建/覆盖服务文件
    echo "正在创建/更新 Systemd 服务文件..."
    cat << EOF > ${SERVICE_FILE}
[Unit]
Description=Gost Proxy/Forwarding Service
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost ${GOST_ARGS}
Restart=always
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # 步骤 5: 重载并启动服务
    echo "正在重载 Systemd 并启动服务..."
    systemctl daemon-reload
    systemctl restart gost
    systemctl enable gost

    echo -e "${GREEN}Gost 服务已成功安装/更新并启动！${NC}"
    echo "你可以选择 '5' 查看服务的当前状态。"
}

# 6. 查看实时日志
view_logs() {
    if ! check_service_file; then return; fi
    echo -e "${YELLOW}正在显示实时日志... 按 Ctrl+C 退出。${NC}"
    journalctl -u gost.service -f --no-pager
}

# 7. 卸载服务
uninstall_service() {
    if ! check_service_file; then return; fi
    echo -e "${RED}警告：此操作将彻底删除 Gost 服务和相关配置！${NC}"
    read -p "您确定要继续吗? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then echo "操作已取消。"; return; fi

    echo "正在停止并禁用 Gost 服务..."
    systemctl stop gost
    systemctl disable gost
    echo "正在删除服务文件..."
    rm -f ${SERVICE_FILE}
    echo "正在重载 Systemd..."
    systemctl daemon-reload
    echo -e "${GREEN}Gost 服务已成功卸载。${NC}"

    read -p "是否要一并删除 /usr/local/bin/gost 程序本身? [y/N]: " confirm_bin
    if [[ "$confirm_bin" == "y" || "$confirm_bin" == "Y" ]]; then
        rm -f /usr/local/bin/gost
        echo "/usr/local/bin/gost 已删除。"
    fi

    echo "内核转发参数保留在 /etc/sysctl.conf 中，通常无需改动。"
}

# 主菜单
main_menu() {
    clear
    echo "======================================="
    echo "             Gost 脚本 v1.0             "
    echo "======================================="
    echo " 1. 安装 / 更新 Gost 转发配置"
    echo " 2. 启动 Gost 服务"
    echo " 3. 停止 Gost 服务"
    echo " 4. 重启 Gost 服务"
    echo " 5. 查看 Gost 服务状态"
    echo " 6. 查看 Gost 实时日志"
    echo " 7. 卸载 Gost 服务"
    echo " q. 退出脚本"
    echo "---------------------------------------"
}

# --- 主逻辑 ---
check_root

while true; do
    main_menu
    read -p "请输入您的选择 [1-7, q]: " choice

    case $choice in
        1) install_or_update_service ;;
        2) if check_service_file; then systemctl start gost; systemctl status gost --no-pager; fi ;;
        3) if check_service_file; then systemctl stop gost; systemctl status gost --no-pager; fi ;;
        4) if check_service_file; then systemctl restart gost; sleep 1; systemctl status gost --no-pager; fi ;;
        5) if check_service_file; then systemctl status gost; fi ;;
        6) view_logs ;;
        7) uninstall_service ;;
        q|Q) echo "退出。"; exit 0 ;;
        *) echo -e "${RED}无效输入，请重新选择。${NC}" ;;
    esac
    
    echo -e "${YELLOW}\n按任意键返回主菜单...${NC}"
    read -n 1 -s
done
