这个镜像不能用，我自己还没有测试！！！
这个镜像不能用，我自己还没有测试！！！
这个镜像不能用，我自己还没有测试！！！
这个镜像不能用，我自己还没有测试！！！
这个镜像不能用，我自己还没有测试！！！
# OpenClaw PVE Image Builder

自动构建适用于 **Proxmox VE / PVE** 的 OpenClaw 镜像。

本项目支持两种镜像类型：

- **LXC 容器模板版本**
- **KVM / QEMU Cloud-Init 虚拟机镜像版本**

构建完成后会自动发布到 **GitHub Releases**，可以直接下载并导入 PVE 使用。

---

## 项目特点

- 自动构建 OpenClaw 镜像
- 自动安装 OpenClaw
- 不使用 Docker
- OpenClaw 预装在镜像内
- 创建容器 / 虚拟机后不再重复下载 OpenClaw
- 首次启动自动生成随机端口
- 首次启动自动生成 OpenClaw 管理密码
- 自动显示网卡访问地址
- 支持 IPv6 开启 / 关闭 / 首次登录询问
- 支持监听 `0.0.0.0` 或 `::`
- 支持自定义模型 API
- 支持 GitHub Actions 自动发布 Release
- 自动生成 SHA256 校验文件
- 自动生成镜像文件列表
- 支持 PVE 批量部署
- 支持售卖独立 OpenClaw 云主机

---

## 镜像类型说明

| 类型 | 输出文件 | PVE 使用方式 | 适合场景 |
|---|---|---|---|
| LXC | `.tar.gz` | `pct create` | 轻量、省资源、启动快 |
| KVM | `.qcow2.xz` | `qm importdisk` | 隔离强、兼容性好 |

---

## LXC 与 KVM 区别

### LXC 版本

LXC 是容器级虚拟化，资源占用更低，启动速度更快。

优点：

- 占用资源少
- 启动速度快
- 适合批量开通
- 适合低配服务器
- 适合售卖轻量 OpenClaw 云主机

缺点：

- 隔离性弱于 KVM
- 依赖宿主机内核
- 某些 systemd、网络、权限行为可能受 LXC 限制影响

---

### KVM 版本

KVM 是完整虚拟机，隔离更强，兼容性更好。

优点：

- 隔离性强
- 更接近真实服务器
- systemd 兼容性更好
- Cloud-Init 配置更方便
- 更适合正式售卖云主机

缺点：

- 占用资源比 LXC 高
- 启动速度比 LXC 慢
- 镜像体积更大

---

## Release 文件说明

### LXC 版本

```text
openclaw-lxc-debian12-版本号.tar.gz
openclaw-lxc-debian12-版本号.tar.gz.sha256
openclaw-lxc-debian12-版本号.tar.gz.list
build-info.txt
```

| 文件 | 说明 |
|---|---|
| `.tar.gz` | PVE LXC 容器模板 |
| `.sha256` | SHA256 校验文件 |
| `.list` | 模板内部文件列表 |
| `build-info.txt` | 构建信息 |

---

### KVM 版本

```text
openclaw-kvm-debian12-版本号.qcow2.xz
openclaw-kvm-debian12-版本号.qcow2.xz.sha256
openclaw-kvm-debian12-版本号.qcow2.xz.list
build-info.txt
```

| 文件 | 说明 |
|---|---|
| `.qcow2.xz` | 压缩后的 KVM / QEMU Cloud-Init 镜像 |
| `.sha256` | SHA256 校验文件 |
| `.list` | 镜像内部文件列表 |
| `build-info.txt` | 构建信息 |

---

## GitHub Actions 文件

本项目可以使用两个 workflow：

```text
.github/workflows/build-openclaw-lxc.yml
.github/workflows/build-openclaw-kvm.yml
```

| Workflow | 说明 |
|---|---|
| `build-openclaw-lxc.yml` | 构建 LXC 容器模板 |
| `build-openclaw-kvm.yml` | 构建 KVM Cloud-Init 镜像 |

---

## GitHub Actions 参数说明

### 通用参数

| 参数 | 说明 | 默认值 |
|---|---|---|
| `version` | 发布版本号 | 自动生成 |
| `openclaw_npm_spec` | OpenClaw npm 包名或版本 | `openclaw` |
| `openclaw_run_cmd` | OpenClaw 启动命令 | `openclaw onboard` |
| `bind_host` | OpenClaw 监听地址 | `0.0.0.0` |
| `ipv6_policy` | IPv6 策略 | `ask` |
| `port_min` | 随机端口最小值 | `20000` |
| `port_max` | 随机端口最大值 | `65000` |
| `prerelease` | 是否标记为预发布 | `false` |

---

### KVM 额外参数

| 参数 | 说明 | 默认值 |
|---|---|---|
| `disk_size` | KVM 虚拟磁盘大小 | `20G` |

推荐填写：

```text
20G
```

也可以兼容：

```text
20GB
```

但更推荐使用 `20G`。

---

## 推荐构建参数

### LXC 推荐参数

```text
openclaw_npm_spec: openclaw
openclaw_run_cmd: openclaw onboard
bind_host: 0.0.0.0
ipv6_policy: ask
port_min: 20000
port_max: 65000
prerelease: false
```

---

### KVM 推荐参数

```text
openclaw_npm_spec: openclaw
openclaw_run_cmd: openclaw onboard
bind_host: 0.0.0.0
ipv6_policy: ask
disk_size: 20G
port_min: 20000
port_max: 65000
prerelease: false
```

---

## IPv6 策略说明

IPv6 支持三种策略：

| 参数 | 说明 |
|---|---|
| `ask` | 首次 root 登录时询问，推荐 |
| `0` | 默认关闭 IPv6 |
| `1` | 默认开启 IPv6 |

国内 NAT、家宽、路由器频繁下发 IPv6 的环境，推荐：

```text
ipv6_policy: ask
```

或者直接使用：

```text
ipv6_policy: 0
```

---

## 监听地址说明

默认监听地址：

```text
0.0.0.0
```

表示监听所有 IPv4 地址，兼容性最好。

如果需要 IPv6 双栈，可以选择：

```text
::
```

注意：是否完全支持双栈取决于 OpenClaw 当前版本和底层 Web 框架。生产环境建议优先使用 `0.0.0.0`。

---

# LXC 使用说明

## 下载 LXC 模板

从 GitHub Releases 下载：

```text
openclaw-lxc-debian12-版本号.tar.gz
```

---

## 上传到 PVE

```bash
scp openclaw-lxc-debian12-版本号.tar.gz root@你的PVE:/var/lib/vz/template/cache/
```

也可以在 PVE 面板上传到：

```text
local → CT Templates
```

---

## 创建 LXC 容器

示例：

```bash
pct create 200 local:vztmpl/openclaw-lxc-debian12-版本号.tar.gz \
  --hostname openclaw-lxc-200 \
  --cores 2 \
  --memory 4096 \
  --swap 1024 \
  --rootfs local-lvm:20 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp,ip6=auto \
  --features nesting=1,keyctl=1 \
  --unprivileged 1 \
  --start 1
```

---

## LXC 禁用 IPv6

如果需要在 PVE 层禁用 IPv6：

```bash
pct create 200 local:vztmpl/openclaw-lxc-debian12-版本号.tar.gz \
  --hostname openclaw-lxc-200 \
  --cores 2 \
  --memory 4096 \
  --swap 1024 \
  --rootfs local-lvm:20 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp,ip6=none \
  --features nesting=1,keyctl=1 \
  --unprivileged 1 \
  --start 1
```

---

## 进入 LXC

```bash
pct enter 200
```

查看 OpenClaw 信息：

```bash
cat /root/openclaw-info.txt
```

---

# KVM 使用说明

## 下载 KVM 镜像

从 GitHub Releases 下载：

```text
openclaw-kvm-debian12-版本号.qcow2.xz
```

---

## 解压 KVM 镜像

```bash
xz -dk openclaw-kvm-debian12-版本号.qcow2.xz
```

解压后得到：

```text
openclaw-kvm-debian12-版本号.qcow2
```

---

## 上传到 PVE

```bash
scp openclaw-kvm-debian12-版本号.qcow2 root@你的PVE:/root/
```

---

## 创建 KVM 模板

以下示例创建 VMID 为 `9000` 的模板。

### 1. 创建空虚拟机

```bash
qm create 9000 \
  --name openclaw-kvm \
  --memory 4096 \
  --cores 2 \
  --net0 virtio,bridge=vmbr0 \
  --agent enabled=1
```

---

### 2. 导入磁盘

```bash
qm importdisk 9000 openclaw-kvm-debian12-版本号.qcow2 local-lvm
```

如果你的存储不是 `local-lvm`，请替换成自己的存储名称，例如：

```text
local
local-zfs
ssd
nvme
```

---

### 3. 设置磁盘和 Cloud-Init

```bash
qm set 9000 \
  --scsihw virtio-scsi-pci \
  --scsi0 local-lvm:vm-9000-disk-0 \
  --ide2 local-lvm:cloudinit \
  --boot c \
  --bootdisk scsi0 \
  --serial0 socket \
  --vga serial0
```

---

### 4. 转换为模板

```bash
qm template 9000
```

---

## 从 KVM 模板克隆虚拟机

```bash
qm clone 9000 101 --name openclaw-101
```

设置 root 用户密码：

```bash
qm set 101 --ciuser root --cipassword '你的密码'
```

设置 DHCP：

```bash
qm set 101 --ipconfig0 ip=dhcp
```

启动虚拟机：

```bash
qm start 101
```

进入控制台：

```bash
qm terminal 101
```

或者 SSH 登录：

```bash
ssh root@虚拟机IP
```

---

## KVM 静态 IP 示例

```bash
qm set 101 --ipconfig0 ip=192.168.1.101/24,gw=192.168.1.1
```

设置 DNS：

```bash
qm set 101 --nameserver 1.1.1.1
```

启动：

```bash
qm start 101
```

---

# 首次启动说明

无论 LXC 还是 KVM，首次启动都会自动执行初始化脚本：

```bash
openclaw-firstboot
```

首次启动会自动完成：

- 等待网卡获取 IP
- 根据配置处理 IPv6
- 生成随机端口
- 生成随机 OpenClaw 管理密码
- 创建运行时配置文件
- 启动 OpenClaw systemd 服务
- 生成 `/root/openclaw-info.txt`

---

## 查看初始化信息

```bash
cat /root/openclaw-info.txt
```

示例：

```text
==================================================
 OpenClaw 已初始化
==================================================

网卡 IPv4 访问地址：
http://192.168.1.100:随机端口

网卡 IPv6 访问地址：
未检测到 IPv6 地址

端口：随机端口
用户名：admin
密码：随机生成
监听地址：0.0.0.0

下一步：执行 openclaw-set-api 配置模型 API
查看服务：systemctl status openclaw --no-pager -l
==================================================
```

---

# 配置模型 API

进入系统后执行：

```bash
openclaw-set-api
```

根据提示填写：

```text
API base_url
默认模型
API Key
```

OpenAI 示例：

```text
API base_url: https://api.openai.com/v1
默认模型: gpt-4.1
API Key: sk-xxxx
```

DeepSeek 示例：

```text
API base_url: https://api.deepseek.com/v1
默认模型: deepseek-chat
API Key: sk-xxxx
```

配置完成后会自动重启 OpenClaw 服务。

---

# OpenClaw 服务管理

查看服务状态：

```bash
systemctl status openclaw --no-pager -l
```

重启服务：

```bash
systemctl restart openclaw
```

停止服务：

```bash
systemctl stop openclaw
```

查看日志：

```bash
journalctl -u openclaw -n 100 --no-pager
```

实时日志：

```bash
journalctl -u openclaw -f
```

---

# 常用命令

查看 OpenClaw 信息：

```bash
cat /root/openclaw-info.txt
```

重新配置 API：

```bash
openclaw-set-api
```

查看访问地址：

```bash
openclaw-get-addresses 端口号
```

查看 IPv6 状态：

```bash
openclaw-ipv6-control status
```

关闭 IPv6：

```bash
openclaw-ipv6-control disable
```

开启 IPv6：

```bash
openclaw-ipv6-control enable
```

查看 OpenClaw 命令路径：

```bash
command -v openclaw
```

查看 OpenClaw 版本：

```bash
openclaw --version
```

查看 Node.js：

```bash
node -v
npm -v
pnpm -v
```

---

# 镜像内部目录

## LXC 版本

常见路径：

```text
/usr/bin/openclaw
/usr/lib/node_modules/openclaw
/etc/openclaw/
/var/lib/openclaw
/home/openclaw
/usr/local/bin/openclaw-firstboot
/usr/local/bin/openclaw-set-api
/usr/local/bin/openclaw-ipv6-control
/usr/local/bin/openclaw-launcher
/etc/systemd/system/openclaw.service
/etc/systemd/system/openclaw-firstboot.service
```

---

## KVM 版本

常见路径：

```text
/usr/bin/openclaw
/opt/node
/opt/openclaw-runtime
/opt/openclaw-runtime/lib/node_modules/openclaw
/etc/openclaw/
/var/lib/openclaw
/home/openclaw
/usr/local/bin/openclaw-firstboot
/usr/local/bin/openclaw-set-api
/usr/local/bin/openclaw-ipv6-control
/usr/local/bin/openclaw-launcher
/etc/systemd/system/openclaw.service
/etc/systemd/system/openclaw-firstboot.service
```

---

# 验证镜像内容

## 验证 LXC 模板

查看文件列表：

```bash
tar -tzf openclaw-lxc-debian12-版本号.tar.gz | grep openclaw | head
```

检查 OpenClaw 命令：

```bash
tar -tzf openclaw-lxc-debian12-版本号.tar.gz | grep './usr/bin/openclaw'
```

检查 OpenClaw 安装目录：

```bash
tar -tzf openclaw-lxc-debian12-版本号.tar.gz | grep './usr/lib/node_modules/openclaw/' | head
```

完整解压检查：

```bash
mkdir -p /tmp/check-openclaw-lxc
tar -xzf openclaw-lxc-debian12-版本号.tar.gz -C /tmp/check-openclaw-lxc

ls -l /tmp/check-openclaw-lxc/usr/bin/openclaw
du -sh /tmp/check-openclaw-lxc/usr/lib/node_modules/openclaw
```

注意不要这样解压：

```bash
tar -xzvf openclaw-lxc-debian12-版本号.tar.gz -C /tmp/check-openclaw-lxc | head
```

这会导致 `head` 提前退出，`tar` 被中断，只解压一部分文件。

---

## 验证 KVM 镜像

解压：

```bash
xz -dk openclaw-kvm-debian12-版本号.qcow2.xz
```

查看镜像信息：

```bash
qemu-img info openclaw-kvm-debian12-版本号.qcow2
```

查看文件列表：

```bash
cat openclaw-kvm-debian12-版本号.qcow2.xz.list | grep openclaw | head
```

校验 SHA256：

```bash
sha256sum -c openclaw-kvm-debian12-版本号.qcow2.xz.sha256
```

---

# 自动检查内容

构建过程中会自动检查：

- Debian 12 镜像是否下载成功
- OpenClaw 是否安装成功
- `openclaw` 命令是否存在
- Node.js 是否存在
- npm 是否存在
- pnpm 是否存在
- OpenClaw node_modules 是否存在
- `openclaw.service` 是否存在
- `openclaw-firstboot` 是否存在
- `openclaw-set-api` 是否语法正确
- `openclaw-ipv6-control` 是否语法正确
- `openclaw-launcher` 是否语法正确
- `openclaw` 用户是否存在
- OpenClaw 普通用户是否能读取模板配置

只有检查通过后才会发布 Release。

---

# 推荐配置

## LXC 推荐配置

最低：

```text
CPU: 2 核
内存: 4GB
硬盘: 20GB
系统: Debian 12 LXC
```

推荐：

```text
CPU: 4 核
内存: 8GB
硬盘: 30GB+
```

---

## KVM 推荐配置

最低：

```text
CPU: 2 核
内存: 4GB
硬盘: 20GB
网卡: virtio
磁盘控制器: virtio-scsi-pci
Cloud-Init: 开启
QEMU Guest Agent: 开启
```

推荐：

```text
CPU: 4 核
内存: 8GB
硬盘: 30GB+
网卡: virtio
磁盘: local-lvm / zfs / nvme
```

---

# 售卖云主机建议

如果你打算售卖 OpenClaw 云主机，建议：

- 每个客户一个独立 LXC 或 KVM
- 不要多个客户共享同一个 OpenClaw 实例
- 每个实例独立密码
- 每个实例独立 API 配置
- 不要在镜像中内置任何私人 API Key
- 不要使用固定密码
- 使用 PVE 限制 CPU、内存、磁盘
- 建议定期备份
- 建议使用 HTTPS 反向代理
- 建议使用防火墙限制管理端口
- 建议使用独立快照
- 重要客户推荐使用 KVM
- 批量轻量客户可以使用 LXC

---

# 安全说明

OpenClaw 属于 AI Agent / 自托管助手类应用，可能具备访问文件、调用外部 API、执行工具等能力。

公网暴露或商业售卖时请注意：

- 不要使用弱密码
- 不要多人共享同一实例
- 不要在模板里内置私人 API Key
- 不要开放不必要的端口
- 建议使用 HTTPS
- 建议使用反向代理
- 建议限制来源 IP
- 建议开启防火墙
- 建议每个客户独立实例隔离

---

# 故障排查

## 1. 看不到访问地址

执行：

```bash
ip addr
cat /root/openclaw-info.txt
```

也可以手动查看：

```bash
openclaw-get-addresses 端口号
```

---

## 2. OpenClaw 没启动

查看服务：

```bash
systemctl status openclaw --no-pager -l
```

查看日志：

```bash
journalctl -u openclaw -n 100 --no-pager
```

重启：

```bash
systemctl restart openclaw
```

---

## 3. 没有生成密码

手动执行：

```bash
openclaw-firstboot
```

然后查看：

```bash
cat /root/openclaw-info.txt
```

---

## 4. 无法访问端口

检查监听：

```bash
ss -tulnp | grep openclaw
```

检查防火墙：

```bash
ufw status
```

允许端口：

```bash
ufw allow 端口号/tcp
```

---

## 5. API 配置错误

重新配置：

```bash
openclaw-set-api
```

重启服务：

```bash
systemctl restart openclaw
```

---

## 6. GitHub Actions 构建失败

常见原因：

| 问题 | 说明 |
|---|---|
| `disk_size` 错误 | 建议填写 `20G` |
| npm 下载失败 | 重新运行 workflow |
| GitHub Runner 空间不足 | 减小镜像大小或使用 self-hosted runner |
| Release 上传失败 | 检查 `permissions: contents: write` |
| workflow 不显示按钮 | workflow 必须在默认分支 |

---

# 注意事项

- LXC 版本使用 `pct create`
- KVM 版本使用 `qm importdisk`
- KVM 版本是 Cloud-Init 镜像
- LXC 版本是容器模板
- OpenClaw 管理密码由首次启动脚本自动生成
- 模型 API Key 不会预置在镜像内
- 进入系统后需要执行 `openclaw-set-api`
- 如果公网访问，务必做好安全防护

---

# License

本项目脚本用于自动构建 OpenClaw PVE 镜像。

OpenClaw 本身版权归其原项目所有，请遵守 OpenClaw 官方许可证和使用条款。

这个镜像不能用，我自己还没有测试！！！
