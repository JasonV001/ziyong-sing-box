#!/usr/bin/env bash
set -e

PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[0;33m"
CYAN="\033[0;36m"
RESET="\033[0m"

INFO="${GREEN}[信息]${RESET}"
ERROR="${RED}[错误]${RESET}"
WARNING="${YELLOW}[警告]${RESET}"

# ==== 配置 ====
MICROSOCKS_BIN="/usr/local/bin/microsocks"
MICROSOCKS_URL="https://github.com/rofl0r/microsocks/releases/latest/download/microsocks"  # x86_64 Linux 通用版
MICROSOCKS_INFO="/etc/microsocks.info"
MICROSOCKS_LOG="/var/log/microsocks.log"

MS_PORT_DEFAULT="1080"

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

install_microsocks_bin() {
  if [[ -x "$MICROSOCKS_BIN" ]]; then
    echo -e "${INFO} 已检测到 microsocks：$MICROSOCKS_BIN"
    return 0
  fi

  check_cmds_or_exit curl
  echo -e "${INFO} 正在下载 microsocks 二进制..."
  curl -L "$MICROSOCKS_URL" -o "$MICROSOCKS_BIN"
  chmod +x "$MICROSOCKS_BIN"
  echo -e "${INFO} microsocks 已安装到：$MICROSOCKS_BIN"
}

prompt_microsocks() {
  echo -e "${CYAN}=== microsocks 参数配置 ===${RESET}"
  local port user pass

  while true; do
    read -rp "SOCKS5 监听端口（留空则使用 ${MS_PORT_DEFAULT}）: " port
    port="${port:-$MS_PORT_DEFAULT}"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
      echo -e "${ERROR} 端口必须是 1-65535 的数字"
      continue
    fi
    if ! check_port_free "$port"; then
      echo -e "${ERROR} 端口 ${port} 已被占用，请重新选择"
      continue
    fi
    MS_PORT="$port"
    break
  done

  check_cmds_or_exit openssl

  # 用户名：可手动输入，留空则自动生成 hex
  while true; do
    read -rp "SOCKS5 用户名（留空则自动生成 hex，仅允许字母数字下划线）: " user
    if [[ -z "$user" ]]; then
      MS_USER=$(openssl rand -hex 4)
      echo -e "${INFO} 已自动生成用户名 (hex): ${MS_USER}"
      break
    fi
    if ! [[ "$user" =~ ^[a-zA-Z0-9_]+$ ]]; then
      echo -e "${ERROR} 用户名仅允许字母、数字和下划线"
      continue
    fi
    MS_USER="$user"
    break
  done

  # 密码：可手动输入，留空则自动生成 hex
  while true; do
    read -rsp "SOCKS5 密码（留空则自动生成 hex）: " pass
    echo
    if [[ -z "$pass" ]]; then
      MS_PASS=$(openssl rand -hex 8)
      echo -e "${INFO} 已自动生成密码 (hex): ${MS_PASS}"
      break
    fi
    MS_PASS="$pass"
    break
  done

  cat >"$MICROSOCKS_INFO" <<EOF
PORT=${MS_PORT}
USER=${MS_USER}
PASS=${MS_PASS}
EOF
}

start_microsocks() {
  if [[ ! -f "$MICROSOCKS_INFO" ]]; then
    echo -e "${WARNING} 未找到配置，将重新配置 microsocks"
    prompt_microsocks
  else
    # shellcheck disable=SC1090
    . "$MICROSOCKS_INFO"
    MS_PORT="${PORT}"
    MS_USER="${USER}"
    MS_PASS="${PASS}"
  fi

  pkill -f "$MICROSOCKS_BIN" 2>/dev/null || true

  if [[ -n "$MS_USER" ]]; then
    nohup "$MICROSOCKS_BIN" -1 -p "$MS_PORT" -u "$MS_USER" -P "$MS_PASS" >"$MICROSOCKS_LOG" 2>&1 &
  else
    nohup "$MICROSOCKS_BIN" -1 -p "$MS_PORT" >"$MICROSOCKS_LOG" 2>&1 &
  fi

  echo -e "${INFO} microsocks 已在后台启动，日志：$MICROSOCKS_LOG"
}

stop_microsocks() {
  pkill -f "$MICROSOCKS_BIN" 2>/dev/null || true
  echo -e "${INFO} microsocks 后台进程已停止"
}

restart_microsocks() {
  stop_microsocks
  start_microsocks
}

show_microsocks_info() {
  if [[ ! -f "$MICROSOCKS_INFO" ]]; then
    echo -e "${WARNING} 未找到 microsocks 信息文件：${MICROSOCKS_INFO}"
    return
  fi
  # shellcheck disable=SC1090
  . "$MICROSOCKS_INFO"

  local ip4
  ip4=$(get_server_ip_simple)

  echo -e "${CYAN}microsocks 节点信息：${RESET}"
  echo -e "  协议: socks5"
  echo -e "  地址: ${ip4:-你的服务器 IP}"
  echo -e "  端口: ${PORT}"
  if [[ -n "$USER" ]]; then
    echo -e "  用户名: ${USER}"
    echo -e "  密码: ${PASS}"
  else
    echo -e "  认证: 无用户名密码（不推荐对公网）"
  fi
}

uninstall_microsocks() {
  echo -e "${WARNING} 即将卸载 microsocks 节点..."
  read -rp "确认卸载 ? (y/N): " c
  if [[ ! "$c" =~ ^[Yy]$ ]]; then
    echo -e "${INFO} 已取消"
    return
  fi

  stop_microsocks
  rm -f "$MICROSOCKS_BIN" "$MICROSOCKS_INFO" "$MICROSOCKS_LOG"
  echo -e "${INFO} microsocks 节点已卸载完成（不再提供 SOCKS5 服务）"
}

install_flow() {
  install_microsocks_bin
  prompt_microsocks
  start_microsocks
  show_microsocks_info
}

main_menu() {
  while true; do
    echo -e "${CYAN}=== microsocks SOCKS5 管理脚本 ===${RESET}"
    echo "1) 安装 / 重新安装 microsocks 节点"
    echo "2) 查看节点信息"
    echo "3) 启动节点"
    echo "4) 停止节点"
    echo "5) 重启节点"
    echo "6) 卸载节点"
    echo "0) 退出"
    read -rp "请选择: " c
    case "$c" in
      1) install_flow ;;
      2) show_microsocks_info ;;
      3) start_microsocks ;;
      4) stop_microsocks ;;
      5) restart_microsocks ;;
      6) uninstall_microsocks ;;
      0) exit 0 ;;
      *) echo -e "${ERROR} 无效选项" ;;
    esac
    echo
  done
}

check_root
main_menu
