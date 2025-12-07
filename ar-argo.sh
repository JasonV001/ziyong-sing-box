#!/usr/bin/env bash
# ============================================================================
# 统一隧道管理脚本 - Unified Tunnel Manager
# 功能: Argo Tunnel + Xray + AnyTLS + Reality (VLESS-Vision)
# 版本: 2.0.0
# ============================================================================

set -e
PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# ===== 颜色定义 =====
readonly GREEN="\033[32m"
readonly RED="\033[31m"
readonly YELLOW="\033[0;33m"
readonly CYAN="\033[0;36m"
readonly PURPLE="\033[0;35m"
readonly RESET="\033[0m"

readonly INFO="${GREEN}[信息]${RESET}"
readonly ERROR="${RED}[错误]${RESET}"
readonly WARNING="${YELLOW}[警告]${RESET}"

# ===== 全局配置路径 =====
readonly BASE_DIR="/opt/unified-tunnel"
readonly CONFIG_DIR="${BASE_DIR}/config"
readonly BIN_DIR="${BASE_DIR}/bin"
readonly LOG_DIR="${BASE_DIR}/logs"
readonly LINK_DIR="${BASE_DIR}/links"

# Argo + Xray 配置
readonly ARGO_DIR="${BASE_DIR}/argo"
readonly XRAY_DIR="${BASE_DIR}/xray"
readonly CLOUDFLARED_BIN="${BIN_DIR}/cloudflared"
readonly XRAY_BIN="${BIN_DIR}/xray"
readonly XRAY_CONFIG="${CONFIG_DIR}/xray.json"

# AnyTLS 配置
readonly ANYTLS_BIN="${BIN_DIR}/anytls-server"
readonly ANYTLS_CONFIG="${CONFIG_DIR}/anytls.conf"

# Reality (sing-box) 配置
readonly SINGBOX_BIN="${BIN_DIR}/sing-box"
readonly REALITY_CONFIG="${CONFIG_DIR}/reality.json"
readonly REALITY_INFO="${CONFIG_DIR}/reality.info"

# 服务文件
readonly SERVICE_DIR="/etc/systemd/system"

# ===== 系统检测与初始化 =====
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${ERROR} 请使用 root 权限运行此脚本"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID,,}"
        OS_LIKE="${ID_LIKE,,}"
        OS_NAME="${PRETTY_NAME}"
    else
        OS_ID="unknown"
        OS_LIKE="unknown"
        OS_NAME="Unknown OS"
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|x64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armv7) ARCH="armv7" ;;
        i386|i686) ARCH="386" ;;
        *) ARCH="unknown" ;;
    esac
}

has_systemctl() {
    command -v systemctl >/dev/null 2>&1
}

init_directories() {
    mkdir -p "${BASE_DIR}" "${CONFIG_DIR}" "${BIN_DIR}" "${LOG_DIR}" "${LINK_DIR}"
    mkdir -p "${ARGO_DIR}" "${XRAY_DIR}"
}

# ===== 依赖包管理 =====
install_dependencies() {
    local pkgs=("$@")
    local to_install=()
    
    for pkg in "${pkgs[@]}"; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            to_install+=("$pkg")
        fi
    done
    
    [[ ${#to_install[@]} -eq 0 ]] && return 0
    
    echo -e "${INFO} 安装依赖: ${to_install[*]}"
    
    if [[ "$OS_ID" == "alpine" || "$OS_LIKE" =~ alpine ]]; then
        apk update -q && apk add --no-cache "${to_install[@]}"
    elif [[ "$OS_ID" =~ (debian|ubuntu) || "$OS_LIKE" =~ (debian|ubuntu) ]]; then
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y "${to_install[@]}"
    elif [[ "$OS_ID" =~ (centos|rhel|rocky|almalinux|fedora) || "$OS_LIKE" =~ (rhel|fedora) ]]; then
        local pm="yum"
        command -v dnf >/dev/null 2>&1 && pm="dnf"
        $pm install -y "${to_install[@]}"
    else
        echo -e "${ERROR} 不支持的系统，请手动安装: ${to_install[*]}"
        return 1
    fi
}

check_dependencies() {
    install_dependencies curl wget unzip tar openssl jq
}

# ===== 通用工具函数 =====
get_server_ip() {
    local ip
    ip=$(curl -s4 --max-time 5 icanhazip.com 2>/dev/null || \
         curl -s4 --max-time 5 ip.sb 2>/dev/null || \
         hostname -I 2>/dev/null | awk '{print $1}')
    echo "${ip:-127.0.0.1}"
}

check_port_available() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ! ss -ltn | grep -q ":${port} "
    elif command -v netstat >/dev/null 2>&1; then
        ! netstat -ltn | grep -q ":${port} "
    else
        return 0
    fi
}

generate_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

generate_random_hex() {
    local length="${1:-16}"
    openssl rand -hex "$length"
}

generate_random_port() {
    echo $((RANDOM + 10000))
}

# ===== Cloudflared 下载与安装 =====
download_cloudflared() {
    echo -e "${INFO} 下载 Cloudflared..."
    
    local url
    case "$ARCH" in
        amd64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
        arm64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
        armv7) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
        386) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386" ;;
        *) echo -e "${ERROR} 不支持的架构: $ARCH"; return 1 ;;
    esac
    
    wget -qO "${CLOUDFLARED_BIN}" "$url" || {
        echo -e "${ERROR} Cloudflared 下载失败"
        return 1
    }
    
    chmod +x "${CLOUDFLARED_BIN}"
    echo -e "${INFO} Cloudflared 安装完成"
}

check_cloudflared() {
    if [[ -x "${CLOUDFLARED_BIN}" ]]; then
        return 0
    fi
    download_cloudflared
}

# ===== Xray 下载与安装 =====
download_xray() {
    echo -e "${INFO} 下载 Xray-core..."
    
    local zip_name
    case "$ARCH" in
        amd64) zip_name="Xray-linux-64.zip" ;;
        arm64) zip_name="Xray-linux-arm64-v8a.zip" ;;
        armv7) zip_name="Xray-linux-arm32-v7a.zip" ;;
        386) zip_name="Xray-linux-32.zip" ;;
        *) echo -e "${ERROR} 不支持的架构: $ARCH"; return 1 ;;
    esac
    
    local url="https://github.com/XTLS/Xray-core/releases/latest/download/${zip_name}"
    local tmp_zip="/tmp/xray.zip"
    
    wget -qO "$tmp_zip" "$url" || {
        echo -e "${ERROR} Xray 下载失败"
        return 1
    }
    
    unzip -qo "$tmp_zip" -d "${XRAY_DIR}"
    mv "${XRAY_DIR}/xray" "${XRAY_BIN}"
    chmod +x "${XRAY_BIN}"
    rm -f "$tmp_zip"
    
    echo -e "${INFO} Xray 安装完成"
}

check_xray() {
    if [[ -x "${XRAY_BIN}" ]]; then
        return 0
    fi
    download_xray
}

# ===== AnyTLS 下载与安装 =====
get_anytls_latest_version() {
    local version
    version=$(curl -s "https://api.github.com/repos/anytls/anytls-go/releases/latest" | \
              grep '"tag_name"' | sed -n 's/.*"v\?\([0-9.]\+\)".*/\1/p' | head -n1)
    echo "${version:-0.0.8}"
}

download_anytls() {
    echo -e "${INFO} 下载 AnyTLS..."
    
    local version
    version=$(get_anytls_latest_version)
    
    local arch_name
    case "$ARCH" in
        amd64|arm64) arch_name="$ARCH" ;;
        *) echo -e "${ERROR} AnyTLS 不支持架构: $ARCH"; return 1 ;;
    esac
    
    local zip="anytls_${version}_linux_${arch_name}.zip"
    local url="https://github.com/anytls/anytls-go/releases/download/v${version}/${zip}"
    local tmp_dir="/tmp/anytls"
    
    mkdir -p "$tmp_dir"
    wget -qO "${tmp_dir}/${zip}" "$url" || {
        echo -e "${ERROR} AnyTLS 下载失败"
        return 1
    }
    
    unzip -qo "${tmp_dir}/${zip}" -d "$tmp_dir"
    mv "${tmp_dir}/anytls-server" "${ANYTLS_BIN}"
    chmod +x "${ANYTLS_BIN}"
    rm -rf "$tmp_dir"
    
    echo -e "${INFO} AnyTLS 安装完成 (版本: ${version})"
}

check_anytls() {
    if [[ -x "${ANYTLS_BIN}" ]]; then
        return 0
    fi
    download_anytls
}

# ===== sing-box 下载与安装 =====
download_singbox() {
    echo -e "${INFO} 下载 sing-box..."
    
    local arch_suffix
    case "$ARCH" in
        amd64) arch_suffix="linux-amd64" ;;
        arm64) arch_suffix="linux-arm64" ;;
        armv7) arch_suffix="linux-armv7" ;;
        *) echo -e "${ERROR} sing-box 不支持架构: $ARCH"; return 1 ;;
    esac
    
    local api="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    local url
    url=$(curl -s "$api" | grep -o "https://github.com[^\"']*${arch_suffix}.tar.gz" | head -n1)
    
    if [[ -z "$url" ]]; then
        echo -e "${ERROR} 无法获取 sing-box 下载链接"
        return 1
    fi
    
    local tmp_tar="/tmp/sing-box.tar.gz"
    wget -qO "$tmp_tar" "$url" || {
        echo -e "${ERROR} sing-box 下载失败"
        return 1
    }
    
    tar -xzf "$tmp_tar" -C /tmp
    local extracted
    extracted=$(find /tmp -maxdepth 4 -type f -name "sing-box" 2>/dev/null | head -n1)
    
    if [[ -z "$extracted" ]]; then
        echo -e "${ERROR} 解压 sing-box 失败"
        return 1
    fi
    
    mv "$extracted" "${SINGBOX_BIN}"
    chmod +x "${SINGBOX_BIN}"
    rm -f "$tmp_tar"
    
    echo -e "${INFO} sing-box 安装完成"
}

check_singbox() {
    if [[ -x "${SINGBOX_BIN}" ]]; then
        return 0
    fi
    download_singbox
}

# ===== Argo Quick Tunnel (临时域名模式) =====
install_argo_quick() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║   Argo Quick Tunnel (临时域名)       ║${RESET}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${RESET}"
    echo
    
    check_cloudflared || return 1
    check_xray || return 1
    
    # 选择协议
    echo "选择 Xray 协议:"
    echo "  1) VMess"
    echo "  2) VLESS"
    read -rp "请选择 [1-2] (默认 2): " protocol_choice
    protocol_choice="${protocol_choice:-2}"
    
    local protocol
    case "$protocol_choice" in
        1) protocol="vmess" ;;
        2) protocol="vless" ;;
        *) echo -e "${ERROR} 无效选择"; return 1 ;;
    esac
    
    # 选择 IP 版本
    read -rp "Argo IP 版本 [4/6] (默认 4): " ip_version
    ip_version="${ip_version:-4}"
    
    # 生成配置
    local uuid port path
    uuid=$(generate_uuid)
    port=$(generate_random_port)
    path=$(generate_random_hex 8)
    
    # 创建 Xray 配置
    create_xray_config "$protocol" "$uuid" "$port" "$path"
    
    # 启动 Xray
    start_xray_process "$port"
    
    # 启动 Argo
    start_argo_quick "$port" "$ip_version"
    
    # 等待获取域名
    local domain
    domain=$(wait_for_argo_domain)
    
    if [[ -n "$domain" ]]; then
        echo -e "${INFO} Argo 域名: ${GREEN}${domain}${RESET}"
        generate_argo_links "$protocol" "$uuid" "$path" "$domain" "$port"
    else
        echo -e "${ERROR} 获取 Argo 域名超时"
    fi
}

create_xray_config() {
    local protocol="$1"
    local uuid="$2"
    local port="$3"
    local path="$4"
    
    if [[ "$protocol" == "vmess" ]]; then
        cat > "${XRAY_CONFIG}" <<EOF
{
    "inbounds": [{
        "port": ${port},
        "listen": "127.0.0.1",
        "protocol": "vmess",
        "settings": {
            "clients": [{"id": "${uuid}", "alterId": 0}]
        },
        "streamSettings": {
            "network": "ws",
            "wsSettings": {"path": "/${path}"}
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOF
    else
        cat > "${XRAY_CONFIG}" <<EOF
{
    "inbounds": [{
        "port": ${port},
        "listen": "127.0.0.1",
        "protocol": "vless",
        "settings": {
            "decryption": "none",
            "clients": [{"id": "${uuid}"}]
        },
        "streamSettings": {
            "network": "ws",
            "wsSettings": {"path": "/${path}"}
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOF
    fi
}

start_xray_process() {
    local port="$1"
    pkill -f "xray.*${port}" 2>/dev/null || true
    nohup "${XRAY_BIN}" run -c "${XRAY_CONFIG}" > "${LOG_DIR}/xray.log" 2>&1 &
    sleep 2
    echo -e "${INFO} Xray 已启动 (端口: ${port})"
}

start_argo_quick() {
    local port="$1"
    local ip_ver="$2"
    local log_file="${LOG_DIR}/argo.log"
    
    pkill -f "cloudflared.*tunnel" 2>/dev/null || true
    > "$log_file"
    
    nohup "${CLOUDFLARED_BIN}" tunnel \
        --url "http://127.0.0.1:${port}" \
        --edge-ip-version "${ip_ver}" \
        --protocol http2 \
        --no-autoupdate \
        > "$log_file" 2>&1 &
    
    echo -e "${INFO} Argo Tunnel 已启动"
}

wait_for_argo_domain() {
    local log_file="${LOG_DIR}/argo.log"
    local max_wait=30
    local waited=0
    
    echo -n "等待 Argo 域名生成"
    while [[ $waited -lt $max_wait ]]; do
        if [[ -f "$log_file" ]]; then
            local domain
            domain=$(grep -oP 'https://\K[^/]+\.trycloudflare\.com' "$log_file" | tail -1)
            if [[ -n "$domain" ]]; then
                echo
                echo "$domain"
                return 0
            fi
        fi
        echo -n "."
        sleep 2
        waited=$((waited + 2))
    done
    echo
    return 1
}

generate_argo_links() {
    local protocol="$1"
    local uuid="$2"
    local path="$3"
    local domain="$4"
    local port="$5"
    
    local link_file="${LINK_DIR}/argo_${protocol}_${port}.txt"
    local server_ip
    server_ip=$(get_server_ip)
    
    cat > "$link_file" <<EOF
========================================
Argo ${protocol^^} 节点信息
========================================
协议: ${protocol}
域名: ${domain}
UUID: ${uuid}
路径: /${path}
本地端口: ${port}

EOF
    
    if [[ "$protocol" == "vmess" ]]; then
        local vmess_json_tls vmess_json_notls link_tls link_notls
        
        vmess_json_tls=$(cat <<VMESS_EOF
{"v":"2","ps":"Argo-${domain}","add":"www.visa.com.sg","port":"443","id":"${uuid}","aid":"0","net":"ws","type":"none","host":"${domain}","path":"/${path}","tls":"tls","sni":"${domain}"}
VMESS_EOF
)
        link_tls="vmess://$(echo -n "$vmess_json_tls" | base64 -w 0 2>/dev/null || echo -n "$vmess_json_tls" | base64)"
        
        vmess_json_notls=$(cat <<VMESS_EOF
{"v":"2","ps":"Argo-${domain}-NoTLS","add":"www.visa.com.sg","port":"80","id":"${uuid}","aid":"0","net":"ws","type":"none","host":"${domain}","path":"/${path}","tls":""}
VMESS_EOF
)
        link_notls="vmess://$(echo -n "$vmess_json_notls" | base64 -w 0 2>/dev/null || echo -n "$vmess_json_notls" | base64)"
        
        cat >> "$link_file" <<EOF
【TLS 链接】(推荐)
${link_tls}

备用端口: 443, 2053, 2083, 2087, 2096, 8443

【非 TLS 链接】
${link_notls}

备用端口: 80, 8080, 8880, 2052, 2082, 2086, 2095
EOF
    else
        local link_tls link_notls
        link_tls="vless://${uuid}@www.visa.com.sg:443?encryption=none&security=tls&type=ws&host=${domain}&path=%2F${path}&sni=${domain}#Argo-${domain}"
        link_notls="vless://${uuid}@www.visa.com.sg:80?encryption=none&security=none&type=ws&host=${domain}&path=%2F${path}#Argo-${domain}-NoTLS"
        
        cat >> "$link_file" <<EOF
【TLS 链接】(推荐)
${link_tls}

备用端口: 443, 2053, 2083, 2087, 2096, 8443

【非 TLS 链接】
${link_notls}

备用端口: 80, 8080, 8880, 2052, 2082, 2086, 2095
EOF
    fi
    
    cat >> "$link_file" <<EOF

========================================
使用说明
========================================
1. 推荐使用 TLS 链接 (443端口)
2. www.visa.com.sg 可替换为 CF 优选 IP
3. 临时域名重启后会变化
4. 链接已保存: ${link_file}
========================================
EOF
    
    echo
    cat "$link_file"
}

# ===== Argo 固定域名模式 (Token/JSON) =====
install_argo_tunnel() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║   Argo Tunnel (固定域名)             ║${RESET}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${RESET}"
    echo
    
    check_cloudflared || return 1
    check_xray || return 1
    
    # 选择协议
    echo "选择 Xray 协议:"
    echo "  1) VMess"
    echo "  2) VLESS"
    read -rp "请选择 [1-2] (默认 2): " protocol_choice
    protocol_choice="${protocol_choice:-2}"
    
    local protocol
    case "$protocol_choice" in
        1) protocol="vmess" ;;
        2) protocol="vless" ;;
        *) echo -e "${ERROR} 无效选择"; return 1 ;;
    esac
    
    # 选择 IP 版本
    read -rp "Argo IP 版本 [4/6] (默认 4): " ip_version
    ip_version="${ip_version:-4}"
    
    # 生成配置
    local uuid port path
    uuid=$(generate_uuid)
    port=$(generate_random_port)
    path=$(generate_random_hex 8)
    
    # 创建 Xray 配置
    create_xray_config "$protocol" "$uuid" "$port" "$path"
    
    # Cloudflare 登录
    echo
    echo -e "${INFO} 请在浏览器中完成 Cloudflare 授权..."
    "${CLOUDFLARED_BIN}" --edge-ip-version "$ip_version" --protocol http2 tunnel login
    
    # 获取域名
    echo
    read -rp "输入要绑定的完整域名 (如 tunnel.example.com): " domain
    
    if [[ -z "$domain" || ! "$domain" =~ \. ]]; then
        echo -e "${ERROR} 域名格式不正确"
        return 1
    fi
    
    local tunnel_name
    tunnel_name=$(echo "$domain" | awk -F. '{print $1}')
    
    # 创建/检查 tunnel
    setup_argo_tunnel "$tunnel_name" "$domain" "$port" "$ip_version"
    
    # 创建服务
    create_argo_service "$tunnel_name" "$port" "$ip_version"
    create_xray_service "$port"
    
    # 启动服务
    if has_systemctl; then
        systemctl daemon-reload
        systemctl enable argo-tunnel xray-tunnel 2>/dev/null
        systemctl restart argo-tunnel xray-tunnel
    fi
    
    echo
    echo -e "${INFO} Argo 固定域名隧道已配置完成"
    generate_argo_links "$protocol" "$uuid" "$path" "$domain" "$port"
}

setup_argo_tunnel() {
    local name="$1"
    local domain="$2"
    local port="$3"
    local ip_ver="$4"
    
    # 检查是否已存在
    local tunnel_list
    tunnel_list=$("${CLOUDFLARED_BIN}" tunnel list 2>/dev/null || true)
    
    if echo "$tunnel_list" | grep -q "$name"; then
        echo -e "${INFO} Tunnel ${name} 已存在，清理旧配置..."
        "${CLOUDFLARED_BIN}" tunnel cleanup "$name" 2>/dev/null || true
    else
        echo -e "${INFO} 创建 Tunnel: ${name}"
        "${CLOUDFLARED_BIN}" --edge-ip-version "$ip_ver" --protocol http2 tunnel create "$name"
    fi
    
    # 绑定域名
    echo -e "${INFO} 绑定域名: ${domain}"
    "${CLOUDFLARED_BIN}" --edge-ip-version "$ip_ver" --protocol http2 tunnel route dns --overwrite-dns "$name" "$domain"
    
    # 获取 tunnel UUID
    local tunnel_uuid
    tunnel_uuid=$("${CLOUDFLARED_BIN}" tunnel list 2>/dev/null | grep "$name" | awk '{print $1}')
    
    # 创建配置文件
    local config_file="${ARGO_DIR}/config.yaml"
    cat > "$config_file" <<EOF
tunnel: ${tunnel_uuid}
credentials-file: /root/.cloudflared/${tunnel_uuid}.json

ingress:
  - hostname: ${domain}
    service: http://127.0.0.1:${port}
  - service: http_status:404
EOF
    
    echo -e "${INFO} Tunnel 配置完成"
}

create_argo_service() {
    local name="$1"
    local port="$2"
    local ip_ver="$3"
    
    if ! has_systemctl; then
        echo -e "${WARNING} 无 systemd，请手动管理服务"
        return
    fi
    
    cat > "${SERVICE_DIR}/argo-tunnel.service" <<EOF
[Unit]
Description=Cloudflare Argo Tunnel
After=network.target

[Service]
Type=simple
User=root
ExecStart=${CLOUDFLARED_BIN} --edge-ip-version ${ip_ver} --protocol http2 tunnel --config ${ARGO_DIR}/config.yaml run ${name}
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
}

create_xray_service() {
    local port="$1"
    
    if ! has_systemctl; then
        return
    fi
    
    cat > "${SERVICE_DIR}/xray-tunnel.service" <<EOF
[Unit]
Description=Xray Tunnel Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${XRAY_BIN} run -c ${XRAY_CONFIG}
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
}

# ===== AnyTLS 安装与配置 =====
install_anytls() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║        AnyTLS 节点配置                ║${RESET}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${RESET}"
    echo
    
    check_anytls || return 1
    
    # 配置参数
    local port password sni
    
    while true; do
        read -rp "监听端口 (默认 8443): " port
        port="${port:-8443}"
        
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            echo -e "${ERROR} 端口必须是 1-65535"
            continue
        fi
        
        if ! check_port_available "$port"; then
            echo -e "${ERROR} 端口 ${port} 已被占用"
            continue
        fi
        break
    done
    
    read -rp "密码 (留空自动生成): " password
    if [[ -z "$password" ]]; then
        password=$(generate_random_hex 16)
        echo -e "${CYAN}自动生成密码: ${password}${RESET}"
    fi
    
    read -rp "伪装域名 SNI (默认 time.is): " sni
    sni="${sni:-time.is}"
    
    # 保存配置
    cat > "${ANYTLS_CONFIG}" <<EOF
listen_addr=[::]
listen_port=${port}
password=${password}
sni=${sni}
insecure=1
EOF
    
    # 创建服务
    if has_systemctl; then
        cat > "${SERVICE_DIR}/anytls.service" <<EOF
[Unit]
Description=AnyTLS Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=${ANYTLS_BIN} -l [::]:${port} -p ${password}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable anytls 2>/dev/null
        systemctl restart anytls
        
        if systemctl is-active --quiet anytls; then
            echo -e "${INFO} AnyTLS 服务已启动"
        else
            echo -e "${ERROR} AnyTLS 启动失败"
            return 1
        fi
    else
        pkill -f "anytls-server.*${port}" 2>/dev/null || true
        nohup "${ANYTLS_BIN}" -l "[::]:${port}" -p "${password}" > "${LOG_DIR}/anytls.log" 2>&1 &
        echo -e "${INFO} AnyTLS 已启动 (后台进程)"
    fi
    
    # 显示节点信息
    show_anytls_info "$port" "$password" "$sni"
}

show_anytls_info() {
    local port="$1"
    local password="$2"
    local sni="$3"
    local server_ip
    server_ip=$(get_server_ip)
    
    local uri="anytls://${password}@${server_ip}:${port}/?sni=${sni}&insecure=1#AnyTLS"
    
    local info_file="${LINK_DIR}/anytls_${port}.txt"
    cat > "$info_file" <<EOF
========================================
AnyTLS 节点信息
========================================
协议: anytls
服务器: ${server_ip}
端口: ${port}
密码: ${password}
SNI: ${sni}
不安全连接: 1

【节点链接】
${uri}

========================================
EOF
    
    echo
    cat "$info_file"
}

# ===== Reality (VLESS-Vision) 安装与配置 =====
install_reality() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║    Reality (VLESS-Vision) 配置       ║${RESET}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${RESET}"
    echo
    
    check_singbox || return 1
    
    # 配置参数
    local port target sni short_id
    
    while true; do
        read -rp "监听端口 (默认 443): " port
        port="${port:-443}"
        
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            echo -e "${ERROR} 端口必须是 1-65535"
            continue
        fi
        
        if ! check_port_available "$port"; then
            echo -e "${ERROR} 端口 ${port} 已被占用"
            continue
        fi
        break
    done
    
    read -rp "真实站点域名 (默认 time.is): " target
    target="${target:-time.is}"
    
    read -rp "Reality SNI (留空与真实站点相同): " sni
    sni="${sni:-$target}"
    
    read -rp "Short ID (留空自动生成): " short_id
    if [[ -z "$short_id" ]]; then
        short_id=$(generate_random_hex 4)
    fi
    
    # 生成凭证
    local uuid private_key public_key
    uuid=$("${SINGBOX_BIN}" generate uuid)
    local keypair
    keypair=$("${SINGBOX_BIN}" generate reality-keypair)
    private_key=$(echo "$keypair" | awk -F': ' '/PrivateKey:/ {print $2}' | xargs)
    public_key=$(echo "$keypair" | awk -F': ' '/PublicKey:/ {print $2}' | xargs)
    
    # 创建配置
    cat > "${REALITY_CONFIG}" <<EOF
{
  "log": {"level": "info"},
  "inbounds": [{
    "type": "vless",
    "tag": "reality-in",
    "listen": "::",
    "listen_port": ${port},
    "users": [{
      "uuid": "${uuid}",
      "flow": "xtls-rprx-vision"
    }],
    "tls": {
      "enabled": true,
      "server_name": "${sni}",
      "reality": {
        "enabled": true,
        "handshake": {
          "server": "${target}",
          "server_port": 443
        },
        "private_key": "${private_key}",
        "short_id": ["${short_id}"]
      }
    }
  }],
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"}
  ]
}
EOF
    
    # 保存信息
    cat > "${REALITY_INFO}" <<EOF
PORT=${port}
UUID=${uuid}
PUBLIC_KEY=${public_key}
PRIVATE_KEY=${private_key}
TARGET=${target}
SNI=${sni}
SHORT_ID=${short_id}
EOF
    
    # 创建服务
    if has_systemctl; then
        cat > "${SERVICE_DIR}/reality.service" <<EOF
[Unit]
Description=Reality VLESS-Vision
After=network.target

[Service]
Type=simple
User=root
ExecStart=${SINGBOX_BIN} run -c ${REALITY_CONFIG}
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable reality 2>/dev/null
        systemctl restart reality
        
        if systemctl is-active --quiet reality; then
            echo -e "${INFO} Reality 服务已启动"
        else
            echo -e "${ERROR} Reality 启动失败"
            return 1
        fi
    else
        pkill -f "sing-box.*reality" 2>/dev/null || true
        nohup "${SINGBOX_BIN}" run -c "${REALITY_CONFIG}" > "${LOG_DIR}/reality.log" 2>&1 &
        echo -e "${INFO} Reality 已启动 (后台进程)"
    fi
    
    # 显示节点信息
    show_reality_info
}

show_reality_info() {
    if [[ ! -f "${REALITY_INFO}" ]]; then
        echo -e "${ERROR} Reality 配置文件不存在"
        return 1
    fi
    
    . "${REALITY_INFO}"
    
    local server_ip
    server_ip=$(get_server_ip)
    
    local vless_uri="vless://${UUID}@${server_ip}:${PORT}?security=reality&sni=${SNI}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&flow=xtls-rprx-vision&type=tcp#Reality"
    
    local info_file="${LINK_DIR}/reality_${PORT}.txt"
    cat > "$info_file" <<EOF
========================================
Reality (VLESS-Vision) 节点信息
========================================
协议: vless
服务器: ${server_ip}
端口: ${PORT}
UUID: ${UUID}
SNI: ${SNI}
公钥: ${PUBLIC_KEY}
Short ID: ${SHORT_ID}
Flow: xtls-rprx-vision

【节点链接】
${vless_uri}

========================================
EOF
    
    echo
    cat "$info_file"
}

# ===== 服务管理功能 =====
manage_services() {
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════╗${RESET}"
        echo -e "${CYAN}║          服务管理菜单                 ║${RESET}"
        echo -e "${CYAN}╚═══════════════════════════════════════╝${RESET}"
        echo
        echo "  1) 启动所有服务"
        echo "  2) 停止所有服务"
        echo "  3) 重启所有服务"
        echo "  4) 查看服务状态"
        echo "  5) 查看服务日志"
        echo "  0) 返回主菜单"
        echo
        read -rp "请选择 [0-5]: " choice
        
        case "$choice" in
            1) start_all_services ;;
            2) stop_all_services ;;
            3) restart_all_services ;;
            4) show_services_status ;;
            5) show_services_logs ;;
            0) return ;;
            *) echo -e "${ERROR} 无效选择" ;;
        esac
        
        echo
        read -rp "按回车继续..."
    done
}

start_all_services() {
    echo -e "${INFO} 启动所有服务..."
    
    if has_systemctl; then
        for svc in argo-tunnel xray-tunnel anytls reality; do
            if [[ -f "${SERVICE_DIR}/${svc}.service" ]]; then
                systemctl start "$svc" 2>/dev/null && \
                    echo -e "  ${GREEN}✓${RESET} ${svc}" || \
                    echo -e "  ${RED}✗${RESET} ${svc}"
            fi
        done
    else
        echo -e "${WARNING} 无 systemd，请手动管理进程"
    fi
}

stop_all_services() {
    echo -e "${INFO} 停止所有服务..."
    
    if has_systemctl; then
        for svc in argo-tunnel xray-tunnel anytls reality; do
            if [[ -f "${SERVICE_DIR}/${svc}.service" ]]; then
                systemctl stop "$svc" 2>/dev/null && \
                    echo -e "  ${GREEN}✓${RESET} ${svc}" || \
                    echo -e "  ${RED}✗${RESET} ${svc}"
            fi
        done
    else
        pkill -f "cloudflared.*tunnel" 2>/dev/null
        pkill -f "xray.*run" 2>/dev/null
        pkill -f "anytls-server" 2>/dev/null
        pkill -f "sing-box.*reality" 2>/dev/null
        echo -e "${INFO} 已停止所有进程"
    fi
}

restart_all_services() {
    stop_all_services
    sleep 2
    start_all_services
}

show_services_status() {
    echo -e "${CYAN}服务状态:${RESET}"
    echo
    
    if has_systemctl; then
        for svc in argo-tunnel xray-tunnel anytls reality; do
            if [[ -f "${SERVICE_DIR}/${svc}.service" ]]; then
                if systemctl is-active --quiet "$svc"; then
                    echo -e "  ${GREEN}●${RESET} ${svc}: 运行中"
                else
                    echo -e "  ${RED}●${RESET} ${svc}: 已停止"
                fi
            fi
        done
    else
        echo -e "${WARNING} 无 systemd，检查进程:"
        pgrep -f "cloudflared" >/dev/null && echo -e "  ${GREEN}●${RESET} cloudflared: 运行中" || echo -e "  ${RED}●${RESET} cloudflared: 已停止"
        pgrep -f "xray" >/dev/null && echo -e "  ${GREEN}●${RESET} xray: 运行中" || echo -e "  ${RED}●${RESET} xray: 已停止"
        pgrep -f "anytls" >/dev/null && echo -e "  ${GREEN}●${RESET} anytls: 运行中" || echo -e "  ${RED}●${RESET} anytls: 已停止"
        pgrep -f "sing-box" >/dev/null && echo -e "  ${GREEN}●${RESET} sing-box: 运行中" || echo -e "  ${RED}●${RESET} sing-box: 已停止"
    fi
}

show_services_logs() {
    echo -e "${CYAN}选择要查看的日志:${RESET}"
    echo "  1) Argo"
    echo "  2) Xray"
    echo "  3) AnyTLS"
    echo "  4) Reality"
    read -rp "请选择 [1-4]: " log_choice
    
    case "$log_choice" in
        1) tail -n 50 "${LOG_DIR}/argo.log" 2>/dev/null || echo "日志文件不存在" ;;
        2) tail -n 50 "${LOG_DIR}/xray.log" 2>/dev/null || echo "日志文件不存在" ;;
        3) tail -n 50 "${LOG_DIR}/anytls.log" 2>/dev/null || echo "日志文件不存在" ;;
        4) tail -n 50 "${LOG_DIR}/reality.log" 2>/dev/null || echo "日志文件不存在" ;;
        *) echo -e "${ERROR} 无效选择" ;;
    esac
}

# ===== 节点信息查看 =====
view_all_nodes() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║          所有节点信息                 ║${RESET}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${RESET}"
    echo
    
    local found=0
    
    # Argo 节点
    if ls "${LINK_DIR}"/argo_*.txt >/dev/null 2>&1; then
        for file in "${LINK_DIR}"/argo_*.txt; do
            cat "$file"
            echo
            found=1
        done
    fi
    
    # AnyTLS 节点
    if [[ -f "${ANYTLS_CONFIG}" ]]; then
        local port password sni
        port=$(grep '^listen_port=' "${ANYTLS_CONFIG}" | cut -d= -f2)
        password=$(grep '^password=' "${ANYTLS_CONFIG}" | cut -d= -f2)
        sni=$(grep '^sni=' "${ANYTLS_CONFIG}" | cut -d= -f2)
        
        if [[ -n "$port" && -n "$password" ]]; then
            show_anytls_info "$port" "$password" "$sni"
            echo
            found=1
        fi
    fi
    
    # Reality 节点
    if [[ -f "${REALITY_INFO}" ]]; then
        show_reality_info
        echo
        found=1
    fi
    
    if [[ $found -eq 0 ]]; then
        echo -e "${WARNING} 未找到任何已配置的节点"
    fi
}

# ===== 卸载功能 =====
uninstall_all() {
    clear
    echo -e "${RED}╔═══════════════════════════════════════╗${RESET}"
    echo -e "${RED}║          卸载所有服务                 ║${RESET}"
    echo -e "${RED}╚═══════════════════════════════════════╝${RESET}"
    echo
    echo -e "${WARNING} 此操作将删除所有配置和服务"
    echo
    read -rp "确认卸载? (输入 YES 确认): " confirm
    
    if [[ "$confirm" != "YES" ]]; then
        echo -e "${INFO} 已取消"
        return
    fi
    
    echo -e "${INFO} 停止所有服务..."
    stop_all_services
    
    if has_systemctl; then
        echo -e "${INFO} 删除 systemd 服务..."
        for svc in argo-tunnel xray-tunnel anytls reality; do
            systemctl disable "$svc" 2>/dev/null || true
            rm -f "${SERVICE_DIR}/${svc}.service"
        done
        systemctl daemon-reload
    fi
    
    echo -e "${INFO} 删除文件..."
    rm -rf "${BASE_DIR}"
    rm -rf ~/.cloudflared
    rm -f /usr/local/bin/ut
    
    echo
    echo -e "${INFO} 卸载完成"
    echo
    echo -e "${YELLOW}如需彻底删除 Cloudflare 授权:${RESET}"
    echo "  访问: https://dash.cloudflare.com/profile/api-tokens"
    echo "  删除 Argo Tunnel API Token"
}

# ===== 快捷命令安装 =====
install_shortcut() {
    local shortcut="/usr/local/bin/ut"
    cat > "$shortcut" <<'SHORTCUT_EOF'
#!/usr/bin/env bash
bash /opt/unified-tunnel/unified-tunnel.sh "$@"
SHORTCUT_EOF
    chmod +x "$shortcut"
    
    # 复制脚本到安装目录
    if [[ -f "$0" && "$0" != "${BASE_DIR}/unified-tunnel.sh" ]]; then
        cp "$0" "${BASE_DIR}/unified-tunnel.sh"
        chmod +x "${BASE_DIR}/unified-tunnel.sh"
    fi
}

# ===== 主菜单 =====
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'BANNER'
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║        统一隧道管理脚本 v2.0                             ║
║        Unified Tunnel Manager                            ║
║                                                          ║
║  支持协议:                                               ║
║    • Argo Tunnel (Quick/Fixed)                          ║
║    • Xray (VMess/VLESS)                                 ║
║    • AnyTLS                                             ║
║    • Reality (VLESS-Vision)                             ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
BANNER
    echo -e "${RESET}"
}

main_menu() {
    while true; do
        show_banner
        
        echo -e "${PURPLE}【Argo 隧道】${RESET}"
        echo "  1) Argo Quick Tunnel (临时域名)"
        echo "  2) Argo Tunnel (固定域名)"
        echo
        echo -e "${PURPLE}【其他协议】${RESET}"
        echo "  3) 安装 AnyTLS 节点"
        echo "  4) 安装 Reality (VLESS-Vision) 节点"
        echo
        echo -e "${PURPLE}【管理功能】${RESET}"
        echo "  5) 查看所有节点信息"
        echo "  6) 服务管理 (启动/停止/重启/状态)"
        echo "  7) 更新核心程序"
        echo "  8) 卸载所有服务"
        echo
        echo "  0) 退出"
        echo
        read -rp "请选择 [0-8]: " choice
        
        case "$choice" in
            1) install_argo_quick ;;
            2) install_argo_tunnel ;;
            3) install_anytls ;;
            4) install_reality ;;
            5) view_all_nodes ;;
            6) manage_services ;;
            7) update_cores ;;
            8) uninstall_all ;;
            0) echo -e "${INFO} 退出"; exit 0 ;;
            *) echo -e "${ERROR} 无效选择" ;;
        esac
        
        if [[ "$choice" != "6" ]]; then
            echo
            read -rp "按回车继续..."
        fi
    done
}

update_cores() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║          更新核心程序                 ║${RESET}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${RESET}"
    echo
    echo "  1) 更新 Cloudflared"
    echo "  2) 更新 Xray"
    echo "  3) 更新 AnyTLS"
    echo "  4) 更新 sing-box"
    echo "  5) 更新全部"
    echo "  0) 返回"
    echo
    read -rp "请选择 [0-5]: " choice
    
    case "$choice" in
        1) download_cloudflared ;;
        2) download_xray ;;
        3) download_anytls ;;
        4) download_singbox ;;
        5)
            download_cloudflared
            download_xray
            download_anytls
            download_singbox
            echo -e "${INFO} 全部更新完成，建议重启服务"
            ;;
        0) return ;;
        *) echo -e "${ERROR} 无效选择" ;;
    esac
}

# ===== 程序入口 =====
main() {
    check_root
    detect_os
    detect_arch
    
    echo -e "${INFO} 系统: ${OS_NAME}"
    echo -e "${INFO} 架构: ${ARCH}"
    
    if [[ "$ARCH" == "unknown" ]]; then
        echo -e "${ERROR} 不支持的系统架构"
        exit 1
    fi
    
    init_directories
    check_dependencies
    install_shortcut
    
    main_menu
}

# 执行主程序
main "$@"
