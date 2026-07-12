#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
OPENCLAW_VERSION="${OPENCLAW_VERSION:-latest}"

echo "配置 Debian 12 软件源"
cat >/etc/apt/sources.list <<'APT_EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
APT_EOF

mkdir -p /etc/apt/sources.list.d
apt-get update

echo "安装系统组件"
CORE_PACKAGES=(
  systemd systemd-sysv libpam-systemd dbus dbus-user-session
  openssh-server openssh-client sudo ifupdown iproute2 iputils-ping net-tools
  procps psmisc lsof htop tmux screen nano vim less bash-completion
  ca-certificates curl wget git rsync unzip zip tar gzip bzip2 xz-utils zstd
  jq file openssl gnupg gpg-agent dirmngr apt-transport-https locales tzdata
  cron logrotate acl attr tree ncdu dnsutils traceroute mtr-tiny tcpdump
  netcat-openbsd socat iptables nftables python3 python3-full python3-venv
  python3-pip pipx build-essential make gcc g++ pkg-config strace sqlite3
  libssl-dev libffi-dev libsqlite3-dev zlib1g-dev
)
apt-get install -y "${CORE_PACKAGES[@]}"

OPTIONAL_PACKAGES=(
  sysstat iotop command-not-found man-db manpages git-lfs yq nmap iperf3
  whois telnet ethtool cmake ninja-build autoconf automake libtool patch
  gettext gdb ripgrep fd-find bat dos2unix
)
for package in "${OPTIONAL_PACKAGES[@]}"; do
  apt-get install -y "$package" || true
done

ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true
ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true

echo "删除 DHCP 客户端和 NetworkManager"
for package in isc-dhcp-client isc-dhcp-common dhcpcd5 dhcpcd-base udhcpc network-manager; do
  apt-get purge -y "$package" 2>/dev/null || true
done
apt-get autoremove -y || true

echo "配置 locale 和时区"
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true
sed -i 's/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen || true
locale-gen || true

cat >/etc/default/locale <<'LOCALE_EOF'
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
LOCALE_EOF

ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" >/etc/timezone

echo "配置 PVE 注入 IP 的网络模式"
mkdir -p /etc/network/interfaces.d

cat >/etc/network/interfaces <<'NETWORK_EOF'
auto lo
iface lo inet loopback

source /etc/network/interfaces.d/*
NETWORK_EOF

cat >/etc/network/interfaces.d/00-openclaw-pve-note <<'NETWORK_NOTE_EOF'
# IPv4 must be configured by Proxmox VE.
# Example:
# pct set CTID --net0 name=eth0,bridge=vmbr0,ip=IP/CIDR,gw=GATEWAY
# This template does not use DHCP.
NETWORK_NOTE_EOF

systemctl unmask networking.service 2>/dev/null || true
systemctl enable networking.service 2>/dev/null || true

echo "配置 IPv6 禁用"
cat >/etc/sysctl.d/99-openclaw-disable-ipv6.conf <<'IPV6_EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv6.conf.eth0.disable_ipv6 = 1
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.eth0.accept_ra = 0
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.default.autoconf = 0
net.ipv6.conf.eth0.autoconf = 0
IPV6_EOF

cat >/etc/systemd/system/openclaw-disable-ipv6.service <<'IPV6_SERVICE_EOF'
[Unit]
Description=Disable IPv6 inside OpenClaw LXC
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target network.target networking.service openclaw-network.service openclaw-gateway.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'sysctl -w net.ipv6.conf.all.disable_ipv6=1 || true; sysctl -w net.ipv6.conf.default.disable_ipv6=1 || true; sysctl -w net.ipv6.conf.lo.disable_ipv6=1 || true; sysctl -w net.ipv6.conf.eth0.disable_ipv6=1 || true; ip -6 addr flush dev eth0 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
IPV6_SERVICE_EOF

cat >/etc/systemd/system/openclaw-network.service <<'NETWORK_SERVICE_EOF'
[Unit]
Description=Bring up OpenClaw LXC network without DHCP
DefaultDependencies=no
After=local-fs.target openclaw-disable-ipv6.service
Before=network-pre.target network.target networking.service openclaw-firstboot.service openclaw-gateway.service
Wants=openclaw-disable-ipv6.service network.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'ip link set lo up 2>/dev/null || true; ip link set eth0 up 2>/dev/null || true; ifup -a 2>/dev/null || true; ip -6 addr flush dev eth0 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
NETWORK_SERVICE_EOF

echo "配置 SSH root 登录"
mkdir -p /run/sshd /etc/ssh/sshd_config.d

cat >/etc/ssh/sshd_config.d/99-openclaw-root.conf <<'SSH_EOF'
PasswordAuthentication yes
PermitRootLogin yes
KbdInteractiveAuthentication yes
UsePAM yes
SSH_EOF

sed -ri 's/^#?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
sed -ri 's/^#?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config || true
sed -ri 's/^#?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config || true
sed -ri 's/^#?UsePAM .*/UsePAM yes/' /etc/ssh/sshd_config || true

cat >/etc/systemd/system/openclaw-regenerate-ssh-keys.service <<'SSH_KEYS_EOF'
[Unit]
Description=Regenerate SSH host keys
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
SSH_KEYS_EOF

echo "安装 Node.js 24"
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y nodejs
node --version
npm --version
npm config set fund false
npm config set audit false
npm config set update-notifier false

echo "安装 OpenClaw 最新版本"
npm install -g "openclaw@${OPENCLAW_VERSION}"
command -v openclaw
openclaw --version
openclaw --version >/etc/openclaw-version

npm config set registry https://registry.npmmirror.com
npm config set fund false
npm config set audit false
npm config set update-notifier false

echo "创建 OpenClaw 目录"
mkdir -p \
  /root/.openclaw/workspace \
  /root/.openclaw/agents/main/sessions \
  /root/.openclaw/agents/main/agent
chown -R root:root /root/.openclaw
chmod 700 /root/.openclaw

cat >/etc/openclaw-lxc.env <<'OPENCLAW_ENV_EOF'
OPENCLAW_LXC=1
OPENCLAW_DANGEROUS_FULL_TOOLS=1
OPENCLAW_USER=root
OPENCLAW_GROUP=root
OPENCLAW_HOME=/root
OPENCLAW_NET_IFACE=eth0
OPENCLAW_GATEWAY_PORT=18789
OPENCLAW_GATEWAY_BIND=lan
OPENCLAW_HIDE_BANNER=1
OPENCLAW_ENV_EOF
chmod 644 /etc/openclaw-lxc.env

echo "写入最高权限配置脚本"
cat >/usr/local/sbin/openclaw-ensure-config <<'ENSURE_EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/root/.openclaw/openclaw.json"
ENV_FILE="/root/.openclaw/.env"

mkdir -p \
  /root/.openclaw/workspace \
  /root/.openclaw/agents/main/sessions \
  /root/.openclaw/agents/main/agent

touch "$ENV_FILE"

kv_set() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"
  grep -v "^${key}=" "$file" >"$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  mv "$tmp" "$file"
}

if ! grep -q '^OPENCLAW_GATEWAY_TOKEN=' "$ENV_FILE"; then
  printf 'OPENCLAW_GATEWAY_TOKEN=%s\n' "$(openssl rand -hex 32)" >>"$ENV_FILE"
fi

kv_set "$ENV_FILE" OPENCLAW_GATEWAY_PORT 18789
kv_set "$ENV_FILE" OPENCLAW_GATEWAY_BIND lan

if [ ! -s "$CONFIG_FILE" ] || ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
  echo '{}' >"$CONFIG_FILE"
fi

TMP_FILE="$(mktemp)"
jq \
  --arg tokenRef '${OPENCLAW_GATEWAY_TOKEN}' \
  '
  .gateway = (.gateway // {}) |
  .gateway.mode = "local" |
  .gateway.port = 18789 |
  .gateway.bind = "lan" |
  .gateway.auth = (.gateway.auth // {}) |
  .gateway.auth.mode = "token" |
  .gateway.auth.token = $tokenRef |
  .gateway.controlUi = (.gateway.controlUi // {}) |
  .gateway.controlUi.enabled = true |

  .tools = (.tools // {}) |
  .tools.profile = "full" |
  .tools.exec = (.tools.exec // {}) |
  .tools.exec.host = "gateway" |
  .tools.exec.security = "full" |
  .tools.exec.ask = "off" |
  .tools.elevated = (.tools.elevated // {}) |
  .tools.elevated.enabled = true |
  del(.tools.allow) |
  del(.tools.deny) |

  .agents = (.agents // {}) |
  .agents.defaults = (.agents.defaults // {}) |
  .agents.defaults.sandbox = (.agents.defaults.sandbox // {}) |
  .agents.defaults.sandbox.mode = "off" |

  .agents.list = (
    if (.agents.list? | type) == "array" and (.agents.list | length) > 0 then
      .agents.list
    else
      [ { id: "main", name: "main" } ]
    end
  ) |

  .agents.list |= map(
    .tools = (.tools // {}) |
    .tools.profile = "full" |
    .tools.exec = (.tools.exec // {}) |
    .tools.exec.host = "gateway" |
    .tools.exec.security = "full" |
    .tools.exec.ask = "off" |
    .tools.elevated = (.tools.elevated // {}) |
    .tools.elevated.enabled = true |
    .sandbox = (.sandbox // {}) |
    .sandbox.mode = "off" |
    del(.tools.allow) |
    del(.tools.deny)
  )
  ' "$CONFIG_FILE" >"$TMP_FILE"

mv "$TMP_FILE" "$CONFIG_FILE"
chown -R root:root /root/.openclaw
chmod 700 /root/.openclaw
chmod 600 "$CONFIG_FILE" "$ENV_FILE"
ENSURE_EOF
chmod +x /usr/local/sbin/openclaw-ensure-config

echo "写入 API 配置命令"
cat >/usr/local/bin/openclaw-api-setup <<'API_EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/root/.openclaw/openclaw.json"
ENV_FILE="/root/.openclaw/.env"

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

env_get() {
  local key="$1"
  grep -m1 "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true
}

env_set() {
  local key="$1"
  local value="$2"
  local tmp
  touch "$ENV_FILE"
  tmp="$(mktemp)"
  grep -v "^${key}=" "$ENV_FILE" >"$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  mv "$tmp" "$ENV_FILE"
}

normalize_url() {
  local url
  url="$(trim "$1")"
  url="${url%/}"
  url="${url%/chat/completions}"
  url="${url%/}"
  printf '%s' "$url"
}

set -a
[ ! -f "$ENV_FILE" ] || . "$ENV_FILE"
set +a

/usr/local/sbin/openclaw-ensure-config

OLD_URL="$(env_get OPENCLAW_PROVIDER_BASE_URL)"
OLD_MODEL="$(env_get OPENCLAW_PROVIDER_MODEL)"
OLD_KEY="$(env_get OPENCLAW_PROVIDER_API_KEY)"
OLD_REASONING="$(env_get OPENCLAW_PROVIDER_REASONING)"

echo "============================================================"
echo "OpenClaw OpenAI-Compatible API 配置"
echo "============================================================"

read -r -p "Base URL${OLD_URL:+ [$OLD_URL]}: " BASE_URL
BASE_URL="$(trim "${BASE_URL:-}")"
BASE_URL="${BASE_URL:-$OLD_URL}"
BASE_URL="$(normalize_url "$BASE_URL")"

read -r -p "模型名称${OLD_MODEL:+ [$OLD_MODEL]}: " MODEL_ID
MODEL_ID="$(trim "${MODEL_ID:-}")"
MODEL_ID="${MODEL_ID:-$OLD_MODEL}"

DEFAULT_REASONING="${OLD_REASONING:-false}"
read -r -p "是否支持 reasoning [$DEFAULT_REASONING]，y/N: " REASONING_INPUT
REASONING_INPUT="${REASONING_INPUT:-$DEFAULT_REASONING}"

case "$REASONING_INPUT" in
  y|Y|yes|YES|true|TRUE|1) MODEL_REASONING=true ;;
  n|N|no|NO|false|FALSE|0) MODEL_REASONING=false ;;
  *)
    echo "错误：reasoning 只能填写 y 或 n"
    exit 1
    ;;
esac

if [ -n "$OLD_KEY" ]; then
  read -r -s -p "API Key，直接回车保留旧 Key: " API_KEY
  echo
  API_KEY="$(trim "${API_KEY:-}")"
  API_KEY="${API_KEY:-$OLD_KEY}"
else
  read -r -s -p "API Key: " API_KEY
  echo
  API_KEY="$(trim "$API_KEY")"
fi

if [ -z "$BASE_URL" ] || [ -z "$MODEL_ID" ] || [ -z "$API_KEY" ]; then
  echo "错误：Base URL、模型名称和 API Key 不能为空"
  exit 1
fi

case "$BASE_URL" in
  http://*|https://*) ;;
  *)
    echo "错误：Base URL 必须以 http:// 或 https:// 开头"
    exit 1
    ;;
esac

TEST_BODY="$(
  jq -nc --arg model "$MODEL_ID" \
    '{model:$model,messages:[{role:"user",content:"Reply with OK"}],max_tokens:32,stream:false}'
)"

HTTP_CODE="$(
  curl -sS \
    --connect-timeout 10 \
    --max-time 45 \
    -o /tmp/openclaw-api-response.json \
    -w '%{http_code}' \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$TEST_BODY" \
    "$BASE_URL/chat/completions" || true
)"

if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "201" ]; then
  echo "API 测试失败，HTTP 状态码：${HTTP_CODE:-无}"
  cat /tmp/openclaw-api-response.json 2>/dev/null || true
  exit 1
fi

env_set OPENCLAW_PROVIDER_API_KEY "$API_KEY"
env_set OPENCLAW_PROVIDER_BASE_URL "$BASE_URL"
env_set OPENCLAW_PROVIDER_MODEL "$MODEL_ID"
env_set OPENCLAW_PROVIDER_REASONING "$MODEL_REASONING"

PRIMARY_MODEL="custom/$MODEL_ID"
TMP_FILE="$(mktemp)"

jq \
  --arg baseUrl "$BASE_URL" \
  --arg modelId "$MODEL_ID" \
  --arg primary "$PRIMARY_MODEL" \
  --argjson reasoning "$MODEL_REASONING" \
  '
  .models = (.models // {}) |
  .models.mode = "merge" |
  .models.providers = (.models.providers // {}) |
  .models.providers.custom = {
    baseUrl: $baseUrl,
    apiKey: "${OPENCLAW_PROVIDER_API_KEY}",
    auth: "api-key",
    api: "openai-completions",
    models: [
      {
        id: $modelId,
        name: $modelId,
        input: ["text"],
        reasoning: $reasoning
      }
    ]
  } |
  .agents = (.agents // {}) |
  .agents.defaults = (.agents.defaults // {}) |
  .agents.defaults.model = {
    primary: $primary,
    fallbacks: []
  }
  ' "$CONFIG_FILE" >"$TMP_FILE"

mv "$TMP_FILE" "$CONFIG_FILE"
chown -R root:root /root/.openclaw
chmod 700 /root/.openclaw
chmod 600 "$CONFIG_FILE" "$ENV_FILE"

set -a
. "$ENV_FILE"
set +a

openclaw config validate
systemctl restart openclaw-gateway
sleep 5
echo "API 配置完成"
systemctl status openclaw-gateway --no-pager || true
API_EOF
chmod +x /usr/local/bin/openclaw-api-setup

echo "写入常用命令"
cat >/usr/local/bin/openclaw-info <<'INFO_EOF'
#!/usr/bin/env bash
set -euo pipefail

/usr/local/sbin/openclaw-ensure-config >/dev/null

ENV_FILE="/root/.openclaw/.env"
TOKEN="$(grep '^OPENCLAW_GATEWAY_TOKEN=' "$ENV_FILE" | cut -d= -f2- || true)"
IPV4="$(
  ip -o -4 addr show dev eth0 scope global 2>/dev/null |
    awk '{print $4}' | cut -d/ -f1 | head -n1 || true
)"

echo "============================================================"
echo "OpenClaw LXC Debian 12"
echo "============================================================"
echo "OpenClaw:"
openclaw --version 2>/dev/null || true

if [ -n "$IPV4" ]; then
  echo
  echo "Gateway HTTP:"
  echo "  http://$IPV4:18789"
  echo
  echo "Gateway WebSocket:"
  echo "  ws://$IPV4:18789"
else
  echo
  echo "未检测到 eth0 IPv4"
  echo "请在 Proxmox VE 中配置容器 IPv4"
fi

echo
echo "Gateway Token:"
echo "$TOKEN"
echo
echo "权限模式:"
echo "  User=root"
echo "  tools.profile=full"
echo "  tools.exec.host=gateway"
echo "  tools.exec.security=full"
echo "  tools.exec.ask=off"
echo "  tools.elevated.enabled=true"
echo "  sandbox.mode=off"
echo "============================================================"
INFO_EOF

cat >/usr/local/bin/openclaw-status <<'STATUS_EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "================ systemd 状态 ================"
systemctl status openclaw-gateway --no-pager || true

echo
echo "================ 配置校验 ================"
set -a
[ ! -f /root/.openclaw/.env ] || . /root/.openclaw/.env
set +a
openclaw config validate || true

echo
echo "================ 监听端口 ================"
ss -lntp | grep ':18789' || true

echo
echo "================ 权限配置 ================"
jq '{gateway:.gateway, tools:.tools, agents:.agents}' \
  /root/.openclaw/openclaw.json 2>/dev/null || true
STATUS_EOF

cat >/usr/local/bin/openclaw-logs <<'LOGS_EOF'
#!/usr/bin/env bash
set -euo pipefail
journalctl -u openclaw-gateway -f
LOGS_EOF

cat >/usr/local/bin/openclaw-restart <<'RESTART_EOF'
#!/usr/bin/env bash
set -euo pipefail
/usr/local/sbin/openclaw-ensure-config
systemctl restart openclaw-gateway
sleep 5
systemctl status openclaw-gateway --no-pager || true
RESTART_EOF

cat >/usr/local/bin/openclaw-update <<'UPDATE_EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl stop openclaw-gateway 2>/dev/null || true
npm config set registry https://registry.npmmirror.com
npm install -g openclaw@latest
openclaw --version
/usr/local/sbin/openclaw-ensure-config
set -a
. /root/.openclaw/.env
set +a
openclaw config validate
systemctl restart openclaw-gateway
sleep 5
systemctl status openclaw-gateway --no-pager || true
UPDATE_EOF

cat >/usr/local/bin/openclaw-repair-max-permissions <<'REPAIR_EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl stop openclaw-gateway 2>/dev/null || true
/usr/local/sbin/openclaw-ensure-config
set -a
. /root/.openclaw/.env
set +a
openclaw config validate
jq '{gateway:.gateway, tools:.tools, agents:.agents}' /root/.openclaw/openclaw.json
systemctl daemon-reload
systemctl reset-failed openclaw-gateway 2>/dev/null || true
systemctl restart openclaw-gateway
sleep 5
systemctl status openclaw-gateway --no-pager || true
ss -lntp | grep ':18789' || true
REPAIR_EOF

chmod +x \
  /usr/local/bin/openclaw-info \
  /usr/local/bin/openclaw-status \
  /usr/local/bin/openclaw-logs \
  /usr/local/bin/openclaw-restart \
  /usr/local/bin/openclaw-update \
  /usr/local/bin/openclaw-repair-max-permissions

echo "写入 systemd 服务"
cat >/etc/systemd/system/openclaw-firstboot.service <<'FIRSTBOOT_EOF'
[Unit]
Description=OpenClaw first boot initialization
After=openclaw-disable-ipv6.service openclaw-network.service network.target
Wants=openclaw-disable-ipv6.service openclaw-network.service network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openclaw-ensure-config
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
FIRSTBOOT_EOF

cat >/etc/systemd/system/openclaw-gateway.service <<'GATEWAY_EOF'
[Unit]
Description=OpenClaw Gateway Root Full Tools
After=openclaw-disable-ipv6.service openclaw-network.service openclaw-firstboot.service network.target
Wants=openclaw-disable-ipv6.service openclaw-network.service openclaw-firstboot.service network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/root
EnvironmentFile=-/etc/openclaw-lxc.env
EnvironmentFile=-/root/.openclaw/.env
Environment=HOME=/root
Environment=OPENCLAW_HOME=/root
Environment=OPENCLAW_CONFIG_PATH=/root/.openclaw/openclaw.json
Environment=OPENCLAW_HIDE_BANNER=1
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStartPre=/usr/local/sbin/openclaw-ensure-config
ExecStart=/usr/bin/env openclaw gateway
Restart=always
RestartSec=5
TimeoutStartSec=120
TimeoutStopSec=30
SuccessExitStatus=0 143
KillMode=control-group

[Install]
WantedBy=multi-user.target
GATEWAY_EOF

systemctl enable openclaw-disable-ipv6.service
systemctl enable openclaw-network.service
systemctl enable openclaw-regenerate-ssh-keys.service
systemctl enable ssh.service || systemctl enable ssh || true
systemctl enable cron.service || true
systemctl enable openclaw-firstboot.service
systemctl enable openclaw-gateway.service

echo "生成初始配置"
rm -f /root/.openclaw/.env
/usr/local/sbin/openclaw-ensure-config

set -a
. /root/.openclaw/.env
set +a
openclaw config validate

# 注意：README 不要使用 markdown 三反引号，避免 heredoc 被编辑器破坏
cat >/root/README-OPENCLAW-LXC.md <<'README_EOF'
# OpenClaw LXC Debian 12

## 首次使用

    openclaw-info
    openclaw-api-setup



## 常用命令

    openclaw-info
    openclaw-status
    openclaw-logs
    openclaw-restart
    openclaw-api-setup

## Gateway

默认端口：18789

Token 文件：

    /root/.openclaw/.env

chmod 600 /root/README-OPENCLAW-LXC.md

echo "清理模板"
# 不把 Token 放入模板。每个新 LXC 首次启动时自动生成。
rm -f /root/.openclaw/.env
rm -f /root/.openclaw/.env.bak.*
rm -f /root/.openclaw/*.bak.*
rm -f /root/.openclaw/*.bad.*

rm -f /etc/machine-id
touch /etc/machine-id
rm -f /var/lib/dbus/machine-id 2>/dev/null || true
ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true

rm -f /etc/ssh/ssh_host_* 2>/dev/null || true
rm -f /root/.bash_history 2>/dev/null || true

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "OpenClaw LXC rootfs ready"
