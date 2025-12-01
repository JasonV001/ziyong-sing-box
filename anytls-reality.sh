#!/usr/bin/env bash
set -e

PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# ===== 颜色 & 提示 =====
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[0;33m"
CYAN="\033[0;36m"
RESET="\033[0m"

INFO="${GREEN}[信息]${RESET}"
ERROR="${RED}[错误]${RESET}"
WARNING="${YELLOW}[警告]${RESET}"

# ===== 全局路径 =====
# AnyTLS (anytls-go)
ANYTLS_INSTALL_DIR="/usr/local/bin"
ANYTLS_BINARY_NAME="anytls-server"
ANYTLS_CONFIG_DIR="/etc/anytls"
ANYTLS_CONFIG_FILE="${ANYTLS_CONFIG_DIR}/config"
ANYTLS_SERVICE_FILE="/etc/systemd/system/anytls.service"
ANYTLS_LISTEN_ADDR="[::]"
ANYTLS_LISTEN_PORT="8443"
ANYTLS_PASSWORD=""
ANYTLS_TMP_DIR="/tmp/anytls"
ANYTLS_VERSION=""
ANYTLS_SNI=""
ANYTLS_INSECURE="1"

# Reality (sing-box vless-reality)
SINGBOX_EXPECTED="/usr/local/bin/sing-box"
SINGBOX_CONFIG_DIR="/usr/local/etc/sing-box"
SINGBOX_REALITY_CONF="${SINGBOX_CONFIG_DIR}/reality.json"
SINGBOX_REALITY_INFO="${SINGBOX_CONFIG_DIR}/reality.info"
SINGBOX_REALITY_SERVICE="/etc/systemd/system/sing-box-reality.service"
SINGBOX_CMD=""

# 脚本自更新地址
SCRIPT_URL="https://raw.githubusercontent.com/JasonV001/ziyong-sing-box/refs/heads/main/anytls-reality"
SCRIPT_PATH="/usr/local/bin/anytls-reality.sh"

# ===== 通用基础函数 =====
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

install_missing_pkgs() {
  local pkgs=("$@")
  local to_install=()
  for p in "${pkgs[@]}"; do
    if ! command -v "$p" >/dev/null 2>&1; then
      to_install+=("$p")
    fi
  done
  [[ ${#to_install[@]} -eq 0 ]] && return 0

  detect_distro
  echo -e "${INFO} 检测到缺少命令：${to_install[*]}，尝试自动安装..."

  if [[ "$DISTRO_ID" == "alpine" || "$DISTRO_LIKE" == "alpine" ]]; then
    apk update -q || true
    apk add --no-cache "${to_install[@]}" || {
      echo -e "${ERROR} apk 安装依赖失败：${to_install[*]}"
      return 1
    }
  elif [[ "$DISTRO_ID" =~ (debian|ubuntu) || "$DISTRO_LIKE" =~ (debian|ubuntu) ]]; then
    apt-get update -y -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${to_install[@]}" || {
      echo -e "${ERROR} apt-get 安装依赖失败：${to_install[*]}"
      return 1
    }
  elif [[ "$DISTRO_ID" =~ (centos|rhel|rocky|almalinux|fedora) || "$DISTRO_LIKE" =~ (rhel|fedora|centos) ]]; then
    local PM="yum"
    command -v dnf >/dev/null 2>&1 && PM="dnf"
    $PM install -y "${to_install[@]}" || {
      echo -e "${ERROR} ${PM} 安装依赖失败：${to_install[*]}"
      return 1
    }
  else
    echo -e "${WARNING} 未识别发行版，无法自动安装依赖：${to_install[*]}"
    return 1
  fi
  return 0
}

check_cmds_or_exit() {
  local NEED_CMDS=("$@")
  local missing=()
  for c in "${NEED_CMDS[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing+=("$c")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  if ! install_missing_pkgs "${missing[@]}"; then
    echo -e "${ERROR} 自动安装依赖失败：${missing[*]}"
    exit 1
  fi

  local still_missing=()
  for c in "${NEED_CMDS[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      still_missing+=("$c")
    fi
  done
  if [[ ${#still_missing[@]} -gt 0 ]]; then
    echo -e "${ERROR} 仍缺少以下命令，请手动安装后再运行："
    printf '  - %s\n' "${still_missing[@]}"
    exit 1
  fi
}

get_server_ip_simple() {
  local ip4
  ip4=$(curl -s4 icanhazip.com || curl -s4 ip.sb || hostname -I 2>/dev/null | awk '{print $1}')
  echo "$ip4"
}

has_systemctl() {
  command -v systemctl >/dev/null 2>&1
}

# ===== AnyTLS (anytls-go) 部分 =====

get_anytls_arch() {
  case "$(uname -m)" in
    x86_64) echo "amd64" ;;
    aarch64) echo "arm64" ;;
    *) echo -e "${ERROR} AnyTLS: 不支持的架构 $(uname -m)"; exit 1 ;;
  esac
}

get_anytls_latest_version() {
  local raw v
  raw=$(curl -s "https://api.github.com/repos/anytls/anytls-go/releases/latest" | grep '"tag_name"' | head -n 1)
  v=$(echo "$raw" | sed -n 's/.*"tag_name":[[:space:]]*"\(v\{0,1\}\([0-9.]\+\)\)".*/\2/p')
  if [[ -z "$v" ]]; then
    echo "[WARN] 无法获取 AnyTLS 最新版本，使用默认 0.0.8" >&2
    echo "0.0.8"
  else
    echo "$v"
  fi
}

download_anytls() {
  check_cmds_or_exit wget curl unzip openssl
  ANYTLS_VERSION=$(get_anytls_latest_version)
  local arch
  arch=$(get_anytls_arch)
  local zip="anytls_${ANYTLS_VERSION}_linux_${arch}.zip"
  local url="https://github.com/anytls/anytls-go/releases/download/v${ANYTLS_VERSION}/${zip}"

  echo -e "${INFO} 正在下载 AnyTLS: ${zip}"
  mkdir -p "$ANYTLS_TMP_DIR"
  wget -O "${ANYTLS_TMP_DIR}/${zip}" "$url" || {
    echo -e "${ERROR} AnyTLS 下载失败"
    exit 1
  }

  echo -e "${INFO} 解压 AnyTLS..."
  unzip -o "${ANYTLS_TMP_DIR}/${zip}" -d "${ANYTLS_TMP_DIR}" >/dev/null 2>&1 || {
    echo -e "${ERROR} 解压失败，请确保 unzip 已安装"
    exit 1
  }

  mv "${ANYTLS_TMP_DIR}/anytls-server" "${ANYTLS_INSTALL_DIR}/"
  chmod +x "${ANYTLS_INSTALL_DIR}/${ANYTLS_BINARY_NAME}"
  rm -rf "${ANYTLS_TMP_DIR}"
  echo -e "${INFO} AnyTLS 二进制安装完成：${ANYTLS_INSTALL_DIR}/${ANYTLS_BINARY_NAME}"
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

configure_anytls() {
  local input_port input_pwd input_sni
  local default_port="8443"
  local default_sni="time.is"

  while true; do
    read -rp "AnyTLS 监听端口（留空则使用 ${default_port}）: " input_port
    input_port="${input_port:-$default_port}"
    if ! [[ "$input_port" =~ ^[0-9]+$ ]] || (( input_port < 1 || input_port > 65535 )); then
      echo -e "${ERROR} 端口必须是 1-65535 的数字"
      continue
    fi
    if ! check_port_free "$input_port"; then
      echo -e "${ERROR} 端口 ${input_port} 已被占用，请重新选择"
      continue
    fi
    ANYTLS_LISTEN_PORT="$input_port"
    break
  done

  read -rp "AnyTLS 密码（留空则自动随机 32 位十六进制）: " input_pwd
  if [[ -z "$input_pwd" ]]; then
    ANYTLS_PASSWORD=$(openssl rand -hex 16)
    echo -e "${CYAN}自动生成 AnyTLS 密码（hex）: ${ANYTLS_PASSWORD}${RESET}"
  else
    ANYTLS_PASSWORD="$input_pwd"
  fi

  read -rp "伪装 TLS 域名 SNI（例如 time.is，留空则使用 ${default_sni}）: " input_sni
  if [[ -z "$input_sni" ]]; then
    ANYTLS_SNI="$default_sni"
  else
    ANYTLS_SNI="$input_sni"
  fi
  ANYTLS_INSECURE="1"

  mkdir -p "$ANYTLS_CONFIG_DIR"
  cat >"$ANYTLS_CONFIG_FILE" <<EOF
listen_addr=${ANYTLS_LISTEN_ADDR}
listen_port=${ANYTLS_LISTEN_PORT}
password=${ANYTLS_PASSWORD}
version=${ANYTLS_VERSION}
sni=${ANYTLS_SNI}
insecure=${ANYTLS_INSECURE}
EOF

  echo -e "${INFO} AnyTLS 配置已保存：${ANYTLS_CONFIG_FILE}"
}

create_anytls_service() {
  if ! has_systemctl; then
    echo -e "${WARNING} 未检测到 systemctl，使用后台进程方式运行 AnyTLS（适用于 Alpine 等无 systemd 系统）"
    return
  fi

  cat >"$ANYTLS_SERVICE_FILE" <<EOF
[Unit]
Description=AnyTLS Server Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=${ANYTLS_INSTALL_DIR}/${ANYTLS_BINARY_NAME} -l ${ANYTLS_LISTEN_ADDR}:${ANYTLS_LISTEN_PORT} -p ${ANYTLS_PASSWORD}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable anytls >/dev/null 2>&1 || true
  echo -e "${INFO} AnyTLS systemd 服务文件已创建：anytls.service"
}

start_anytls() {
  if has_systemctl; then
    systemctl start anytls || true
    sleep 1
    if systemctl is-active --quiet anytls; then
      echo -e "${INFO} AnyTLS 服务已启动"
    else
      echo -e "${ERROR} AnyTLS 服务启动失败，请执行：journalctl -u anytls -n 20 --no-pager"
    fi
  else
    # 无 systemd：用 nohup 后台跑
    pkill -f "${ANYTLS_BINARY_NAME} -l ${ANYTLS_LISTEN_ADDR}:${ANYTLS_LISTEN_PORT}" 2>/dev/null || true
    nohup "${ANYTLS_INSTALL_DIR}/${ANYTLS_BINARY_NAME}" -l "${ANYTLS_LISTEN_ADDR}:${ANYTLS_LISTEN_PORT}" -p "${ANYTLS_PASSWORD}" >/var/log/anytls.log 2>&1 &
    echo -e "${INFO} AnyTLS 已在后台启动（无 systemd），日志：/var/log/anytls.log"
  fi
}

stop_anytls() {
  if has_systemctl; then
    systemctl stop anytls 2>/dev/null || true
    echo -e "${INFO} AnyTLS systemd 服务已停止"
  else
    pkill -f "${ANYTLS_BINARY_NAME} -l ${ANYTLS_LISTEN_ADDR}:${ANYTLS_LISTEN_PORT}" 2>/dev/null || true
    echo -e "${INFO} AnyTLS 后台进程已停止"
  fi
}

restart_anytls() {
  if has_systemctl; then
    systemctl restart anytls 2>/dev/null || true
    sleep 1
    if systemctl is-active --quiet anytls; then
      echo -e "${INFO} AnyTLS 服务已重启"
    else
      echo -e "${ERROR} AnyTLS 服务重启失败，请执行：journalctl -u anytls -n 20 --no-pager"
    fi
  else
    stop_anytls
    start_anytls
  fi
}

view_anytls_config() {
  if [[ ! -f "$ANYTLS_CONFIG_FILE" ]]; then
    echo -e "${ERROR} 未找到 AnyTLS 配置文件：${ANYTLS_CONFIG_FILE}"
    return
  fi

  local listen_port password sni insecure version server_ip
  listen_port=$(grep '^listen_port=' "$ANYTLS_CONFIG_FILE" | cut -d= -f2)
  password=$(grep '^password=' "$ANYTLS_CONFIG_FILE" | cut -d= -f2)
  sni=$(grep '^sni=' "$ANYTLS_CONFIG_FILE" | cut -d= -f2)
  insecure=$(grep '^insecure=' "$ANYTLS_CONFIG_FILE" | cut -d= -f2)
  version=$(grep '^version=' "$ANYTLS_CONFIG_FILE" | cut -d= -f2)
  server_ip=$(get_server_ip_simple)

  echo -e "${CYAN}AnyTLS 节点信息：${RESET}"
  echo -e "  协议: anytls"
  echo -e "  服务器 IP: ${server_ip}"
  echo -e "  端口: ${listen_port}"
  echo -e "  密码 (hex): ${password}"
  echo -e "  SNI: ${sni}"
  echo -e "  不安全连接: ${insecure} (1=启用, 0=禁用)"
  echo -e "  版本: ${version}"

  local host="$server_ip"
  [[ "$server_ip" == *:* ]] && host="[$server_ip]"
  local uri="anytls://${password}@${host}:${listen_port}/?sni=${sni}&insecure=${insecure}"
  echo
  echo -e "${CYAN}AnyTLS URI：${RESET}"
  echo -e "${YELLOW}${uri}${RESET}"
}

uninstall_anytls() {
  echo -e "${WARNING} 即将卸载 AnyTLS..."
  read -rp "确认卸载 AnyTLS ? (y/N): " c
  if [[ ! "$c" =~ ^[Yy]$ ]]; then
    echo -e "${INFO} 已取消"
    return
  fi
  stop_anytls
  if has_systemctl; then
    systemctl disable anytls 2>/dev/null || true
  fi
  rm -f "$ANYTLS_SERVICE_FILE"
  rm -f "${ANYTLS_INSTALL_DIR}/${ANYTLS_BINARY_NAME}"
  rm -rf "$ANYTLS_CONFIG_DIR"
  if has_systemctl; then
    systemctl daemon-reload
  fi
  echo -e "${INFO} AnyTLS 已卸载完成"
}

install_anytls_flow() {
  download_anytls
  configure_anytls
  create_anytls_service
  start_anytls
  clear
  view_anytls_config
}

# ===== Reality (sing-box VLESS-REALITY) 部分 =====

find_singbox_cmd() {
  if [[ -x "$SINGBOX_EXPECTED" ]]; then
    SINGBOX_CMD="$SINGBOX_EXPECTED"
  elif command -v sing-box >/dev/null 2>&1; then
    SINGBOX_CMD=$(command -v sing-box)
  else
    SINGBOX_CMD=""
  fi
}

get_singbox_arch_suffix() {
  case "$(uname -m)" in
    x86_64|amd64) echo "linux-amd64" ;;
    aarch64|arm64) echo "linux-arm64" ;;
    armv7l) echo "linux-armv7" ;;
    amd64v3) echo "linux-amd64v3" ;;
    s390x) echo "linux-s390x" ;;
    *) echo "" ;;
  esac
}

install_singbox_core() {
  find_singbox_cmd
  if [[ -n "$SINGBOX_CMD" ]]; then
    echo -e "${INFO} 已检测到 sing-box：$SINGBOX_CMD"
    return 0
  fi

  check_cmds_or_exit curl wget tar
  local arch_suffix
  arch_suffix=$(get_singbox_arch_suffix)
  if [[ -z "$arch_suffix" ]]; then
    echo -e "${ERROR} 不支持的架构：$(uname -m)"
    return 1
  fi

  local api="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
  local url
  url=$(curl -s "$api" | grep -o "https://github.com[^\"']*${arch_suffix}.tar.gz" | head -n 1)

  if [[ -z "$url" ]]; then
    echo -e "${ERROR} 无法获取 sing-box 最新下载链接"
    return 1
  fi

  echo -e "${INFO} 正在下载 sing-box: ${url}"
  wget -qO /tmp/sing-box.tar.gz "$url" || {
    echo -e "${ERROR} 下载 sing-box 失败"
    return 1
  }

  tar -xzf /tmp/sing-box.tar.gz -C /tmp
  local extracted_bin
  extracted_bin=$(find /tmp -maxdepth 4 -type f -name "sing-box" | head -n 1)
  if [[ -z "$extracted_bin" ]]; then
    echo -e "${ERROR} 未在压缩包中找到 sing-box 可执行文件"
    return 1
  fi

  mkdir -p "$(dirname "$SINGBOX_EXPECTED")"
  mv "$extracted_bin" "$SINGBOX_EXPECTED"
  chmod +x "$SINGBOX_EXPECTED"
  rm -f /tmp/sing-box.tar.gz

  SINGBOX_CMD="$SINGBOX_EXPECTED"
  echo -e "${INFO} sing-box 已安装到：$SINGBOX_CMD"
  return 0
}

gen_reality_credentials() {
  if [[ -z "$SINGBOX_CMD" ]]; then
    echo -e "${ERROR} 未找到 sing-box 命令"
    return 1
  fi

  local uuid_out kp_out
  uuid_out=$("$SINGBOX_CMD" generate uuid) || {
    echo -e "${ERROR} 生成 Reality UUID 失败"
    return 1
  }
  REALITY_UUID="$uuid_out"

  kp_out=$("$SINGBOX_CMD" generate reality-keypair) || {
    echo -e "${ERROR} 生成 Reality Keypair 失败"
    return 1
  }

  REALITY_PRIVATE_KEY=$(echo "$kp_out" | awk -F': ' '/PrivateKey:/ {print $2}' | xargs)
  REALITY_PUBLIC_KEY=$(echo "$kp_out" | awk -F': ' '/PublicKey:/ {print $2}' | xargs)

  if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
    echo -e "${ERROR} 解析 Reality 密钥失败"
    return 1
  fi
  return 0
}

prompt_reality() {
  echo -e "${CYAN}=== Reality (VLESS-Vision) 参数配置 ===${RESET}"
  local default_port="443"
  local default_target="time.is"
  local port

  check_cmds_or_exit openssl

  while true; do
    read -rp "Reality 监听端口（留空则使用 ${default_port}）: " port
    port="${port:-$default_port}"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
      echo -e "${ERROR} 端口必须是 1-65535 的数字"
      continue
    fi
    if [[ -f "$ANYTLS_CONFIG_FILE" ]]; then
      local a_port
      a_port=$(grep '^listen_port=' "$ANYTLS_CONFIG_FILE" | cut -d= -f2)
      if [[ -n "$a_port" && "$a_port" == "$port" ]]; then
        echo -e "${ERROR} 当前 AnyTLS 使用端口 ${a_port}，请为 Reality 选择其他端口"
        continue
      fi
    fi
    REALITY_PORT="$port"
    break
  done

  read -rp "真实站点域名（握手用，例如 time.is，留空则使用 ${default_target}）: " REALITY_TARGET
  if [[ -z "$REALITY_TARGET" ]]; then
    REALITY_TARGET="$default_target"
  fi

  read -rp "Reality SNI（留空则与真实域名相同）: " REALITY_SNI
  REALITY_SNI="${REALITY_SNI:-$REALITY_TARGET}"

  read -rp "Reality short_id（留空则随机 8 位十六进制）: " REALITY_SHORT_ID
  if [[ -z "$REALITY_SHORT_ID" ]]; then
    REALITY_SHORT_ID=$(openssl rand -hex 4)
  fi
}

write_reality_config() {
  mkdir -p "$SINGBOX_CONFIG_DIR"

  cat >"$SINGBOX_REALITY_CONF" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "reality-in",
      "listen": "::",
      "listen_port": ${REALITY_PORT},
      "users": [
        {
          "uuid": "${REALITY_UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_TARGET}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": [
            "${REALITY_SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF

  cat >"$SINGBOX_REALITY_INFO" <<EOF
PORT=${REALITY_PORT}
UUID=${REALITY_UUID}
PUBLIC_KEY=${REALITY_PUBLIC_KEY}
PRIVATE_KEY=${REALITY_PRIVATE_KEY}
TARGET=${REALITY_TARGET}
SNI=${REALITY_SNI}
SHORT_ID=${REALITY_SHORT_ID}
EOF
}

write_reality_service() {
  if has_systemctl; then
    cat >"$SINGBOX_REALITY_SERVICE" <<EOF
[Unit]
Description=sing-box Reality (vless-vision)
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=${SINGBOX_CMD} run -c ${SINGBOX_REALITY_CONF}
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box-reality.service >/dev/null 2>&1 || true
    systemctl restart sing-box-reality.service || true
    echo -e "${INFO} Reality systemd 服务已创建/重启"
  else
    echo -e "${WARNING} 未检测到 systemctl，将以后台进程方式运行 Reality（适用于 Alpine 等无 systemd 系统）"
    pkill -f "sing-box run -c ${SINGBOX_REALITY_CONF}" 2>/dev/null || true
    nohup "${SINGBOX_CMD}" run -c "${SINGBOX_REALITY_CONF}" >/var/log/singbox-reality.log 2>&1 &
    echo -e "${INFO} Reality 已在后台启动（无 systemd），日志：/var/log/singbox-reality.log"
  fi
}

check_reality_config() {
  if [[ -z "$SINGBOX_CMD" ]]; then
    return 0
  fi
  "$SINGBOX_CMD" check -c "$SINGBOX_REALITY_CONF"
}

install_reality_flow() {
  check_cmds_or_exit curl openssl
  install_singbox_core
  find_singbox_cmd
  if [[ -z "$SINGBOX_CMD" ]]; then
    echo -e "${ERROR} sing-box 未就绪，无法安装 Reality"
    return
  fi

  prompt_reality
  gen_reality_credentials
  write_reality_config
  if ! check_reality_config; then
    echo -e "${ERROR} Reality 配置检查失败，请执行：sing-box check -c ${SINGBOX_REALITY_CONF}"
    return
  fi
  write_reality_service
  echo -e "${INFO} Reality 节点已安装并启动"
  show_reality_info
}

show_reality_info() {
  if [[ ! -f "$SINGBOX_REALITY_INFO" ]]; then
    echo -e "${ERROR} 未找到 Reality 配置信息：${SINGBOX_REALITY_INFO}"
    return
  fi
  # shellcheck disable=SC1090
  . "$SINGBOX_REALITY_INFO"

  local ip4
  ip4=$(get_server_ip_simple)

  echo -e "${CYAN}Reality (VLESS-Vision) 节点信息：${RESET}"
  echo -e "  协议: vless"
  echo -e "  地址: ${ip4:-你的服务器 IP}"
  echo -e "  端口: ${PORT}"
  echo -e "  UUID: ${UUID}"
  echo -e "  server_name (SNI): ${SNI}"
  echo -e "  reality 公钥: ${PUBLIC_KEY}"
  echo -e "  reality short_id (hex): ${SHORT_ID}"

  local host="$ip4"
  [[ "$ip4" == *:* ]] && host="[$ip4]"
  local vless_uri="vless://${UUID}@${host}:${PORT}?security=reality&sni=${SNI}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&flow=xtls-rprx-vision&type=tcp#Reality"
  echo
  echo -e "${CYAN}VLESS Reality 导入链接：${RESET}"
  echo -e "${YELLOW}${vless_uri}${RESET}"
}

uninstall_reality() {
  echo -e "${WARNING} 即将卸载 Reality 节点..."
  read -rp "确认卸载 Reality ? (y/N): " c
  if [[ ! "$c" =~ ^[Yy]$ ]]; then
    echo -e "${INFO} 已取消"
    return
  fi

  if has_systemctl; then
    systemctl stop sing-box-reality.service 2>/dev/null || true
    systemctl disable sing-box-reality.service 2>/dev/null || true
  else
    pkill -f "sing-box run -c ${SINGBOX_REALITY_CONF}" 2>/dev/null || true
  fi
  rm -f "$SINGBOX_REALITY_SERVICE"
  rm -f "$SINGBOX_REALITY_CONF" "$SINGBOX_REALITY_INFO"
  if has_systemctl; then
    systemctl daemon-reload
  fi
  echo -e "${INFO} Reality 节点已卸载完成"
}

nodes_manage_menu() {
  echo -e "${CYAN}=== 节点管理 ===${RESET}"
  echo "1) 启动全部节点"
  echo "2) 停止全部节点"
  echo "3) 重启全部节点"
  echo "4) 查看服务状态"
  echo "0) 返回主菜单"
  read -rp "请选择: " opt
  case "$opt" in
    1)
      start_anytls
      if has_systemctl; then
        systemctl start sing-box-reality.service 2>/dev/null || true
      else
        pkill -f "sing-box run -c ${SINGBOX_REALITY_CONF}" 2>/dev/null || true
        nohup "${SINGBOX_CMD}" run -c "${SINGBOX_REALITY_CONF}" >/var/log/singbox-reality.log 2>&1 &
      fi
      ;;
    2)
      stop_anytls
      if has_systemctl; then
        systemctl stop sing-box-reality.service 2>/dev/null || true
      else
        pkill -f "sing-box run -c ${SINGBOX_REALITY_CONF}" 2>/dev/null || true
      fi
      ;;
    3)
      restart_anytls
      if has_systemctl; then
        systemctl restart sing-box-reality.service 2>/dev/null || true
      else
        pkill -f "sing-box run -c ${SINGBOX_REALITY_CONF}" 2>/dev/null || true
        nohup "${SINGBOX_CMD}" run -c "${SINGBOX_REALITY_CONF}" >/var/log/singbox-reality.log 2>&1 &
      fi
      ;;
    4)
      if has_systemctl; then
        systemctl status anytls 2>/dev/null || echo "AnyTLS 服务不存在或未安装"
        systemctl status sing-box-reality.service 2>/dev/null || echo "Reality 服务不存在或未安装"
      else
        echo -e "${WARNING} 无 systemd，无法使用 systemctl 查看状态；请通过 ps/日志自行确认进程。"
      fi
      ;;
  esac
}

update_script() {
  if [[ -z "$SCRIPT_URL" ]]; then
    echo -e "${ERROR} 脚本更新地址未配置"
    return
  fi
  check_cmds_or_exit wget
  wget -N -O "$SCRIPT_PATH" "$SCRIPT_URL"
  chmod +x "$SCRIPT_PATH"
  echo -e "${INFO} 脚本已更新，重新运行即可生效"
}

uninstall_all() {
  echo -e "${WARNING} 此操作会卸载 AnyTLS & Reality 节点及其服务（保留 sing-box 二进制）"
  read -rp "确认卸载全部节点? (y/N): " c
  if [[ ! "$c" =~ ^[Yy]$ ]]; then
    echo -e "${INFO} 已取消"
    return
  fi

  if [[ -f "$ANYTLS_CONFIG_FILE" || -f "$ANYTLS_SERVICE_FILE" ]]; then
    uninstall_anytls
  fi
  if [[ -f "$SINGBOX_REALITY_CONF" || -f "$SINGBOX_REALITY_SERVICE" ]]; then
    uninstall_reality
  fi
}

show_all_nodes_info() {
  view_anytls_config
  echo
  show_reality_info
}

# ===== 主菜单 =====
main_menu() {
  while true; do
    echo -e "${CYAN}=== AnyTLS & Reality 管理脚本 ===${RESET}"
    echo "1) 安装 / 重新安装 AnyTLS 节点 (anytls-go)"
    echo "2) 安装 / 重新安装 Reality (VLESS-Vision) 节点 (sing-box)"
    echo "3) 查看节点信息 (AnyTLS + Reality)"
    echo "4) 节点管理（启动 / 停止 / 重启 / 状态）"
    echo "5) 重新下载/更新 sing-box 二进制"
    echo "6) 更新本管理脚本"
    echo "7) 卸载 AnyTLS 节点"
    echo "8) 卸载 Reality 节点"
    echo "9) 卸载全部节点与配置"
    echo "0) 退出"
    read -rp "请选择: " c
    case "$c" in
      1) install_anytls_flow ;;
      2) install_reality_flow ;;
      3) show_all_nodes_info ;;
      4) nodes_manage_menu ;;
      5) install_singbox_core ;;
      6) update_script ;;
      7) uninstall_anytls ;;
      8) uninstall_reality ;;
      9) uninstall_all ;;
      0) exit 0 ;;
      *) echo -e "${ERROR} 无效选项" ;;
    esac
    echo
  done
}

# ===== 入口 =====
check_root
main_menu
