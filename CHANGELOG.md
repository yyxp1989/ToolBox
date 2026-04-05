# Changelog

All notable changes to `OpenClaw ToolBox` will be documented in this file.

## v3.0.0

### Added

- 新增面向 `Debian / WSL Debian` 的 `OpenClaw ToolBox` 发布版 README
- 新增 `CLI Proxy API` 的 `Linux/systemd` 与 `Docker` 双模式识别和管理
- 新增 `CLI Proxy API` 配置路径自动识别
- 新增 `CLI Proxy API` 模型一键接入 `OpenClaw`
- 新增 `Agent Tool` 一键权限设置
- 新增 `TigerVNC + XFCE` 的 Debian 系统服务管理
- 新增 `Samba` 共享 `~/.openclaw` 的菜单化管理
- 新增 `whiptail` 单选 / 多选交互，并支持缺失时自动安装

### Changed

- 工具箱版本统一为 `v3.0.0`
- 主菜单改为运维面板风格，顶部直接显示关键状态
- 菜单结构重组为：
  - 一键部署 OpenClaw
  - OpenClaw 部署管理
  - 系统环境与依赖
  - 网关与服务运维
- `OpenClaw 业务配置` 重新聚合模型、频道、节点、权限配置
- `Agent 模型管理` 拆分为主模型单选与 Fallback 多选
- `供应商模型管理` 统一为更清晰的同步 / 删除逻辑
- `环境配套` 更名为 `系统环境与依赖`
- `Agent Tool 权限 / Approvals` 更名为 `Agent Tool 工具权限审批策略`
- 主菜单和环境页状态检测做了轻量化，减少卡顿

### Notes

- 当前版本主要面向 `Debian / WSL Debian`
