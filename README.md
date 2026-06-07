# OpenClaw PVE LXC Template Builder

自动构建适用于 **Proxmox VE / PVE** 的 OpenClaw LXC 容器模板。

本项目通过 **GitHub Actions** 自动构建 Debian 12 LXC 镜像，并在镜像内预装：

- Node.js
- npm
- pnpm
- OpenClaw
- systemd 服务
- 首次启动初始化脚本
- API 配置脚本
- IPv6 开关脚本

构建完成后会自动发布到 GitHub Releases，可以直接下载 `.tar.gz` 模板并导入 PVE 使用。

---

## 功能特点

- 自动构建 PVE LXC 模板
- 自动安装 OpenClaw
- 不使用 Docker
- OpenClaw 预装在镜像内，创建容器后不再重复下载
- 首次启动自动生成随机端口
- 首次启动自动生成 OpenClaw 管理密码
- 自动显示 LXC 网卡访问地址
- 支持 IPv6 开启 / 关闭 / 首次登录询问
- 支持监听 `0.0.0.0` 或 `::`
- 支持自定义模型 API
- 支持 GitHub Actions 自动发布 Release
- 自动生成 SHA256 校验文件
- 自动生成模板文件列表

---

## 文件说明

Release 中会生成以下文件：

```text
openclaw-lxc-debian12-版本号.tar.gz
openclaw-lxc-debian12-版本号.tar.gz.sha256
openclaw-lxc-debian12-版本号.tar.gz.list
build-info.txt
