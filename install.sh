#!/usr/bin/env bash

set -u

# 上传到其他仓库时，修改这里。
SELF_URL="${SELF_URL:-https://raw.githubusercontent.com/liu200320/sing-box-argo-lite/main/install.sh}"

APP_DIR="${HOME}/.local/share/sb-argo"
BIN_DIR="${APP_DIR}/bin"
STATE_DIR="${APP_DIR}/state"
LOG_DIR="${APP_DIR}/logs"
CONFIG_DIR="${HOME}/.config/sb-argo"

MANAGER="${HOME}/.local/bin/sb-argo"
SAVED_CONFIG="${CONFIG_DIR}/config.conf"
SECRET_CONFIG="${CONFIG_DIR}/secrets.conf"

SB_BIN="${BIN_DIR}/sing-box"
CF_BIN="${BIN_DIR}/cloudflared"
SB_CONFIG="${CONFIG_DIR}/sing-box.json"

SB_PID_FILE="${STATE_DIR}/sing-box.pid"
CF_PID_FILE="${STATE_DIR}/cloudflared.pid"

SB_LOG="${LOG_DIR}/sing-box.log"
CF_LOG="${LOG_DIR}/cloudflared.log"

NODE_FILE="${STATE_DIR}/node-info.txt"
SUB_FILE="${STATE_DIR}/subscription.txt"

ACTION="${1:-install}"

LOCAL_PORT="${LOCAL_PORT:-40001}"
UUID="${UUID:-}"
WS_PATH="${WS_PATH:-}"
NODE_NAME="${NODE_NAME:-NAT-Argo-VLESS-WS-TLS}"

SUBSCRIBE="${SUBSCRIBE:-true}"
GIST_PUBLIC="${GIST_PUBLIC:-false}"
GIST_ID="${GIST_ID:-}"
GIST_OWNER="${GIST_OWNER:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

ENABLE_CRON="${ENABLE_CRON:-true}"

SB_MEMORY="${SB_MEMORY:-18MiB}"
CF_MEMORY="${CF_MEMORY:-24MiB}"
SB_VERSION="${SB_VERSION:-}"
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
  sb-argo uninstall
EOF
}

case "$ACTION" in
  install|start|restart|stop|status|show|logs|update|uninstall) ;;
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

# 管理命令运行时读取已保存配置。
if [ -s "$SAVED_CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$SAVED_CONFIG"
fi

if [ -s "$SECRET_CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$SECRET_CONFIG"
fi

fetch() {
  local url="$1"
  local output="$2"

  case "$url" in
    https://github.com/*|https://raw.githubusercontent.com/*)
      url="${GH_PROXY}${url}"
      ;;
  esac

  if command -v curl >/dev/null 2>&1; then
    curl -fL \
      --retry 5 \
      --retry-delay 2 \
      --connect-timeout 20 \
      -o "$output" \
      "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q \
      --tries=5 \
      --timeout=30 \
      -O "$output" \
      "$url"
  else
    die "系统中没有 curl 或 wget"
  fi
}

pid_running() {
  local pid_file="$1"
  local expected_bin="$2"
  local pid

  [ -s "$pid_file" ] || return 1

  pid="$(cat "$pid_file" 2>/dev/null || true)"

  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
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
  while kill -0 "$pid" 2>/dev/null && [ "$count" -lt 10 ]; do
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

  cron_line="@reboot sleep 20 && ${MANAGER} start >/dev/null 2>&1"

  {
    crontab -l 2>/dev/null |
      grep -Fv "${MANAGER} start" || true
    printf '%s\n' "$cron_line"
  } | crontab - 2>/dev/null || true
}

save_config() {
  cat >"$SAVED_CONFIG" <<EOF
LOCAL_PORT=$(printf '%q' "$LOCAL_PORT")
UUID=$(printf '%q' "$UUID")
WS_PATH=$(printf '%q' "$WS_PATH")
NODE_NAME=$(printf '%q' "$NODE_NAME")
SUBSCRIBE=$(printf '%q' "$SUBSCRIBE")
GIST_PUBLIC=$(printf '%q' "$GIST_PUBLIC")
GIST_ID=$(printf '%q' "$GIST_ID")
GIST_OWNER=$(printf '%q' "$GIST_OWNER")
ENABLE_CRON=$(printf '%q' "$ENABLE_CRON")
SB_MEMORY=$(printf '%q' "$SB_MEMORY")
CF_MEMORY=$(printf '%q' "$CF_MEMORY")
SB_VERSION=$(printf '%q' "$SB_VERSION")
GH_PROXY=$(printf '%q' "$GH_PROXY")
SELF_URL=$(printf '%q' "$SELF_URL")
EOF

  chmod 600 "$SAVED_CONFIG"
}

install_manager() {
  local temp_file="${STATE_DIR}/manager-download.$$"
  local clean_file="${STATE_DIR}/manager-clean.$$"

  say "正在安装管理命令..."

  fetch "$SELF_URL" "$temp_file" || die "无法下载管理脚本"

  # 即使 GitHub 文件误用 CRLF，安装到服务器时也强制转换成 LF。
  tr -d '\r' <"$temp_file" >"$clean_file"

  chmod 700 "$clean_file"
  mv "$clean_file" "$MANAGER"
  rm -f "$temp_file"
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

get_sing_box_version() {
  local release_json="${STATE_DIR}/sing-box-release.json"

  if [ -n "$SB_VERSION" ]; then
    return 0
  fi

  say "正在查询 sing-box 最新版本..."

  fetch \
    "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
    "$release_json" ||
    die "无法查询 sing-box 最新版本"

  SB_VERSION="$(
    sed -n \
      's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' \
      "$release_json" |
      head -n 1
  )"

  [ -n "$SB_VERSION" ] || die "无法解析 sing-box 版本号"
}

download_sing_box() {
  local force="$1"
  local package
  local archive
  local new_bin="${SB_BIN}.new"

  if [ "$force" != "true" ] && [ -x "$SB_BIN" ]; then
    return 0
  fi

  get_sing_box_version

  package="sing-box-${SB_VERSION}-linux-${SB_ARCH}.tar.gz"
  archive="${STATE_DIR}/${package}"

  say "正在下载 sing-box ${SB_VERSION}..."

  fetch \
    "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${package}" \
    "$archive" ||
    die "sing-box 下载失败"

  tar -xOzf \
    "$archive" \
    "sing-box-${SB_VERSION}-linux-${SB_ARCH}/sing-box" \
    >"$new_bin" ||
    die "sing-box 解压失败"

  chmod 700 "$new_bin"
  mv "$new_bin" "$SB_BIN"
  rm -f "$archive"
}

download_cloudflared() {
  local force="$1"
  local new_bin="${CF_BIN}.new"

  if [ "$force" != "true" ] && [ -x "$CF_BIN" ]; then
    return 0
  fi

  say "正在下载 cloudflared..."

  fetch \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
    "$new_bin" ||
    die "cloudflared 下载失败"

  chmod 700 "$new_bin"
  mv "$new_bin" "$CF_BIN"
}

validate_settings() {
  case "$LOCAL_PORT" in
    ''|*[!0-9]*) die "LOCAL_PORT 必须是数字" ;;
  esac

  if [ "$LOCAL_PORT" -lt 1024 ] || [ "$LOCAL_PORT" -gt 65535 ]; then
    die "LOCAL_PORT 必须在 1024 到 65535 之间"
  fi

  case "$SUBSCRIBE" in
    true|false) ;;
    *) die "SUBSCRIBE 只能是 true 或 false" ;;
  esac

  case "$GIST_PUBLIC" in
    true|false) ;;
    *) die "GIST_PUBLIC 只能是 true 或 false" ;;
  esac

  case "$ENABLE_CRON" in
    true|false) ;;
    *) die "ENABLE_CRON 只能是 true 或 false" ;;
  esac

  if ! printf '%s' "$NODE_NAME" |
    grep -Eq '^[A-Za-z0-9._-]+$'; then
    die "NODE_NAME 只能包含英文字母、数字、点、下划线和短横线"
  fi
}

make_identity() {
  if [ -z "$UUID" ]; then
    UUID="$("$SB_BIN" generate uuid)" ||
      die "UUID 生成失败"
  fi

  if [ -z "$WS_PATH" ]; then
    WS_PATH="/${UUID%%-*}-vl"
  fi

  case "$WS_PATH" in
    /*) ;;
    *) WS_PATH="/${WS_PATH}" ;;
  esac

  case "$WS_PATH" in
    *\"*|*\\*|*" "*|*"?"*|*"#"*)
      die "WS_PATH 不能包含空格、引号、反斜杠、问号或井号"
      ;;
  esac
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

  while [ "$count" -lt 60 ]; do
    if ! pid_running "$CF_PID_FILE" "$CF_BIN"; then
      tail -n 60 "$CF_LOG" >&2 || true
      die "cloudflared 已退出，可能是网络错误或内存不足"
    fi

    domain="$(
      sed -n \
        's|.*https://\([A-Za-z0-9-]*\.trycloudflare\.com\).*|\1|p' \
        "$CF_LOG" |
        head -n 1
    )"

    if [ -n "$domain" ]; then
      printf '%s' "$domain"
      return 0
    fi

    count=$((count + 1))
    sleep 1
  done

  tail -n 60 "$CF_LOG" >&2 || true
  die "60 秒内没有取得 trycloudflare.com 临时域名"
}

publish_gist() {
  local sub_content
  local payload="${STATE_DIR}/gist-payload.json"
  local response="${STATE_DIR}/gist-response.json"

  command -v curl >/dev/null 2>&1 || {
    say "警告: 发布 Gist 订阅需要 curl"
    return 1
  }

  if [ -z "$GITHUB_TOKEN" ] && [ -t 0 ]; then
    printf '请输入具有 gist 权限的 GitHub Classic Token（输入不显示，可直接回车跳过）: '
    read -r -s GITHUB_TOKEN
    printf '\n'
  fi

  if [ -z "$GITHUB_TOKEN" ]; then
    say "未输入 GitHub Token，只生成本地订阅文件。"
    return 1
  fi

  cat >"$SECRET_CONFIG" <<EOF
GITHUB_TOKEN=$(printf '%q' "$GITHUB_TOKEN")
EOF
  chmod 600 "$SECRET_CONFIG"

  sub_content="$(tr -d '\r\n' <"$SUB_FILE")"

  cat >"$payload" <<EOF
{
  "description": "sb-argo auto-updated subscription",
  "public": ${GIST_PUBLIC},
  "files": {
    "sub.txt": {
      "content": "${sub_content}"
    }
  }
}
EOF

  if [ -z "$GIST_ID" ]; then
    say "正在创建 GitHub Gist 订阅..."

    curl -fsS \
      -X POST \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      --data-binary "@${payload}" \
      "https://api.github.com/gists" \
      >"$response" ||
      return 1

    GIST_ID="$(
      grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' "$response" |
        head -n 1 |
        sed 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
    )"
  else
    say "正在更新 GitHub Gist 订阅..."

    curl -fsS \
      -X PATCH \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      --data-binary "@${payload}" \
      "https://api.github.com/gists/${GIST_ID}" \
      >"$response" ||
      return 1
  fi

  GIST_OWNER="$(
    grep -oE '"login"[[:space:]]*:[[:space:]]*"[^"]+"' "$response" |
      head -n 1 |
      sed 's/.*"login"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
  )"

  if [ -z "$GIST_ID" ] || [ -z "$GIST_OWNER" ]; then
    say "警告: 无法解析 Gist 返回结果"
    return 1
  fi

  return 0
}

create_node_info() {
  local domain="$1"
  local encoded_path
  local vless_link
  local sub_url="未发布在线订阅"

  encoded_path="$(
    printf '%s' "$WS_PATH" |
      sed 's|%|%25|g; s|/|%2F|g; s|?|%3F|g; s|#|%23|g'
  )"

  vless_link="vless://${UUID}@${domain}:443?encryption=none&security=tls&sni=${domain}&alpn=http%2F1.1&type=ws&host=${domain}&path=${encoded_path}#${NODE_NAME}"

  printf '%s\n' "$vless_link" |
    base64 |
    tr -d '\r\n' >"$SUB_FILE"

  printf '\n' >>"$SUB_FILE"
  chmod 600 "$SUB_FILE"

  if [ "$SUBSCRIBE" = "true" ]; then
    if publish_gist; then
      sub_url="https://gist.githubusercontent.com/${GIST_OWNER}/${GIST_ID}/raw/sub.txt"
    else
      sub_url="发布失败或未配置 Token，仅生成本地订阅"
    fi
  fi

  save_config

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
${vless_link}

订阅链接:
${sub_url}
EOF

  chmod 600 "$NODE_FILE"
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
      say "尚未生成节点，请先执行安装。"
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

validate_settings
detect_arch

if [ "$ACTION" = "install" ] || [ "$ACTION" = "update" ]; then
  install_manager
fi

if [ "$ACTION" = "update" ]; then
  stop_all
  SB_VERSION=""
  download_sing_box true
  download_cloudflared true
else
  download_sing_box false
  download_cloudflared false
fi

make_identity
write_sing_box_config
save_config

if [ "$ACTION" = "start" ] &&
  pid_running "$SB_PID_FILE" "$SB_BIN" &&
  pid_running "$CF_PID_FILE" "$CF_BIN"; then
  show_status
  [ -s "$NODE_FILE" ] && cat "$NODE_FILE"
  exit 0
fi

stop_all
start_sing_box
start_cloudflared

DOMAIN="$(wait_for_domain)"

if ! pid_running "$SB_PID_FILE" "$SB_BIN"; then
  tail -n 40 "$SB_LOG" >&2 || true
  die "取得临时域名后 sing-box 已退出，可能是内存不足"
fi

create_node_info "$DOMAIN"
add_cron

say ""
say "安装或启动完成"
say ""
cat "$NODE_FILE"
say ""
say "管理命令:"
say "  ${MANAGER} show"
say "  ${MANAGER} status"
say "  ${MANAGER} restart"
say "  ${MANAGER} logs"
say "  ${MANAGER} stop"
say "  ${MANAGER} update"
say "  ${MANAGER} uninstall"
