#!/bin/sh
set -u

export LC_ALL=C
export LANG=C

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

环境变量:
  LOCAL_PORT=40001
  NODE_NAME=NAT-Argo-VLESS-WS-TLS
  SB_MEMORY=18MiB
  CF_MEMORY=24MiB
  SB_VERSION=1.13.18
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
  DL_URL="$1"
  DL_OUTPUT="$2"
  DL_TEMP="${DL_OUTPUT}.download"

  case "$DL_URL" in
    https://github.com/*|https://raw.githubusercontent.com/*)
      DL_URL="${GH_PROXY}${DL_URL}"
      ;;
  esac

  rm -f "$DL_TEMP"

  # 低内存环境优先使用 wget。
  if command -v wget >/dev/null 2>&1; then
    wget -q \
      -T 30 \
      -t 10 \
      -O "$DL_TEMP" \
      "$DL_URL" || {
        rm -f "$DL_TEMP"
        return 1
      }
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL \
      --retry 10 \
      --retry-delay 2 \
      --connect-timeout 20 \
      -o "$DL_TEMP" \
      "$DL_URL" || {
        rm -f "$DL_TEMP"
        return 1
      }
  else
    die "系统中没有 wget 或 curl"
  fi

  if [ ! -s "$DL_TEMP" ]; then
    rm -f "$DL_TEMP"
    return 1
  fi

  mv "$DL_TEMP" "$DL_OUTPUT"
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
  PORT_DEFAULT="40001"
  PORT_SAVED=""
  PORT_INPUT=""

  if [ -s "$PORT_FILE" ]; then
    PORT_SAVED="$(
      head -n 1 "$PORT_FILE" 2>/dev/null |
        tr -d '\r\n'
    )"

    case "$PORT_SAVED" in
      ''|*[!0-9]*)
        PORT_SAVED=""
        ;;
    esac
  fi

  if [ -n "$PORT_SAVED" ]; then
    PORT_DEFAULT="$PORT_SAVED"
  fi

  # 环境变量的优先级最高。
  if [ -n "$LOCAL_PORT" ]; then
    return 0
  fi

  # 只有 install 操作交互询问。
  # 从管道执行时，使用 /dev/tty 读取用户输入。
  if [ "$ACTION" = "install" ] && [ -c /dev/tty ]; then
    printf '请输入 sing-box 本地回源端口 [默认 %s]: ' \
      "$PORT_DEFAULT" >/dev/tty

    if ! IFS= read -r PORT_INPUT </dev/tty; then
      PORT_INPUT=""
    fi

    LOCAL_PORT="${PORT_INPUT:-$PORT_DEFAULT}"
  else
    LOCAL_PORT="$PORT_DEFAULT"
  fi
}

validate_settings() {
  case "$LOCAL_PORT" in
    ''|*[!0-9]*)
      die "端口必须是数字"
      ;;
  esac

  if [ "$LOCAL_PORT" -lt 1024 ] ||
     [ "$LOCAL_PORT" -gt 65535 ]; then
    die "端口必须在 1024 到 65535 之间"
  fi

  case "$NODE_NAME" in
    ''|*[!A-Za-z0-9._-]*)
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

save_local_port() {
  printf '%s\n' "$LOCAL_PORT" >"$PORT_FILE"
  chmod 600 "$PORT_FILE"
}

pid_running() {
  PID_FILE_ARG="$1"
  EXPECTED_BIN_ARG="$2"

  [ -s "$PID_FILE_ARG" ] || return 1

  PID_VALUE="$(cat "$PID_FILE_ARG" 2>/dev/null || true)"

  case "$PID_VALUE" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac

  kill -0 "$PID_VALUE" 2>/dev/null || return 1

  if [ -r "/proc/${PID_VALUE}/cmdline" ]; then
    tr '\000' ' ' <"/proc/${PID_VALUE}/cmdline" |
      grep -Fq "$EXPECTED_BIN_ARG" || return 1
  fi

  return 0
}

stop_process() {
  STOP_PID_FILE="$1"
  STOP_EXPECTED_BIN="$2"

  if ! pid_running "$STOP_PID_FILE" "$STOP_EXPECTED_BIN"; then
    rm -f "$STOP_PID_FILE"
    return 0
  fi

  STOP_PID="$(cat "$STOP_PID_FILE")"
  kill "$STOP_PID" 2>/dev/null || true

  STOP_COUNT=0

  while kill -0 "$STOP_PID" 2>/dev/null &&
        [ "$STOP_COUNT" -lt 8 ]; do
    sleep 1
    STOP_COUNT=$((STOP_COUNT + 1))
  done

  if kill -0 "$STOP_PID" 2>/dev/null; then
    kill -9 "$STOP_PID" 2>/dev/null || true
  fi

  rm -f "$STOP_PID_FILE"
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
  MANAGER_SOURCE="${STATE_DIR}/manager-source"
  MANAGER_NEW="${MANAGER}.new"

  say "正在安装管理命令..."

  download_file "$SELF_URL" "$MANAGER_SOURCE" ||
    die "无法从 GitHub 下载管理脚本"

  # 自动清除 GitHub 文件中可能存在的 CRLF。
  tr -d '\r' <"$MANAGER_SOURCE" >"$MANAGER_NEW"

  chmod 700 "$MANAGER_NEW"
  mv "$MANAGER_NEW" "$MANAGER"
  rm -f "$MANAGER_SOURCE"
}

download_sing_box() {
  DOWNLOAD_FORCE="$1"

  if [ "$DOWNLOAD_FORCE" != "true" ] &&
     [ -x "$SB_BIN" ]; then
    return 0
  fi

  SB_PACKAGE="sing-box-${SB_VERSION}-linux-${SB_ARCH}.tar.gz"
  SB_ARCHIVE="${STATE_DIR}/${SB_PACKAGE}"
  SB_NEW="${SB_BIN}.new"

  say "正在下载 sing-box ${SB_VERSION}..."

  download_file \
    "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${SB_PACKAGE}" \
    "$SB_ARCHIVE" ||
    die "sing-box 下载失败"

  rm -f "$SB_NEW"

  tar -xOzf \
    "$SB_ARCHIVE" \
    "sing-box-${SB_VERSION}-linux-${SB_ARCH}/sing-box" \
    >"$SB_NEW" || {
      rm -f "$SB_NEW"
      die "sing-box 解压失败"
    }

  chmod 700 "$SB_NEW"
  mv "$SB_NEW" "$SB_BIN"
  rm -f "$SB_ARCHIVE"

  "$SB_BIN" version >/dev/null 2>&1 ||
    die "sing-box 二进制无法运行，可能与当前系统不兼容"
}

download_cloudflared() {
  DOWNLOAD_FORCE="$1"

  if [ "$DOWNLOAD_FORCE" != "true" ] &&
     [ -x "$CF_BIN" ]; then
    return 0
  fi

  CF_NEW="${CF_BIN}.new"

  say "正在下载 cloudflared..."

  download_file \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
    "$CF_NEW" ||
    die "cloudflared 下载失败，可能是网络中断或内存不足"

  chmod 700 "$CF_NEW"
  mv "$CF_NEW" "$CF_BIN"

  "$CF_BIN" --version >/dev/null 2>&1 ||
    die "cloudflared 二进制无法运行，可能与当前系统不兼容"
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
    ''|*[!0-9A-Fa-f-]*)
      die "保存的 UUID 无效"
      ;;
  esac

  case "$WS_PATH" in
    /*)
      ;;
    *)
      die "WebSocket 路径必须以 / 开头"
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
  DOMAIN_CANDIDATE=""
  DOMAIN_COUNT=0

  while [ "$DOMAIN_COUNT" -lt 120 ]; do
    if ! pid_running "$CF_PID_FILE" "$CF_BIN"; then
      return 1
    fi

    DOMAIN_CANDIDATE="$(
      grep -Eo \
        'https://[A-Za-z0-9-]+\.trycloudflare\.com' \
        "$CF_LOG" 2>/dev/null |
        tail -n 1 |
        sed 's#https://##'
    )"

    case "$DOMAIN_CANDIDATE" in
      *.trycloudflare.com)
        printf '%s' "$DOMAIN_CANDIDATE"
        return 0
        ;;
    esac

    DOMAIN_COUNT=$((DOMAIN_COUNT + 1))
    sleep 1
  done

  return 1
}

create_node() {
  NODE_DOMAIN="$1"

  case "$NODE_DOMAIN" in
    *.trycloudflare.com)
      ;;
    *)
      die "拒绝使用空域名或无效域名生成节点"
      ;;
  esac

  ENCODED_PATH="%2F${WS_PATH#/}"

  VLESS_LINK="vless://${UUID}@${NODE_DOMAIN}:443?encryption=none&security=tls&sni=${NODE_DOMAIN}&alpn=http%2F1.1&type=ws&host=${NODE_DOMAIN}&path=${ENCODED_PATH}#${NODE_NAME}"

  printf '%s\n' "$NODE_DOMAIN" >"$DOMAIN_FILE"

  printf '%s\n' "$VLESS_LINK" |
    base64 |
    tr -d '\r\n' >"$SUB_FILE"

  printf '\n' >>"$SUB_FILE"

  cat >"$NODE_FILE" <<EOF
协议: VLESS
地址: ${NODE_DOMAIN}
端口: 443
UUID: ${UUID}
传输: WebSocket
路径: ${WS_PATH}
Host: ${NODE_DOMAIN}
TLS: 开启
SNI: ${NODE_DOMAIN}
本地回源端口: ${LOCAL_PORT}

节点链接:
${VLESS_LINK}

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
  [ "$ENABLE_CRON" = "true" ] || return 0
  command -v crontab >/dev/null 2>&1 || return 0

  CRON_LINE="@reboot sleep 20 && ${MANAGER} start >>${LOG_DIR}/boot.log 2>&1"

  {
    crontab -l 2>/dev/null |
      grep -Fv "${MANAGER} start" || true
    printf '%s\n' "$CRON_LINE"
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
  die "系统缺少 tar 命令"

command -v base64 >/dev/null 2>&1 ||
  die "系统缺少 base64 命令"

command -v grep >/dev/null 2>&1 ||
  die "系统缺少 grep 命令"

command -v sed >/dev/null 2>&1 ||
  die "系统缺少 sed 命令"

command -v tr >/dev/null 2>&1 ||
  die "系统缺少 tr 命令"

choose_local_port
validate_settings
save_local_port
detect_arch

if [ "$ACTION" = "install" ] ||
   [ "$ACTION" = "update" ]; then
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

  if [ -s "$NODE_FILE" ]; then
    cat "$NODE_FILE"
  fi

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
