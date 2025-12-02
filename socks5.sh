#!/usr/bin/env bash
set -e

PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

# 颜色
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[0;33m"
CYAN="\033[0;36m"
RESET="\033[0m"

INFO="${GREEN}[信息]${RESET}"
ERROR="${RED}[错误]${RESET}"
WARNING="${YELLOW}[警告]${RESET}"

# 全局变量
SOCKS5_CONFIG_FILE="/etc/danted.conf"
SOCKS5_INFO_FILE="/etc/danted.info"
SOCKS5_SERVICE_NAME="danted"
SOCKS5_DEFAULT_PORT="1080"
DANTE_CMD=""

# 基础函数
check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${ERROR} 请以 root 或 sudo 运行本脚本"
    exit 1
  fi
}

detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    DISTRO_ID=${ID,,}
    DISTRO_LIKE=${ID_LIKE,,}
  else
    DISTRO_ID=""
    DISTRO_LIKE=""
  fi
}

has_systemctl() {
  command -v systemctl >/dev/null 2>&1
}

check_cmds_or_exit() {
  local NEED_CMDS=("$@")
  local missing=()
  for c in "${NEED_CMDS[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  detect_distro
  echo -e "${INFO} 缺少命令：${missing[*]}，尝试自动安装..."

  if [[ "$DISTRO_ID" == "alpine" || "$DISTRO_LIKE" == "alpine" ]]; then
    apk update -q || true
    apk add --no-cache "${missing[@]}" || {
      echo -e "${ERROR} apk 安装依赖失败：${missing[*]}"
      exit 1
    }
  elif [[ "$DISTRO_ID" =~ (debian|ubuntu) || "$DISTRO_LIKE" =~ (debian|ubuntu) ]]; then
    apt-get update -y -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" || {
      echo -e "${ERROR} apt-get 安装依赖失败：${missing[*]}"
      exit 1
    }
  else
    echo -e "${ERROR} 未识别发行版，无法自动安装依赖：${missing[*]}"
    exit 1
  fi
}

check_port_free() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH "sport = :$port" | grep -q . && return 1 || return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn | awk '{print $4}' | grep -q ":$port\$" && return 1 || return 0
  else
    return 0
  fi
}

get_server_ip_simple() {
  local ip4
  ip4=$(curl -s4 icanhazip.com 2>/dev/null || curl -s4 ip.sb 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
  echo "$ip4"
}

# 检测 Dante 可执行文件
find_dante_cmd() {
  if command -v danted >/dev/null 2>&1; then
    DANTE_CMD=$(command -v danted)
    return 0
  fi
  if command -v sockd >/dev/null 2>&1; then
    DANTE_CMD=$(command -v sockd)
    return 0
  fi
  echo -e "${ERROR} 未找到 danted 或 sockd，可执行文件；请确认 dante-server 是否安装成功"
  return 1
}

# 安装 dante-server
install_dante_core() {
  detect_distro
  echo -e "${INFO} 正在安装 SOCKS5 (Dante) 服务端依赖..."
  if [[ "$DISTRO_ID" == "alpine" || "$DISTRO_LIKE" == "alpine" ]]; then
    apk update -q || true
    apk add --no-cache dante-server iproute2 || {
      echo -e "${ERROR} apk 安装 dante-server 失败"
      return 1
    }
  elif [[ "$DISTRO_ID" =~ (debian|ubuntu) || "$DISTRO_LIKE" =~ (debian|ubuntu) ]]; then
    apt-get update -y -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends dante-server iproute2 || {
      echo -e "${ERROR} apt-get 安装 dante-server 失败（可能是内存不足，建议增加 swap）"
      return 1
    }
  else
    echo -e "${ERROR} 未识别或暂不支持的发行版，仅支持 Debian/Ubuntu/Alpine"
    return 1
  fi
  return 0
}

# 交互获取端口/账号
prompt_socks5() {
  echo -e "${CYAN}=== SOCKS5 (Dante) 参数配置 ===${RESET}"
  local port user pass
  local default_port="$SOCKS5_DEFAULT_PORT"

  while true; do
    read -rp "SOCKS5 监听端口（留空则使用 ${default_port}）: " port
    port="${port:-$default_port}"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
      echo -e "${ERROR} 端口必须是 1-65535 的数字"
      continue
    fi
    if ! check_port_free "$port"; then
      echo -e "${ERROR} 端口 ${port} 已被占用，请重新选择"
      continue
    fi
    SOCKS5_PORT="$port"
    break
  done

  check_cmds_or_exit openssl

  # 用户名：可手动输入，留空则自动生成 hex
  while true; do
    read -rp "SOCKS5 用户名（留空则自动生成 hex，仅允许字母数字下划线）: " user
    if [[ -z "$user" ]]; then
      SOCKS5_USER=$(openssl rand -hex 4)
      echo -e "${INFO} 已自动生成 SOCKS5 用户名 (hex): ${SOCKS5_USER}"
      break
    fi
    if ! [[ "$user" =~ ^[a-zA-Z0-9_]+$ ]]; then
      echo -e "${ERROR} 用户名仅允许字母、数字和下划线"
      continue
    fi
    SOCKS5_USER="$user"
    break
  done

  # 密码：可手动输入，留空则自动生成 hex
  while true; do
    read -rsp "SOCKS5 密码（留空则自动生成 hex）: " pass
    echo
    if [[ -z "$pass" ]]; then
      SOCKS5_PASS=$(openssl rand -hex 8)
      echo -e "${INFO} 已自动生成 SOCKS5 密码 (hex): ${SOCKS5_PASS}"
      break
    fi
    SOCKS5_PASS="$pass"
    break
  done
}

# 创建本地用户
create_socks5_user() {
  if id "$SOCKS5_USER" >/dev/null 2>&1; then
    userdel -r -f "$SOCKS5_USER" >/dev/null 2>&1 || true
  fi
  useradd -m -s /bin/false "$SOCKS5_USER" >/dev/null 2>&1 || true
  echo -e "${SOCKS5_PASS}\n${SOCKS5_PASS}" | passwd "$SOCKS5_USER" >/dev/null 2>&1 || true
}

# 写 danted 配置
write_socks5_config() {
  local iface
  iface=$(ip -4 route ls 2>/dev/null | grep default | grep -Po '(?<=dev )\S+' | head -n 1 || true)
  iface="${iface:-eth0}"

  cat >"$SOCKS5_CONFIG_FILE" <<EOF
logoutput: /var/log/socks.log
internal: 0.0.0.0 port = ${SOCKS5_PORT}
external: ${iface}
socksmethod: username
user.privileged: root
user.notprivileged: nobody

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: error connect disconnect
}

client block {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: connect error
}

socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: error connect disconnect
}

socks block {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: connect error
}
EOF

  cat >"$SOCKS5_INFO_FILE" <<EOF
PORT=${SOCKS5_PORT}
USER=${SOCKS5_USER}
PASS=${SOCKS5_PASS}
EOF
}

# 启停
start_socks5() {
  if has_systemctl; then
    systemctl restart "$SOCKS5_SERVICE_NAME" 2>/dev/null || systemctl start "$SOCKS5_SERVICE_NAME" 2>/dev/null || true
    sleep 1
    if systemctl is-active --quiet "$SOCKS5_SERVICE_NAME"; then
      echo -e "${INFO} SOCKS5 (Dante) 服务已启动"
    else
      echo -e "${ERROR} SOCKS5 (Dante) 服务启动失败，请执行：journalctl -u ${SOCKS5_SERVICE_NAME} -n 20 --no-pager"
    fi
  else
    if ! find_dante_cmd; then
      return 1
    fi
    pkill -f "danted" 2>/dev/null || true
    pkill -f "sockd" 2>/dev/null || true
    nohup "$DANTE_CMD" -f "$SOCKS5_CONFIG_FILE" >/var/log/danted.log 2>&1 &
    echo -e "${INFO} SOCKS5 (Dante) 已在后台启动（无 systemd），日志：/var/log/danted.log"
  fi
}

stop_socks5() {
  if has_systemctl; then
    systemctl stop "$SOCKS5_SERVICE_NAME" 2>/dev/null || true
    echo -e "${INFO} SOCKS5 (Dante) systemd 服务已停止"
  else
    pkill -f "danted" 2>/dev/null || true
    pkill -f "sockd" 2>/dev/null || true
    echo -e "${INFO} SOCKS5 (Dante) 后台进程已停止"
  fi
}

restart_socks5() {
  stop_socks5
  start_socks5
}

show_socks5_info() {
  if [[ ! -f "$SOCKS5_INFO_FILE" ]]; then
    echo -e "${WARNING} 未找到 SOCKS5 信息文件：${SOCKS5_INFO_FILE}，可能尚未安装节点"
    return
  fi
  # shellcheck disable=SC1090
  . "$SOCKS5_INFO_FILE"

  local ip4
  ip4=$(get_server_ip_simple)

  echo -e "${CYAN}SOCKS5 (Dante) 节点信息：${RESET}"
  echo -e "  协议: socks5"
  echo -e "  地址: ${ip4:-你的服务器 IP}"
  echo -e "  端口: ${PORT}"
  echo -e "  用户名: ${USER}"
  echo -e "  密码: ${PASS}"
}

uninstall_socks5() {
  echo -e "${WARNING} 即将卸载 SOCKS5 (Dante) 节点..."
  read -rp "确认卸载 SOCKS5 ? (y/N): " c
  if [[ ! "$c" =~ ^[Yy]$ ]]; then
    echo -e "${INFO} 已取消"
    return
  fi

  stop_socks5
  detect_distro
  if [[ "$DISTRO_ID" == "alpine" || "$DISTRO_LIKE" == "alpine" ]]; then
    apk del dante-server 2>/dev/null || true
  elif [[ "$DISTRO_ID" =~ (debian|ubuntu) || "$DISTRO_LIKE" =~ (debian|ubuntu) ]]; then
    apt-get remove --purge -y dante-server 2>/dev/null || true
  fi
  rm -f "$SOCKS5_CONFIG_FILE" "$SOCKS5_INFO_FILE"
  echo -e "${INFO} SOCKS5 (Dante) 节点已卸载完成"
}

install_socks5_flow() {
  check_cmds_or_exit ip passwd
  if ! install_dante_core; then
    return
  fi
  prompt_socks5
  create_socks5_user
  write_socks5_config
  start_socks5
  echo -e "${INFO} SOCKS5 (Dante) 节点已安装并启动"
  show_socks5_info
}

# 菜单
main_menu() {
  while true; do
    echo -e "${CYAN}=== SOCKS5 (Dante) 管理脚本 ===${RESET}"
    echo "1) 安装 / 重新安装 SOCKS5 (Dante) 节点"
    echo "2) 查看节点信息"
    echo "3) 启动节点"
    echo "4) 停止节点"
    echo "5) 重启节点"
    echo "6) 卸载节点"
    echo "0) 退出"
    read -rp "请选择: " c
    case "$c" in
      1) install_socks5_flow ;;
      2) show_socks5_info ;;
      3) start_socks5 ;;
      4) stop_socks5 ;;
      5) restart_socks5 ;;
      6) uninstall_socks5 ;;
      0) exit 0 ;;
      *) echo -e "${ERROR} 无效选项" ;;
    esac
    echo
  done
}

# 入口
check_root
main_menu
