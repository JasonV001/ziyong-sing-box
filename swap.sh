#!/bin/bash

# ============================================
# NAT VPS Swap 一键安装脚本
# 功能：自动创建、配置和管理Swap交换空间
# 版本：1.0
# ============================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 全局变量
SWAPFILE="/swapfile"
SWAPSIZE=""
SWAPPINESS="20"

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误：此脚本必须以root权限运行${NC}"
        echo -e "请使用 'sudo bash $0' 或切换至root用户"
        exit 1
    fi
}

# 显示当前系统信息
show_system_info() {
    echo -e "${BLUE}========== 系统信息 ==========${NC}"
    echo -e "主机名: $(hostname)"
    echo -e "系统: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    echo -e "内核: $(uname -r)"
    echo -e "内存: $(free -h | grep Mem | awk '{print $2}')"
    echo -e "磁盘空间: $(df -h / | tail -1 | awk '{print $4}') 可用"
    
    # 检查现有Swap
    existing_swap=$(free -h | grep Swap | awk '{print $2}')
    if [[ "$existing_swap" != "0B" && "$existing_swap" != "0" ]]; then
        echo -e "当前Swap: ${YELLOW}$existing_swap${NC}"
        echo -e "${YELLOW}警告：系统已存在Swap空间${NC}"
    else
        echo -e "当前Swap: ${GREEN}未配置${NC}"
    fi
    echo ""
}

# 检查现有Swap
check_existing_swap() {
    if swapon --show | grep -q "."; then
        echo -e "${YELLOW}检测到已激活的Swap：${NC}"
        swapon --show
        echo ""
        return 1
    fi
    return 0
}

# 选择Swap大小
select_swap_size() {
    local mem_total=$(free -m | grep Mem | awk '{print $2}')
    local recommended=$((mem_total * 2))
    
    echo -e "${BLUE}请选择Swap大小：${NC}"
    echo "1) 1GB (适合内存 < 512MB)"
    echo "2) 2GB (通用推荐)"
    echo "3) 4GB (适合数据库应用)"
    echo "4) 推荐大小 (内存的2倍: ${recommended}MB)"
    echo "5) 自定义大小"
    echo ""
    
    read -p "请输入选项 [1-5]: " choice
    
    case $choice in
        1) SWAPSIZE="1024" ;;
        2) SWAPSIZE="2048" ;;
        3) SWAPSIZE="4096" ;;
        4) SWAPSIZE="$recommended" ;;
        5)
            read -p "请输入Swap大小(MB): " custom_size
            if [[ ! $custom_size =~ ^[0-9]+$ ]] || [ $custom_size -lt 256 ]; then
                echo -e "${RED}错误：请输入大于256的数字${NC}"
                exit 1
            fi
            SWAPSIZE="$custom_size"
            ;;
        *)
            echo -e "${YELLOW}使用默认值2GB${NC}"
            SWAPSIZE="2048"
            ;;
    esac
    
    echo -e "${GREEN}已选择Swap大小: ${SWAPSIZE}MB ($((SWAPSIZE / 1024))GB)${NC}"
    echo ""
}

# 检查磁盘空间
check_disk_space() {
    local available_kb=$(df / | tail -1 | awk '{print $4}')
    local required_kb=$((SWAPSIZE * 1024))
    
    if [ $available_kb -lt $required_kb ]; then
        echo -e "${RED}错误：磁盘空间不足！${NC}"
        echo -e "需要: ${required_kb}KB, 可用: ${available_kb}KB"
        exit 1
    fi
    
    echo -e "${GREEN}磁盘空间检查通过${NC}"
}

# 创建Swap文件
create_swap_file() {
    echo -e "${BLUE}正在创建Swap文件...${NC}"
    
    # 如果已存在swapfile，先清理
    if [ -f "$SWAPFILE" ]; then
        echo -e "${YELLOW}发现已存在的swap文件，正在清理...${NC}"
        swapoff "$SWAPFILE" 2>/dev/null
        rm -f "$SWAPFILE"
    fi
    
    # 使用fallocate创建文件（比dd更快）
    if command -v fallocate &> /dev/null; then
        fallocate -l ${SWAPSIZE}M "$SWAPFILE"
    else
        dd if=/dev/zero of="$SWAPFILE" bs=1M count=$SWAPSIZE status=progress
    fi
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Swap文件创建失败${NC}"
        exit 1
    fi
    
    # 设置权限
    chmod 600 "$SWAPFILE"
    
    # 格式化Swap
    echo -e "${BLUE}正在格式化Swap...${NC}"
    mkswap "$SWAPFILE"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Swap格式化失败${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Swap文件创建成功${NC}"
}

# 启用Swap
enable_swap() {
    echo -e "${BLUE}正在启用Swap...${NC}"
    swapon "$SWAPFILE"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Swap启用失败${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Swap已成功启用${NC}"
}

# 配置系统参数
configure_system() {
    echo -e "${BLUE}正在配置系统参数...${NC}"
    
    # 添加到fstab实现开机自动挂载
    if ! grep -q "$SWAPFILE" /etc/fstab; then
        echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
        echo -e "${GREEN}已添加至/etc/fstab${NC}"
    fi
    
    # 调整swappiness
    echo "vm.swappiness=$SWAPPINESS" >> /etc/sysctl.conf
    sysctl -p
    
    echo -e "${GREEN}系统参数配置完成${NC}"
}

# 显示安装结果
show_result() {
    echo -e "${GREEN}========== 安装完成 ==========${NC}"
    echo -e "Swap文件: $SWAPFILE"
    echo -e "Swap大小: ${SWAPSIZE}MB"
    echo -e "swappiness: $SWAPPINESS"
    echo ""
    
    echo -e "${BLUE}当前内存状态：${NC}"
    free -h
    
    echo ""
    echo -e "${YELLOW}验证命令：${NC}"
    echo "查看Swap状态: free -h 或 swapon --show"
    echo "查看swappiness: cat /proc/sys/vm/swappiness"
    echo ""
    
    echo -e "${YELLOW}重要提示：${NC}"
    echo "1. Swap使用硬盘空间模拟内存，速度较慢"
    echo "2. 仅作为应急用途，长期内存不足应考虑升级配置"
    echo "3. 监控命令: watch -n 1 free -h"
}

# 删除Swap
remove_swap() {
    echo -e "${YELLOW}正在移除Swap配置...${NC}"
    
    if [ -f "$SWAPFILE" ]; then
        swapoff "$SWAPFILE"
        rm -f "$SWAPFILE"
        
        # 从fstab中删除
        sed -i "\|$SWAPFILE|d" /etc/fstab
        
        echo -e "${GREEN}Swap已成功移除${NC}"
    else
        echo -e "${RED}未找到Swap文件${NC}"
    fi
}

# 主菜单
main_menu() {
    clear
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN}    NAT VPS Swap 管理脚本       ${NC}"
    echo -e "${GREEN}=================================${NC}"
    echo ""
    
    show_system_info
    
    echo -e "${BLUE}请选择操作：${NC}"
    echo "1) 安装/配置Swap"
    echo "2) 删除现有Swap"
    echo "3) 查看当前状态"
    echo "4) 退出"
    echo ""
    
    read -p "请输入选项 [1-4]: " main_choice
    
    case $main_choice in
        1)
            if check_existing_swap; then
                select_swap_size
                check_disk_space
                create_swap_file
                enable_swap
                configure_system
                show_result
            else
                echo -e "${YELLOW}系统已存在Swap，如需重新配置请先删除现有Swap${NC}"
            fi
            ;;
        2)
            remove_swap
            ;;
        3)
            echo -e "${BLUE}当前系统状态：${NC}"
            free -h
            echo ""
            echo -e "${BLUE}Swap文件信息：${NC}"
            swapon --show
            echo ""
            echo -e "swappiness: $(cat /proc/sys/vm/swappiness 2>/dev/null || echo '未设置')"
            ;;
        4)
            echo "退出脚本"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项${NC}"
            ;;
    esac
}

# 脚本入口
check_root
main_menu

# 等待用户操作
echo ""
read -p "按Enter键继续..." 