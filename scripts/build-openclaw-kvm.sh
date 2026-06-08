#!/usr/bin/env bash
set -Eeuo pipefail

# ================================
# OpenClaw KVM Cloud-Init 镜像构建脚本
# 由 .github/workflows/build-openclaw-kvm.yml 调用
# 需要 root 运行：sudo -E bash scripts/build-openclaw-kvm.sh
# ==================================================

# ---------- 可由环境变量覆盖的配置 ----------
WORK_DIR="${WORK_DIR:-/tmp/openclaw-build}"
DIST_DIR="${DIST_DIR:-${GITHUB_WORKSPACE:-$PWD}/dist}"
PAYLOAD_DIR="${WORK_DIR}/payload"
OFFLINE_DIR="${WORK_DIR}/offline"

BASE_IMG="${WORK_DIR}/debian-12-base.qcow2"
WORK_IMG="${WORK_DIR}/openclaw-kvm.qcow2"

DEBIAN_CLOUD_URL="${DEBIAN_CLOUD_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2}"

OPENCLAW_NPM_SPEC="${OPENCLAW_NPM_SPEC:-openclaw}"
OPENCLAW_RUN_CMD="${OPENCLAW_RUN_CMD:-openclaw onboard}"
BIND_HOST="${BIND_HOST:-0.0.0.0}"
IPV6_POLICY="${IPV6_POLICY:-ask}"
DISK_SIZE="${DISK_SIZE:-20G}"
PORT_MIN="${PORT_MIN:-20000}"
PORT_MAX="${PORT_MAX:-65000}"

NPM_INSTALL_REGISTRY="${NPM_INSTALL_REGISTRY:-https://registry.npmjs.org/}"
NPM_FINAL_REGISTRY="${NPM_FINAL_REGISTRY:-https://registry.npmjs.org/}"

VERSION="${VERSION:-dev}"
SAFE_VERSION="${SAFE_VERSION:-${VERSION#v}"

# ---------- 产物路径 ----------
OUT_QCOW2="${DIST_DIR}/openclaw-kvm-${SAFE_VERSION}.qcow2"
OUT_XZ="${OUT_QCOW2}.xz"
OUT_SHA="${DIST_DIR}/openclaw-kvm-${SAFE_VERSION}.sha256"
OUT_LIST="${DIST_DIR}/openclaw-kvm-${SAFE_VERSION}.filelist.txt"
OUT_INFO="${DIST_DIR}/openclaw-kvm-${SAFE_VERSION}.buildinfo.txt"

# 供 buildinfo 引用（在 prepare_offline_openclaw 中赋值）
NODE_FILE=""

# ================================================
# 工具函数
# ==================================
log() {
  echo "==> $*"
}

die() {
  echo "错误：$*" >&2
  exit 1
}

q() {
  printf '%q' "$1"
}

need_root() {
  if [ "$(id -u)" != "0" ]; then
    die "本构建脚本需要 root，请使用 sudo -E bash 运行"
  fi
}

on_error() {
  local line="$1"
  echo
  echo "================================================="
  echo "构建失败，出错行：${line}"
  echo "=================================================="
  exit 1
}

# ==================================================
# 输入校验
# ================================================
normalize_disk_size() {
  local raw="${DISK_SIZE:-20G}"

  raw="$(echo "$raw" | tr -d ' ')"
  raw="$(echo "$raw" | tr '[:lower:]' '[:upper:]')"

  if [[ "$raw" =~ ^[0-9]+$ ]; then
    raw="${raw}G"
  fi

  raw="${raw/KB/K}"
  raw="${raw/MB/M}"
  raw="${raw/GB/G}"
  raw="${raw/TB/T}"
  raw="${raw/PB/P}"
  raw="${raw/EB/E}"

  if [[ ! "$raw" =~ ^[0-9]+[KMGTPE]$ ]]; then
    die "disk_size 格式不正确：${DISK_SIZE}，正确示例：20G、30G、10240M"
  fi

  DISK_SIZE="$raw"
}

validate_inputs() {
  normalize_disk_size

  [[ "$PORT_MIN" =~ ^[0-9]+$ ]] || die "port_min 必须是数字"
  [[ "$PORT_MAX" =~ ^[0-9]+$ ]] || die "port_max 必须是数字"

  local pmin="$((10#$PORT_MIN))"
  local pmax="$((10#$PORT_MAX))"

  ( pmin >= 1 && pmin <= 65535 )) || die "port_min 必须在 1-65535"
  ( pmax >= 1 && pmax <= 65535 )) || die "port_max 必须在 1-65535"
  ( pmin <= pmax )) || die "port_min 不能大于 port_max"

  PORT_MIN="$pmin"
  PORT_MAX="$pmax"

  [[ "$IPV6_POLICY" =~ ^(ask|0|1)$ ]] || die "ipv6_policy 只能是 ask、0、1"
  [[ "$BIND_HOST" == "0.0.0" || "$BIND_HOST" == "::" ]] || die "bind_host 只能是 0.0.0.0 或 ::"

  if [[ "$BIND_HOST" == "::" && "$IPV6_POLICY" != "1" ]]; then
    die "bind_host 为 : 时，ipv6_policy 必须为 1，否则服务可能无法监听"
  fi
}

# ==================================================
# [1/12] 安装构建依赖
# ================================================
install_deps() {
  log "[1/12] 安装构建依赖"

  export DEBIAN_FRONTEND=noninteractive

  apt-get update
  apt-get install -y \
    curl \
    xz-utils \
    ca-certificates \
    qemu-utils \
    libguestfs-tools \
    file \
    coreutils \
    findutils \
    tar \
    gzip

  # libguestfs 在 GitHub Runner 上需要可读的内核镜像
  chmod 0644 /boot/vmlinuz-* || true
}

# ================================
# [2/12] 下载 Debian 12 Cloud-Init qcow2 镜像
# ==================================================
download_cloud_image() {
  log "[2/12] 下载 Debian 12 Cloud-Init qcow2 镜像"

  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR" "$DIST_DIR" "$PAYLOAD_DIR" "$OFFLINE_DIR"

  curl -L --fail --retry 5 --retry-delay 5 \
    -o "$BASE_IMG" \
    "$DEBIAN_CLOUD_URL"

  log "基础镜像大小：$(du -h "$BASE_IMG" | awk '{print $1}')"
}

# ================================
# [3/12] 扩容 qcow2 镜像
# ==================================
resize_image() {
  log "[3/12] 扩容 qcow2 镜像"
  log "规范化后的磁盘大小：${DISK_SIZE}"

  ROOT_PART="$(virt-filesystems -a "$BASE_IMG" --partitions --long --human-readable \
    | awk 'NR>1 {print $1}' | head -n1)"

  if [ -z "$ROOT_PART" ]; then
    die "无法检测 Debian cloud 镜像的根分区"
  fi

  log "检测到根分区：${ROOT_PART}"

  qemu-img create -f qcow2 "$WORK_IMG" "$DISK_SIZE"
  virt-resize --expand "$ROOT_PART" "$BASE_IMG" "$WORK_IMG"

  rm -f "$BASE_IMG"
}

# ================================
# [4/12] 准备 Node.js + OpenClaw 离线包
# ==================================
prepare_offline_openclaw() {
  log "[4/12] 准备 Node.js + OpenClaw 离线包"

  NODE_TMP="${WORK_DIR}/node-tmp"
  NODE_TAR_DIR="${WORK_DIR}/node-official"
  RUNTIME_ROOT="${OFLINE_DIR}/opt/openclaw-runtime"
  NODE_ROT="${OFFLINE_DIR}/opt/node"

  mkdir -p "$NODE_TMP" "$NODE_TAR_DIR" "$RUNTIME_ROT" "$NODE_ROOT"
  mkdir -p "$OFFLINE_DIR/usr/bin"
  mkdir -p "$OFFLINE_DIR/usr/local/bin"
  mkdir -p "$OFFLINE_DIR/etc/openclaw"
  mkdir -p "$OFLINE_DIR/var/lib/openclaw"
  mkdir -p "$OFFLINE_DIR/home/openclaw/.openclaw"

  log "获取 Node.js 24 官方 Linux x64 包名"

  NODE_SHASUMS="$(curl -fsSL https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt)"
  NODE_FILE="$(awk '/linux-x64.tar.xz/ {print $2; exit}' << "$NODE_SHASUMS")"
  NODE_SHA="$(awk -v f="$NODE_FILE" '$2 == f {print $1; exit}' <<< "$NODE_SHASUMS")"

  if [ -z "$NODE_FILE" ] || [ -z "$NODE_SHA" ]; then
    die "无法获取 Node.js 24 linux-x64.tar.xz 文件名或校验值"
  fi

  log "Node.js 文件：$NODE_FILE"

  curl -fsSL "https://nodejs.org/dist/latest-v24.x/${NODE_FILE}" -o "${NODE_TMP}/${NODE_FILE}"

  echo "${NODE_SHA}  ${NODE_TMP}/${NODE_FILE}" | sha256sum -c -

  tar -xJf "${NODE_TMP}/${NODE_FILE}" -C "$NODE_TAR_DIR" --strip-components=1

  cp -a "$NODE_TAR_DIR/." "$NODE_ROOT/"

  log "使用官方 Node.js 安装 pnpm 和 OpenClaw 到离线目录"

  "$NODE_TAR_DIR/bin/npm" config set registry "$NPM_INSTAL_REGISTRY"
  "$NODE_TAR_DIR/bin/npm" config set fund false
  "$NODE_TAR_DIR/bin/npm" config set audit false

  "$NODE_TAR_DIR/bin/npm" install -g \
    --prefix "$RUNTIME_ROOT" \
    pnpm \
    "$OPENCLAW_NPM_SPEC"

  if [ ! -d "$RUNTIME_ROOT/lib/node_modules/openclaw" ]; then
    die "离线目录中没有 OpenClaw node_modules"
  fi

  if [ ! -x "$RUNTIME_ROOT/bin/openclaw" ]; then
    die "离线目录中没有可执行文件：$RUNTIME_ROOT/bin/openclaw"
  fi

  cat > "$OFFLINE_DIR/usr/bin/node" <<'EOF'
#!/usr/bin/env bash
exec /opt/node/bin/node "$@"
EOF

  cat > "$OFFLINE_DIR/usr/bin/npm" <<'EOF'
#!/usr/bin/env bash
exec /opt/node/bin/npm "$@"
EOF

  cat > "$OFFLINE_DIR/usr/bin/npx" <'EOF'
#!/usr/bin/env bash
exec /opt/node/bin/npx "$@"
EOF

  cat > "$OFFLINE_DIR/usr/bin/pnpm" <<'EOF'
#!/usr/bin/env bash
exec /opt/openclaw-runtime/bin/pnpm "$@"
EOF

  cat > "$OFFLINE_DIR/usr/bin/openclaw" <<'EOF'
#!/usr/bin/env bash
exec /opt/openclaw-runtime/bin/openclaw "$@"
EOF

  chmod +x "$OFFLINE_DIR/usr/bin/node" \
    "$OFFLINE_DIR/usr/bin/npm" \
    "$OFFLINE_DIR/usr/bin/npx" \
    "$OFFLINE_DIR/usr/bin/pnpm" \
    "$OFLINE_DIR/usr/bin/openclaw"

  cat > "$OFFLINE_DIR/usr/local/bin/openclaw-offline-fix" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

NPM_FINAL_REGISTRY="__NPM_FINAL_REGISTRY__"

useradd -m -s /bin/bash openclaw || true

mkdir -p /var/lib/openclaw
mkdir -p /home/openclaw/.openclaw
mkdir -p /etc/openclaw

chown -R openclaw:openclaw /var/lib/openclaw
chown -R openclaw:openclaw /home/openclaw

chmod +x /usr/bin/node /usr/bin/npm /usr/bin/npx /usr/bin/pnpm /usr/bin/openclaw || true

npm config set registry "$NPM_FINAL_REGISTRY" || true
pnpm config set registry "$NPM_FINAL_REGISTRY" || true

command -v node
command -v npm
command -v pnpm
command -v openclaw

node -v
npm -v
pnpm -v || true
openclaw --version || true
EOF

  REG_ESC="$(printf '%s' "$NPM_FINAL_REGISTRY" | sed 's/[\/&]/\\&/g')"
  sed -i "s/__NPM_FINAL_REGISTRY__/${REG_ESC}/g" "$OFFLINE_DIR/usr/local/bin/openclaw-offline-fix"

  chmod +x "$OFLINE_DIR/usr/local/bin/openclaw-offline-fix"

  tar -czf "$WORK_DIR/openclaw-offline.tar.gz" -C "$OFFLINE_DIR" .

  log "离线包大小：$(du -h "$WORK_DIR/openclaw-offline.tar.gz" | awk '{print $1}')"
}

# ==================================================
# [5/12] 生成 firstboot / API / IPv6 / systemd 脚本
# ==================================================
write_payload_files() {
  log "[5/12] 生成 firstboot / API / IPv6 / systemd 脚本"

  mkdir -p "$PAYLOAD_DIR/usr/local/bin"
  mkdir -p "$PAYLOAD_DIR/etc/openclaw"
  mkdir -p "$PAYLOAD_DIR/etc/systemd/system"
  mkdir -p "$PAYLOAD_DIR/etc/profile.d"

  cat > "$PAYLOAD_DIR/etc/openclaw/template.conf" <<EOF
PORT_MIN=$(q "$PORT_MIN")
PORT_MAX=$(q "$PORT_MAX")
OPENCLAW_RUN_CMD=$(q "$OPENCLAW_RUN_CMD")
ENABLE_IPV6_DEFAULT=$(q "$IPV6_POLICY")
OPENCLAW_BIND_HOST=$(q "$BIND_HOST")
EOF

  cat > "$PAYLOAD_DIR/usr/local/bin/openclaw-get-addresses" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

PORT="${1:-}"

get_ipv4_list() {
  ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.' || true
}

get_ipv6_list() {
  ip -o -6 addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -v '^fe80' || true
}

echo "网卡 IPv4 访问地址："
found4=0

while read -r ip4; do
  [ -z "$ip4" ] && continue
  found4=1
  if [ -n "$PORT" ]; then
    echo "http://${ip4}:${PORT}"
  else
    echo "$ip4"
  fi
done < <(get_ipv4_list)

if [ "$found4" = "0" ]; then
  echo "未检测到 IPv4 地址"
fi

echo
echo "网卡 IPv6 访问地址："
found6=0

while read -r ip6; do
  [ -z "$ip6" ] && continue
  found6=1
  if [ -n "$PORT" ]; then
    echo "http://[${ip6}]:${PORT}"
  else
    echo "$ip6"
  fi
done < <(get_ipv6_list)

if [ "$found6" = "0" ]; then
  echo "未检测到 IPv6 地址"
fi
EOF

  cat > "$PAYLOAD_DIR/usr/local/bin/openclaw-wait-network" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

for _ in $(seq 1 30); do
  if ip -o -4 addr show scope global | grep -q .; then
    exit 0
  fi

  if ip -o -6 addr show scope global | grep -q .; then
    exit 0
  fi

  sleep 1
done

exit 0
EOF

  cat > "$PAYLOAD_DIR/usr/local/bin/openclaw-ipv6-control" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-status}"

get_main_ifaces() {
  ip -o link show \
    | awk -F': ' '{print $2}' \
    | cut -d'@' -f1 \
    | grep -vE '^(lo|docker|veth|br-|virbr|tun|tap)' \
    || true
}

disable_ipv6() {
  echo "[IPv6] 正在强制关闭 IPv6.."

  cat > /etc/sysctl.d/99-openclaw-disable-ipv6.conf <<'EOT'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.default.autoconf = 0
net.ipv6.conf.all.use_tempaddr = 0
net.ipv6.conf.default.use_tempaddr = 0
EOT

  rm -f /etc/sysctl.d/99-openclaw-enable-ipv6.conf

  sysctl --system >/dev/null 2>&1 || true

  for dev in $(get_main_ifaces); do
    ip -6 addr flush dev "$dev" || true
    ip -6 route flush dev "$dev" || true
    sysctl -w "net.ipv6.conf.${dev}.disable_ipv6=1" >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.${dev}.accept_ra=0" >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.${dev}.autoconf=0" >/dev/null 2>&1 || true
  done

  echo "[IPv6] 已关闭。"
}

enable_ipv6() {
  echo "[IPv6] 正在开启 IPv6..."

  rm -f /etc/sysctl.d/99-openclaw-disable-ipv6.conf

  cat > /etc/sysctl.d/99-openclaw-enable-ipv6.conf <<'EOT'
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.all.accept_ra = 1
net.ipv6.conf.default.accept_ra = 1
net.ipv6.conf.all.autoconf = 1
net.ipv6.conf.default.autoconf = 1
EOT

  sysctl --system >/dev/null 2>&1 || true

  for dev in $(get_main_ifaces); do
    sysctl -w "net.ipv6.conf.${dev}.disable_ipv6=0" >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.${dev}.accept_ra=1" >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.${dev}.autoconf=1" >/dev/null 2>&1 || true
  done

  echo "[IPv6] 已开启。"
}

status_ipv6() {
  echo "IPv6 全局地址："
  ip -6 addr show scope global || true
  echo
  echo "IPv6 路由："
  ip -6 route show || true
}

case "$ACTION" in
  enable) enable_ipv6 ;;
  disable) disable_ipv6 ;;
  status) status_ipv6 ;;
  *)
    echo "用法：openclaw-ipv6-control enable|disable|status"
    exit 1
    ;;
esac
EOF

  cat > "$PAYLOAD_DIR/usr/local/bin/openclaw-firstbot" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

FLAG="/etc/openclaw/firstboot.done"
RUNTIME="/etc/openclaw/runtime.env"
INFO="/root/openclaw-info.txt"

env_quote() {
  printf "%s" "$1" | sed "s/'\\''/g; 1s/^/'/; \$s/\$/'/"
}

source /etc/openclaw/template.conf

if [ -f "$FLAG" ]; then
  exit 0
fi

echo "[OpenClaw] 首次启动初始化..."

openclaw-wait-network || true

ENABLE_IPV6="${ENABLE_IPV6_DEFAULT}"

if [ "$ENABLE_IPV6" = "ask" ]; then
  ENABLE_IPV6="0"
  touch /etc/openclaw/ipv6_need_ask
fi

if [ "$ENABLE_IPV6" = "1" ]; then
  openclaw-ipv6-control enable || true
else
  openclaw-ipv6-control disable || true
fi

PORT="$(shuf -i "${PORT_MIN}-${PORT_MAX}" -n 1)"
ADMIN_PASS="$(od -An -N9 -tx1 /dev/urandom | tr -d ' \n')"

cat > "$RUNTIME" <<EOT
OPENCLAW_PORT=${PORT}
OPENCLAW_ADMIN_PASSWORD=${ADMIN_PASS}
ENABLE_IPV6=${ENABLE_IPV6}
EOT

chown root:openclaw "$RUNTIME"
chmod 640 "$RUNTIME"

cat > /etc/openclaw/openclaw.env <EOT
HOST=$(env_quote "$OPENCLAW_BIND_HOST")
OPENCLAW_HOST=$(env_quote "$OPENCLAW_BIND_HOST")
PORT=${PORT}
OPENCLAW_PORT=${PORT}
OPENCLAW_ADMIN_USER=admin
OPENCLAW_ADMIN_PASSWORD=${ADMIN_PASS}
EOT

chown root:openclaw /etc/openclaw/openclaw.env
chmod 640 /etc/openclaw/openclaw.env

systemctl daemon-reload
systemctl enable openclaw >/dev/null 2>&1 || true

{
  echo "================================================="
  echo " OpenClaw KVM 已初始化"
  echo "=================================================="
  echo
  openclaw-get-addreses "${PORT}"
  echo
  echo "端口：${PORT}"
  echo "用户名：admin"
  echo "密码：${ADMIN_PASS}"
  echo "监听地址：${OPENCLAW_BIND_HOST}"
  echo
  if [ "$ENABLE_IPV6" = "1" ]; then
    echo "IPv6 状态：已开启"
  else
    echo "IPv6 状态：已关闭"
  fi
  echo "下一步：执行 openclaw-set-api 配置模型 API"
  echo "查看服务：systemctl status openclaw --no-pager -l"
  echo
  echo "=================================================="
} > "$INFO"

chmod 600 "$INFO"
touch "$FLAG"
cat "$INFO"
EOF

  cat > "$PAYLOAD_DIR/usr/local/bin/openclaw-set-api" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONF="/etc/openclaw/openclaw.env"
RUNTIME="/etc/openclaw/runtime.env"
INFO="/root/openclaw-info.txt"

env_quote() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g; 1s/^/'/; \$s/\$/'/"
}

if [ ! -f "$RUNTIME" ]; then
  echo "运行时配置不存在，请先执行：openclaw-firstbot"
  exit 1
fi

source /etc/openclaw/template.conf
source "$RUNTIME"

echo "================================================="
echo " OpenClaw 自定义 API 配置"
echo "=================================================="
echo

read -rp "API base_url，例如 https://api.openai.com/v1 或 https://api.deepseek.com/v1: " BASE_URL
BASE_URL="${BASE_URL:-https://api.openai.com/v1}"

read -rp "默认模型，例如 gpt-4.1 / deepseek-chat / deepseek-v4-flash: " MODEL
MODEL="${MODEL:-gpt-4.1}"

read -rsp "请输入 API Key: " API_KEY
echo

if [ -z "$API_KEY" ]; then
  echo "API Key 不能为空"
  exit 1
fi

cat > "$CONF" <<EOT
HOST=$(env_quote "$OPENCLAW_BIND_HOST")
OPENCLAW_HOST=$(env_quote "$OPENCLAW_BIND_HOST")
PORT=$(env_quote "$OPENCLAW_PORT")
OPENCLAW_PORT=$(env_quote "$OPENCLAW_PORT")
OPENCLAW_ADMIN_USER=admin
OPENCLAW_ADMIN_PASSWORD=$(env_quote "$OPENCLAW_ADMIN_PASSWORD")

OPENAI_BASE_URL=$(env_quote "$BASE_URL")
OPENAI_API_KEY=$(env_quote "$API_KEY")
OPENAI_MODEL=$(env_quote "$MODEL")

ANTHROPIC_BASE_URL=$(env_quote "$BASE_URL")
ANTHROPIC_API_KEY=$(env_quote "$API_KEY")

DEEPSEK_BASE_URL=$(env_quote "$BASE_URL")
DEEPSEK_API_KEY=$(env_quote "$API_KEY")
DEEPSEEK_MODEL=$(env_quote "$MODEL")
EOT

chown root:openclaw "$CONF"
chmod 640 "$CONF"

touch /etc/openclaw/api_configured

systemctl restart openclaw || true

{
  echo
  echo "================================="
  echo " OpenClaw KVM 信息"
  echo "=================================================="
  echo
  openclaw-get-addreses "${OPENCLAW_PORT}"
  echo
  echo "端口：${OPENCLAW_PORT}"
  echo "用户名：admin"
  echo "密码：${OPENCLAW_ADMIN_PASSWORD}"
  echo "监听地址：${OPENCLAW_BIND_HOST}"
  echo
  echo "模型接口：${BASE_URL}"
  echo "默认模型：${MODEL}"
  echo
  echo "重新配置 API：openclaw-set-api"
  echo "查看服务：systemctl status openclaw --no-pager -l"
  echo
  echo "=================================================="
} > "$INFO"

chmod 600 "$INFO"
cat "$INFO"
EOF

  cat > "$PAYLOAD_DIR/usr/local/bin/openclaw-ipv6-ask" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ASK_FLAG="/etc/openclaw/ipv6_need_ask"
RUNTIME="/etc/openclaw/runtime.env"

if [ ! -f "$ASK_FLAG" ]; then
  exit 0
fi

echo
echo "================================="
echo " IPv6 配置"
echo "=================================================="
echo "1) 关闭 IPv6，推荐国内 NAT / 路由器频繁下发 IPv6 的环境"
echo "2) 开启 IPv6"
echo
read -rp "请选择 [1]: " ip6_choice
ip6_choice="${ip6_choice:-1}"

if [ "$ip6_choice" = "2" ]; then
  openclaw-ipv6-control enable || true
  NEW_IPV6="1"
else
  openclaw-ipv6-control disable || true
  NEW_IPV6="0"
fi

if [ -f "$RUNTIME" ]; then
  sed -i '/^ENABLE_IPV6=/d' "$RUNTIME"
  echo "ENABLE_IPV6=${NEW_IPV6}" >> "$RUNTIME"
  chown root:openclaw "$RUNTIME" || true
  chmod 640 "$RUNTIME" || true
fi

rm -f "$ASK_FLAG"
EOF

  cat > "$PAYLOAD_DIR/usr/local/bin/openclaw-launcher" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

source /etc/openclaw/template.conf
source /etc/openclaw/openclaw.env 2>/dev/null || true

export HOME=/home/openclaw
export HOST="${OPENCLAW_BIND_HOST:-0.0.0.0}"
export OPENCLAW_HOST="${OPENCLAW_BIND_HOST:-0.0.0.0}"
export PORT="${OPENCLAW_PORT:-${PORT:-18789}}"
export OPENCLAW_PORT="${OPENCLAW_PORT:-${PORT:-18789}}"

cd /var/lib/openclaw
exec bash -lc "$OPENCLAW_RUN_CMD"
EOF

  cat > "$PAYLOAD_DIR/etc/systemd/system/openclaw-firstboot.service" <<'EOF'
[Unit]
Description=OpenClaw First Boot Init
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/etc/openclaw/firstboot.done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/openclaw-firstboot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  cat > "$PAYLOAD_DIR/etc/systemd/system/openclaw.service" <<'EOF'
[Unit]
Description=OpenClaw Service
After=network-online.target openclaw-firstboot.service
Wants=network-online.target openclaw-firstboot.service

[Service]
Type=simple
User=openclaw
Group=openclaw
EnvironmentFile=-/etc/openclaw/openclaw.env
WorkingDirectory=/var/lib/openclaw
ExecStartPre=/usr/local/bin/openclaw-firstboot
ExecStart=/usr/local/bin/openclaw-launcher
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  cat > "$PAYLOAD_DIR/etc/profile.d/openclaw-info.sh" <<'EOF'
#!/usr/bin/env bash

case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

if [ "$(id -u)" = "0" ]; then
  echo

  if [ -f /etc/openclaw/ipv6_need_ask ]; then
    openclaw-ipv6-ask
  fi

  if [ -f /root/openclaw-info.txt ]; then
    cat /root/openclaw-info.txt
  else
    echo "OpenClaw 信息文件不存在。"
    echo "如果首次启动没有完成，可以执行：openclaw-firstboot"
  fi

  if [ -f /etc/openclaw/firstboot.done ] && [ ! -f /etc/openclaw/api_configured ]; then
    echo
    echo "检测到还没有配置自定义 API。"
    read -rp "是否现在配置？[Y/n]: " answer
    answer="${answer:-Y}"
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      openclaw-set-api
    fi
  fi
fi
EOF

  chmod +x "$PAYLOAD_DIR/usr/local/bin/"*
  chmod +x "$PAYLOAD_DIR/etc/profile.d/openclaw-info.sh"
}

# ================================
# [6/12] 注入 OpenClaw 离线包到 qcow2
# ================================================
inject_offline_openclaw() {
  log "[6/12] 注入 OpenClaw 离线包到 qcow2"

  virt-copy-in -a "$WORK_IMG" "$WORK_DIR/openclaw-offline.tar.gz" /tmp/

  virt-customize -a "$WORK_IMG" \
    --run-command 'tar -xzf /tmp/openclaw-offline.tar.gz -C / && rm -f /tmp/openclaw-offline.tar.gz'
}

# ==================================
# [7/12] 注入 systemd / firstboot / API / IPv6 脚本
# ==================================
inject_payload() {
  log "[7/12] 注入 systemd / firstboot / API / IPv6 脚本"

  tar -czf "$WORK_DIR/openclaw-payload.tar.gz" -C "$PAYLOAD_DIR" .

  virt-copy-in -a "$WORK_IMG" "$WORK_DIR/openclaw-payload.tar.gz" /tmp/

  virt-customize -a "$WORK_IMG" \
    --run-command 'tar -xzf /tmp/openclaw-payload.tar.gz -C / && rm -f /tmp/openclaw-payload.tar.gz' \
    --run-command 'chmod +x /usr/local/bin/openclaw-* /etc/profile.d/openclaw-info.sh'
}

# ==================================
# [8/12] 离线运行级检查 + 启用服务
# ==================================================
offline_check() {
  log "[8/12] 离线运行级检查"

  virt-customize -a "$WORK_IMG" \
    --run-command 'chmod +x /usr/local/bin/openclaw-offline-fix && /usr/local/bin/openclaw-offline-fix' \
    --run-command 'systemctl enable openclaw-firstboot.service' \
    --run-command 'systemctl enable openclaw.service'
}

# ==================================================
# [9/12] 清理镜像缓存和唯一标识
# ==================================================
cleanup_image() {
  log "[9/12] 清理镜像缓存和唯一标识"

  virt-customize -a "$WORK_IMG" \
    --run-command 'apt-get clean || true' \
    --run-command 'rm -rf /var/lib/apt/lists/* || true' \
    --run-command 'rm -f /etc/ssh/ssh_host_* || true' \
    --run-command 'truncate -s 0 /etc/machine-id || true' \
    --run-command 'rm -f /var/lib/dbus/machine-id || true' \
    --run-command 'cloud-init clean --logs || true' \
    --run-command 'rm -rf /tmp/* /var/tmp/* || true'
}

# ==================================================
# [10/12] 导出并压缩 qcow2
# ==================================================
export_image() {
  log "[10/12] 导出并压缩 qcow2"

  rm -f "$OUT_QCOW2" "$OUT_XZ" "$OUT_SHA" "$OUT_LIST"

  qemu-img convert -O qcow2 -c "$WORK_IMG" "$OUT_QCOW2"

  log "压缩 qcow2 -> xz"
  xz -T0 -9 -e -f "$OUT_QCOW2"
  # xz 默认删除原文件，生成 ${OUT_QCOW2}.xz == $OUT_XZ

  ( cd "$DIST_DIR" && sha256sum "$(basename "$OUT_XZ")" > "$(basename "$OUT_SHA")" )

  log "最终镜像：$(du -h "$OUT_XZ" | awk '{print $1}')"
}

# ================================
# [11/12] 生成镜像文件列表
# ================================
generate_filelist() {
  log "[11/12] 生成镜像文件列表"

  virt-ls -a "$WORK_IMG" -lR /etc/openclaw /usr/local/bin /opt > "$OUT_LIST" 2>/dev/null || true
}

# ==================================================
# [12/12] 写入构建信息
# ================================
write_buildinfo() {
  log "[12/12] 写入构建信息"

  {
    echo "OpenClaw KVM Cloud-Init 镜像"
    echo "================================================="
    echo "版本：${VERSION}"
    echo "构建时间(UTC)：$(date -u +'%Y-%m-%d %H:%M:%S')"
    echo "基础镜像：Debian 12 (bookworm) genericcloud amd64"
    echo "磁盘大小：${DISK_SIZE}"
    echo "OpenClaw 包：${OPENCLAW_NPM_SPEC}"
    echo "启动命令：${OPENCLAW_RUN_CMD}"
    echo "监听地址：${BIND_HOST}"
    echo "IPv6 策略：${IPV6_POLICY}"
    echo "端口范围：${PORT_MIN}-${PORT_MAX}"
    echo "Node.js：${NODE_FILE:-unknown}"
    echo "镜像文件：$(basename "$OUT_XZ")"
    echo "SHA256：$(awk '{print $1}' "$OUT_SHA" 2>/dev/null || echo unknown)"
    echo "=================================================="
    echo
    echo "使用提示："
    echo "1. 解压：xz -d $(basename "$OUT_XZ")"
    echo "2. 导入到 KVM / Proxmox / OpenStack 等平台启动"
    echo "3. 首次以 root 登录控制台即可看到端口、用户名、密码"
    echo "4. 执行 openclaw-set-api 配置模型 API"
  } > "$OUT_INFO"

  cat "$OUT_INFO"
}

# ==================================================
# 主流程
# ================================
main() {
  trap 'on_error $LINENO' ERR

  need_root
  validate_inputs

  install_deps
  download_cloud_image
  resize_image
  prepare_offline_openclaw
  write_payload_files
  inject_offline_openclaw
  inject_payload
  offline_check
  cleanup_image
  export_image
  generate_filelist
  write_buildinfo

  log "构建完成：$OUT_XZ"
  log "产物目录：$DIST_DIR"
  ls -lh "$DIST_DIR"
}

main "$@"
