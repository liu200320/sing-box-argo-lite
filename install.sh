#!/usr/bin/env bash
set -u

SELF_URL="${SELF_URL:-https://raw.githubusercontent.com/liu200320/sing-box-argo-lite/main/install.sh}"

APP_DIR="${HOME}/.local/share/sb-argo"
BIN_DIR="${APP_DIR}/bin"
STATE_DIR="${APP_DIR}/state"
LOG_DIR="${APP_DIR}/logs"
CONFIG_DIR="${HOME}/.config/sb-argo"
MANAGER="${HOME}/.local/bin/sb-argo"

SB_BIN="${BIN_DIR}/sing-box"
CF_BIN="${BIN_DIR}/cloudflared"
SB_CONFIG="${CONFIG_DIR}/sing-box.json"

SB_PID_FILE="${STATE_DIR}/sing-box.pid"
CF_PID_FILE="${STATE_DIR}/cloudflared.pid"
UUID_FILE="${CONFIG_DIR}/uuid"
WS_PATH_FILE="${CONFIG_DIR}/ws-path"
PORT_FILE="${CONFIG_DIR}/local-port"
DOMAIN_FILE="${STATE_DIR}/domain"
NODE_FILE="${STATE_DIR}/node-info.txt"
SUB_FILE="${STATE_DIR}/subscription.txt"

SB_LOG="${LOG_DIR}/sing-box.log"
CF_LOG="${LOG_DIR}/cloudflared.log"

ACTION="${1:-install}"

LOCAL_PORT="${LOCAL_PORT:-}"
NODE_NAME="${NODE_NAME:-NAT-Argo-VLESS-WS-TLS}"
SB_VERSION="${SB_VERSION:-1.13.18}"
SB_MEMORY="${SB_MEMORY:-18MiB}"
CF_MEMORY="${CF_MEMORY:-24MiB}"
ENABLE_CRON="${ENABLE_CRON:-true}"
GH_PROXY="${GH_PROXY:-}"

say() {
  printf '%s\n' "$*"
}

die() {
  printf '错误: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法:
  sb-argo install
  sb-argo start
  sb-argo restart
  sb-argo stop
  sb-argo status
  sb-argo show
  sb-argo logs
  sb-argo update
  sb-argo rotate
  sb-argo uninstall
EOF
}

case "$ACTION" in
  install|start|restart|stop|status|show|logs|update|rotate|uninstall)
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage
    die "未知操作: ${ACTION}"
    ;;
esac

mkdir -p \
  "$BIN_DIR" \
  "$STATE_DIR" \
  "$LOG_DIR" \
  "$CONFIG_DIR" \
  "$(dirname "$MANAGER")"

chmod 700 "$APP_DIR" "$CONFIG_DIR"

download_file() {
  local url="$1"
  local output="$2"
  local temp="${output}.download"

  case "$url" in
    https://github.com/*|https://raw.githubusercontent.com/*)
      url="${GH_PROXY}${url}"
      ;;
  esac

  rm -f "$temp"

  # 64 MB 机器优先使用 wget，避免 curl 下载时出现较高内存峰值。
  if command -v wget >/dev/null 2>&1; then
    wget -q \
      --tries=10 \
      --timeout=30 \
      -O "$temp" \
      "$url" || {
        rm -f "$temp"
        return 1
      }
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL \
      --retry 10 \
      --retry-delay 2 \
      --connect-timeout 20 \
      -o "$temp" \
      "$url" || {
        rm -f "$temp"
        return 1
      }
  else
    die "系统中没有 wget 或 curl"
  fi

  [ -s "$temp" ] || {
    rm -f "$temp"
    return 1
  }

  mv "$temp" "$output"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      SB_ARCH="amd64"
      CF_ARCH="amd64"
      ;;
    aarch64|arm64)
      SB_ARCH="arm64"
      CF_ARCH="arm64"
      ;;
    armv7l|armv7)
      SB_ARCH="armv7"
      CF_ARCH="arm"
      ;;
    i386|i686)
      SB_ARCH="386"
      CF_ARCH="386"
      ;;
    *)
      die "不支持的 CPU 架构: $(uname -m)"
      ;;
  esac
}
choose_local_port() {
  local saved_port=""
  local input_port=""
  local default_port="40001"

  if [ -s "$PORT_FILE" ]; then
    saved_port="$(head -n 1 "$PORT_FILE" | tr -d '\r\n')"

    case "$saved_port" in
      ''|*[!0-9]*)
        saved_port=""
        ;;
    esac
  fi

  if [ -n "$saved_port" ]; then
    default_port="$saved_port"
  fi

  # 环境变量优先，例如：LOCAL_PORT=40002 bash install.sh
  if [ -n "$LOCAL_PORT" ]; then
    return 0
  fi

  # 只在首次安装或重新安装时询问。
  # 使用 /dev/tty，因此 wget | tr | bash 的运行方式也可以交互。
  if [ "$ACTION" = "install" ] &&
     [ -t 1 ] &&
     [ -r /dev/tty ]; then
    printf '请输入 sing-box 本地回源端口 [默认 %s]: ' \
      "$default_port" >/dev/tty

    if ! IFS= read -r input_port </dev/tty; then
      input_port=""
    fi

    LOCAL_PORT="${input_port:-$default_port}"
  else
    LOCAL_PORT="$default_port"
  fi
}

save_local_port() {
  printf '%s\n' "$LOCAL_PORT" >"$PORT_FILE"
  chmod 600 "$PORT_FILE"
}
validate_settings() {
  case "$LOCAL_PORT" in
    ''|*[!0-9]*)
      die "LOCAL_PORT 必须是数字"
      ;;
  esac

  if [ "$LOCAL_PORT" -lt 1024 ] || [ "$LOCAL_PORT" -gt 65535 ]; then
    die "LOCAL_PORT 必须在 1024 到 65535 之间"
  fi

  case "$NODE_NAME" in
    *[!A-Za-z0-9._-]*)
      die "NODE_NAME 只能包含字母、数字、点、下划线和短横线"
      ;;
  esac

  case "$ENABLE_CRON" in
    true|false)
      ;;
    *)
      die "ENABLE_CRON 只能是 true 或 false"
      ;;
  esac
}

pid_running() {
  local pid_file="$1"
  local expected_bin="$2"
  local pid

  [ -s "$pid_file" ] || return 1

  pid="$(cat "$pid_file" 2>/dev/null || true)"

  case "$pid" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac

  kill -0 "$pid" 2>/dev/null || return 1

  if [ -r "/proc/${pid}/cmdline" ]; then
    tr '\000' ' ' <"/proc/${pid}/cmdline" |
      grep -Fq "$expected_bin" || return 1
  fi

  return 0
}

stop_process() {
  local pid_file="$1"
  local expected_bin="$2"
  local pid
  local count

  if ! pid_running "$pid_file" "$expected_bin"; then
    rm -f "$pid_file"
    return 0
  fi

  pid="$(cat "$pid_file")"
  kill "$pid" 2>/dev/null || true

  count=0
  while kill -0 "$pid" 2>/dev/null && [ "$count" -lt 8 ]; do
    sleep 1
    count=$((count + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi

  rm -f "$pid_file"
}

stop_all() {
  stop_process "$CF_PID_FILE" "$CF_BIN"
  stop_process "$SB_PID_FILE" "$SB_BIN"
}

show_status() {
  if pid_running "$SB_PID_FILE" "$SB_BIN"; then
    say "sing-box:    running, PID $(cat "$SB_PID_FILE")"
  else
    say "sing-box:    stopped"
  fi

  if pid_running "$CF_PID_FILE" "$CF_BIN"; then
    say "cloudflared: running, PID $(cat "$CF_PID_FILE")"
  else
    say "cloudflared: stopped"
  fi
}

install_manager() {
  local downloaded="${STATE_DIR}/manager-source"
  local cleaned="${MANAGER}.new"

  say "正在安装管理命令..."

  download_file "$SELF_URL" "$downloaded" ||
    die "无法从 GitHub 下载管理脚本"

  # 即使 GitHub 文件意外使用 CRLF，服务器上的管理脚本仍转换为 LF。
  tr -d '\r' <"$downloaded" >"$cleaned"

  chmod 700 "$cleaned"
  mv "$cleaned" "$MANAGER"
  rm -f "$downloaded"
}

download_sing_box() {
  local force="$1"
  local package
  local archive
  local new_bin="${SB_BIN}.new"

  if [ "$force" != "true" ] && [ -x "$SB_BIN" ]; then
    return 0
  fi

  package="sing-box-${SB_VERSION}-linux-${SB_ARCH}.tar.gz"
  archive="${STATE_DIR}/${package}"

  say "正在下载 sing-box ${SB_VERSION}..."

  download_file \
    "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${package}" \
    "$archive" ||
    die "sing-box 下载失败"

  rm -f "$new_bin"

  tar -xOzf \
    "$archive" \
    "sing-box-${SB_VERSION}-linux-${SB_ARCH}/sing-box" \
    >"$new_bin" || {
      rm -f "$new_bin"
      die "sing-box 解压失败"
    }

  chmod 700 "$new_bin"
  mv "$new_bin" "$SB_BIN"
  rm -f "$archive"

  "$SB_BIN" version >/dev/null 2>&1 ||
    die "sing-box 二进制无法运行"
}

download_cloudflared() {
  local force="$1"
  local new_bin="${CF_BIN}.new"

  if [ "$force" != "true" ] && [ -x "$CF_BIN" ]; then
    return 0
  fi

  say "正在下载 cloudflared..."

  download_file \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
    "$new_bin" ||
    die "cloudflared 下载失败，可能是内存不足或网络中断"

  chmod 700 "$new_bin"
  mv "$new_bin" "$CF_BIN"

  "$CF_BIN" --version >/dev/null 2>&1 ||
    die "cloudflared 二进制无法运行"
}

create_identity() {
  if [ ! -s "$UUID_FILE" ]; then
    "$SB_BIN" generate uuid >"$UUID_FILE" ||
      die "UUID 生成失败"
  fi

  UUID="$(cat "$UUID_FILE")"

  if [ ! -s "$WS_PATH_FILE" ]; then
    printf '/%s-vl\n' "${UUID%%-*}" >"$WS_PATH_FILE"
  fi

  WS_PATH="$(cat "$WS_PATH_FILE")"

  case "$UUID" in
    *[!0-9A-Fa-f-]*|'')
      die "保存的 UUID 无效"
      ;;
  esac

  case "$WS_PATH" in
    /*)
      ;;
    *)
      die "WS 路径必须以 / 开头"
      ;;
  esac

  chmod 600 "$UUID_FILE" "$WS_PATH_FILE"
}

write_sing_box_config() {
  cat >"$SB_CONFIG" <<EOF
{
  "log": {
    "level": "error",
    "timestamp": false
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "listen_port": ${LOCAL_PORT},
      "users": [
        {
          "uuid": "${UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

  chmod 600 "$SB_CONFIG"

  env \
    GOMAXPROCS=1 \
    GOMEMLIMIT="$SB_MEMORY" \
    GOGC=25 \
    GODEBUG=madvdontneed=1 \
    "$SB_BIN" check -c "$SB_CONFIG" ||
    die "sing-box 配置检查失败"
}

start_sing_box() {
  : >"$SB_LOG"

  say "正在启动 sing-box..."

  nohup env \
    GOMAXPROCS=1 \
    GOMEMLIMIT="$SB_MEMORY" \
    GOGC=25 \
    GODEBUG=madvdontneed=1 \
    "$SB_BIN" run -c "$SB_CONFIG" \
    </dev/null >>"$SB_LOG" 2>&1 &

  printf '%s\n' "$!" >"$SB_PID_FILE"

  sleep 2

  if ! pid_running "$SB_PID_FILE" "$SB_BIN"; then
    tail -n 40 "$SB_LOG" >&2 || true
    die "sing-box 启动失败，可能是配置错误或内存不足"
  fi
}

start_cloudflared() {
  : >"$CF_LOG"

  say "正在启动 Cloudflare 临时隧道..."

  nohup env \
    GOMAXPROCS=1 \
    GOMEMLIMIT="$CF_MEMORY" \
    GOGC=25 \
    GODEBUG=madvdontneed=1 \
    "$CF_BIN" tunnel \
      --no-autoupdate \
      --protocol http2 \
      --url "http://127.0.0.1:${LOCAL_PORT}" \
    </dev/null >>"$CF_LOG" 2>&1 &

  printf '%s\n' "$!" >"$CF_PID_FILE"
}

wait_for_domain() {
  local domain=""
  local count=0

  while [ "$count" -lt 120 ]; do
    if ! pid_running "$CF_PID_FILE" "$CF_BIN"; then
      return 1
    fi

    domain="$(
      grep -aoE \
        'https://[A-Za-z0-9-]+\.trycloudflare\.com' \
        "$CF_LOG" 2>/dev/null |
        tail -n 1 |
        sed 's#https://##'
    )"

    case "$domain" in
      *.trycloudflare.com)
        printf '%s' "$domain"
        return 0
        ;;
    esac

    count=$((count + 1))
    sleep 1
  done

  return 1
}

create_node() {
  local domain="$1"
  local encoded_path
  local link

  case "$domain" in
    *.trycloudflare.com)
      ;;
    *)
      die "拒绝使用空域名或无效临时域名生成节点"
      ;;
  esac

  encoded_path="%2F${WS_PATH#/}"

  link="vless://${UUID}@${domain}:443?encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=${encoded_path}#${NODE_NAME}"

  printf '%s\n' "$domain" >"$DOMAIN_FILE"

  printf '%s\n' "$link" |
    base64 |
    tr -d '\r\n' >"$SUB_FILE"

  printf '\n' >>"$SUB_FILE"

  cat >"$NODE_FILE" <<EOF
协议: VLESS
地址: ${domain}
端口: 443
UUID: ${UUID}
传输: WebSocket
路径: ${WS_PATH}
Host: ${domain}
TLS: 开启
SNI: ${domain}

节点链接:
${link}

本地 Base64 订阅文件:
${SUB_FILE}
EOF

  chmod 600 "$DOMAIN_FILE" "$NODE_FILE" "$SUB_FILE"
}

remove_cron() {
  command -v crontab >/dev/null 2>&1 || return 0

  {
    crontab -l 2>/dev/null |
      grep -Fv "${MANAGER} start" || true
  } | crontab - 2>/dev/null || true
}

add_cron() {
  local cron_line

  [ "$ENABLE_CRON" = "true" ] || return 0
  command -v crontab >/dev/null 2>&1 || return 0

  cron_line="@reboot sleep 20 && ${MANAGER} start >>${LOG_DIR}/boot.log 2>&1"

  {
    crontab -l 2>/dev/null |
      grep -Fv "${MANAGER} start" || true
    printf '%s\n' "$cron_line"
  } | crontab - 2>/dev/null || true
}

case "$ACTION" in
  stop)
    stop_all
    say "已停止"
    exit 0
    ;;
  status)
    show_status
    exit 0
    ;;
  show)
    if [ -s "$NODE_FILE" ]; then
      cat "$NODE_FILE"
    else
      say "尚未生成节点，请执行: ${MANAGER} restart"
    fi
    exit 0
    ;;
  logs)
    say "----- sing-box -----"
    tail -n 50 "$SB_LOG" 2>/dev/null || true
    say "----- cloudflared -----"
    tail -n 80 "$CF_LOG" 2>/dev/null || true
    exit 0
    ;;
  uninstall)
    stop_all
    remove_cron
    rm -rf "$APP_DIR" "$CONFIG_DIR"
    rm -f "$MANAGER"
    say "已卸载"
    exit 0
    ;;
esac

command -v tar >/dev/null 2>&1 ||
  die "服务器缺少 tar 命令"

command -v base64 >/dev/null 2>&1 ||
  die "服务器缺少 base64 命令"

command -v tr >/dev/null 2>&1 ||
  die "服务器缺少 tr 命令"

choose_local_port
validate_settings
save_local_port
detect_arch

if [ "$ACTION" = "install" ] || [ "$ACTION" = "update" ]; then
  install_manager
fi

if [ "$ACTION" = "update" ]; then
  stop_all
  download_sing_box true
  download_cloudflared true
else
  download_sing_box false
  download_cloudflared false
fi

if [ "$ACTION" = "rotate" ]; then
  stop_all
  rm -f "$UUID_FILE" "$WS_PATH_FILE"
fi

create_identity
write_sing_box_config

if [ "$ACTION" = "start" ] &&
   pid_running "$SB_PID_FILE" "$SB_BIN" &&
   pid_running "$CF_PID_FILE" "$CF_BIN"; then
  show_status
  [ -s "$NODE_FILE" ] && cat "$NODE_FILE"
  exit 0
fi

stop_all
rm -f "$DOMAIN_FILE" "$NODE_FILE"

start_sing_box
start_cloudflared

DOMAIN=""

if ! DOMAIN="$(wait_for_domain)"; then
  say "----- cloudflared 日志 -----" >&2
  tail -n 80 "$CF_LOG" >&2 || true
  stop_all
  die "无法取得 Cloudflare 临时域名，已停止生成节点"
fi

case "$DOMAIN" in
  *.trycloudflare.com)
    ;;
  *)
    stop_all
    die "Cloudflare 临时域名为空或格式无效"
    ;;
esac

if ! pid_running "$SB_PID_FILE" "$SB_BIN"; then
  tail -n 40 "$SB_LOG" >&2 || true
  stop_all
  die "sing-box 已退出，可能是内存不足"
fi

create_node "$DOMAIN"
add_cron

say
say "节点生成成功"
say
cat "$NODE_FILE"
say
say "管理命令:"
say "  ${MANAGER} show"
say "  ${MANAGER} status"
say "  ${MANAGER} restart"
say "  ${MANAGER} logs"
say "  ${MANAGER} stop"
say "  ${MANAGER} update"
say "  ${MANAGER} rotate"
say "  ${MANAGER} uninstall"
