#!/bin/bash
set -e

RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m'

SING_BOX_BIN="/usr/local/bin/sing-box"
SING_BOX_CONF_DIR="/usr/local/etc/sing-box"
SING_BOX_CONF="$SING_BOX_CONF_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

install_pkgs() {
    local PKGS_DEB=(curl wget tar jq openssl xxd)
    local PKGS_RHEL=(curl wget tar jq openssl vim-common)
    local PKGS_ALPINE=(bash curl wget tar jq openssl xxd)

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        local OS_ID=${ID,,}
        local OS_LIKE=${ID_LIKE,,}
    else
        echo -e "${RED}无法检测系统类型！${NC}"
        exit 1
    fi

    local SUPPORTED=("debian" "ubuntu" "centos" "rhel" "rocky" "almalinux" "fedora" "alpine")
    if ! [[ " ${SUPPORTED[*]} " =~ " ${OS_ID} " ]] && ! [[ " ${SUPPORTED[*]} " =~ " ${OS_LIKE} " ]]; then
        echo -e "${RED}不支持的系统类型: $OS_ID${NC}"
        exit 1
    fi

    if [[ "$OS_ID" =~ (debian|ubuntu) ]] || [[ "$OS_LIKE" =~ (debian|ubuntu) ]]; then
        local MISSING=()
        for pkg in "${PKGS_DEB[@]}"; do
            dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
        done
        if [[ ${#MISSING[@]} -gt 0 ]]; then
            apt-get update -y -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${MISSING[@]}"
        fi
    elif [[ "$OS_ID" =~ (centos|rhel|rocky|almalinux|fedora) ]] || [[ "$OS_LIKE" =~ (rhel|fedora|centos) ]]; then
        local PKG_MGR="yum"
        command -v dnf &>/dev/null && PKG_MGR="dnf"
        local MISSING=()
        for pkg in "${PKGS_RHEL[@]}"; do
            rpm -q "$pkg" &>/dev/null || MISSING+=("$pkg")
        done
        if [[ ${#MISSING[@]} -gt 0 ]]; then
            $PKG_MGR makecache -q
            $PKG_MGR install -y "${MISSING[@]}"
        fi
    elif [[ "$OS_ID" == "alpine" || "$OS_LIKE" == "alpine" ]]; then
        local MISSING=()
        for pkg in "${PKGS_ALPINE[@]}"; do
            apk info -e "$pkg" &>/dev/null || MISSING+=("$pkg")
        done
        if [[ ${#MISSING[@]} -gt 0 ]]; then
            apk update -q
            apk add --no-cache "${MISSING[@]}"
        fi
    fi
}

install_sing_box() {
    if [[ -x "$SING_BOX_BIN" ]]; then
        echo "sing-box 已存在，跳过安装。"
        return
    fi

    mkdir -p "$SING_BOX_CONF_DIR"

    local arch=$(uname -m)
    local url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    local download_url=""

    case $arch in
        x86_64|amd64)
            download_url=$(curl -s $url | grep -o "https://github.com[^\"']*linux-amd64.tar.gz" | head -n 1)
            ;;
        armv7l)
            download_url=$(curl -s $url | grep -o "https://github.com[^\"']*linux-armv7.tar.gz" | head -n 1)
            ;;
        aarch64|arm64)
            download_url=$(curl -s $url | grep -o "https://github.com[^\"']*linux-arm64.tar.gz" | head -n 1)
            ;;
        amd64v3)
            download_url=$(curl -s $url | grep -o "https://github.com[^\"']*linux-amd64v3.tar.gz" | head -n 1)
            ;;
        s390x)
            download_url=$(curl -s $url | grep -o "https://github.com[^\"']*linux-s390x.tar.gz" | head -n 1)
            ;;
        *)
            echo -e "${RED}不支持的架构：$arch${NC}"
            exit 1
            ;;
    esac

    if [[ -z "$download_url" ]]; then
        echo -e "${RED}获取 sing-box 下载链接失败${NC}"
        exit 1
    fi

    echo "下载 sing-box..."
    wget -qO /tmp/sing-box.tar.gz "$download_url"
    tar -xzf /tmp/sing-box.tar.gz -C /tmp
    local extracted_bin
    extracted_bin=$(find /tmp -maxdepth 3 -type f -name "sing-box" | head -n 1)
    if [[ -z "$extracted_bin" ]]; then
        echo -e "${RED}找不到 sing-box 可执行文件${NC}"
        exit 1
    fi
    mv "$extracted_bin" "$SING_BOX_BIN"
    chmod +x "$SING_BOX_BIN"
    rm -f /tmp/sing-box.tar.gz
}

gen_uuid() {
    if command -v "$SING_BOX_BIN" >/dev/null 2>&1; then
        "$SING_BOX_BIN" generate uuid
    else
        openssl rand -hex 16 | awk '{print substr($1,1,8) "-" substr($1,9,4) "-" substr($1,13,4) "-" substr($1,17,4) "-" substr($1,21)}'
    fi
}

gen_reality_keypair() {
    local key priv pub
    key=$(openssl genpkey -algorithm X25519 | openssl pkey -text -noout)
    priv=$(echo "$key" | grep -A 3 "priv:" | tail -n +2 | tr -d ' \n:' | xxd -r -p | base64)
    pub=$(echo "$key" | grep -A 3 "pub:" | tail -n +2 | tr -d ' \n:' | xxd -r -p | base64)
    REALITY_PRIVATE_KEY="$priv"
    REALITY_PUBLIC_KEY="$pub"
}

ask_params() {
    echo -e "${CYAN}=== AnyTLS & Reality 参数配置 ===${NC}"

    read -rp "监听端口 (默认 443): " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-443}

    read -rp "真实域名（用于 Reality / SNI）: " REAL_HOST
    if [[ -z "$REAL_HOST" ]]; then
        echo -e "${RED}真实域名不能为空${NC}"
        exit 1
    fi

    read -rp "Reality 验证用的 SNI（默认与真实域名相同）: " REALITY_SERVER_NAME
    REALITY_SERVER_NAME=${REALITY_SERVER_NAME:-$REAL_HOST}

    read -rp "Reality short_id（默认随机 8 位十六进制）: " REALITY_SHORT_ID
    if [[ -z "$REALITY_SHORT_ID" ]]; then
        REALITY_SHORT_ID=$(openssl rand -hex 4)
    fi

    ANYTLS_PASSWORD=$(gen_uuid)
    REALITY_UUID=$(gen_uuid)

    echo -e "${YELLOW}AnyTLS 密码: ${ANYTLS_PASSWORD}${NC}"
    echo -e "${YELLOW}Reality UUID: ${REALITY_UUID}${NC}"
}

write_config() {
    mkdir -p "$SING_BOX_CONF_DIR"

    cat >"$SING_BOX_CONF" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "trojan",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $LISTEN_PORT,
      "users": [
        {
          "password": "$ANYTLS_PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$REAL_HOST",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        }
      }
    },
    {
      "type": "vless",
      "tag": "reality-in",
      "listen": "::",
      "listen_port": $LISTEN_PORT,
      "users": [
        {
          "uuid": "$REALITY_UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SERVER_NAME",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$REAL_HOST",
            "server_port": 443
          },
          "private_key": "$REALITY_PRIVATE_KEY",
          "short_id": [
            "$REALITY_SHORT_ID"
          ]
        },
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
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
}

write_service() {
    echo "配置 systemd 服务..."
    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box service (AnyTLS & Reality)
After=network.target nss-lookup.target

[Service]
ExecStart=$SING_BOX_BIN run -c $SING_BOX_CONF
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box.service >/dev/null 2>&1 || true
    systemctl restart sing-box.service
}

show_info() {
    echo -e "${CYAN}=== 节点信息 ===${NC}"
    echo -e "${YELLOW}AnyTLS (trojan)：${NC}"
    echo "  协议: trojan"
    echo "  地址: 你的服务器 IP"
    echo "  端口: $LISTEN_PORT"
    echo "  密码: $ANYTLS_PASSWORD"
    echo "  SNI : $REAL_HOST"

    echo
    echo -e "${YELLOW}Reality (vless-vision)：${NC}"
    echo "  协议: vless"
    echo "  UUID : $REALITY_UUID"
    echo "  端口: $LISTEN_PORT"
    echo "  server_name: $REALITY_SERVER_NAME"
    echo "  reality 公钥: $REALITY_PUBLIC_KEY"
    echo "  reality short_id: $REALITY_SHORT_ID"
}

main() {
    install_pkgs
    install_sing_box
    ask_params
    gen_reality_keypair
    write_config
    write_service
    show_info
    echo -e "${CYAN}安装完成，服务已启动。如有问题请执行：journalctl -u sing-box -e${NC}"
}

main
