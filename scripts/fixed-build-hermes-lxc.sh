#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# Hermes Agent Root PVE LXC Builder
# - Two-file version: GitHub Actions YAML calls this script.
# - No Docker
# - No Nginx
# - No extra hermes user
# - Run Hermes as root
# - SSH password login enabled by default
# - Random root SSH password on first boot
# - Random Dashboard port / Basic Auth / API keys
# - Custom model API menu
# - API Server toggles
# - Backup / restore
# - MCP / Profile / Gateway menus
# - IPv6 on/off
# - SHA256 / file list / GitHub Release artifact support
# ==========================================================

export DEBIAN_FRONTEND=noninteractive

DISTRO="${DEBIAN_RELEASE:-${DISTRO:-bookworm}}"
ARCH="${ARCH:-amd64}"
HERMES_REPO="${HERMES_REPO:-https://github.com/NousResearch/hermes-agent.git}"
HERMES_REF="${HERMES_REF:-main}"
TEMPLATE_NAME="${TEMPLATE_NAME:-hermes-lxc}"
VERSION="${VERSION:-$(date -u +'%Y.%m.%d-%H%M')}"
BIND_HOST="${BIND_HOST:-0.0.0.0}"
IPV6_POLICY="${IPV6_POLICY:-ask}"
PORT_MIN="${PORT_MIN:-20000}"
PORT_MAX="${PORT_MAX:-65000}"
BUILD_MIRROR="${BUILD_MIRROR:-http://deb.debian.org/debian}"
CN_APT_MIRROR="${CN_APT_MIRROR:-https://mirrors.aliyun.com/debian}"
CN_SECURITY_MIRROR="${CN_SECURITY_MIRROR:-https://mirrors.aliyun.com/debian-security}"

WORK="${GITHUB_WORKSPACE:-$PWD}/work"
ROOTFS="$WORK/rootfs"
DIST="${GITHUB_WORKSPACE:-$PWD}/dist"

SAFE_VERSION="${VERSION#v}"
IMAGE_NAME="${TEMPLATE_NAME}-debian12-${SAFE_VERSION}.tar.gz"
IMAGE_PATH="$DIST/$IMAGE_NAME"

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "IMAGE_NAME=$IMAGE_NAME"
    echo "SAFE_VERSION=$SAFE_VERSION"
  } >> "$GITHUB_ENV"
fi

log() {
  echo
  echo "=================================================="
  echo "$*"
  echo "=================================================="
}

cleanup_mounts() {
  set +e
  sudo umount -lf "$ROOTFS/proc" 2>/dev/null || true
  sudo umount -lf "$ROOTFS/sys" 2>/dev/null || true
  sudo umount -lf "$ROOTFS/dev/pts" 2>/dev/null || true
  sudo umount -lf "$ROOTFS/dev" 2>/dev/null || true
}
trap cleanup_mounts EXIT

log "[1/10] Install build dependencies"

sudo apt-get update
sudo apt-get install -y \
  debootstrap \
  ca-certificates \
  curl \
  wget \
  git \
  gnupg \
  tar \
  gzip \
  xz-utils \
  zstd \
  rsync \
  openssl \
  jq \
  qemu-user-static \
  binutils \
  coreutils \
  util-linux

log "[2/10] Create Debian rootfs"

sudo rm -rf "$WORK"
mkdir -p "$DIST"
sudo mkdir -p "$ROOTFS"

sudo debootstrap \
  --variant=minbase \
  --arch="$ARCH" \
  "$DISTRO" \
  "$ROOTFS" \
  "$BUILD_MIRROR"

sudo cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

sudo mount -t proc proc "$ROOTFS/proc"
sudo mount --rbind /sys "$ROOTFS/sys"
sudo mount --make-rslave "$ROOTFS/sys"
sudo mount --rbind /dev "$ROOTFS/dev"
sudo mount --make-rslave "$ROOTFS/dev"

log "[3/10] Write installer into rootfs"

sudo tee "$ROOTFS/root/install-hermes-inside.sh" >/dev/null <<'INSIDE'
#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export HOME=/root
export HERMES_HOME=/root/.hermes
export PATH=/opt/hermes-agent/venv/bin:/root/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

HERMES_REF="${HERMES_REF:-main}"
BIND_HOST="${BIND_HOST:-0.0.0.0}"
IPV6_POLICY="${IPV6_POLICY:-ask}"
PORT_MIN="${PORT_MIN:-20000}"
PORT_MAX="${PORT_MAX:-65000}"
CN_APT_MIRROR="${CN_APT_MIRROR:-https://mirrors.aliyun.com/debian}"
CN_SECURITY_MIRROR="${CN_SECURITY_MIRROR:-https://mirrors.aliyun.com/debian-security}"
PUBLISH_RELEASE="${PUBLISH_RELEASE:-true}"

log() {
  echo
  echo "=================================================="
  echo "$*"
  echo "=================================================="
}

log "[inside 1/9] Base packages"

cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

apt-get update
apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  wget \
  gnupg \
  git \
  bash \
  sudo \
  locales \
  tzdata \
  dbus \
  systemd \
  systemd-sysv \
  openssh-server \
  openssl \
  python3 \
  python3.11 \
  python3.11-venv \
  python3-pip \
  python3-dev \
  build-essential \
  pkg-config \
  libffi-dev \
  libssl-dev \
  ripgrep \
  ffmpeg \
  jq \
  nano \
  vim-tiny \
  iproute2 \
  iputils-ping \
  net-tools \
  procps \
  lsof \
  htop \
  less \
  unzip \
  xz-utils \
  tar \
  cron \
  logrotate \
  bash-completion

sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true
sed -i 's/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen || true
locale-gen || true

cat > /etc/default/locale <<'EOF'
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
EOF

ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone

log "[inside 2/9] Enable SSH password login"

mkdir -p /etc/ssh/sshd_config.d

cat > /etc/ssh/sshd_config.d/99-hermes-root-password.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PubkeyAuthentication yes
UsePAM yes
EOF

systemctl enable ssh >/dev/null 2>&1 || true
systemctl enable ssh.service >/dev/null 2>&1 || true

log "[inside 3/9] Install Node.js 22"

curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup.sh
bash /tmp/nodesource_setup.sh
apt-get install -y nodejs

node -v
npm -v

log "[inside 4/9] Clone Hermes Agent"

rm -rf /opt/hermes-agent
git clone --depth 1 https://github.com/NousResearch/hermes-agent.git /opt/hermes-agent
cd /opt/hermes-agent

if [ "$HERMES_REF" != "main" ]; then
  git fetch --depth 1 origin "$HERMES_REF" || true
  git checkout FETCH_HEAD 2>/dev/null || git checkout "$HERMES_REF" 2>/dev/null || true
fi

git rev-parse --short HEAD > /etc/hermes-commit.txt

log "[inside 5/9] Install Hermes Agent as root"

chmod +x ./setup-hermes.sh

# setup-hermes.sh may ask whether to launch setup; answer no.
printf 'n\n' | ./setup-hermes.sh

ln -sf /opt/hermes-agent/venv/bin/hermes /usr/local/bin/hermes
ln -sf /opt/hermes-agent/venv/bin/hermes-agent /usr/local/bin/hermes-agent || true

log "[inside 6/9] Build Web Dashboard"

npm install --workspace web --silent || (cd web && npm install --silent)
npm run build -w web || (cd web && npm run build)

test -f /opt/hermes-agent/hermes_cli/web_dist/index.html

log "[inside 7/9] Write runtime scripts"

mkdir -p /etc/hermes-lxc /root/.hermes /root/hermes-workspace /root/hermes-backups
chmod 700 /root/.hermes

cat > /usr/local/bin/hermes-env-set <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="/root/.hermes/.env"
KEY="${1:?missing key}"
VALUE="${2:-}"

mkdir -p /root/.hermes
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

tmp="$(mktemp)"
grep -v -E "^${KEY}=" "$ENV_FILE" > "$tmp" 2>/dev/null || true
printf '%s=%s\n' "$KEY" "$VALUE" >> "$tmp"
cat "$tmp" > "$ENV_FILE"
rm -f "$tmp"
chmod 600 "$ENV_FILE"
EOF
chmod +x /usr/local/bin/hermes-env-set

cat > /usr/local/bin/hermes-env-del <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="/root/.hermes/.env"
KEY="${1:?missing key}"

[ -f "$ENV_FILE" ] || exit 0
tmp="$(mktemp)"
grep -v -E "^${KEY}=" "$ENV_FILE" > "$tmp" 2>/dev/null || true
cat "$tmp" > "$ENV_FILE"
rm -f "$tmp"
chmod 600 "$ENV_FILE"
EOF
chmod +x /usr/local/bin/hermes-env-del

cat > /usr/local/bin/hermes-start-dashboard <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export HOME=/root
export HERMES_HOME=/root/.hermes
export PATH=/opt/hermes-agent/venv/bin:/root/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

[ -f /etc/hermes-lxc/info.env ] && source /etc/hermes-lxc/info.env
[ -f /root/.hermes/.env ] && set -a && source /root/.hermes/.env && set +a

WEB_PORT="${WEB_PORT:-9119}"
BIND_HOST="${BIND_HOST:-0.0.0.0}"

cd /opt/hermes-agent

# No Nginx. Direct Dashboard exposure with built-in Basic Auth environment variables.
exec hermes dashboard \
  --host "$BIND_HOST" \
  --port "$WEB_PORT" \
  --no-open \
  --skip-build
EOF
chmod +x /usr/local/bin/hermes-start-dashboard

cat > /usr/local/bin/hermes-firstboot <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p /etc/hermes-lxc /root/.hermes /root/hermes-workspace /root/hermes-backups
chmod 700 /root/.hermes

INFO="/etc/hermes-lxc/info.env"
DONE="/etc/hermes-lxc/firstboot.done"
ENV_FILE="/root/.hermes/.env"

rand_port() {
  local min="${PORT_MIN:-20000}"
  local max="${PORT_MAX:-65000}"
  shuf -i "${min}-${max}" -n 1
}

rand_alnum() {
  openssl rand -base64 80 | tr -dc 'A-Za-z0-9' | head -c "${1:-24}"
}

rand_secret() {
  openssl rand -base64 64 | tr -d '\n'
}

[ -f "$INFO" ] && source "$INFO"

RESET_MODE="false"
[ "${1:-}" = "--reset-web" ] && RESET_MODE="true"

if [ "$RESET_MODE" = "true" ] || [ ! -f "$DONE" ]; then
  if [ "$RESET_MODE" = "true" ]; then
    WEB_PORT="${HERMES_WEB_PORT:-$(rand_port)}"
    WEB_USER="${HERMES_WEB_USER:-admin}"
    WEB_PASS="${HERMES_WEB_PASS:-$(rand_alnum 24)}"
    ROOT_PASS="${HERMES_ROOT_PASS:-$(rand_alnum 24)}"
    DASHBOARD_SECRET="$(rand_secret)"
    API_KEY="$(openssl rand -hex 32)"
  else
    WEB_PORT="${HERMES_WEB_PORT:-${WEB_PORT:-$(rand_port)}}"
    WEB_USER="${HERMES_WEB_USER:-${WEB_USER:-admin}}"
    WEB_PASS="${HERMES_WEB_PASS:-${WEB_PASS:-$(rand_alnum 24)}}"
    ROOT_PASS="${HERMES_ROOT_PASS:-${ROOT_PASS:-$(rand_alnum 24)}}"
    DASHBOARD_SECRET="${DASHBOARD_SECRET:-$(rand_secret)}"
    API_KEY="${API_KEY:-$(openssl rand -hex 32)}"
  fi

  cat > "$INFO" <<INFO
WEB_PORT="$WEB_PORT"
WEB_USER="$WEB_USER"
WEB_PASS="$WEB_PASS"
ROOT_PASS="$ROOT_PASS"
DASHBOARD_SECRET="$DASHBOARD_SECRET"
API_KEY="$API_KEY"
BIND_HOST="${BIND_HOST:-0.0.0.0}"
PORT_MIN="${PORT_MIN:-20000}"
PORT_MAX="${PORT_MAX:-65000}"
IPV6_POLICY="${IPV6_POLICY:-ask}"
INFO
  chmod 600 "$INFO"
fi

touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

# Set root password and generate SSH host keys on first boot.
if [ -n "${ROOT_PASS:-}" ]; then
  echo "root:${ROOT_PASS}" | chpasswd
fi
ssh-keygen -A >/dev/null 2>&1 || true

# Set Dashboard Basic Auth and API keys.
for key in \
  HERMES_DASHBOARD_BASIC_AUTH_USERNAME \
  HERMES_DASHBOARD_BASIC_AUTH_PASSWORD \
  HERMES_DASHBOARD_BASIC_AUTH_SECRET \
  HERMES_API_KEY \
  API_SERVER_KEY
do
  /usr/local/bin/hermes-env-del "$key" || true
done

/usr/local/bin/hermes-env-set HERMES_DASHBOARD_BASIC_AUTH_USERNAME "${WEB_USER:-admin}"
/usr/local/bin/hermes-env-set HERMES_DASHBOARD_BASIC_AUTH_PASSWORD "${WEB_PASS:-}"
/usr/local/bin/hermes-env-set HERMES_DASHBOARD_BASIC_AUTH_SECRET "${DASHBOARD_SECRET:-}"
/usr/local/bin/hermes-env-set HERMES_API_KEY "${API_KEY:-}"
/usr/local/bin/hermes-env-set API_SERVER_KEY "${API_KEY:-}"
/usr/local/bin/hermes-env-set API_SERVER_ENABLED "false"

if [ ! -f /root/.hermes/config.yaml ]; then
  cat > /root/.hermes/config.yaml <<'CFG'
terminal:
  backend: "local"
  cwd: "/root/hermes-workspace"
  timeout: 180
  lifetime_seconds: 300

browser:
  inactivity_timeout: 120

compression:
  enabled: true
  threshold: 0.50
  target_ratio: 0.20
CFG
fi

if [ ! -f "$DONE" ]; then
  case "${IPV6_POLICY:-ask}" in
    0|off|disable|disabled|false)
      /usr/local/bin/hermes-ipv6-off || true
      ;;
    ask)
      touch /etc/hermes-lxc/ask-ipv6-on-login
      ;;
    *)
      rm -f /etc/hermes-lxc/ask-ipv6-on-login
      ;;
  esac
fi

cat > /root/HERMES-INFO.txt <<TXT
Hermes Agent Root LXC

SSH:
  user: root
  password: ${ROOT_PASS:-unknown}

Web Dashboard:
  port: ${WEB_PORT:-unknown}
  username: ${WEB_USER:-admin}
  password: ${WEB_PASS:-unknown}

API:
  API_SERVER_KEY / HERMES_API_KEY: ${API_KEY:-unknown}

Commands:
  hermes-info
  hermes-menu
  hermes-set-model
  hermes-api-info
  hermes-health
TXT
chmod 600 /root/HERMES-INFO.txt

cat > /etc/issue <<TXT
Hermes Agent Root LXC

SSH/root password: ${ROOT_PASS:-unknown}
Web username: ${WEB_USER:-admin}
Web password: ${WEB_PASS:-unknown}
Run after login: hermes-info

TXT

cat > /etc/motd <<'TXT'
Hermes Agent LXC is installed.
Run: hermes-info
Run: hermes-menu
TXT

systemctl enable ssh >/dev/null 2>&1 || true
systemctl enable ssh.service >/dev/null 2>&1 || true
systemctl restart ssh >/dev/null 2>&1 || systemctl restart ssh.service >/dev/null 2>&1 || true

systemctl enable hermes-dashboard.service >/dev/null 2>&1 || true
systemctl restart hermes-dashboard.service || true

touch "$DONE"
EOF
chmod +x /usr/local/bin/hermes-firstboot

cat > /usr/local/bin/hermes-info <<'EOF'
#!/usr/bin/env bash
set -e

[ -f /etc/hermes-lxc/info.env ] && source /etc/hermes-lxc/info.env

IPV4="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -n1 || true)"
IPV6="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep ':' | head -n1 || true)"

echo
echo "=================================================="
echo "Hermes Agent Root LXC"
echo "=================================================="
echo "运行用户       : root"
echo "Nginx          : 不安装 / 不使用"
echo "SSH 用户       : root"
echo "SSH 密码       : ${ROOT_PASS:-未初始化}"
echo "Web 端口       : ${WEB_PORT:-未初始化}"
echo "Web 用户名     : ${WEB_USER:-admin}"
echo "Web 密码       : ${WEB_PASS:-未初始化}"
echo "API Key        : ${API_KEY:-未初始化}"
echo

[ -n "${IPV4:-}" ] && [ -n "${WEB_PORT:-}" ] && echo "IPv4 访问      : http://${IPV4}:${WEB_PORT}"
[ -n "${IPV6:-}" ] && [ -n "${WEB_PORT:-}" ] && echo "IPv6 访问      : http://[${IPV6}]:${WEB_PORT}"

echo
echo "Hermes 目录    : /opt/hermes-agent"
echo "配置目录       : /root/.hermes"
echo "工作目录       : /root/hermes-workspace"
echo "信息文件       : /root/HERMES-INFO.txt"
echo "=================================================="
echo "常用命令:"
echo "  hermes-menu"
echo "  hermes-set-model"
echo "  hermes-api-on / hermes-api-off / hermes-api-info"
echo "  hermes-health"
echo "  hermes-backup / hermes-restore"
echo "  hermes-ipv6-off / hermes-ipv6-on"
echo "=================================================="
echo
EOF
chmod +x /usr/local/bin/hermes-info

cat > /usr/local/bin/hermes-set-model <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p /root/.hermes /root/hermes-workspace
touch /root/.hermes/.env
chmod 600 /root/.hermes/.env

echo
echo "=================================================="
echo "Hermes 模型 API 配置"
echo "=================================================="
echo "1. DeepSeek"
echo "2. OpenAI"
echo "3. OpenRouter"
echo "4. 本地 OpenAI-compatible"
echo "5. 自定义"
echo "=================================================="
read -rp "请选择 [1]: " choice
choice="${choice:-1}"

case "$choice" in
  1)
    PROVIDER="custom"
    BASE_URL="https://api.deepseek.com/v1"
    MODEL_NAME="deepseek-chat"
    ;;
  2)
    PROVIDER="openai"
    BASE_URL="https://api.openai.com/v1"
    MODEL_NAME="gpt-4o-mini"
    ;;
  3)
    PROVIDER="openrouter"
    BASE_URL="https://openrouter.ai/api/v1"
    MODEL_NAME="openai/gpt-4o-mini"
    ;;
  4)
    PROVIDER="custom"
    BASE_URL="http://127.0.0.1:11434/v1"
    MODEL_NAME="local-model"
    ;;
  *)
    read -rp "Provider [custom]: " PROVIDER
    PROVIDER="${PROVIDER:-custom}"
    read -rp "Base URL [https://api.deepseek.com/v1]: " BASE_URL
    BASE_URL="${BASE_URL:-https://api.deepseek.com/v1}"
    read -rp "Model [deepseek-chat]: " MODEL_NAME
    MODEL_NAME="${MODEL_NAME:-deepseek-chat}"
    ;;
esac

echo "Provider: $PROVIDER"
read -rp "Base URL [$BASE_URL]: " tmp_base
BASE_URL="${tmp_base:-$BASE_URL}"
read -rp "Model [$MODEL_NAME]: " tmp_model
MODEL_NAME="${tmp_model:-$MODEL_NAME}"

read -rsp "API Key: " API_KEY
echo
[ -z "$API_KEY" ] && echo "API Key 不能为空" && exit 1

export HERMES_PROVIDER="$PROVIDER"
export HERMES_BASE_URL="$BASE_URL"
export HERMES_MODEL_NAME="$MODEL_NAME"
export HERMES_MODEL_API_KEY="$API_KEY"

python3 - <<'PY'
from pathlib import Path
import json
import os

provider = os.environ["HERMES_PROVIDER"]
base_url = os.environ["HERMES_BASE_URL"]
model = os.environ["HERMES_MODEL_NAME"]
api_key = os.environ["HERMES_MODEL_API_KEY"]

home = Path('/root/.hermes')
home.mkdir(parents=True, exist_ok=True)

(home / 'config.yaml').write_text(f'''model:
  default: {json.dumps(model)}
  provider: {json.dumps(provider)}
  base_url: {json.dumps(base_url)}
  api_key: {json.dumps(api_key)}

terminal:
  backend: "local"
  cwd: "/root/hermes-workspace"
  timeout: 180
  lifetime_seconds: 300

browser:
  inactivity_timeout: 120

compression:
  enabled: true
  threshold: 0.50
  target_ratio: 0.20
''', encoding='utf-8')
PY

/usr/local/bin/hermes-env-set OPENAI_API_KEY "$API_KEY"
/usr/local/bin/hermes-env-set OPENAI_BASE_URL "$BASE_URL"
/usr/local/bin/hermes-env-set HERMES_API_KEY "$API_KEY"

if [ "$PROVIDER" = "openrouter" ]; then
  /usr/local/bin/hermes-env-set OPENROUTER_API_KEY "$API_KEY"
fi

chmod 600 /root/.hermes/.env
systemctl restart hermes-dashboard.service || true

echo
echo "模型配置完成："
echo "Provider : $PROVIDER"
echo "Base URL : $BASE_URL"
echo "Model    : $MODEL_NAME"
echo
EOF
chmod +x /usr/local/bin/hermes-set-model

cat > /usr/local/bin/hermes-api-on <<'EOF'
#!/usr/bin/env bash
set -e

[ -f /etc/hermes-lxc/info.env ] && source /etc/hermes-lxc/info.env

/usr/local/bin/hermes-env-set API_SERVER_ENABLED "true"
/usr/local/bin/hermes-env-set API_SERVER_HOST "0.0.0.0"
/usr/local/bin/hermes-env-set API_SERVER_PORT "8642"
/usr/local/bin/hermes-env-set API_SERVER_KEY "${API_KEY:-$(openssl rand -hex 32)}"

systemctl restart hermes-dashboard.service || true

echo "API Server 已启用配置。"
echo "如 Hermes 版本需要 Gateway 才启动 API，请运行：hermes-gateway-menu"
hermes-api-info
EOF
chmod +x /usr/local/bin/hermes-api-on

cat > /usr/local/bin/hermes-api-off <<'EOF'
#!/usr/bin/env bash
set -e
/usr/local/bin/hermes-env-set API_SERVER_ENABLED "false"
systemctl restart hermes-dashboard.service || true
echo "API Server 已关闭配置。"
EOF
chmod +x /usr/local/bin/hermes-api-off

cat > /usr/local/bin/hermes-api-info <<'EOF'
#!/usr/bin/env bash
set -e

[ -f /etc/hermes-lxc/info.env ] && source /etc/hermes-lxc/info.env
[ -f /root/.hermes/.env ] && set -a && source /root/.hermes/.env && set +a

IPV4="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -n1 || true)"
API_PORT="${API_SERVER_PORT:-8642}"

echo
echo "=================================================="
echo "Hermes API Server"
echo "=================================================="
echo "Enabled : ${API_SERVER_ENABLED:-false}"
echo "Port    : ${API_PORT}"
echo "Key     : ${API_SERVER_KEY:-${API_KEY:-未初始化}}"
[ -n "$IPV4" ] && echo "BaseURL : http://${IPV4}:${API_PORT}/v1"
echo "Model   : hermes-agent"
echo "=================================================="
echo
EOF
chmod +x /usr/local/bin/hermes-api-info

cat > /usr/local/bin/hermes-health <<'EOF'
#!/usr/bin/env bash
set +e

echo
echo "=================================================="
echo "Hermes 健康检查"
echo "=================================================="

ok() { echo "[OK] $*"; }
bad() { echo "[FAIL] $*"; }

[ -x /opt/hermes-agent/venv/bin/hermes ] && ok "Hermes binary exists" || bad "Hermes binary missing"
[ -L /usr/local/bin/hermes ] && ok "/usr/local/bin/hermes link exists" || bad "/usr/local/bin/hermes link missing"
[ -f /opt/hermes-agent/hermes_cli/web_dist/index.html ] && ok "Web Dashboard dist exists" || bad "Web Dashboard dist missing"
[ -f /root/.hermes/.env ] && ok ".env exists" || bad ".env missing"
[ -f /root/.hermes/config.yaml ] && ok "config.yaml exists" || bad "config.yaml missing"

systemctl is-active --quiet ssh && ok "SSH active" || bad "SSH inactive"
systemctl is-active --quiet hermes-dashboard.service && ok "Dashboard active" || bad "Dashboard inactive"

ss -tulnp | grep -q ':22 ' && ok "SSH port listening" || bad "SSH port not listening"
[ -f /etc/hermes-lxc/info.env ] && source /etc/hermes-lxc/info.env
[ -n "${WEB_PORT:-}" ] && ss -tulnp | grep -q ":${WEB_PORT} " && ok "Dashboard port listening: ${WEB_PORT}" || bad "Dashboard port not listening"

command -v node >/dev/null && ok "Node: $(node -v)" || bad "Node missing"
command -v npm >/dev/null && ok "npm: $(npm -v)" || bad "npm missing"
command -v python3 >/dev/null && ok "Python: $(python3 --version 2>&1)" || bad "Python missing"

df -h /
free -h
echo
echo "Hermes version:"
hermes version 2>/dev/null || hermes --version 2>/dev/null || true

echo "=================================================="
EOF
chmod +x /usr/local/bin/hermes-health

cat > /usr/local/bin/hermes-logs <<'EOF'
#!/usr/bin/env bash
journalctl -u hermes-dashboard.service -u hermes-firstboot.service -u ssh.service -n 300 --no-pager
EOF
chmod +x /usr/local/bin/hermes-logs

cat > /usr/local/bin/hermes-status <<'EOF'
#!/usr/bin/env bash
set +e

systemctl --no-pager --full status hermes-firstboot.service | sed -n '1,14p'
echo
systemctl --no-pager --full status hermes-dashboard.service | sed -n '1,24p'
echo
systemctl --no-pager --full status ssh.service | sed -n '1,16p'
echo
ss -tulnp | grep -E '(:22|hermes|python|node)' || true
echo
hermes-info
EOF
chmod +x /usr/local/bin/hermes-status

cat > /usr/local/bin/hermes-reset-web <<'EOF'
#!/usr/bin/env bash
set -e
unset HERMES_WEB_PORT
unset HERMES_WEB_USER
unset HERMES_WEB_PASS
/usr/local/bin/hermes-firstboot --reset-web
hermes-info
EOF
chmod +x /usr/local/bin/hermes-reset-web

cat > /usr/local/bin/hermes-ipv6-off <<'EOF'
#!/usr/bin/env bash
set -e

cat > /etc/sysctl.d/99-disable-ipv6.conf <<'SYSCTL'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSCTL

sysctl --system >/dev/null 2>&1 || true

for f in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
  echo 1 > "$f" 2>/dev/null || true
done

echo "IPv6 关闭命令已执行。非特权 LXC 可能需要在 PVE 宿主机侧关闭。"
EOF
chmod +x /usr/local/bin/hermes-ipv6-off

cat > /usr/local/bin/hermes-ipv6-on <<'EOF'
#!/usr/bin/env bash
set -e

rm -f /etc/sysctl.d/99-disable-ipv6.conf

for f in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
  echo 0 > "$f" 2>/dev/null || true
done

sysctl --system >/dev/null 2>&1 || true
echo "IPv6 开启命令已执行。"
EOF
chmod +x /usr/local/bin/hermes-ipv6-on

cat > /usr/local/bin/hermes-backup <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p /root/hermes-backups
OUT="/root/hermes-backups/hermes-backup-$(date +'%Y%m%d-%H%M%S').tar.gz"

tar -czf "$OUT" \
  /root/.hermes \
  /root/hermes-workspace \
  /etc/hermes-lxc \
  /etc/systemd/system/hermes-*.service \
  /usr/local/bin/hermes-* \
  2>/dev/null || true

chmod 600 "$OUT"
echo "备份完成: $OUT"
EOF
chmod +x /usr/local/bin/hermes-backup

cat > /usr/local/bin/hermes-restore <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

echo "可用备份："
ls -1 /root/hermes-backups/*.tar.gz 2>/dev/null || {
  echo "没有找到备份。"
  exit 1
}

read -rp "请输入备份文件完整路径: " BACKUP
[ -f "$BACKUP" ] || {
  echo "文件不存在: $BACKUP"
  exit 1
}

tar -xzf "$BACKUP" -C / 2>/dev/null || true
systemctl daemon-reload || true
systemctl restart hermes-dashboard.service || true
echo "恢复完成。"
EOF
chmod +x /usr/local/bin/hermes-restore

cat > /usr/local/bin/hermes-profile-menu <<'EOF'
#!/usr/bin/env bash
set -e
export HOME=/root
export HERMES_HOME=/root/.hermes
export PATH=/opt/hermes-agent/venv/bin:/root/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

while true; do
  clear
  echo "========== Hermes Profile 管理 =========="
  echo "1. 查看 profile 帮助"
  echo "2. 查看 profile 列表"
  echo "3. 创建 / 切换 profile"
  echo "0. 返回"
  read -rp "请选择: " n
  case "$n" in
    1) hermes profile --help || true; read -rp "回车继续..." _ ;;
    2) hermes profile list || hermes profile --list || true; read -rp "回车继续..." _ ;;
    3) read -rp "Profile 名称: " p; hermes profile "$p" || hermes profile switch "$p" || true; read -rp "回车继续..." _ ;;
    0) exit 0 ;;
    *) echo "无效"; sleep 1 ;;
  esac
done
EOF
chmod +x /usr/local/bin/hermes-profile-menu

cat > /usr/local/bin/hermes-mcp-menu <<'EOF'
#!/usr/bin/env bash
set -e
export HOME=/root
export HERMES_HOME=/root/.hermes
export PATH=/opt/hermes-agent/venv/bin:/root/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

while true; do
  clear
  echo "========== Hermes MCP 管理 =========="
  echo "1. 查看 MCP 帮助"
  echo "2. 查看 MCP 列表"
  echo "3. 打开配置文件"
  echo "0. 返回"
  read -rp "请选择: " n
  case "$n" in
    1) hermes mcp --help || true; read -rp "回车继续..." _ ;;
    2) hermes mcp list || true; read -rp "回车继续..." _ ;;
    3) nano /root/.hermes/config.yaml; read -rp "回车继续..." _ ;;
    0) exit 0 ;;
    *) echo "无效"; sleep 1 ;;
  esac
done
EOF
chmod +x /usr/local/bin/hermes-mcp-menu

cat > /usr/local/bin/hermes-gateway-menu <<'EOF'
#!/usr/bin/env bash
set -e
export HOME=/root
export HERMES_HOME=/root/.hermes
export PATH=/opt/hermes-agent/venv/bin:/root/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

while true; do
  clear
  echo "========== Hermes Gateway 管理 =========="
  echo "1. 查看 gateway 帮助"
  echo "2. 安装 system gateway"
  echo "3. 启动 gateway"
  echo "4. 停止 gateway"
  echo "5. 查看 gateway 状态"
  echo "6. 查看 gateway 日志"
  echo "0. 返回"
  read -rp "请选择: " n
  case "$n" in
    1) hermes gateway --help || true; read -rp "回车继续..." _ ;;
    2) hermes gateway install --system || true; read -rp "回车继续..." _ ;;
    3) hermes gateway start --system || hermes gateway start || true; read -rp "回车继续..." _ ;;
    4) hermes gateway stop --system || hermes gateway stop || true; read -rp "回车继续..." _ ;;
    5) hermes gateway status --system || hermes gateway status || true; read -rp "回车继续..." _ ;;
    6) journalctl -u hermes-gateway -u hermes-agent-gateway -n 200 --no-pager || true; read -rp "回车继续..." _ ;;
    0) exit 0 ;;
    *) echo "无效"; sleep 1 ;;
  esac
done
EOF
chmod +x /usr/local/bin/hermes-gateway-menu

cat > /usr/local/bin/hermes-menu <<'EOF'
#!/usr/bin/env bash
set -e

while true; do
  clear
  echo "========== Hermes Agent Root LXC =========="
  echo "1. 查看访问信息"
  echo "2. 查看服务状态"
  echo "3. 配置模型 API"
  echo "4. 重置 Web 端口 / 认证 / SSH 密码"
  echo "5. 重启 Dashboard"
  echo "6. 查看日志"
  echo "7. 开启 API Server"
  echo "8. 关闭 API Server"
  echo "9. 显示 API Server 信息"
  echo "10. 健康检查"
  echo "11. 备份配置"
  echo "12. 恢复配置"
  echo "13. 关闭 IPv6"
  echo "14. 开启 IPv6"
  echo "15. Profile 管理"
  echo "16. MCP 管理"
  echo "17. Gateway 管理"
  echo "18. 进入 /opt/hermes-agent"
  echo "0. 退出"
  read -rp "请选择: " n

  case "$n" in
    1) hermes-info; read -rp "回车继续..." _ ;;
    2) hermes-status; read -rp "回车继续..." _ ;;
    3) hermes-set-model; read -rp "回车继续..." _ ;;
    4) hermes-reset-web; read -rp "回车继续..." _ ;;
    5) systemctl restart hermes-dashboard.service; echo OK; read -rp "回车继续..." _ ;;
    6) hermes-logs; read -rp "回车继续..." _ ;;
    7) hermes-api-on; read -rp "回车继续..." _ ;;
    8) hermes-api-off; read -rp "回车继续..." _ ;;
    9) hermes-api-info; read -rp "回车继续..." _ ;;
    10) hermes-health; read -rp "回车继续..." _ ;;
    11) hermes-backup; read -rp "回车继续..." _ ;;
    12) hermes-restore; read -rp "回车继续..." _ ;;
    13) hermes-ipv6-off; read -rp "回车继续..." _ ;;
    14) hermes-ipv6-on; read -rp "回车继续..." _ ;;
    15) hermes-profile-menu ;;
    16) hermes-mcp-menu ;;
    17) hermes-gateway-menu ;;
    18) cd /opt/hermes-agent && bash ;;
    0) exit 0 ;;
    *) echo "无效"; sleep 1 ;;
  esac
done
EOF
chmod +x /usr/local/bin/hermes-menu

cat > /etc/profile.d/hermes-info.sh <<'EOF'
#!/usr/bin/env bash
[ -t 1 ] && echo "Hermes 已安装。输入 hermes-info 查看地址，输入 hermes-menu 管理。"
EOF
chmod +x /etc/profile.d/hermes-info.sh

cat > /etc/profile.d/hermes-ipv6-ask.sh <<'EOF'
#!/usr/bin/env bash
if [ -t 0 ] && [ -f /etc/hermes-lxc/ask-ipv6-on-login ] && [ "$(id -u)" = "0" ]; then
  echo
  echo "IPv6 策略为 ask："
  read -rp "是否关闭 IPv6？输入 y 关闭，其他跳过: " ans
  case "$ans" in
    y|Y|yes|YES) /usr/local/bin/hermes-ipv6-off || true ;;
    *) echo "保持当前 IPv6 状态。" ;;
  esac
  rm -f /etc/hermes-lxc/ask-ipv6-on-login
fi
EOF
chmod +x /etc/profile.d/hermes-ipv6-ask.sh

log "[inside 8/9] systemd services"

cat > /etc/systemd/system/hermes-firstboot.service <<'EOF'
[Unit]
Description=Hermes Agent First Boot Root LXC
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target hermes-dashboard.service ssh.service

[Service]
Type=oneshot
Environment=IPV6_POLICY=ask
Environment=BIND_HOST=0.0.0.0
Environment=PORT_MIN=20000
Environment=PORT_MAX=65000
ExecStart=/usr/local/bin/hermes-firstboot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sed -i "s/Environment=IPV6_POLICY=ask/Environment=IPV6_POLICY=${IPV6_POLICY}/" /etc/systemd/system/hermes-firstboot.service
sed -i "s/Environment=BIND_HOST=0.0.0.0/Environment=BIND_HOST=${BIND_HOST}/" /etc/systemd/system/hermes-firstboot.service
sed -i "s/Environment=PORT_MIN=20000/Environment=PORT_MIN=${PORT_MIN}/" /etc/systemd/system/hermes-firstboot.service
sed -i "s/Environment=PORT_MAX=65000/Environment=PORT_MAX=${PORT_MAX}/" /etc/systemd/system/hermes-firstboot.service

cat > /etc/systemd/system/hermes-dashboard.service <<'EOF'
[Unit]
Description=Hermes Agent Dashboard Root LXC
Wants=network-online.target
After=network-online.target hermes-firstboot.service
Requires=hermes-firstboot.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/hermes-agent
Environment=HOME=/root
Environment=HERMES_HOME=/root/.hermes
Environment=PATH=/opt/hermes-agent/venv/bin:/root/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
EnvironmentFile=-/root/.hermes/.env
ExecStart=/usr/local/bin/hermes-start-dashboard
Restart=always
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF

systemctl enable hermes-firstboot.service
systemctl enable hermes-dashboard.service
systemctl enable ssh >/dev/null 2>&1 || true
systemctl enable ssh.service >/dev/null 2>&1 || true

log "[inside 9/9] switch apt source and clean"

cat > /etc/apt/sources.list <<EOF
deb ${CN_APT_MIRROR}/ bookworm main contrib non-free non-free-firmware
deb ${CN_APT_MIRROR}/ bookworm-updates main contrib non-free non-free-firmware
deb ${CN_SECURITY_MIRROR}/ bookworm-security main contrib non-free non-free-firmware
EOF

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id || true
rm -f /var/lib/dbus/machine-id || true
find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true

echo "Hermes root LXC install inside completed."
INSIDE

sudo chmod +x "$ROOTFS/root/install-hermes-inside.sh"

log "[4/10] Run installer in chroot"

sudo chroot "$ROOTFS" /usr/bin/env \
  HERMES_REF="$HERMES_REF" \
  BIND_HOST="$BIND_HOST" \
  IPV6_POLICY="$IPV6_POLICY" \
  PORT_MIN="$PORT_MIN" \
  PORT_MAX="$PORT_MAX" \
  CN_APT_MIRROR="$CN_APT_MIRROR" \
  CN_SECURITY_MIRROR="$CN_SECURITY_MIRROR" \
  DEBIAN_FRONTEND=noninteractive \
  HOME=/root \
  /bin/bash /root/install-hermes-inside.sh

log "[5/10] Self check"

sudo chroot "$ROOTFS" /bin/bash -lc '
set -Eeuo pipefail

test -x /opt/hermes-agent/venv/bin/hermes
test -L /usr/local/bin/hermes
test -f /opt/hermes-agent/hermes_cli/web_dist/index.html
test -f /etc/systemd/system/hermes-firstboot.service
test -f /etc/systemd/system/hermes-dashboard.service
test -f /etc/ssh/sshd_config.d/99-hermes-root-password.conf
test -x /usr/local/bin/hermes-menu
test -x /usr/local/bin/hermes-set-model
test -x /usr/local/bin/hermes-start-dashboard
test -x /usr/local/bin/hermes-api-on
test -x /usr/local/bin/hermes-backup
test -x /usr/local/bin/hermes-health

if [ -e /etc/nginx ]; then
  echo "ERROR: nginx should not exist"
  exit 1
fi

if id hermes >/dev/null 2>&1; then
  echo "ERROR: hermes user should not exist"
  exit 1
fi

/opt/hermes-agent/venv/bin/hermes version || /opt/hermes-agent/venv/bin/hermes --version || true
echo "Self check passed."
'

log "[6/10] Build info"

sudo mkdir -p "$ROOTFS/etc/hermes-lxc"

sudo tee "$ROOTFS/etc/hermes-lxc/build-info.txt" >/dev/null <<EOF
Image: ${IMAGE_NAME}
Build date UTC: $(date -u +'%Y-%m-%d %H:%M:%S')
Debian: 12 bookworm
Arch: ${ARCH}
Hermes repo: ${HERMES_REPO}
Hermes ref: ${HERMES_REF}
GitHub repository: ${GITHUB_REPOSITORY:-unknown}
GitHub run id: ${GITHUB_RUN_ID:-unknown}
Run user: root
Nginx: disabled / not installed
Extra hermes user: disabled / not created
SSH: root password login enabled by default
Dashboard: 0.0.0.0 random port with built-in Basic Auth
Bind host: ${BIND_HOST}
Port range: ${PORT_MIN}-${PORT_MAX}
IPv6 policy: ${IPV6_POLICY}
Removed features: one-key update, firewall menu, platform info
EOF

sudo cp "$ROOTFS/etc/hermes-lxc/build-info.txt" "$DIST/build-info.txt"

log "[7/10] Cleanup mounts"

cleanup_mounts
trap - EXIT

log "[8/10] Package tar.gz"

sudo tar \
  --numeric-owner \
  --xattrs \
  --acls \
  -C "$ROOTFS" \
  -czf "$IMAGE_PATH" \
  .

sudo chown -R "$USER:$USER" "$DIST"

log "[9/10] SHA256 and file list"

tar -tzf "$IMAGE_PATH" > "${IMAGE_PATH}.list"
(
  cd "$DIST"
  sha256sum "$IMAGE_NAME" > "${IMAGE_NAME}.sha256"
)

grep -q './opt/hermes-agent/venv/bin/hermes' "${IMAGE_PATH}.list"
grep -q './usr/local/bin/hermes-menu' "${IMAGE_PATH}.list"
grep -q './usr/local/bin/hermes-set-model' "${IMAGE_PATH}.list"
grep -q './usr/local/bin/hermes-start-dashboard' "${IMAGE_PATH}.list"
grep -q './usr/local/bin/hermes-api-on' "${IMAGE_PATH}.list"
grep -q './usr/local/bin/hermes-backup' "${IMAGE_PATH}.list"
grep -q './usr/local/bin/hermes-health' "${IMAGE_PATH}.list"
grep -q './etc/systemd/system/hermes-dashboard.service' "${IMAGE_PATH}.list"
grep -q './etc/ssh/sshd_config.d/99-hermes-root-password.conf' "${IMAGE_PATH}.list"
grep -q './opt/hermes-agent/hermes_cli/web_dist/index.html' "${IMAGE_PATH}.list"

if grep -q './etc/nginx' "${IMAGE_PATH}.list"; then
  echo "ERROR: nginx should not be included"
  exit 1
fi

if grep -q './home/hermes' "${IMAGE_PATH}.list"; then
  echo "ERROR: /home/hermes should not be included"
  exit 1
fi

log "[10/10] README"

cat > "$DIST/README.md" <<EOF
# Hermes Agent Root PVE LXC Template

## Features

- No Docker
- No Nginx
- No extra hermes user
- Hermes runs as root
- SSH root password login enabled by default
- First boot random root SSH password
- Web Dashboard random port
- Web Dashboard built-in Basic Auth
- Random Dashboard secret
- Random HERMES_API_KEY / API_SERVER_KEY
- Web Chat panel available in Hermes Dashboard
- Custom model API menu
- API Server on/off/info
- Backup / restore
- MCP menu
- Profile menu
- Gateway menu
- IPv6 on/off
- Health check
- SHA256 and image file list

Removed by request:

- One-key update
- Firewall menu
- Platform information menu

## Import to PVE

Upload this file to:

\`\`\`bash
/var/lib/vz/template/cache/${IMAGE_NAME}
\`\`\`

Create LXC:

\`\`\`bash
pct create 101 local:vztmpl/${IMAGE_NAME} \\
  --hostname hermes-agent \\
  --cores 2 \\
  --memory 2048 \\
  --swap 1024 \\
  --rootfs local-lvm:16 \\
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \\
  --unprivileged 1 \\
  --features nesting=1 \\
  --start 1
\`\`\`

## First login

Open PVE console. The root SSH password is written to:

\`\`\`bash
/etc/issue
/root/HERMES-INFO.txt
\`\`\`

After login:

\`\`\`bash
hermes-info
hermes-menu
\`\`\`

## Configure model API

\`\`\`bash
hermes-set-model
\`\`\`

## API Server

\`\`\`bash
hermes-api-on
hermes-api-info
hermes-api-off
\`\`\`

## Backup and restore

\`\`\`bash
hermes-backup
hermes-restore
\`\`\`

## Logs and health check

\`\`\`bash
hermes-status
hermes-logs
hermes-health
\`\`\`

## IPv6

\`\`\`bash
hermes-ipv6-off
hermes-ipv6-on
\`\`\`
EOF

ls -lh "$DIST"
echo
cat "$DIST/${IMAGE_NAME}.sha256"
echo
echo "Build completed: $IMAGE_PATH"
