#!/bin/bash
# ============================================================
#  Reality + Hysteria2 一键安装脚本 v3
#  适用系统: Debian 12
#  v3: 自定义节点名称 + 自动生成 Clash Verge (mihomo) 配置
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---- 检查 root ----
[[ $EUID -ne 0 ]] && echo -e "${RED}请以 root 权限运行此脚本${NC}" && exit 1

# ---- 全局变量 ----
XRAY_CONFIG="/usr/local/etc/xray/config.json"
HY2_CONFIG="/etc/hysteria/config.yaml"
HY2_CERT_DIR="/etc/hysteria/certs"

# ============================================================
#  工具函数
# ============================================================
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
title()   { echo -e "\n${BOLD}${CYAN}===== $* =====${NC}\n"; }
confirm() {
    read -rp "$1 [y/N]: " ans
    [[ "${ans,,}" == "y" ]]
}

random_port() {
    local lo=${1:-10000} hi=${2:-60000}
    echo $(( RANDOM % (hi - lo + 1) + lo ))
}

gen_uuid() { cat /proc/sys/kernel/random/uuid; }

get_public_ip() {
    curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || \
    curl -s6 --max-time 5 https://api6.ipify.org 2>/dev/null || \
    echo "YOUR_IP"
}

install_deps() {
    title "安装基础依赖"
    apt-get update -qq
    apt-get install -y -qq curl wget unzip openssl qrencode jq coreutils lsof net-tools
    info "依赖安装完成"
}

# ============================================================
#  [修正] 开启 BBR 加速
# ============================================================
enable_bbr() {
    title "开启 BBR 加速"
    local current
    current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$current" == "bbr" ]]; then
        info "BBR 已经是启用状态，跳过"
        return
    fi
    # 写入内核参数
    grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf || \
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf || \
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

    # 避免重复写入
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

    sysctl -p &>/dev/null
    current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$current" == "bbr" ]]; then
        info "BBR 开启成功"
    else
        warn "BBR 开启失败，当前算法: $current（不影响节点使用）"
    fi
}

# ============================================================
#  Reality (Xray) 安装
# ============================================================
install_xray() {
    title "安装 Xray-core (Reality)"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    [[ $? -ne 0 ]] && error "Xray 安装失败"
    info "Xray 安装成功: $(xray version | head -1)"
}

configure_reality() {
    title "配置 VLESS-Reality"

    read -rp "监听端口 [默认随机]: " REALITY_PORT
    [[ -z "$REALITY_PORT" ]] && REALITY_PORT=$(random_port 10000 50000)

    read -rp "节点名称 [默认 Reality]: " REALITY_NAME
    [[ -z "$REALITY_NAME" ]] && REALITY_NAME="Reality"

    read -rp "伪装域名 [默认 www.microsoft.com]: " REALITY_DEST
    [[ -z "$REALITY_DEST" ]] && REALITY_DEST="www.microsoft.com"

    # 生成密钥对
    KEYS=$(xray x25519)
    REALITY_PRIVATE=$(echo "$KEYS" | grep 'Private' | awk '{print $NF}')
    REALITY_PUBLIC=$(echo "$KEYS"  | grep 'Public'  | awk '{print $NF}')
    REALITY_UUID=$(gen_uuid)
    REALITY_SID=$(openssl rand -hex 8)
    REALITY_SNI="$REALITY_DEST"

    mkdir -p /usr/local/etc/xray
    cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${REALITY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${REALITY_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}:443",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${REALITY_PRIVATE}",
          "shortIds": ["${REALITY_SID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http","tls","quic"]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

    systemctl enable xray --now && systemctl restart xray
    sleep 1
    systemctl is-active --quiet xray && info "Xray 服务运行正常" || warn "Xray 服务启动失败，请检查日志: journalctl -u xray -n 20"

    local SERVER_IP
    SERVER_IP=$(get_public_ip)

    cat > /root/reality_info.txt <<EOF
===== VLESS-Reality 配置信息 =====
IP       : ${SERVER_IP}
端口     : ${REALITY_PORT}
UUID     : ${REALITY_UUID}
公钥     : ${REALITY_PUBLIC}
ShortID  : ${REALITY_SID}
SNI      : ${REALITY_SNI}
Flow     : xtls-rprx-vision
EOF

    local SHARE_LINK="vless://${REALITY_UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SID}&type=tcp#${REALITY_NAME}"
    echo "$SHARE_LINK" >> /root/reality_info.txt

    # Clash 节点片段
    cat > /root/clash_reality.part <<CEOF
  - name: "${REALITY_NAME}"
    type: vless
    server: ${SERVER_IP}
    port: ${REALITY_PORT}
    uuid: ${REALITY_UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${REALITY_PUBLIC}
      short-id: ${REALITY_SID}
CEOF

    echo ""
    cat /root/reality_info.txt
    echo ""
    info "分享链接："
    echo -e "${CYAN}${SHARE_LINK}${NC}"

    if command -v qrencode &>/dev/null; then
        echo ""
        info "扫码导入："
        qrencode -t ansiutf8 "$SHARE_LINK"
    fi
}

# ============================================================
#  Hysteria2 安装
# ============================================================
install_hysteria2() {
    title "安装 Hysteria2"
    bash <(curl -fsSL https://get.hy2.sh/)
    [[ $? -ne 0 ]] && error "Hysteria2 安装失败"
    info "Hysteria2 安装成功: $(hysteria version 2>&1 | head -1)"
}

# ============================================================
#  [修正] configure_hysteria2
#  修正点：
#  1. 先生成证书，再写配置文件（原版顺序相同但权限未设置）
#  2. 官方安装脚本会写入空配置，必须在安装后覆盖写入
#  3. 证书目录/文件权限正确归属 hysteria 用户
#  4. 启动前等待 systemd reload
# ============================================================
configure_hysteria2() {
    title "配置 Hysteria2"

    read -rp "监听端口 [默认随机]: " HY2_PORT
    [[ -z "$HY2_PORT" ]] && HY2_PORT=$(random_port 20000 59999)

    read -rp "节点名称 [默认 Hysteria2]: " HY2_NAME
    [[ -z "$HY2_NAME" ]] && HY2_NAME="Hysteria2"

    read -rp "认证密码 [默认随机生成]: " HY2_PASSWORD
    [[ -z "$HY2_PASSWORD" ]] && HY2_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/')

    echo ""
    echo "证书方式："
    echo "  1) 自签证书 (无需域名，推荐)"
    echo "  2) ACME 自动申请 (需要域名)"
    read -rp "选择 [1]: " CERT_MODE
    [[ -z "$CERT_MODE" ]] && CERT_MODE=1

    # ---- 步骤1: 先创建证书目录 ----
    mkdir -p "$HY2_CERT_DIR"

    if [[ "$CERT_MODE" == "2" ]]; then
        read -rp "输入你的域名: " HY2_DOMAIN
        [[ -z "$HY2_DOMAIN" ]] && error "域名不能为空"
        HY2_SNI="$HY2_DOMAIN"

        systemctl stop nginx 2>/dev/null
        systemctl stop apache2 2>/dev/null

        # ---- 步骤2: 写入 ACME 配置 ----
        cat > "$HY2_CONFIG" <<EOF
listen: :${HY2_PORT}

acme:
  domains:
    - ${HY2_DOMAIN}
  email: admin@${HY2_DOMAIN}

auth:
  type: password
  password: ${HY2_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true

bandwidth:
  up: 1 gbps
  down: 1 gbps
EOF

    else
        HY2_SNI="bing.com"

        # ---- 步骤2: 先生成自签证书 ----
        info "生成自签证书..."
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
            -keyout "${HY2_CERT_DIR}/private.key" \
            -out    "${HY2_CERT_DIR}/cert.crt" \
            -days 3650 \
            -subj "/CN=${HY2_SNI}" 2>/dev/null

        [[ ! -f "${HY2_CERT_DIR}/cert.crt" ]] && error "证书生成失败"
        info "证书生成成功"

        # ---- 步骤3: 写入配置（证书路径已确认存在）----
        cat > "$HY2_CONFIG" <<EOF
listen: :${HY2_PORT}

tls:
  cert: ${HY2_CERT_DIR}/cert.crt
  key: ${HY2_CERT_DIR}/private.key

auth:
  type: password
  password: ${HY2_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://bing.com/
    rewriteHost: true

bandwidth:
  up: 1 gbps
  down: 1 gbps
EOF

        # ---- 步骤4: 修复权限（hysteria 用户需能读取证书）----
        chown -R hysteria:hysteria /etc/hysteria/
        chmod 750 "$HY2_CERT_DIR"
        chmod 640 "${HY2_CERT_DIR}/private.key"
        chmod 644 "${HY2_CERT_DIR}/cert.crt"
        info "权限设置完成"
    fi

    # ---- 步骤5: 启动服务 ----
    systemctl daemon-reload
    systemctl enable hysteria-server
    systemctl restart hysteria-server
    sleep 2

    if systemctl is-active --quiet hysteria-server; then
        info "Hysteria2 服务运行正常"
    else
        warn "Hysteria2 启动失败，错误信息："
        journalctl -u hysteria-server -n 10 --no-pager
    fi

    local SERVER_IP
    SERVER_IP=$(get_public_ip)

    cat > /root/hysteria2_info.txt <<EOF
===== Hysteria2 配置信息 =====
IP       : ${SERVER_IP}
端口     : ${HY2_PORT}
密码     : ${HY2_PASSWORD}
SNI      : ${HY2_SNI}
证书模式 : $( [[ "$CERT_MODE" == "2" ]] && echo "ACME域名" || echo "自签(insecure)" )
EOF

    local SHARE_LINK
    if [[ "$CERT_MODE" == "2" ]]; then
        SHARE_LINK="hysteria2://${HY2_PASSWORD}@${HY2_DOMAIN}:${HY2_PORT}?sni=${HY2_SNI}#${HY2_NAME}"
    else
        SHARE_LINK="hysteria2://${HY2_PASSWORD}@${SERVER_IP}:${HY2_PORT}?insecure=1&sni=${HY2_SNI}#${HY2_NAME}"
    fi
    echo "$SHARE_LINK" >> /root/hysteria2_info.txt

    # Clash 节点片段
    local CLASH_SERVER="$SERVER_IP" CLASH_SKIP="true"
    if [[ "$CERT_MODE" == "2" ]]; then
        CLASH_SERVER="$HY2_DOMAIN"; CLASH_SKIP="false"
    fi
    cat > /root/clash_hy2.part <<CEOF
  - name: "${HY2_NAME}"
    type: hysteria2
    server: ${CLASH_SERVER}
    port: ${HY2_PORT}
    password: ${HY2_PASSWORD}
    sni: ${HY2_SNI}
    skip-cert-verify: ${CLASH_SKIP}
    alpn:
      - h3
CEOF

    echo ""
    cat /root/hysteria2_info.txt
    echo ""
    info "分享链接："
    echo -e "${CYAN}${SHARE_LINK}${NC}"

    if command -v qrencode &>/dev/null; then
        echo ""
        info "扫码导入："
        qrencode -t ansiutf8 "$SHARE_LINK"
    fi
}

# ============================================================
#  生成 Clash Verge (mihomo) 完整配置
# ============================================================
build_clash() {
    local OUT=/root/clash_verge.yaml
    local NAMES=()
    [[ -f /root/clash_reality.part ]] && NAMES+=("$(grep -m1 'name:' /root/clash_reality.part | sed 's/.*name: //')")
    [[ -f /root/clash_hy2.part ]]     && NAMES+=("$(grep -m1 'name:' /root/clash_hy2.part | sed 's/.*name: //')")
    [[ ${#NAMES[@]} -eq 0 ]] && { warn "没有可用的节点信息"; return; }

    {
        echo "mixed-port: 7897"
        echo "allow-lan: false"
        echo "mode: rule"
        echo "log-level: info"
        echo "ipv6: false"
        echo ""
        echo "proxies:"
        [[ -f /root/clash_reality.part ]] && cat /root/clash_reality.part
        [[ -f /root/clash_hy2.part ]]     && cat /root/clash_hy2.part
        echo ""
        echo "proxy-groups:"
        echo "  - name: \"节点选择\""
        echo "    type: select"
        echo "    proxies:"
        for n in "${NAMES[@]}"; do echo "      - $n"; done
        echo "      - DIRECT"
        echo ""
        echo "rules:"
        echo "  - GEOIP,LAN,DIRECT"
        echo "  - GEOIP,CN,DIRECT"
        echo "  - MATCH,节点选择"
    } > "$OUT"

    echo ""
    title "Clash Verge 配置 (保存于 $OUT)"
    cat "$OUT"
    echo ""
    info "导入方法：Clash Verge → 订阅(Profiles) → 新建 → 类型选 Local → 编辑文件，粘贴以上内容保存并启用"
}

# ============================================================
#  防火墙
# ============================================================
configure_firewall() {
    title "配置防火墙"
    # iptables 放行
    if command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "$REALITY_PORT" -j ACCEPT 2>/dev/null
        iptables -I INPUT -p udp --dport "$HY2_PORT"    -j ACCEPT 2>/dev/null
        iptables -I INPUT -p tcp --dport "$HY2_PORT"    -j ACCEPT 2>/dev/null
        info "iptables 规则已添加"
    fi
    # ufw 放行
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$REALITY_PORT"/tcp  2>/dev/null
        ufw allow "$HY2_PORT"/udp     2>/dev/null
        ufw allow "$HY2_PORT"/tcp     2>/dev/null
        info "ufw 规则已添加"
    fi
    info "注意：腾讯云/阿里云等云服务器还需在控制台安全组放行以上端口"
}

# ============================================================
#  管理菜单
# ============================================================
show_menu() {
    clear
    echo -e "${BOLD}${BLUE}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   Reality + Hysteria2 管理面板  v3    ║"
    echo "  ║   Debian 12 | $(date '+%Y-%m-%d')          ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  ${GREEN}[1]${NC} 全新安装 (Reality + Hysteria2)"
    echo -e "  ${GREEN}[2]${NC} 仅安装 Reality (VLESS)"
    echo -e "  ${GREEN}[3]${NC} 仅安装 Hysteria2"
    echo -e "  ${GREEN}[4]${NC} 查看配置信息 & 分享链接"
    echo -e "  ${GREEN}[5]${NC} 重启所有服务"
    echo -e "  ${GREEN}[6]${NC} 查看服务状态"
    echo -e "  ${GREEN}[7]${NC} 开启 BBR 加速"
    echo -e "  ${GREEN}[8]${NC} 卸载所有组件"
    echo -e "  ${GREEN}[9]${NC} 查看 Clash Verge 配置"
    echo -e "  ${GREEN}[0]${NC} 退出"
    echo ""
}

view_info() {
    title "当前配置信息"
    if [[ -f /root/reality_info.txt ]]; then
        cat /root/reality_info.txt
        echo ""
    else
        warn "Reality 配置文件不存在"
    fi
    if [[ -f /root/hysteria2_info.txt ]]; then
        cat /root/hysteria2_info.txt
        echo ""
    else
        warn "Hysteria2 配置文件不存在"
    fi
}

restart_services() {
    title "重启服务"
    systemctl restart xray            2>/dev/null && info "Xray 重启成功"       || warn "Xray 未安装或重启失败"
    systemctl restart hysteria-server 2>/dev/null && info "Hysteria2 重启成功"  || warn "Hysteria2 未安装或重启失败"
}

show_status() {
    title "服务状态"
    echo -e "${BOLD}--- Xray (Reality) ---${NC}"
    systemctl status xray --no-pager -l 2>/dev/null || echo "未安装"
    echo ""
    echo -e "${BOLD}--- Hysteria2 ---${NC}"
    systemctl status hysteria-server --no-pager -l 2>/dev/null || echo "未安装"
}

uninstall_all() {
    confirm "确认卸载所有组件？" || return
    title "卸载中..."
    systemctl stop xray hysteria-server 2>/dev/null
    systemctl disable xray hysteria-server 2>/dev/null
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove 2>/dev/null
    rm -rf /etc/hysteria
    rm -f /usr/local/bin/hysteria
    rm -f /etc/systemd/system/hysteria-server.service
    rm -f /etc/systemd/system/hysteria-server@.service
    systemctl daemon-reload
    rm -f /root/reality_info.txt /root/hysteria2_info.txt /root/clash_*.part /root/clash_verge.yaml
    info "卸载完成"
}

# ============================================================
#  主程序
# ============================================================
do_full_install() {
    install_deps
    enable_bbr
    install_xray
    configure_reality
    install_hysteria2
    configure_hysteria2
    configure_firewall
    build_clash
    info "全部安装完成！配置已保存至 /root/"
}

main() {
    case "$1" in
        install) do_full_install; exit 0 ;;
        reality) install_deps; enable_bbr; install_xray; configure_reality; configure_firewall; build_clash; exit 0 ;;
        hy2)     install_deps; install_hysteria2; configure_hysteria2; configure_firewall; build_clash; exit 0 ;;
        bbr)     enable_bbr; exit 0 ;;
        clash)   build_clash; exit 0 ;;
    esac

    while true; do
        show_menu
        read -rp "  请输入选项: " choice
        case "$choice" in
            1) do_full_install ;;
            2) install_deps; enable_bbr; install_xray; configure_reality; configure_firewall; build_clash ;;
            3) install_deps; install_hysteria2; configure_hysteria2; configure_firewall; build_clash ;;
            4) view_info ;;
            5) restart_services ;;
            6) show_status ;;
            7) enable_bbr ;;
            8) uninstall_all ;;
            9) build_clash ;;
            0) echo "退出"; exit 0 ;;
            *) warn "无效选项" ;;
        esac
        echo ""
        read -rp "按 Enter 继续..." _
    done
}

main "$@"
