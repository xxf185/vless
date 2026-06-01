#!/usr/bin/env bash
set -e

# =========================================================
# VLESS Reality 一键菜单脚本（终极完整版）
# Author: jinqians
# =========================================================

SCRIPT_REMOTE_URL="https://raw.githubusercontent.com/xxf185/vless/refs/heads/main/vless.sh"

CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="$CONFIG_DIR/config.json"
META_FILE="$CONFIG_DIR/vless-meta.conf"
VLESS_CMD="/usr/local/bin/vless"

# root 校验
if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 运行此脚本"
  exit 1
fi

# ================= 基础工具函数 =================

ensure_deps() {
  apt update -y
  apt install -y curl qrencode || true
}

get_ips() {
  IPV4=$(curl -4 -s https://api.ipify.org || true)
  IPV6=$(curl -6 -s https://api64.ipify.org || true)
}

# ================= Reality Key 解析 =================

parse_x25519() {
  KEY_OUTPUT=$(xray x25519 2>&1)

  PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep -i 'private' | awk -F': *' '{print $2}' | head -n1)
  PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -i 'public' | awk -F': *' '{print $2}' | head -n1)

  if [[ -z "$PUBLIC_KEY" ]]; then
    PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -i 'password' | awk -F': *' '{print $2}' | head -n1)
  fi
  if [[ -z "$PUBLIC_KEY" ]]; then
    PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -i 'hash32' | awk -F': *' '{print $2}' | head -n1)
  fi

  echo "$KEY_OUTPUT" > /tmp/x25519-raw.txt
}

# ================= 写入 Xray 配置 =================

write_config() {
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_FILE" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "$DEST",
          "serverNames": $SERVER_NAMES_JSON,
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [""]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF
}

# ================= 安装 vless 管理命令 =================

install_vless_cmd() {
  if [[ -f "$VLESS_CMD" ]]; then return; fi

  cat > "$VLESS_CMD" << 'EOFSCRIPT'
#!/bin/bash
if [ "$(id -u)" != "0" ]; then
  echo "请以 root 运行 vless"
  exit 1
fi
TMP=$(mktemp)
curl -fsSL https://raw.githubusercontent.com/xxf185/vless/refs/heads/main/vless.sh -o "$TMP"
bash "$TMP"
rm -f "$TMP"
EOFSCRIPT

  chmod +x "$VLESS_CMD"
}

# ================= 输出链接 =================

output_links() {
  get_ips

  if [[ -n "$IPV4" ]]; then
    V4="vless://${UUID}@${IPV4}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME_FIRST}&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp#vless-reality"
    echo "IPv4 链接："
    echo "$V4"
    qrencode -t ANSIUTF8 "$V4"
    echo
  fi

  if [[ -n "$IPV6" ]]; then
    V6="vless://${UUID}@[$IPV6]:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME_FIRST}&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp#vless-reality"
    echo "IPv6 链接："
    echo "$V6"
    qrencode -t ANSIUTF8 "$V6"
    echo
  fi
}

# ================= 安装动作 =================

install_action() {
  ensure_deps

  if ! command -v xray >/dev/null 2>&1; then
    bash <(curl -L https://github.com/xxf185/vless/raw/main/install-release.sh) install
  fi

  read -p "监听端口 [443]: " PORT
  PORT=${PORT:-443}

  read -p "dest [www.ebay.com:443]: " DEST
  DEST=${DEST:-www.ebay.com:443}

  read -p "serverNames (逗号) [www.ebay.com]: " SERVER_NAMES_RAW
  SERVER_NAMES_RAW=${SERVER_NAMES_RAW:-www.ebay.com}

  IFS=',' read -ra SN <<< "$SERVER_NAMES_RAW"
  SERVER_NAMES_JSON=$(printf '"%s",' "${SN[@]}")
  SERVER_NAMES_JSON="[${SERVER_NAMES_JSON%,}]"
  SERVER_NAME_FIRST=${SN[0]}

  UUID=$(xray uuid)
  parse_x25519

  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    echo "❌ Reality Key 解析失败"
    cat /tmp/x25519-raw.txt
    exit 1
  fi

  write_config

  systemctl enable xray
  systemctl restart xray

  # ===== 保存 Reality 元信息（关键）=====
  get_ips
  cat > "$META_FILE" <<EOF
UUID="$UUID"
PUBLIC_KEY="$PUBLIC_KEY"
PORT="$PORT"
DEST="$DEST"
SERVER_NAMES="$SERVER_NAMES_RAW"
SERVER_NAME_FIRST="$SERVER_NAME_FIRST"
IPV4="$IPV4"
IPV6="$IPV6"
INSTALL_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
EOF

  install_vless_cmd

  echo
  echo "=========== 安装完成 ==========="
  echo "UUID       : $UUID"
  echo "PublicKey  : $PUBLIC_KEY"
  echo "端口       : $PORT"
  echo "dest       : $DEST"
  echo "serverNames: $SERVER_NAMES_RAW"
  echo
  echo "👉 后续管理请直接执行命令： vless"
  echo

  output_links

  echo "✅ 安装完成，脚本已退出"
  exit 0
}

# ================= 查看配置 =================

show_config_action() {
  if [[ ! -f "$META_FILE" ]]; then
    echo "❌ 未找到节点元信息文件：$META_FILE"
    return
  fi

  source "$META_FILE"

  echo
  echo "=========== 当前 VLESS Reality 配置 ==========="
  echo "安装时间 : $INSTALL_TIME"
  echo "UUID     : $UUID"
  echo "PublicKey: $PUBLIC_KEY"
  echo "端口     : $PORT"
  echo "dest     : $DEST"
  echo "serverNames:"
  echo "$SERVER_NAMES" | tr ',' '\n' | sed 's/^/  - /'
  echo

  get_ips

  if [[ -n "$IPV4" ]]; then
    echo "IPv4 完整链接："
    echo "vless://${UUID}@${IPV4}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME_FIRST}&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp#vless-reality"
    echo
  fi

  if [[ -n "$IPV6" ]]; then
    echo "IPv6 完整链接："
    echo "vless://${UUID}@[$IPV6]:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME_FIRST}&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp#vless-reality"
    echo
  fi

  read -p "按 Enter 返回菜单..."
}

# ================= 其它菜单功能 =================

update_action() {
  bash <(curl -L https://github.com/xxf185/vless/raw/main/install-release.sh) install
  systemctl restart xray || true
  xray -version | head -n 3
}

uninstall_action() {
  read -p "⚠️ 将彻底删除 Xray 与所有配置，是否继续？(y/N): " yn
  [[ ! "$yn" =~ ^[Yy]$ ]] && return

  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true
  pkill -9 xray 2>/dev/null || true

  rm -f /etc/systemd/system/xray.service
  rm -f /etc/systemd/system/xray@.service
  rm -rf /etc/systemd/system/xray*.d

  rm -rf /usr/local/etc/xray /etc/xray /usr/local/etc/xray-reality /etc/xray-reality
  rm -f /usr/local/bin/xray /usr/bin/xray /bin/xray
  rm -f "$VLESS_CMD"

  systemctl daemon-reexec
  systemctl daemon-reload

  echo "✅ 已彻底卸载 VLESS Reality"
}

status_action() {
  systemctl status xray --no-pager || true
  ss -lntp || true
}

self_update() {
  curl -fsSL "$SCRIPT_REMOTE_URL" -o /tmp/vless-menu.sh
  chmod +x /tmp/vless-menu.sh
  cp /tmp/vless-menu.sh "$0"
  exec bash "$0"
}

# ================= 主菜单 =================

while true; do
  echo "============================================"
  echo "           vless Reality 管理菜单"
  echo "============================================"
  echo "1) 安装 VLESS Reality"
  echo "2) 更新 Xray"
  echo "3) 卸载 VLESS Reality"
  echo "4) 查看运行状态"
  echo "5) 查看当前配置"
  echo "0) 更新脚本"
  echo "q) 退出"
  read -p "请选择: " c
  case "$c" in
    1) install_action ;;
    2) update_action ;;
    3) uninstall_action ;;
    4) status_action ;;
    5) show_config_action ;;
    0) self_update ;;
    q|Q) exit 0 ;;
    *) echo "无效选项" ;;
  esac
done
