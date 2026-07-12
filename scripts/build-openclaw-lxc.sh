#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

VERSION="${INPUT_VERSION:-auto}"

if [ "$VERSION" = "auto" ]; then
  VERSION="$(date -u +'%Y.%m.%d-%H%M%S')-${GITHUB_SHA:0:7}"
fi

if ! printf '%s' "$VERSION" | grep -Eq '^[A-Za-z0-9._-]+$'; then
  echo "错误：version 只能包含字母、数字、点、下划线和横线"
  exit 1
fi

IMAGE_PREFIX="openclaw-lxc-debian12"
IMAGE_NAME="${IMAGE_PREFIX}-${VERSION}.tar.gz"
SHA_NAME="${IMAGE_NAME}.sha256"
RELEASE_TAG="${IMAGE_PREFIX}-${VERSION}"
RELEASE_TITLE="OpenClaw LXC Debian 12 Root Full Tools ${VERSION}"

PROJECT_DIR="${GITHUB_WORKSPACE:-$PWD}"
WORK_DIR="$PROJECT_DIR/work"
ROOTFS="$WORK_DIR/rootfs"
DIST_DIR="$PROJECT_DIR/dist"
INSTALL_SCRIPT="$PROJECT_DIR/scripts/install-openclaw.sh"

mkdir -p "$WORK_DIR" "$DIST_DIR"

if [ ! -f "$INSTALL_SCRIPT" ]; then
  echo "错误：找不到 $INSTALL_SCRIPT"
  exit 1
fi

cleanup_mounts() {
  set +e

  echo "清理 rootfs 挂载点"

  if [ -d "$ROOTFS/dev" ]; then
    sudo umount -Rlf "$ROOTFS/dev" 2>/dev/null || true
  fi

  if [ -d "$ROOTFS/proc" ]; then
    sudo umount -Rlf "$ROOTFS/proc" 2>/dev/null || true
  fi

  if [ -d "$ROOTFS/sys" ]; then
    sudo umount -Rlf "$ROOTFS/sys" 2>/dev/null || true
  fi

  sync
}

check_leftover_mounts() {
  local mounts

  mounts="$(
    sudo findmnt -rn -o TARGET 2>/dev/null |
      awk -v root="$ROOTFS" '
        $0 == root || index($0, root "/") == 1
      ' || true
  )"

  if [ -n "$mounts" ]; then
    echo "错误：rootfs 下仍有挂载点："
    printf '%s\n' "$mounts"
    exit 1
  fi
}

trap cleanup_mounts EXIT INT TERM

echo "============================================================"
echo "[1/8] 创建 Debian 12 rootfs"
echo "============================================================"

sudo rm -rf "$ROOTFS"
sudo mkdir -p "$ROOTFS"

sudo debootstrap \
  --arch=amd64 \
  --variant=minbase \
  bookworm \
  "$ROOTFS" \
  http://deb.debian.org/debian

echo "============================================================"
echo "[2/8] 准备 chroot 环境"
echo "============================================================"

sudo mount -t proc proc "$ROOTFS/proc"

sudo mount --rbind /sys "$ROOTFS/sys"
sudo mount --make-rslave "$ROOTFS/sys"

sudo mount --rbind /dev "$ROOTFS/dev"
sudo mount --make-rslave "$ROOTFS/dev"

sudo cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

echo "openclaw" | sudo tee "$ROOTFS/etc/hostname" >/dev/null

sudo tee "$ROOTFS/etc/hosts" >/dev/null <<'HOSTS_EOF'
127.0.0.1 localhost
127.0.1.1 openclaw

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
HOSTS_EOF

echo "============================================================"
echo "[3/8] 复制容器安装脚本"
echo "============================================================"

sudo cp "$INSTALL_SCRIPT" "$ROOTFS/tmp/install-openclaw.sh"
sudo chmod +x "$ROOTFS/tmp/install-openclaw.sh"

echo "============================================================"
echo "[4/8] 安装 Debian 和 OpenClaw"
echo "============================================================"

sudo env \
  OPENCLAW_VERSION=latest \
  chroot "$ROOTFS" \
  /bin/bash /tmp/install-openclaw.sh

echo "============================================================"
echo "[5/8] 构建阶段自检"
echo "============================================================"

sudo chroot "$ROOTFS" command -v openclaw
sudo chroot "$ROOTFS" openclaw --version

sudo test -x \
  "$ROOTFS/usr/local/sbin/openclaw-ensure-config"

sudo test -x \
  "$ROOTFS/usr/local/bin/openclaw-api-setup"

sudo test -x \
  "$ROOTFS/usr/local/bin/openclaw-info"

sudo test -x \
  "$ROOTFS/usr/local/bin/openclaw-status"

sudo test -x \
  "$ROOTFS/usr/local/bin/openclaw-logs"

sudo test -x \
  "$ROOTFS/usr/local/bin/openclaw-restart"

sudo test -x \
  "$ROOTFS/usr/local/bin/openclaw-update"

sudo test -x \
  "$ROOTFS/usr/local/bin/openclaw-repair-max-permissions"

sudo test -f \
  "$ROOTFS/etc/systemd/system/openclaw-gateway.service"

sudo grep -q '^User=root$' \
  "$ROOTFS/etc/systemd/system/openclaw-gateway.service"

sudo grep -q '^Group=root$' \
  "$ROOTFS/etc/systemd/system/openclaw-gateway.service"

sudo test -f \
  "$ROOTFS/etc/network/interfaces"

sudo grep -Fq \
  'source /etc/network/interfaces.d/*' \
  "$ROOTFS/etc/network/interfaces"

if sudo grep -R \
  -E 'iface eth0 inet dhcp|iface eth0 inet6 dhcp' \
  "$ROOTFS/etc/network" >/dev/null 2>&1
then
  echo "错误：发现 DHCP 配置"
  exit 1
fi

if sudo chroot "$ROOTFS" \
  sh -c 'command -v dhclient' >/dev/null 2>&1
then
  echo "错误：dhclient 不应该存在"
  exit 1
fi

sudo test -f \
  "$ROOTFS/etc/sysctl.d/99-openclaw-disable-ipv6.conf"

sudo jq empty \
  "$ROOTFS/root/.openclaw/openclaw.json"

sudo jq -e '
  .gateway.bind == "lan"
  and .gateway.port == 18789
  and .tools.profile == "full"
  and .tools.exec.host == "gateway"
  and .tools.exec.security == "full"
  and .tools.exec.ask == "off"
  and .tools.elevated.enabled == true
  and .agents.defaults.sandbox.mode == "off"
  and (.tools.allow? | not)
  and (.tools.deny? | not)
' "$ROOTFS/root/.openclaw/openclaw.json"

if sudo find "$ROOTFS/root/.openclaw" \
  -type f \
  -name ".env" \
  -print 2>/dev/null |
  grep -q .
then
  echo "错误：模板中不能预置 Gateway Token"
  exit 1
fi

echo "============================================================"
echo "[6/8] 卸载 chroot 挂载点"
echo "============================================================"

cleanup_mounts
trap - EXIT INT TERM

check_leftover_mounts

sudo rm -f "$ROOTFS/etc/resolv.conf"

sudo tee "$ROOTFS/etc/resolv.conf" >/dev/null <<'DNS_EOF'
nameserver 223.5.5.5
nameserver 119.29.29.29
DNS_EOF

echo "============================================================"
echo "[7/8] 打包 LXC 模板"
echo "============================================================"

rm -f "$DIST_DIR/$IMAGE_NAME"
rm -f "$DIST_DIR/$SHA_NAME"

sudo tar \
  --one-file-system \
  --numeric-owner \
  --xattrs \
  --acls \
  -cpf - \
  -C "$ROOTFS" . |
  gzip -9n >"$DIST_DIR/$IMAGE_NAME"

sync

test -s "$DIST_DIR/$IMAGE_NAME"

file "$DIST_DIR/$IMAGE_NAME"
gzip -t "$DIST_DIR/$IMAGE_NAME"
tar -tzf "$DIST_DIR/$IMAGE_NAME" >/dev/null

TEST_DIR="$WORK_DIR/test-extract"

sudo rm -rf "$TEST_DIR"
sudo mkdir -p "$TEST_DIR"

sudo tar \
  -xzf "$DIST_DIR/$IMAGE_NAME" \
  -C "$TEST_DIR" \
  --numeric-owner \
  --acls \
  --xattrs \
  --warning=no-unknown-keyword

sudo test -x \
  "$TEST_DIR/usr/local/bin/openclaw-api-setup"

sudo test -x \
  "$TEST_DIR/usr/local/bin/openclaw-info"

sudo test -f \
  "$TEST_DIR/root/.openclaw/openclaw.json"

sudo jq empty \
  "$TEST_DIR/root/.openclaw/openclaw.json"

sudo test ! -e \
  "$TEST_DIR/root/.openclaw/.env"

sudo rm -rf "$TEST_DIR"

(
  cd "$DIST_DIR"
  sha256sum "$IMAGE_NAME" >"$SHA_NAME"
  sha256sum -c "$SHA_NAME"
)

cat >"$DIST_DIR/README.md" <<README_EOF
# OpenClaw LXC Debian 12

## 模板文件

- $IMAGE_NAME
- $SHA_NAME

## 创建容器

IP 必须由 Proxmox VE 配置：

\`\`\`bash
pct create CTID \\
  local:vztmpl/$IMAGE_NAME \\
  --hostname openclaw \\
  --cores 4 \\
  --memory 8192 \\
  --rootfs local-lvm:32 \\
  --net0 name=eth0,bridge=vmbr0,ip=IP/CIDR,gw=GATEWAY \\
  --unprivileged 0 \\
  --features nesting=1
\`\`\`

模板内部不使用 DHCP。

## Gateway

默认端口：

\`\`\`text
18789
\`\`\`

访问地址：

\`\`\`text
http://CONTAINER_IP:18789
\`\`\`

## OpenClaw 权限

- Gateway 使用 root 运行
- tools.profile=full
- tools.exec.host=gateway
- tools.exec.security=full
- tools.exec.ask=off
- tools.elevated.enabled=true
- agents.defaults.sandbox.mode=off
- 不设置 tools.allow
- 不设置 tools.deny

OpenClaw 可以在 LXC 容器内部执行任意 root 命令。

## 常用命令

\`\`\`bash
openclaw-info
openclaw-status
openclaw-logs
openclaw-restart
openclaw-update
openclaw-repair-max-permissions
openclaw-api-setup
\`\`\`

## 安全说明

Gateway 监听公网接口。

Gateway Token 位于：

\`\`\`text
/root/.openclaw/.env
\`\`\`

获得 Gateway Token 的用户可能获得该 LXC 容器内的 root 级操作能力。
README_EOF

ls -lh \
  "$DIST_DIR/$IMAGE_NAME" \
  "$DIST_DIR/$SHA_NAME" \
  "$DIST_DIR/README.md"

echo "============================================================"
echo "[8/8] 发布 GitHub Release"
echo "============================================================"

cd "$DIST_DIR"

gh auth status --hostname github.com

if gh release view "$RELEASE_TAG" \
  --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1
then
  gh release upload "$RELEASE_TAG" \
    "$IMAGE_NAME" \
    "$SHA_NAME" \
    README.md \
    --repo "$GITHUB_REPOSITORY" \
    --clobber

  gh release edit "$RELEASE_TAG" \
    --repo "$GITHUB_REPOSITORY" \
    --title "$RELEASE_TITLE" \
    --notes-file README.md
else
  gh release create "$RELEASE_TAG" \
    "$IMAGE_NAME" \
    "$SHA_NAME" \
    README.md \
    --repo "$GITHUB_REPOSITORY" \
    --target "$GITHUB_SHA" \
    --title "$RELEASE_TITLE" \
    --notes-file README.md
fi

VERIFY_DIR="$(mktemp -d)"

gh release download "$RELEASE_TAG" \
  --repo "$GITHUB_REPOSITORY" \
  --pattern "$IMAGE_NAME" \
  --pattern "$SHA_NAME" \
  --dir "$VERIFY_DIR" \
  --clobber

(
  cd "$VERIFY_DIR"

  sha256sum -c "$SHA_NAME"
  gzip -t "$IMAGE_NAME"
  tar -tzf "$IMAGE_NAME" >/dev/null
)

rm -rf "$VERIFY_DIR"

echo "============================================================"
echo "构建和发布完成"
echo "============================================================"
echo "Release Tag: $RELEASE_TAG"
echo "Image: $IMAGE_NAME"
