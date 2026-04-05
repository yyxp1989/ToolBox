# OpenClaw ToolBox

OpenClaw ToolBox 是一个面向 Debian / WSL Debian 的 `OpenClaw` 一体化部署与运维菜单脚本。

它的目标很简单：

- 把 `OpenClaw` 的安装、初始化、业务配置、网关运维集中到一个菜单里
- 把 `Node.js`、`pnpm`、`Docker`、`CLI Proxy API`、`VNC`、`Samba` 这些常见配套环境一起收口
- 尽量减少手工记忆 CLI 命令，优先通过菜单选择完成配置

当前工具箱版本：`v3.0.0`

作者：`YY`  
GitHub：[@yyxp1989/ToolBox](https://github.com/yyxp1989/ToolBox)

## 界面预览

建议在 GitHub 发布前补充 1 到 3 张截图，放在仓库中例如：

- `docs/images/main-menu.png`
- `docs/images/model-management.png`
- `docs/images/gateway-ops.png`

推荐展示页面：

- 主菜单总览
- 模型与供应商配置
- 网关与服务运维

## 适用场景

- 在 `Debian / WSL Debian` 上首次部署 `OpenClaw`
- 需要长期维护 `OpenClaw` 网关、系统服务和模型配置
- 使用 `CLI Proxy API` 作为本地模型聚合入口
- 希望通过菜单方式完成常见运维，而不是反复手敲命令

## 主要功能

### 1. 一键部署 OpenClaw

- 安装和修复 `pnpm`
- 安装 / 更新 `OpenClaw`
- 执行官方初始化流程
- 自动校验部署结果并尝试修复常见环境问题

### 2. OpenClaw 部署管理

- 安装 / 更新 / 卸载 `OpenClaw`
- 打开官方配置向导 `openclaw configure`
- 修复 `OpenClaw` 系统服务
- 执行部署健康检查和自动修复

### 3. OpenClaw 业务配置

- 自定义模型 / 供应商配置
- 一键接入 `CLI Proxy API` 模型
- Agent 主模型与 Fallback 配置
- 聊天与节点管理
- Agent Tool 工具权限审批策略

### 4. 系统环境与依赖

- `Node.js`
- `pnpm`
- `Docker`
- `CLI Proxy API`
- `VNC`
- `SSH / Samba 文件共享`

### 5. 网关与服务运维

- 查看网关状态
- 重启网关
- `doctor --fix`
- Dashboard / 日志
- 修复 OpenClaw 系统服务

## 菜单设计原则

- 主菜单顶部直接显示关键状态，不让用户重复点进去看版本
- 修改已有配置时，优先“读取当前值并选择”，尽量避免让用户手工回忆输入
- 高风险删除操作需要多次确认
- 在 Debian 环境中优先使用 `whiptail` 提供更友好的单选 / 多选界面
- 若 `whiptail` 缺失，脚本会自动安装；非 Debian 环境则自动回退文本交互

## 当前支持的重点能力

### CLI Proxy API

- 同时识别 `Docker` 部署和 `Linux/systemd` 部署
- 自动识别已有安装的真实配置路径
- 全新安装时自动生成最小可用配置
- 支持从 `CLI Proxy API` 读取模型列表并写入 `OpenClaw`

### 模型管理

- 从供应商接口同步模型到 `OpenClaw`
- 从 `OpenClaw` 删除已配置的供应商模型
- 用颜色区分“已存在 / 可新增 / 不可删除”
- Agent 主模型单选、Fallback 多选

### Agent Tool 权限

支持一键执行：

```bash
openclaw config set tools.exec.security full
openclaw config set tools.exec.ask off
openclaw config set tools.exec.strictInlineEval false
openclaw config validate
```

## 运行环境建议

- Debian 12/13
- WSL2 Debian
- 已安装 `sudo`
- 可联网安装依赖

## 使用方式

将脚本放到目标 Debian 用户目录，例如：

```bash
/home/dd/openclaw-menu.sh
```

赋予执行权限后运行：

```bash
chmod +x /home/dd/openclaw-menu.sh
/home/dd/openclaw-menu.sh
```

脚本也支持配置快捷别名：

```bash
y
```

## 推荐使用流程

### 首次部署

1. 打开 `一键部署 OpenClaw`
2. 完成官方初始化
3. 进入 `系统环境与依赖` 检查 `Node.js / pnpm / Docker / CLI Proxy API`
4. 进入 `OpenClaw 业务配置 -> 自定义模型`
5. 接入 `CLI Proxy API` 或其他自定义供应商模型

### 日常运维

1. 主菜单直接查看顶部状态
2. 通过快捷操作查看网关状态 / 重启网关 / 执行 `doctor --fix`
3. 在 `网关与服务运维` 中处理日志、服务与修复

## 注意事项

- 本工具箱当前主要面向 `Debian / WSL Debian`
- 某些功能依赖目标系统已具备 `sudo` 能力
- `OpenClaw`、`CLI Proxy API`、`Docker` 等第三方组件的具体行为以其官方文档为准
- 删除 `~/.openclaw` 这类高风险操作已加入多次确认，但仍建议提前备份重要配置

## 仓库定位

这个仓库更适合作为：

- `OpenClaw` Debian 运维脚本仓库
- 个人 / 团队内部部署工具箱
- 面向 WSL Debian 用户的落地菜单化运维工具

如果后续继续演进，建议下一步加入：

- 发布说明与变更日志
- 截图展示
- 常见问题 FAQ
- 发行版安装脚本

## 更新日志

详细版本记录见：

- [CHANGELOG.md](./CHANGELOG.md)
