# OpenClaw Debian Menu

> Debian 系统 OpenClaw 一键安装与运维菜单脚本

## 版本

**当前版本**: v2.7.0

## 功能特性

- 🚀 系统一键初始化（sudo免密 + Docker + Node.js + OpenClaw）
- 🔧 系统环境管理（SSH/VNC/SMB/Docker）
- 🦞 OpenClaw 安装与配置
- 🌐 网关运维（启动/停止/日志/Dashboard）
- 📱 聊天与节点管理
- 🛠️ 诊断与高级工具

## 快速开始

```bash
# 下载脚本
wget https://raw.githubusercontent.com/yyxp1989/ToolBox/main/openclaw-debian-menu/openclaw-debian-menu.sh

# 添加执行权限
chmod +x openclaw-debian-menu.sh

# 运行
./openclaw-debian-menu.sh
```

## 安全特性 (v2.7.0)

- ✅ 防环境变量注入
- ✅ 防路径穿越攻击
- ✅ 防命令注入
- ✅ 防符号链接攻击
- ✅ 原子文件写入

## 更新日志

详见 [CHANGELOG.md](CHANGELOG.md)

## 许可证

MIT License
