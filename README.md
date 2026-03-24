# OpenClaw ToolBox 🦞

针对 Debian 系统深度优化的 OpenClaw 一键部署与全能运维脚本。集成了系统初始化、Docker 环境、OpenClaw 运维、远程访问及文件共享等功能。

---

## 🚀 快速开始

在终端中执行以下一行命令，即可完成**下载、赋权、配置快捷别名**并启动：

```bash
curl -fsSL https://raw.githubusercontent.com/yyxp1989/ToolBox/main/openclaw-debian-menu.sh -o ~/openclaw-menu.sh && chmod +x ~/openclaw-menu.sh && echo "alias y='~/openclaw-menu.sh'" >> ~/.bashrc && source ~/.bashrc && ~/openclaw-menu.sh
```

### 快捷启动
安装完成后，以后在任何地方只需输入一个字母即可进入菜单：
```bash
y
```

---

## 🛠️ 核心功能

### 1. ⚡ 系统一键初始化
按顺序自动完成：配置 sudo 免密、设置别名、安装 Node.js (v22.22+)、安装 pnpm、安装 Docker、配置用户组、安装 OpenClaw CLI。

### 2. 🦞 OpenClaw 全能运维
- **网关管理**：状态查看、一键重启、日志追踪、`onboard` 服务重装。
- **诊断修复**：执行 `doctor` 诊断、`--fix` 环境自动修复、渠道探测。
- **配对管理**：Secure DM 配对审批、渠道账号增删、状态查看。
- **工具集成**：一键打开 Web Dashboard、模型配置、会话清理、安全审计。
- **移动节点**：iOS/Android 节点配对、生成配对二维码（QR）。

### 3. 🔐 远程访问 (SSH/VNC)
- **SSH**：一键安装服务、端口状态检测、开机自启配置。
- **VNC**：TigerVNC 自动化部署、XFCE 轻量桌面可选安装、xstartup 自动配置。

### 4. 📁 文件共享 (SMB)
- **极简配置**：一键安装 Samba 并配置当前用户共享。
- **灵活路径**：默认共享 `~/.openclaw`（方便远程修改配置），支持自定义路径。
- **全平台支持**：自动输出 Windows/macOS/Linux 的连接地址。

---

## 📂 菜单结构预览

```text
1) 🚀 系统一键初始化 (sudo免密 + Alias别名 + Node + Docker + OpenClaw)
2) 🔧 配置 sudo 免密 (方案A - NOPASSWD)
3) 🐳 Docker 管理 (安装/加组/状态检查)
4) 🦞 OpenClaw 安装 (pnpm优先/工作空间初始化)
5) 🌐 OpenClaw 网关 (启动/重启/日志/服务重装)
6) 🏥 OpenClaw 诊断与修复 (doctor --fix/渠道日志)
7) 📱 Chat/配对管理 (审批/渠道列表)
8) 🔧 OpenClaw 工具 (Dashboard/模型/更新)
9) 📱 节点管理 (iOS/Android 配对/二维码)
10) 🔐 远程访问 (SSH/VNC 管理)
11) 📁 文件共享 (SMB 共享配置)
12) 📊 状态总览 (系统全状态一览)
0) 🚪 退出
```

---

## ⚠️ 注意事项

- **Node.js 版本**：脚本强制检查并支持安装 v22.22.0+，以满足最新版 OpenClaw 要求。
- **Dashboard 避坑**：安装完成后，首次进入 Web UI 时，**禁止**点击页面上的 "Update" 按钮，请通过本脚本的菜单进行更新。
- **权限说明**：修改系统配置（如 sudoers, smb.conf）时会申请临时 sudo 权限，建议首选执行“系统一键初始化”。

---

## 📄 开源协议
[MIT License](LICENSE)
