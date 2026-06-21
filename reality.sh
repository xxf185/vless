#!/bin/bash

# ═══════════════════════════════════════════════════════════════
#                    VLESS-Reality  
# ═══════════════════════════════════════════════════════════════

set -uo pipefail

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Paths & defaults ─────────────────────────────────────────
CONFIG="/usr/local/etc/xray/config.json"
STATE_FILE="/root/.vless-state"
INFO_FILE="/root/vpn-info.txt"
LOG_FILE="/root/setup.log"
XRAY_CMD=""
SELF_PATH="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")"
DEFAULT_PORT=443
PORT_MIN=47000
PORT_MAX=60000

# ── Variables (filled at runtime) ─────────────────────────────
SERVER_IP=""
PORT=""
UUID=""
TARGET=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""

# ── Root & OS check ──────────────────────────────────────────
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo -e "${RED}以 root 用户身份运行 ${NC}"
  exit 1
fi
if [ ! -f /etc/debian_version ]; then
  echo -e "${RED}仅支持 Debian / Ubuntu 系统.${NC}"
  exit 1
fi

# ══════════════════════════════════════════════════════════════
#   HELPERS
# ══════════════════════════════════════════════════════════════

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"; }

print_header() {
  echo ""
  echo -e "${CYAN}╔═══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║           VLESS—Reality              管理菜单     ║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════╝${NC}"
}

xray_installed() {
  command -v xray >/dev/null 2>&1 || [ -x "/usr/local/bin/xray" ]
}

refresh_xray_cmd() {
  XRAY_CMD="$(command -v xray 2>/dev/null || echo /usr/local/bin/xray)"
}

get_public_ip() {
  local ip=""
  ip=$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null) \
    || ip=$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null) \
    || ip=$(curl -4 -s --max-time 5 https://icanhazip.com 2>/dev/null) \
    || ip=""
  echo "$ip" | tr -d '[:space:]'
}

random_port() {
  local port
  port=$(shuf -i "${PORT_MIN}-${PORT_MAX}" -n1)
  while ss -ltnp 2>/dev/null | grep -q ":${port} "; do
    port=$(shuf -i "${PORT_MIN}-${PORT_MAX}" -n1)
  done
  echo "$port"
}

wait_xray_active() {
  local i
  for i in $(seq 1 15); do
    systemctl is-active --quiet xray && return 0
    sleep 1
  done
  return 1
}

wait_xray_stopped() {
  local i
  for i in $(seq 1 15); do
    systemctl is-active --quiet xray || return 0
    sleep 1
  done
  return 1
}

wait_port_listening() {
  local port="$1" i
  for i in $(seq 1 10); do
    if ss -ltnp 2>/dev/null | grep -q ":${port} "; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# ── JSON helper (jq first, python3 fallback) ──────────────────
json_val() {
  local jpath="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r "$jpath" "$CONFIG" 2>/dev/null
  else
    python3 -c "
import json
with open('$CONFIG') as f:
    d = json.load(f)
path = '$jpath'.lstrip('.').replace('][','|').replace('[','|').replace(']','').split('|')
ref = d
for p in path:
    if p.isdigit():
        ref = ref[int(p)]
    else:
        ref = ref[p]
print(ref)
" 2>/dev/null
  fi
}

# ══════════════════════════════════════════════════════════════
#   STATE MANAGEMENT
#   Instead of re-deriving public key every time (fragile),
#   we save all connection params to a state file.
# ══════════════════════════════════════════════════════════════

save_state() {
  cat > "$STATE_FILE" <<EOF
PORT=${PORT}
UUID=${UUID}
TARGET=${TARGET}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
EOF
  chmod 600 "$STATE_FILE"
}

load_state() {
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    return 0
  fi
  return 1
}

get_server_info() {
  SERVER_IP="$(get_public_ip)"

  # Try state file first (reliable)
  if load_state; then
    return 0
  fi

  # Fallback: parse from config (for upgrades from old script)
  if [ -f "$CONFIG" ]; then
    PORT="$(json_val '.inbounds[0].port')" || PORT=""
    UUID="$(json_val '.inbounds[0].settings.clients[0].id')" || UUID=""
    TARGET="$(json_val '.inbounds[0].streamSettings.realitySettings.serverNames[0]')" || TARGET=""
    PRIVATE_KEY="$(json_val '.inbounds[0].streamSettings.realitySettings.privateKey')" || PRIVATE_KEY=""

    # Get first non-empty shortId
    SHORT_ID="$(json_val '.inbounds[0].streamSettings.realitySettings.shortIds[0]')" || SHORT_ID=""
    if [ -z "$SHORT_ID" ]; then
      SHORT_ID="$(json_val '.inbounds[0].streamSettings.realitySettings.shortIds[1]')" || SHORT_ID=""
    fi

    # Try to derive public key
    if [ -n "$PRIVATE_KEY" ]; then
      refresh_xray_cmd
      local raw
      raw="$("$XRAY_CMD" x25519 -i "$PRIVATE_KEY" 2>/dev/null || true)"
      PUBLIC_KEY="$(echo "$raw" | tail -1 | awk '{print $NF}' | tr -d '[:space:]')"
      log "Fallback derive: raw=$raw  result=$PUBLIC_KEY"
    fi

    # Save state for future use
    if [ -n "$PUBLIC_KEY" ] && [ -n "$UUID" ]; then
      save_state
    fi
  fi
}

make_link() {
  local uuid="${1}" label="${2:-MyVPN}"

  if [ -z "${PUBLIC_KEY:-}" ]; then
    echo -e "${RED}  ✗ PUBLIC_KEY is empty — cannot generate link.${NC}" >&2
    echo -e "${RED}    Check ${LOG_FILE} for debug info.${NC}" >&2
    return 1
  fi
  if [ -z "${SHORT_ID:-}" ]; then
    echo -e "${RED}  ✗ SHORT_ID is empty — cannot generate link.${NC}" >&2
    return 1
  fi

  echo "vless://${uuid}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${TARGET}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision&headerType=none#reality"
}

# ══════════════════════════════════════════════════════════════
#   KEY GENERATION
# ══════════════════════════════════════════════════════════════

generate_reality_keys() {
  refresh_xray_cmd

  local raw_output=""
  raw_output="$("$XRAY_CMD" x25519 2>&1 || true)"

  log "=== x25519 raw output START ==="
  log "$raw_output"
  log "=== x25519 raw output END ==="

  # xray x25519 outputs exactly 2 lines:
  #   Private key: XXXXX
  #   Public key: YYYYY
  # OR:
  #   PrivateKey: XXXXX
  #   PublicKey: YYYYY
  #
  # Strategy: just take the LAST token on each line.

  local line1 line2
  line1="$(echo "$raw_output" | head -1)"
  line2="$(echo "$raw_output" | head -2 | tail -1)"

  PRIVATE_KEY="$(echo "$line1" | awk '{print $NF}' | tr -d '[:space:]')"
  PUBLIC_KEY="$(echo "$line2" | awk '{print $NF}' | tr -d '[:space:]')"

  log "Parsed PRIVATE_KEY=${PRIVATE_KEY}"
  log "Parsed PUBLIC_KEY=${PUBLIC_KEY}"

  # Validate: keys should be 43-44 chars of base64url
  if [ -z "$PRIVATE_KEY" ] || [ ${#PRIVATE_KEY} -lt 40 ]; then
    echo -e "${RED}  ✗ Private key 无效 (len=${#PRIVATE_KEY}): '${PRIVATE_KEY}'${NC}"
    echo -e "${RED}  输出:${NC}"
    echo "$raw_output"
    return 1
  fi

  if [ -z "$PUBLIC_KEY" ] || [ ${#PUBLIC_KEY} -lt 40 ]; then
    echo -e "${YELLOW} Public key 看起来有问题，它源自 private...${NC}"
    local derive_out
    derive_out="$("$XRAY_CMD" x25519 -i "$PRIVATE_KEY" 2>&1 || true)"
    log "Derive output: $derive_out"
    PUBLIC_KEY="$(echo "$derive_out" | tail -1 | awk '{print $NF}' | tr -d '[:space:]')"
    log "Derived PUBLIC_KEY=${PUBLIC_KEY}"
  fi

  if [ -z "$PUBLIC_KEY" ] || [ ${#PUBLIC_KEY} -lt 40 ]; then
    echo -e "${RED}  ✗ Public key 生成失败。${NC}"
    echo -e "${RED}  Private key: ${PRIVATE_KEY}${NC}"
    echo -e "${RED}  输出:${NC}"
    "$XRAY_CMD" x25519 -i "$PRIVATE_KEY" 2>&1 || true
    return 1
  fi

  echo -e "${GREEN}  ✓ Private key: ${PRIVATE_KEY:0:8}...${NC}"
  echo -e "${GREEN}  ✓ Public key:  ${PUBLIC_KEY:0:8}...${NC}"
  return 0
}

# ══════════════════════════════════════════════════════════════
#   SETUP STEPS
# ══════════════════════════════════════════════════════════════

ensure_packages() {
  echo -e "${YELLOW}▶ 安装 packages...${NC}"
  apt-get update -qq >> "$LOG_FILE" 2>&1
  apt-get install -y -qq \
    curl unzip openssl netcat-openbsd qrencode ufw fail2ban jq \
    unattended-upgrades ca-certificates python3 >> "$LOG_FILE" 2>&1
  echo -e "${GREEN}  ✓ Packages 已安装 ${NC}"
}

setup_ufw() {
  local vpn_port="$1"
  echo -e "${YELLOW}▶ 正在配置 UFW...${NC}"
  [ -f /etc/default/ufw ] && sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw
  ufw default deny incoming  >/dev/null 2>&1
  ufw default allow outgoing >/dev/null 2>&1
  ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1
  ufw allow "${vpn_port}/tcp" comment 'VLESS-Reality' >/dev/null 2>&1
  ufw --force enable >/dev/null 2>&1
  echo -e "${GREEN}  ✓ UFW active  (SSH: 22,  VPN: ${vpn_port})${NC}"
}

cleanup_old_ufw_vpn() {
  local new_port="$1"
  ufw status numbered 2>/dev/null | grep 'VLESS-Reality' | grep -oP '\d+(?=/tcp)' | while read -r rule_port; do
    if [ "$rule_port" != "$new_port" ]; then
      ufw delete allow "${rule_port}/tcp" >/dev/null 2>&1 || true
    fi
  done
}

setup_fail2ban() {
  echo -e "${YELLOW}▶ Configuring Fail2Ban...${NC}"
  cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
ignoreip = 127.0.0.1/8

[sshd]
enabled  = true
port     = 22
logpath  = %(sshd_log)s
backend  = systemd
maxretry = 3
bantime  = 86400
EOF
  systemctl enable fail2ban  >/dev/null 2>&1 || true
  systemctl restart fail2ban >/dev/null 2>&1 || true
  echo -e "${GREEN}  ✓ Fail2Ban active${NC}"
}

setup_auto_updates() {
  echo -e "${YELLOW}▶ 启用自动安全更新...${NC}"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  echo -e "${GREEN}  ✓ 自动安全更新已启用${NC}"
}

setup_sysctl() {
  echo -e "${YELLOW}▶ 系统优化中...${NC}"
  sed -i '/# --- vless-setup-start ---/,/# --- vless-setup-end ---/d' /etc/sysctl.conf
  cat >> /etc/sysctl.conf <<'EOF'

# --- vless-setup-start ---
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
# --- vless-setup-end ---
EOF
  sysctl -p >/dev/null 2>&1 || true
  echo -e "${GREEN}  ✓ 内核强化 + BBR 启用${NC}"
}

install_xray() {
  echo -e "${YELLOW}▶ 安装 Xray-core...${NC}"
  if bash <(curl -Ls https://raw.githubusercontent.com/xxf185/vless/refs/heads/main/install-release.sh) install >> "$LOG_FILE" 2>&1; then
    refresh_xray_cmd
    if xray_installed; then
      echo -e "${GREEN}  ✓ Xray 安装成功 ($("$XRAY_CMD" version 2>/dev/null | head -1))${NC}"
      return 0
    fi
  fi
  echo -e "${RED}  ✗ Xray 安装失败 ${LOG_FILE}${NC}"
  return 1
}

pick_target() {
  echo -e "${YELLOW}▶ 选择SNI${NC}"
  local targets=(
    "www.ebay.com"
    "www.amd.com"
  )
  TARGET=""
  for t in "${targets[@]}"; do
    if nc -z -w3 "$t" 443 >/dev/null 2>&1; then
      TARGET="$t"
      break
    fi
  done
  [ -n "$TARGET" ] || TARGET="www.ebay.com"
  echo -e "${GREEN}  ✓ SNI target: ${TARGET}${NC}"
}

write_xray_config() {
  local port="$1" uuid="$2" target="$3" privkey="$4" sid="$5"

  local sid2 sid3
  sid2="$(openssl rand -hex 8)"
  sid3="$(openssl rand -hex 4)"

  mkdir -p "$(dirname "$CONFIG")"
  cat > "$CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
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
          "dest": "${target}:443",
          "serverNames": [
            "${target}"
          ],
          "privateKey": "${privkey}",
          "shortIds": [
            "${sid}",
            "${sid2}",
            "${sid3}",
            ""
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
}

setup_xray_service() {
  mkdir -p /etc/systemd/system/xray.service.d
  cat > /etc/systemd/system/xray.service.d/override.conf <<'EOF'
[Service]
User=root
Restart=always
RestartSec=5
LimitNOFILE=65535
EOF
  systemctl daemon-reload
}

save_info_file() {
  local link="$1"
  cat > "$INFO_FILE" <<EOF
════════════════════════════════════════════════════════
  VLESS-Reality 配置信息
════════════════════════════════════════════════════════

Server IP    : ${SERVER_IP}
VPN Port     : ${PORT}
UUID         : ${UUID}
Public Key   : ${PUBLIC_KEY}
Short ID     : ${SHORT_ID}
SNI Target   : ${TARGET}
Fingerprint  : chrome
Flow         : (none)
Connections  : unlimited

IMPORT LINK:
${link}

════════════════════════════════════════════════════════
Generated : $(date '+%Y-%m-%d %H:%M:%S %Z')
Manage    : bash ${SELF_PATH}
════════════════════════════════════════════════════════
EOF
}

print_result() {
  local link="$1"

  echo ""
  echo -e "${CYAN}╔═══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║                 reality 配置信息                   ║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Server${NC}     : ${SERVER_IP}"
  echo -e "  ${BOLD}Port${NC}       : ${PORT}"
  echo -e "  ${BOLD}SNI${NC}        : ${TARGET}"
  echo -e "  ${BOLD}Public Key${NC} : ${PUBLIC_KEY}"
  echo -e "  ${BOLD}Short ID${NC}   : ${SHORT_ID}"
  echo ""
  echo -e "${BOLD}${GREEN}${link}${NC}"
  echo ""

  if command -v qrencode >/dev/null 2>&1; then
    echo -e "${YELLOW}══════════ QR CODE ══════════${NC}"
    qrencode -t ANSIUTF8 -m 2 "$link"
    echo -e "${YELLOW}═════════════════════════════${NC}"
  fi

  echo ""
}

# ══════════════════════════════════════════════════════════════
#   ACTIONS
# ══════════════════════════════════════════════════════════════

do_install() {
  echo ""
  echo -e "${CYAN}╔═══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║       安装并启动 VLESS Reality                     ║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════╝${NC}"

  : > "$LOG_FILE"

  SERVER_IP="$(get_public_ip)"
  if [ -z "$SERVER_IP" ]; then
    echo -e "${RED}  ✗ 无法确定服务器公网 IP 地址.${NC}"
    return 1
  fi

  # ── Port selection ──────────────────────────────────────
  echo ""
  echo -e "${CYAN}  端口选择:${NC}"
  echo -e "    1) ${BOLD}443${NC}  — 标准 HTTPS (${GREEN}推荐${NC})"
  echo -e "    2) 随机高端口 (${PORT_MIN}-${PORT_MAX})"
  echo -e "    3) 输入自定义端口"
  echo ""
  read -rp "$(echo -e "${YELLOW}  Choice [1]: ${NC}")" port_choice

  case "${port_choice:-1}" in
    1|"")
      PORT="$DEFAULT_PORT"
      if ss -ltnp 2>/dev/null | grep -q ":${PORT} "; then
        echo -e "${RED}  ✗ Port 443 is 已在使用中。${NC}"
        echo -e "${YELLOW}  回退到随机端口...${NC}"
        PORT="$(random_port)"
      fi
      ;;
    2)
      PORT="$(random_port)"
      ;;
    3)
      read -rp "$(echo -e "${YELLOW}  请输入端口号: ${NC}")" custom_port
      if [[ "$custom_port" =~ ^[0-9]+$ ]] && [ "$custom_port" -ge 1 ] && [ "$custom_port" -le 65535 ]; then
        if ss -ltnp 2>/dev/null | grep -q ":${custom_port} "; then
          echo -e "${RED}  ✗ Port ${custom_port} 已在使用中.${NC}"
          return 1
        fi
        PORT="$custom_port"
      else
        echo -e "${RED}  ✗ 无效端口.${NC}"
        return 1
      fi
      ;;
    *) PORT="$DEFAULT_PORT" ;;
  esac

  echo -e "${GREEN}  ▸ Server IP  : ${SERVER_IP}${NC}"
  echo -e "${GREEN}  ▸ VPN port   : ${PORT}${NC}"

  ensure_packages    || return 1
  setup_ufw "$PORT"  || return 1
  setup_fail2ban     || return 1
  setup_auto_updates || return 1
  setup_sysctl       || return 1
  install_xray       || return 1

  echo -e "${YELLOW}▶ 生成 Reality keys...${NC}"
  if ! generate_reality_keys; then
    echo -e "${RED}  ✗ 生成 Reality keys失败${NC}"
    return 1
  fi

  refresh_xray_cmd
  UUID="$("$XRAY_CMD" uuid 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$UUID" ]; then
    echo -e "${RED}  ✗ UUID 生成失败.${NC}"
    return 1
  fi

  SHORT_ID="$(openssl rand -hex 8)"

  pick_target
  write_xray_config "$PORT" "$UUID" "$TARGET" "$PRIVATE_KEY" "$SHORT_ID"
  setup_xray_service

  # Save state BEFORE starting (so we have the keys even if start fails)
  save_state

  echo -e "${YELLOW}▶ 启动Xray...${NC}"
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray

  if ! wait_xray_active; then
    echo -e "${RED}  ✗ Xray 启动失败{NC}"
    journalctl -u xray -n 30 --no-pager
    return 1
  fi

  if ! wait_port_listening "$PORT"; then
    echo -e "${RED}  ✗ Port ${PORT} 10秒后就没再听了.${NC}"
    journalctl -u xray -n 30 --no-pager
    return 1
  fi

  echo -e "${GREEN}  ✓ Xray运行中 ${PORT}${NC}"

  local link
  link="$(make_link "$UUID" "MyVPN")" || return 1
  save_info_file "$link"
  print_result "$link"
  log "INSTALL OK  ip=${SERVER_IP} port=${PORT}"
}

do_show_link() {
  if [ ! -f "$STATE_FILE" ] && [ ! -f "$CONFIG" ]; then
    echo -e "${RED}未安装${NC}"
    return 1
  fi

  get_server_info

  local link
  link="$(make_link "$UUID" "reality")" || return 1
  print_result "$link"
}

do_regenerate_keys() {
  if [ ! -f "$CONFIG" ]; then
    echo -e "${RED}未安装${NC}"
    return 1
  fi

  echo -e "${YELLOW}这将生成新的 UUID + Reality keys.${NC}"
  echo -e "${YELLOW}所有客户都需要这个新链接。.${NC}"
  read -rp "$(echo -e "${YELLOW}确认继续? [y/N]: ${NC}")" ans
  [[ "${ans,,}" != "y" ]] && { echo "取消."; return 0; }

  get_server_info
  refresh_xray_cmd

  echo -e "${YELLOW}▶ 生成新密钥...${NC}"
  if ! generate_reality_keys; then
    echo -e "${RED}  ✗ 生成新密钥失败.${NC}"
    return 1
  fi

  UUID="$("$XRAY_CMD" uuid 2>/dev/null | tr -d '[:space:]')"
  SHORT_ID="$(openssl rand -hex 8)"

  write_xray_config "$PORT" "$UUID" "$TARGET" "$PRIVATE_KEY" "$SHORT_ID"
  save_state

  echo -e "${YELLOW}▶ 重启 Xray...${NC}"
  systemctl restart xray

  if ! wait_xray_active; then
    echo -e "${RED}  ✗ 启动 Xray 失败.${NC}"
    journalctl -u xray -n 20 --no-pager
    return 1
  fi

  echo -e "${GREEN}  ✓ 重新生成密钥，重新启动 Xray.${NC}"

  local link
  link="$(make_link "$UUID" "reality")" || return 1
  save_info_file "$link"
  print_result "$link"
  log "REGEN KEYS  port=${PORT}"
}

do_uninstall() {
  echo ""
  echo -e "${RED}这将彻底移除 Xray、配置和防火墙.${NC}"
  read -rp "$(echo -e "${YELLOW}确认继续? [y/N]: ${NC}")" confirm
  [[ "${confirm,,}" != "y" ]] && { echo "取消."; return 0; }

  echo -e "${YELLOW}▶ 停止 & 禁用 Xray...${NC}"
  systemctl stop xray    2>/dev/null || true
  systemctl disable xray 2>/dev/null || true

  rm -rf /etc/systemd/system/xray.service.d
  systemctl daemon-reload

  echo -e "${YELLOW}▶ 卸载Xray ...${NC}"
  bash <(curl -Ls https://raw.githubusercontent.com/xxf185/vless/refs/heads/main/install-release.sh) remove >> "$LOG_FILE" 2>&1 || true

  rm -f "$CONFIG" "$INFO_FILE" "$STATE_FILE"

  echo -e "${YELLOW}▶ 移除 UFW rules...${NC}"
  ufw status numbered 2>/dev/null | grep 'VLESS-Reality' | grep -oP '\d+(?=/tcp)' | sort -rn | while read -r p; do
    ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true
  done

  echo -e "${YELLOW}▶ 移除 sysctl 配置${NC}"
  sed -i '/# --- vless-setup-start ---/,/# --- vless-setup-end ---/d' /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1 || true

  echo -e "${YELLOW}▶ 移除  fail2ban 配置...${NC}"
  rm -f /etc/fail2ban/jail.local
  systemctl restart fail2ban 2>/dev/null || true

  echo ""
  echo -e "${GREEN}卸载完成${NC}"
  echo ""
}

# ══════════════════════════════════════════════════════════════
#   MAIN MENU
# ══════════════════════════════════════════════════════════════

while true; do
  print_header

  if systemctl is-active --quiet xray 2>/dev/null; then
    local_port="$(json_val '.inbounds[0].port' 2>/dev/null || echo '?')"
    echo -e "   状态 : ${GREEN}● 运行${NC}  (port ${local_port})"
  elif xray_installed; then
    echo -e "   状态 : ${RED}● 停止${NC}"
  else
    echo -e "   状态 : ${YELLOW}● 未安装${NC}"
  fi

  echo ""
  echo "   1)  安装reality"
  echo "   2)  查看配置"
  echo "   3)  更改keys"
  echo "   4)  卸载"
  echo "   0)  退出"
  echo ""
  read -rp "$(echo -e "${YELLOW}  选项 [0-4]: ${NC}")" choice

  case "$choice" in
    1) do_install         ;;
    2) do_show_link       ;;
    3) do_regenerate_keys ;;
    4) do_uninstall       ;;
    0) echo ""; exit 0 ;;
    *) echo -e "${RED}未知选项${NC}" ;;
  esac

  echo ""
  read -rp "$(echo -e "${CYAN} 继续...${NC}")" _
done
