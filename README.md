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

### 1. ⚡ 系统一键初始化 (7步流)
按顺序自动完成：配置 sudo 免密、设置别名、安装 Node.js (v22.22+)、安装 pnpm、安装 Docker、配置用户组、**安装 OpenClaw 并引导交互式配置 (Onboarding)**。

### 2. 🦞 OpenClaw 全能运维
- **快捷入口**：主菜单直达 **🔄一键重启网关** 与 **💬进入 TUI 聊天界面**。
- **网关管理**：状态查看、日志追踪、`onboard` 服务重置、Dashboard 一键打开。
- **安装卸载**：支持 `pnpm` 优先安装，提供 **❌完全卸载** 选项（支持清理工作区）。
- **诊断工具**：集成了 `doctor --fix` 自动修复、安全审计、模型状态管理、配置查看。
- **配对管理**：Secure DM 配对、渠道账号增删、iOS/Android 移动节点 QR 码生成。

### 3. 🔐 系统环境管理
- **系统工具**：sudo 免密配置、别名设置、Docker 环境一键部署。
- **远程访问**：SSH 服务一键开关、VNC 服务（带 XFCE 桌面）自动化配置。

### 4. 📁 文件共享 (SMB)
- **专为 OpenClaw 优化**：默认共享路径为 `~/.openclaw`，方便你在 Windows/macOS 上直接远程修改配置文件。
- **自动修复**：配置时自动修复父目录权限，解决隐藏文件夹访问无效的问题。

---

## 📂 菜单结构预览 (v2.5.4)

```text
1) 🚀 系统一键初始化 (自动化 7 步全家桶)
2) 🔧 系统环境管理 (Alias/Docker/SSH/VNC/SMB)
3) 🦞 OpenClaw 安装与初始化 (安装/卸载/引导配置)
4) 🌐 OpenClaw 网关运维 (启动/日志/Dashboard)
5) 📱 聊天与节点管理 (配对/渠道/iOS节点/二维码)
6) 🛠️ 诊断与高级工具 (Doctor/修复/审计/模型/更新)
------------------------------------------
7) 🔄 一键重启网关 (快捷入口)
8) 💬 进入 TUI 聊天界面 (快捷入口)
9) 📊 状态总览
0) 🚪 退出
```

---

## ⚠️ 注意事项

- **Node.js 版本**：脚本强制支持 v22.22.0+，满足最新版 OpenClaw 运行要求。
- **Dashboard 避坑**：安装完成后，首次进入 Web UI 时，**禁止**点击页面上的 "Update" 按钮，请通过脚本菜单进行系统维护。
- **权限安全**：修改关键系统配置时会调用 sudo，建议在首次使用时通过“一键初始化”完成基础授权。

---

## 📄 开源协议
[MIT License](LICENSE)
