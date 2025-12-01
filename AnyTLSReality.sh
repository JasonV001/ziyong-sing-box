#!/bin/bash
set -e

RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m'

SING_BOX_BIN="/usr/local/bin/sing-box"
CONF_DIR="/usr/local/etc/sing-box"
ANYTLS_CONF="$CONF_DIR/anytls.json"
REALITY_CONF="$CONF_DIR/reality.json"
ANYTLS_INFO="$CONF_DIR/anytls.info"
REALITY_INFO="$CONF_DIR/reality.info"
ANYTLS_SERVICE="sing-box-anytls.service"
REALITY_SERVICE="sing-box-reality.service"
# 请把下面地址改成你实际的 Raw 链接
SCRIPT_URL="https://raw.githubusercontent.com/JasonV001/ziyong-sing-box/refs/heads/main/AnyTLSReality.sh"
SCRIPT_PATH="/usr/local/bin/anytls-reality.sh"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}请使用 root 用户运行本脚本${NC}"
        exit 1
    fi
}

install_pkgs() {
    # 极简：只检查命令，不自动安装系统包
    local CMDS=(bash curl wget tar openssl xxd)

    local missing=()
    for c in "${CMDS[@]}"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            missing+=("$c")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}缺少以下必需命令，请手动安装后再运行本脚本：${NC}"
        printf '  - %s\n' "${missing[@]}"
        echo
        echo "Debian/Ubuntu 示例：apt-get install -y ${missing[*]}"
        echo "CentOS/RHEL 示例：yum install -y ${missing[*]}"
        echo "Alpine 示例：apk add --no-cache ${missing[*]}"
        exit 1
    fi
}

install_sing_box() {
    if [[ -x "$SING_BOX_BIN" ]]; then
        return
    fi

    mkdir -p "$CONF_DIR"

    local arch=$(uname -m)
    local url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    local download_url=""

    case $arch in
        x86_64|amd64)
            download_url=$(curl -s "$url" | grep -o "https://github.com[^\"']*linux-amd64.tar.gz" | head -n 1)
            ;;
        armv7l)
            download_url=$(curl -s "$url" | grep -o "https://github.com[^\"']*linux-armv7.tar.gz" | head -n 1)
            ;;
        aarch64|arm64)
            download_url=$(curl -s "$url" | grep -o "https://github.com[^\"']*linux-arm64.tar.gz" | head -n 1)
            ;;
        amd64v3)
            download_url=$(curl -s "$url" | grep -o "https://github.com[^\"']*linux-amd64v3.tar.gz" | head -n 1)
            ;;
        s390x)
            download_url=$(curl -s "$url" | grep -o "https://github.com[^\"']*linux-s390x.tar.gz" | head -n 1)
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

prompt_anytls() {
    echo -e "${CYAN}=== AnyTLS (trojan) 参数配置 ===${NC}"
    while true; do
        read -rp "监听端口 (默认 443): " ANYTLS_PORT
        ANYTLS_PORT=${ANYTLS_PORT:-443}
        if [[ $ANYTLS_PORT =~ ^[1-9][0-9]{0,4}$ && $ANYTLS_PORT -le 65535 ]]; then
            # 如果已经有 Reality，避免端口相同
            if [[ -f "$REALITY_INFO" ]]; then
                local r_port
                r_port=$(grep '^PORT=' "$REALITY_INFO" 2>/dev/null | cut -d= -f2)
                if [[ -n "$r_port" && "$r_port" == "$ANYTLS_PORT" ]]; then
                    echo -e "${RED}当前 Reality 使用端口 $r_port，请选择不同端口${NC}"
                    continue
                fi
            fi
            break
        else
            echo -e "${RED}端口范围 1-65535，请重新输入${NC}"
        fi
    done

    read -rp "SNI 域名（例如 time.is）: " ANYTLS_SNI
    if [[ -z "$ANYTLS_SNI" ]]; then
        echo -e "${RED}SNI 域名不能为空${NC}"
        exit 1
    fi

    ANYTLS_PASSWORD=$(gen_uuid)

    cat >"$ANYTLS_INFO" <<EOF
PORT=$ANYTLS_PORT
SNI=$ANYTLS_SNI
PASSWORD=$ANYTLS_PASSWORD
EOF
}

write_anytls_config() {
    mkdir -p "$CONF_DIR"

    . "$ANYTLS_INFO"

    cat >"$ANYTLS_CONF" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "trojan",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "password": "$PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
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

write_anytls_service() {
    cat >/etc/systemd/system/$ANYTLS_SERVICE <<EOF
[Unit]
Description=sing-box AnyTLS
After=network.target nss-lookup.target

[Service]
ExecStart=$SING_BOX_BIN run -c $ANYTLS_CONF
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$ANYTLS_SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$ANYTLS_SERVICE"
}

install_anytls() {
    install_sing_box
    prompt_anytls
    write_anytls_config
    write_anytls_service
    echo -e "${YELLOW}AnyTLS 节点已安装并启动${NC}"
}

prompt_reality() {
    echo -e "${CYAN}=== Reality (vless-vision) 参数配置 ===${NC}"
    while true; do
        read -rp "监听端口 (默认 8443): " REALITY_PORT
        REALITY_PORT=${REALITY_PORT:-8443}
        if [[ $REALITY_PORT =~ ^[1-9][0-9]{0,4}$ && $REALITY_PORT -le 65535 ]]; then
            # 如果已经有 AnyTLS，避免端口相同
            if [[ -f "$ANYTLS_INFO" ]]; then
                local a_port
                a_port=$(grep '^PORT=' "$ANYTLS_INFO" 2>/dev/null | cut -d= -f2)
                if [[ -n "$a_port" && "$a_port" == "$REALITY_PORT" ]]; then
                    echo -e "${RED}当前 AnyTLS 使用端口 $a_port，请选择不同端口${NC}"
                    continue
                fi
            fi
            break
        else
            echo -e "${RED}端口范围 1-65535，请重新输入${NC}"
        fi
    done

    read -rp "真实站点域名（用于握手，例如 time.is）: " REAL_HOST
    if [[ -z "$REAL_HOST" ]]; then
        echo -e "${RED}真实域名不能为空${NC}"
        exit 1
    fi

    read -rp "Reality SNI（默认与真实域名相同）: " REALITY_SNI
    REALITY_SNI=${REALITY_SNI:-$REAL_HOST}

    read -rp "Reality short_id（默认随机 8 位十六进制）: " REALITY_SHORT_ID
    if [[ -z "$REALITY_SHORT_ID" ]]; then
        REALITY_SHORT_ID=$(openssl rand -hex 4)
    fi

    REALITY_UUID=$(gen_uuid)
    gen_reality_keypair

    cat >"$REALITY_INFO" <<EOF
PORT=$REALITY_PORT
REAL_HOST=$REAL_HOST
SNI=$REALITY_SNI
UUID=$REALITY_UUID
PUBLIC_KEY=$REALITY_PUBLIC_KEY
PRIVATE_KEY=$REALITY_PRIVATE_KEY
SHORT_ID=$REALITY_SHORT_ID
EOF
}

write_reality_config() {
    mkdir -p "$CONF_DIR"
    . "$REALITY_INFO"

    cat >"$REALITY_CONF" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "reality-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$REAL_HOST",
            "server_port": 443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": [
            "$SHORT_ID"
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

write_reality_service() {
    cat >/etc/systemd/system/$REALITY_SERVICE <<EOF
[Unit]
Description=sing-box Reality (vless-vision)
After=network.target nss-lookup.target

[Service]
ExecStart=$SING_BOX_BIN run -c $REALITY_CONF
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$REALITY_SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$REALITY_SERVICE"
}

install_reality() {
    install_sing_box
    prompt_reality
    write_reality_config
    write_reality_service
    echo -e "${YELLOW}Reality 节点已安装并启动${NC}"
}

show_info() {
    # 自动检测机器公网 IP（IPv4 优先）
    local IP4
    IP4=$(curl -s4 icanhazip.com || curl -s4 ip.sb || hostname -I 2>/dev/null | awk '{print $1}')

    echo -e "${CYAN}=== 节点信息 ===${NC}"

    if [[ -f "$ANYTLS_INFO" ]]; then
        . "$ANYTLS_INFO"
        echo -e "${YELLOW}AnyTLS 节点：${NC}"
        echo "  协议: anytls"
        echo "  地址: ${IP4:-你的服务器 IP}"
        echo "  端口: $PORT"
        echo "  密码: $PASSWORD"
        echo "  SNI : $SNI"
        echo
    else
        echo "未安装 AnyTLS 节点"
        echo
    fi

    if [[ -f "$REALITY_INFO" ]]; then
        . "$REALITY_INFO"
        echo -e "${YELLOW}Reality (vless-vision) 节点：${NC}"
        echo "  协议: vless"
        echo "  地址: ${IP4:-你的服务器 IP}"
        echo "  端口: $PORT"
        echo "  UUID : $UUID"
        echo "  server_name: $SNI"
        echo "  reality 公钥: $PUBLIC_KEY"
        echo "  reality short_id: $SHORT_ID"
        echo
    else
        echo "未安装 Reality 节点"
        echo
    fi
}

nodes_manage_menu() {
    echo -e "${CYAN}=== 节点管理 ===${NC}"
    echo "1) 启动全部节点"
    echo "2) 停止全部节点"
    echo "3) 重启全部节点"
    echo "4) 查看状态"
    echo "0) 返回主菜单"
    read -rp "请选择: " opt
    case "$opt" in
        1)
            systemctl start "$ANYTLS_SERVICE" 2>/dev/null || true
            systemctl start "$REALITY_SERVICE" 2>/dev/null || true
            ;;
        2)
            systemctl stop "$ANYTLS_SERVICE" 2>/dev/null || true
            systemctl stop "$REALITY_SERVICE" 2>/dev/null || true
            ;;
        3)
            systemctl restart "$ANYTLS_SERVICE" 2>/dev/null || true
            systemctl restart "$REALITY_SERVICE" 2>/dev/null || true
            ;;
        4)
            systemctl status "$ANYTLS_SERVICE" 2>/dev/null || echo "AnyTLS 服务不存在或未安装"
            systemctl status "$REALITY_SERVICE" 2>/dev/null || echo "Reality 服务不存在或未安装"
            ;;
    esac
}

enable_bbr() {
    if grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null; then
        echo "BBR 已配置，跳过。"
        return
    fi
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
    echo "BBR 配置完成（如内核支持则生效）。"
}

update_script() {
    if [[ -z "$SCRIPT_URL" ]]; then
        echo -e "${RED}脚本更新地址未配置${NC}"
        return
    fi
    wget -N -O "$SCRIPT_PATH" "$SCRIPT_URL"
    chmod +x "$SCRIPT_PATH"
    echo "脚本已更新，重新运行即可生效。"
}

uninstall_all() {
    systemctl stop "$ANYTLS_SERVICE" 2>/dev/null || true
    systemctl stop "$REALITY_SERVICE" 2>/dev/null || true
    systemctl disable "$ANYTLS_SERVICE" "$REALITY_SERVICE" 2>/dev/null || true
    rm -f /etc/systemd/system/"$ANYTLS_SERVICE" /etc/systemd/system/"$REALITY_SERVICE"
    systemctl daemon-reload

    rm -f "$ANYTLS_CONF" "$REALITY_CONF" "$ANYTLS_INFO" "$REALITY_INFO"
    echo "已卸载 AnyTLS / Reality 配置和服务（sing-box 二进制保留）。"
}

main_menu() {
    while true; do
        echo -e "${CYAN}=== AnyTLS & Reality 管理脚本 ===${NC}"
        echo "1) 安装 / 重新安装 AnyTLS 节点"
        echo "2) 安装 / 重新安装 Reality (vless-vision) 节点"
        echo "3) 查看节点信息"
        echo "4) 节点管理（启动 / 停止 / 重启 / 状态）"
        echo "5) 开启 BBR（简单内核参数配置）"
        echo "6) 更新脚本"
        echo "7) 卸载全部节点与配置"
        echo "0) 退出"
        read -rp "请选择: " choice
        case "$choice" in
            1) install_anytls ;;
            2) install_reality ;;
            3) show_info ;;
            4) nodes_manage_menu ;;
            5) enable_bbr ;;
            6) update_script ;;
            7) uninstall_all ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${NC}" ;;
        esac
        echo
    done
}

main() {
    check_root
    install_pkgs
    main_menu
}

main
