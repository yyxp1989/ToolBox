#!/usr/bin/env bash
set -u

# OpenClaw Debian Menu Installer / Operator v2
# 功能：
# 1) 为当前登录用户配置 sudo 免密（方案A，NOPASSWD）
# 2) 安装 Docker
# 3) 当前用户加入 docker 组
# 4) 安装 OpenClaw CLI
# 5) OpenClaw 菜单化运维（网关/doctor/配对等）

VERSION="2.5.1"
LOG_FILE="/tmp/openclaw-menu.log"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
MAGENTA='\033[35m'
NC='\033[0m'

# 必须先定义 TARGET_USER
TARGET_USER="${SUDO_USER:-$USER}"

# 扩展 PATH 确保能找到 sbin 下的系统命令（如 smbd, sshd）
export PATH="$PATH:/usr/sbin:/sbin:/usr/local/sbin"

# SMB 配置（默认路径改为 ~/.openclaw）
SMB_CONF="/etc/samba/smb.conf"
SMB_SHARE_NAME="OpenClawShare"
SMB_DEFAULT_SHARE_PATH="/home/${TARGET_USER}/.openclaw"
SMB_SHARE_PATH_FILE="/home/${TARGET_USER}/.config/openclaw-menu/smb-share-path.conf"

# VNC 配置（使用 TARGET_USER 而非 HOME）
VNC_PASS_FILE="/home/${TARGET_USER}/.vnc/passwd"

# ==================== 通用函数 ====================

log() {
  local msg="$1"
  echo -e "$(date '+%F %T') $msg" | tee -a "$LOG_FILE"
}

ok() {
  echo -e "${GREEN}✅ $1${NC}"
}

warn() {
  echo -e "${YELLOW}⚠️  $1${NC}"
}

err() {
  echo -e "${RED}❌ $1${NC}"
}

info() {
  echo -e "${CYAN}ℹ️  $1${NC}"
}

step() {
  echo -e "${MAGENTA}▶ $1${NC}"
}

pause() {
  read -rp "按回车继续..." _
}

run_cmd() {
  local desc="$1"
  shift
  info "$desc"
  if "$@"; then
    ok "$desc 成功"
    return 0
  else
    err "$desc 失败"
    return 1
  fi
}

run_cmd_retry() {
  local desc="$1"
  local max_retries="$2"
  shift 2
  local retry=0

  while [ $retry -lt $max_retries ]; do
    info "$desc (尝试 $((retry+1))/$max_retries)"
    if "$@"; then
      ok "$desc 成功"
      return 0
    fi
    retry=$((retry+1))
    if [ $retry -lt $max_retries ]; then
      warn "重试中..."
      sleep 2
    fi
  done
  err "$desc 失败（已重试 $max_retries 次）"
  return 1
}

need_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  # 补充检查 sbin 目录（Debian 普通用户 PATH 往往不含 sbin）
  if [ -x "/usr/sbin/$1" ] || [ -x "/sbin/$1" ] || [ -x "/usr/local/sbin/$1" ]; then
    return 0
  fi
  return 1
}

is_root() {
  [ "$(id -u)" -eq 0 ]
}

ensure_root() {
  if is_root; then
    return 0
  fi

  if need_cmd sudo; then
    warn "检测到当前不是 root，将尝试使用 sudo 执行需要提权的操作。"
    return 0
  fi

  err "当前不是 root 且未找到 sudo，无法继续。"
  return 1
}

# ==================== 快捷启动配置 ====================

setup_shortcut() {
  local script_dest="/home/${TARGET_USER}/openclaw-menu.sh"
  local bashrc="/home/${TARGET_USER}/.bashrc"
  
  step "配置快捷启动别名 (alias y)..."
  
  # 1. 保存当前脚本到家目录
  if [ ! -f "$script_dest" ] || [ "$(realpath "$0")" != "$(realpath "$script_dest")" ]; then
    cp "$0" "$script_dest"
    chmod +x "$script_dest"
    ok "脚本已保存至: $script_dest"
  fi

  # 2. 注入别名到 .bashrc
  if grep -q "alias y=" "$bashrc"; then
    # 如果已存在，则更新
    sed -i "s|alias y=.*|alias y='$script_dest'|" "$bashrc"
    ok "快捷别名 'y' 已更新"
  else
    echo "alias y='$script_dest'" >> "$bashrc"
    ok "快捷别名 'y' 已添加"
  fi

  info "配置已完成。请手动执行 'source ~/.bashrc' 或重新登录使别名生效。"
  warn "生效后，你只需在终端输入 'y' 即可启动本菜单。"
}

as_root() {
  if is_root; then
    "$@"
  else
    sudo "$@"
  fi
}

check_debian() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "${ID:-}" != "debian" && "${ID_LIKE:-}" != *"debian"* ]]; then
      warn "当前系统看起来不是 Debian，脚本仍可尝试执行，但可能存在兼容风险。"
    fi
  fi
}

show_status_summary() {
  clear
  echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║        OpenClaw 状态总览               ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
  echo
  
  # 系统信息
  echo -e "${CYAN}【系统信息】${NC}"
  echo "  用户: ${TARGET_USER}"
  echo "  系统: $(. /etc/os-release && echo "${PRETTY_NAME:-$ID}")"
  echo "  内核: $(uname -r)"
  echo "  IP: $(hostname -I | awk '{print $1}')"
  echo
  
  # Docker 状态
  echo -e "${CYAN}【Docker】${NC}"
  if need_cmd docker; then
    echo -e "  ${GREEN}✓${NC} 已安装: $(docker --version 2>/dev/null || echo '未知版本')"
    if systemctl is-active docker >/dev/null 2>&1; then
      echo -e "  ${GREEN}✓${NC} 服务运行中"
    else
      echo -e "  ${YELLOW}!${NC} 服务未运行"
    fi
    if id -nG "$TARGET_USER" 2>/dev/null | grep -qw docker; then
      echo -e "  ${GREEN}✓${NC} 用户已在 docker 组"
    else
      echo -e "  ${YELLOW}!${NC} 用户不在 docker 组"
    fi
  else
    echo -e "  ${RED}✗${NC} 未安装"
  fi
  echo
  
  # OpenClaw 状态
  echo -e "${CYAN}【OpenClaw】${NC}"
  if need_cmd openclaw; then
    echo -e "  ${GREEN}✓${NC} 已安装: $(openclaw --version 2>/dev/null || echo '未知版本')"
    if openclaw gateway status >/dev/null 2>&1; then
      echo -e "  ${GREEN}✓${NC} 网关运行中"
    else
      echo -e "  ${YELLOW}!${NC} 网关未运行"
    fi
  else
    echo -e "  ${RED}✗${NC} 未安装"
  fi
  echo
  
  # Node.js 状态
  echo -e "${CYAN}【Node.js】${NC}"
  if need_cmd node; then
    echo -e "  ${GREEN}✓${NC} 已安装: $(node --version 2>/dev/null || echo '未知版本')"
  else
    echo -e "  ${RED}✗${NC} 未安装"
  fi
  echo

  # SSH 状态
  echo -e "${CYAN}【SSH】${NC}"
  if need_cmd sshd; then
    echo -e "  ${GREEN}✓${NC} 已安装"
    if systemctl is-active ssh >/dev/null 2>&1; then
      echo -e "  ${GREEN}✓${NC} 服务运行中"
    else
      echo -e "  ${YELLOW}!${NC} 服务未运行"
    fi
  else
    echo -e "  ${RED}✗${NC} 未安装"
  fi
  echo

  # VNC 状态
  echo -e "${CYAN}【VNC】${NC}"
  if need_cmd vncserver || need_cmd Xvnc; then
    echo -e "  ${GREEN}✓${NC} 已安装"
    if ss -tlnp 2>/dev/null | grep -q ':5901'; then
      echo -e "  ${GREEN}✓${NC} 服务运行中"
    else
      echo -e "  ${YELLOW}!${NC} 服务未运行"
    fi
  else
    echo -e "  ${RED}✗${NC} 未安装"
  fi
  echo

  # SMB 状态
  echo -e "${CYAN}【SMB/Samba】${NC}"
  if need_cmd smbd; then
    echo -e "  ${GREEN}✓${NC} 已安装"
    if systemctl is-active smbd >/dev/null 2>&1; then
      echo -e "  ${GREEN}✓${NC} 服务运行中"
      local smb_share_path
      smb_share_path=$(get_smb_share_path)
      echo "  共享路径: ${smb_share_path}"
    else
      echo -e "  ${YELLOW}!${NC} 服务未运行"
    fi
  else
    echo -e "  ${RED}✗${NC} 未安装"
  fi
  echo
  
  echo -e "${BLUE}════════════════════════════════════════${NC}"
  pause
}

# ==================== 系统初始化 ====================

configure_nopasswd() {
  ensure_root || return 1

  if [ -z "${TARGET_USER:-}" ]; then
    err "无法识别目标用户。"
    return 1
  fi

  local sudoers_file="/etc/sudoers.d/${TARGET_USER}-nopasswd"
  local line="${TARGET_USER} ALL=(ALL:ALL) NOPASSWD: ALL"

  # 检查是否已配置（sudoers 文件需要 root 读取）
  if as_root test -f "$sudoers_file" && as_root grep -q "$line" "$sudoers_file" 2>/dev/null; then
    ok "用户 ${TARGET_USER} 已配置 sudo 免密。"
    return 0
  fi

  read -rp "将为用户 ${TARGET_USER} 启用 sudo 免密（NOPASSWD），是否继续？[y/N]: " cfm
  if [[ ! "$cfm" =~ ^[Yy]$ ]]; then
    warn "已取消。"
    return 0
  fi

  local tmpf
  tmpf="$(mktemp)"
  echo "$line" > "$tmpf"

  if ! as_root visudo -cf "$tmpf" >/dev/null 2>&1; then
    rm -f "$tmpf"
    err "sudoers 语法校验失败，未写入。"
    return 1
  fi

  if as_root install -m 0440 "$tmpf" "$sudoers_file"; then
    rm -f "$tmpf"
    ok "已写入 $sudoers_file"
    info "从现在开始，${TARGET_USER} 使用 sudo 时将不再需要输入密码。"
  else
    rm -f "$tmpf"
    err "写入 sudoers 文件失败。"
    return 1
  fi
}

# ==================== Node.js 安装 ====================

install_nodejs() {
  ensure_root || return 1

  if need_cmd node; then
    local node_ver
    node_ver=$(node --version 2>/dev/null || echo "未知")
    ok "Node.js 已安装: $node_ver"
    
    # 检查版本是否满足要求 (22.22+)
    local major minor version_str
    version_str=$(node --version 2>/dev/null | tr -d 'v')
    
    if [[ "$version_str" =~ ^([0-9]+)\.([0-9]+) ]]; then
      major="${BASH_REMATCH[1]}"
      minor="${BASH_REMATCH[2]}"
      
      if [ "$major" -ge 24 ] 2>/dev/null || { [ "$major" -eq 22 ] 2>/dev/null && [ "$minor" -ge 22 ] 2>/dev/null; }; then
        ok "Node.js 版本满足要求 (≥22.22)"
        return 0
      else
        warn "Node.js 版本较低，建议升级到 v22.22.0 或更高版本"
        read -rp "是否尝试安装 Node.js 22.x LTS? [y/N]: " cfm
        if [[ ! "$cfm" =~ ^[Yy]$ ]]; then
          return 0
        fi
      fi
    else
      warn "无法解析 Node.js 版本号"
    fi
  fi

  step "开始安装 Node.js 22.x LTS..."
  
  # 使用 NodeSource 仓库
  if curl -fsSL https://deb.nodesource.com/setup_22.x | as_root bash -; then
    ok "NodeSource 仓库添加成功"
  else
    err "NodeSource 仓库添加失败"
    return 1
  fi
  
  run_cmd_retry "安装 Node.js" 3 as_root apt-get install -y nodejs || return 1
  
  if need_cmd node; then
    ok "Node.js 安装完成: $(node --version)"
    ok "npm 版本: $(npm --version)"
  else
    err "Node.js 安装失败"
    return 1
  fi
}

# ==================== pnpm 安装 ====================

install_pnpm() {
  if need_cmd pnpm; then
    ok "pnpm 已安装: $(pnpm --version 2>/dev/null || echo '未知')"
    return 0
  fi

  # 检查 Node.js
  if ! need_cmd node; then
    err "请先安装 Node.js"
    return 1
  fi

  step "安装 pnpm..."

  # 方式 1：corepack（需要提权）
  if need_cmd corepack; then
    info "通过 corepack 启用 pnpm..."
    if as_root corepack enable pnpm 2>/dev/null; then
      corepack prepare pnpm@latest --activate 2>/dev/null || true
      if need_cmd pnpm; then
        # 配置 pnpm 全局目录
        _setup_pnpm_global
        ok "已通过 corepack 安装 pnpm: $(pnpm --version)"
        return 0
      fi
    fi
    warn "corepack 方式失败，尝试 npm 安装..."
  fi

  # 方式 2：npm 全局安装
  run_cmd_retry "npm 安装 pnpm" 3 npm install -g pnpm || return 1

  if need_cmd pnpm; then
    _setup_pnpm_global
    ok "pnpm 安装完成: $(pnpm --version)"
  else
    err "pnpm 安装失败"
    return 1
  fi
}

# 配置 pnpm 全局 bin 目录（解决 ERR_PNPM_NO_GLOBAL_BIN_DIR）
_setup_pnpm_global() {
  need_cmd pnpm || return 1

  # 设置 PNPM_HOME
  local pnpm_home="/home/${TARGET_USER}/.local/share/pnpm"
  mkdir -p "$pnpm_home"
  export PNPM_HOME="$pnpm_home"

  # 显式设置全局 bin 目录 (关键修复)
  pnpm config set global-bin-dir "$pnpm_home" 2>/dev/null || true

  # 运行 pnpm setup
  pnpm setup --force 2>/dev/null || true

  # 确保 PNPM_HOME 在当前 session 的 PATH 中
  if [[ ":$PATH:" != *":${pnpm_home}:"* ]]; then
    export PATH="${pnpm_home}:${PATH}"
  fi

  info "pnpm 全局目录已配置: ${pnpm_home}"
}

# ==================== Docker 安装 ====================

install_docker() {
  ensure_root || return 1

  if need_cmd docker; then
    ok "Docker 已安装：$(docker --version 2>/dev/null || true)"
    return 0
  fi

  run_cmd_retry "更新 apt 索引" 3 as_root apt-get update || return 1
  run_cmd_retry "安装基础依赖" 3 as_root apt-get install -y ca-certificates curl gnupg lsb-release || return 1

  run_cmd "创建 keyrings 目录" as_root install -m 0755 -d /etc/apt/keyrings || return 1

  step "下载 Docker GPG key..."
  if curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
    ok "Docker GPG key 下载成功"
  else
    err "Docker GPG key 下载失败"
    return 1
  fi

  run_cmd "设置 Docker GPG key 权限" as_root chmod a+r /etc/apt/keyrings/docker.gpg || return 1

  local arch codename repo_line
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  repo_line="deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable"

  echo "$repo_line" | as_root tee /etc/apt/sources.list.d/docker.list >/dev/null || { err "写入 Docker apt 源失败"; return 1; }
  ok "Docker apt 源写入成功"
  run_cmd_retry "刷新 apt 索引" 3 as_root apt-get update || return 1

  run_cmd_retry "安装 Docker CE" 3 as_root apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
  run_cmd "启动并设置 Docker 开机自启" as_root systemctl enable --now docker || return 1

  if need_cmd docker; then
    ok "Docker 安装完成：$(docker --version 2>/dev/null || true)"
  else
    err "Docker 安装后仍未检测到 docker 命令。"
    return 1
  fi
}

add_user_to_docker_group() {
  ensure_root || return 1

  if [ -z "${TARGET_USER:-}" ]; then
    err "无法识别目标用户。"
    return 1
  fi

  if ! getent group docker >/dev/null 2>&1; then
    run_cmd "创建 docker 组" as_root groupadd docker || return 1
  fi

  if id -nG "$TARGET_USER" | grep -qw docker; then
    ok "用户 ${TARGET_USER} 已在 docker 组中。"
    return 0
  fi

  run_cmd "将用户 ${TARGET_USER} 添加到 docker 组" as_root usermod -aG docker "$TARGET_USER" || return 1
  warn "组变更通常需要重新登录后生效。你也可以尝试执行：newgrp docker"
}

check_docker_status() {
  echo -e "${BLUE}═══ Docker 状态 ═══${NC}"
  if need_cmd docker; then
    echo "--- docker --version ---"
    docker --version || true
    echo
    echo "--- Docker Compose ---"
    docker compose version 2>/dev/null || docker-compose --version 2>/dev/null || warn "未安装 docker-compose"
  else
    warn "未检测到 docker 命令。"
  fi

  echo
  echo "--- systemctl status docker ---"
  systemctl status docker --no-pager 2>/dev/null || true
}

# ==================== OpenClaw 安装 ====================

install_openclaw() {
  if need_cmd openclaw; then
    local ver
    ver=$(openclaw --version 2>/dev/null || echo "未知")
    ok "OpenClaw 已安装: $ver"
    read -rp "是否重新安装/更新到最新版？[y/N]: " cfm
    if [[ ! "$cfm" =~ ^[Yy]$ ]]; then
      return 0
    fi
  fi

  # 检查 Node.js（要求 v22.22.0+）
  if ! need_cmd node; then
    warn "未检测到 Node.js，将先安装 Node.js..."
    install_nodejs || return 1
  fi

  step "安装 OpenClaw CLI (最新稳定版)..."
  info "推荐安装方式: pnpm (备选: npm)"

  # 优先使用 pnpm
  if need_cmd pnpm; then
    # 确保 pnpm 全局目录已配置
    _setup_pnpm_global 2>/dev/null
    if run_cmd_retry "pnpm 安装 openclaw" 3 pnpm add -g openclaw; then
      need_cmd openclaw && pnpm_installed_oc=true
    else
      warn "pnpm 安装失败，尝试 npm 回退方式..."
    fi
  fi

  if [ "${pnpm_installed_oc:-false}" != "true" ]; then
    if need_cmd npm; then
      warn "使用 npm 安装 openclaw"
      run_cmd_retry "npm 安装 openclaw" 3 npm install -g openclaw || return 1
    else
      err "未检测到 pnpm 或 npm，无法安装"
      return 1
    fi
  fi

  if need_cmd openclaw; then
    ok "OpenClaw 安装完成: $(openclaw --version 2>/dev/null || echo '未知')"
    info "下一步: 主菜单 → OpenClaw安装 → 2) 初始化工作空间"
  else
    err "OpenClaw 安装失败"
    return 1
  fi
}

init_openclaw() {
  if ! need_cmd openclaw; then
    err "请先安装 OpenClaw CLI"
    return 1
  fi

  step "初始化 OpenClaw 配置与工作空间..."
  info "执行: openclaw setup"
  openclaw setup

  echo
  step "运行自检并修复潜在环境冲突..."
  info "执行: openclaw doctor --fix"
  openclaw doctor --fix

  echo
  ok "初始化完成！"
  warn "⚠️  首次进入 Dashboard 时，禁止点击页面上的 'Update' 按钮！"
  info "配置文件路径: ~/.openclaw/config.json"
  info "后续: 启动网关 → openclaw gateway start"
}

onboard_openclaw() {
  if ! need_cmd openclaw; then
    err "请先安装 OpenClaw CLI"
    return 1
  fi

  step "运行 OpenClaw onboarding（旧版向导）..."
  openclaw onboard --install-daemon
}

# ==================== OpenClaw 管理菜单 ====================

ensure_openclaw_installed() {
  if ! need_cmd openclaw; then
    err "未检测到 openclaw 命令，请先安装 OpenClaw CLI。"
    return 1
  fi
  return 0
}

openclaw_install_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== OpenClaw 安装与初始化 =====${NC}"
    echo "1) 安装/更新 OpenClaw CLI (pnpm优先)"
    echo "2) 安装 pnpm 包管理器"
    echo "3) 初始化工作空间 (openclaw setup + doctor --fix)"
    echo "4) 旧版 Onboarding (openclaw onboard --install-daemon)"
    echo "5) 检查 OpenClaw 版本"
    echo "6) ❌ 卸载 OpenClaw"
    echo "0) 返回主菜单"
    read -rp "请选择: " n

    case "$n" in
      1) install_openclaw; pause ;;
      2) install_pnpm; pause ;;
      3) init_openclaw; pause ;;
      4) onboard_openclaw; pause ;;
      5)
        if ensure_openclaw_installed; then
          openclaw --version
        fi
        pause
        ;;
      6) uninstall_openclaw; pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

openclaw_gateway_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== OpenClaw 网关运维 =====${NC}"
    echo "1) 网关状态 (openclaw gateway status)"
    echo "2) 启动网关 (openclaw gateway start)"
    echo "3) 重启网关 (openclaw gateway restart)"
    echo "4) 停止网关 (openclaw gateway stop)"
    echo "5) 查看网关日志 (openclaw logs)"
    echo "6) 打开 Web Dashboard (浏览器)"
    echo "7) 重新安装/配置系统服务 (onboard)"
    echo "0) 返回主菜单"
    read -rp "请选择: " n

    case "$n" in
      1) ensure_openclaw_installed && openclaw gateway status; pause ;;
      2) ensure_openclaw_installed && openclaw gateway start; pause ;;
      3) ensure_openclaw_installed && openclaw gateway restart; pause ;;
      4) ensure_openclaw_installed && openclaw gateway stop; pause ;;
      5) ensure_openclaw_installed && openclaw logs; pause ;;
      6) ensure_openclaw_installed && openclaw dashboard; pause ;;
      7) onboard_openclaw; pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

openclaw_advanced_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== 诊断与高级工具 =====${NC}"
    echo "1) 执行 doctor 诊断"
    echo "2) 自动修复环境 (doctor --fix)"
    echo "3) 安全审计 (security audit)"
    echo "4) 查看模型状态 (models status)"
    echo "5) 管理模型别名 (models aliases)"
    echo "6) 查看/管理配置 (config get/set)"
    echo "7) 查看/维护会话 (sessions)"
    echo "8) 查看渠道日志 (channels logs)"
    echo "9) 🔄 更新 OpenClaw (最新版)"
    echo "0) 返回主菜单"
    read -rp "请选择: " n

    case "$n" in
      1) ensure_openclaw_installed && openclaw doctor; pause ;;
      2) ensure_openclaw_installed && openclaw doctor --fix; pause ;;
      3) ensure_openclaw_installed && openclaw security audit; pause ;;
      4) ensure_openclaw_installed && openclaw models status; pause ;;
      5) ensure_openclaw_installed && openclaw models aliases; pause ;;
      6) ensure_openclaw_installed && openclaw config; pause ;;
      7) ensure_openclaw_installed && openclaw sessions; pause ;;
      8) ensure_openclaw_installed && openclaw channels logs; pause ;;
      9) install_openclaw; pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

openclaw_chat_nodes_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== 聊天与节点管理 =====${NC}"
    echo "--- 配对管理 (Chat/DM) ---"
    echo "1) 查看待配对请求 (pairing list)"
    echo "2) 批准配对 (pairing approve)"
    echo "--- 渠道管理 (Channels) ---"
    echo "3) 查看渠道列表"
    echo "4) 查看渠道状态 (probe 探测)"
    echo "5) 添加渠道账号"
    echo "--- 移动节点 (iOS/Android) ---"
    echo "6) 查看节点状态"
    echo "7) 生成 iOS 配对二维码 (QR)"
    echo "8) 批准节点配对 (node approve)"
    echo "0) 返回主菜单"
    read -rp "请选择: " n

    case "$n" in
      1) ensure_openclaw_installed && openclaw pairing list; pause ;;
      2) 
        ensure_openclaw_installed || { pause; continue; }
        read -rp "请输入 pairing code: " code
        [ -n "$code" ] && openclaw pairing approve "$code"
        pause ;;
      3) ensure_openclaw_installed && openclaw channels list; pause ;;
      4) ensure_openclaw_installed && openclaw channels status --probe; pause ;;
      5) ensure_openclaw_installed && openclaw channels add; pause ;;
      6) ensure_openclaw_installed && openclaw nodes status; pause ;;
      7) ensure_openclaw_installed && openclaw qr; pause ;;
      8)
        ensure_openclaw_installed || { pause; continue; }
        read -rp "请输入节点配对 code: " node_code
        [ -n "$node_code" ] && openclaw nodes approve "$node_code"
        pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

# ==================== Docker 管理 ====================

docker_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== Docker 管理菜单 =====${NC}"
    echo "1) 安装 Docker"
    echo "2) 启动并设开机自启"
    echo "3) 当前用户加入 docker 组"
    echo "4) Docker 状态检查"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1) install_docker; pause ;;
      2) ensure_root && run_cmd "启动并设开机自启" as_root systemctl enable --now docker; pause ;;
      3) add_user_to_docker_group; pause ;;
      4) check_docker_status; pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

# ==================== SSH 管理 ====================

install_ssh() {
  ensure_root || return 1

  if need_cmd sshd; then
    ok "OpenSSH Server 已安装"
    return 0
  fi

  step "安装 OpenSSH Server..."
  run_cmd_retry "安装 openssh-server" 3 as_root apt-get install -y openssh-server || return 1
  run_cmd "启动并设置开机自启" as_root systemctl enable --now ssh || return 1

  if need_cmd sshd; then
    ok "OpenSSH Server 安装完成"
  else
    err "OpenSSH Server 安装失败"
    return 1
  fi
}

start_ssh() {
  ensure_root || return 1
  run_cmd "启动 SSH 服务" as_root systemctl start ssh
}

stop_ssh() {
  ensure_root || return 1
  run_cmd "停止 SSH 服务" as_root systemctl stop ssh
}

restart_ssh() {
  ensure_root || return 1
  run_cmd "重启 SSH 服务" as_root systemctl restart ssh
}

enable_ssh_autostart() {
  ensure_root || return 1
  run_cmd "设置 SSH 开机自启" as_root systemctl enable ssh
}

disable_ssh_autostart() {
  ensure_root || return 1
  run_cmd "禁用 SSH 开机自启" as_root systemctl disable ssh
}

check_ssh_status() {
  echo -e "${BLUE}═══ SSH 状态 ═══${NC}"
  
  if ! need_cmd sshd; then
    warn "OpenSSH Server 未安装"
    return 0
  fi

  echo
  echo "--- 服务状态 ---"
  systemctl status ssh --no-pager 2>/dev/null || true
  
  echo
  echo "--- 监听端口 ---"
  as_root ss -tlnp | grep -E ':22|sshd' || echo "未检测到 SSH 监听端口"
  
  echo
  echo "--- 连接信息 ---"
  local ip
  ip=$(hostname -I | awk '{print $1}')
  echo "  连接命令: ssh ${TARGET_USER}@${ip}"
  
  echo
  echo "--- 配置文件 ---"
  echo "  主配置: /etc/ssh/sshd_config"
}

ssh_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== SSH 管理菜单 =====${NC}"
    echo "1) 安装 OpenSSH Server"
    echo "2) 启动 SSH 服务"
    echo "3) 停止 SSH 服务"
    echo "4) 重启 SSH 服务"
    echo "5) 设置开机自启"
    echo "6) 禁用开机自启"
    echo "7) 查看 SSH 状态"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1) install_ssh; pause ;;
      2) start_ssh; pause ;;
      3) stop_ssh; pause ;;
      4) restart_ssh; pause ;;
      5) enable_ssh_autostart; pause ;;
      6) disable_ssh_autostart; pause ;;
      7) check_ssh_status; pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

# ==================== VNC 管理 ====================

install_vnc() {
  ensure_root || return 1

  # 检查是否已安装 VNC 服务器
  if need_cmd vncserver || need_cmd Xvnc; then
    ok "VNC 服务器已安装"
    return 0
  fi

  step "安装 TigerVNC Server..."
  run_cmd_retry "更新 apt 索引" 3 as_root apt-get update || return 1
  run_cmd_retry "安装 TigerVNC" 3 as_root apt-get install -y tigervnc-standalone-server tigervnc-common || return 1

  # 检查是否需要安装桌面环境
  if ! dpkg -l | grep -q "xfce4\|gnome-shell\|kde-plasma\|lxde"; then
    warn "未检测到桌面环境"
    read -rp "是否安装 XFCE 轻量桌面环境？[y/N]: " cfm
    if [[ "$cfm" =~ ^[Yy]$ ]]; then
      step "安装 XFCE 桌面环境（可能需要较长时间）..."
      run_cmd_retry "安装 XFCE" 3 as_root apt-get install -y xfce4 xfce4-goodies || warn "XFCE 安装失败，VNC 可能无法正常显示桌面"
    fi
  fi

  if need_cmd vncserver || need_cmd Xvnc; then
    ok "VNC 服务器安装完成"
    info "请运行 '配置 VNC 密码' 并 '启动 VNC 服务'"
  else
    err "VNC 服务器安装失败"
    return 1
  fi
}

configure_vnc_password() {
  if ! need_cmd vncserver && ! need_cmd Xvnc; then
    err "请先安装 VNC 服务器"
    return 1
  fi

  local vnc_dir="/home/${TARGET_USER}/.vnc"
  step "配置 VNC 密码..."
  mkdir -p "$vnc_dir"
  
  # 使用 vncpasswd 设置密码
  if vncpasswd 2>/dev/null; then
    ok "VNC 密码配置成功"
    # 连动触发
    read -rp "是否立即重启 VNC 服务以应用新密码？[y/N]: " cfm_restart
    if [[ "$cfm_restart" =~ ^[Yy]$ ]]; then
      restart_vnc
    fi
  else
    err "VNC 密码配置失败"
  fi
}

start_vnc() {
  if ! need_cmd vncserver && ! need_cmd Xvnc; then
    err "请先安装 VNC 服务器"
    return 1
  fi

  if [ ! -f "$VNC_PASS_FILE" ]; then
    err "请先配置 VNC 密码"
    return 1
  fi

  step "启动 VNC 服务器..."
  
  # 创建 xstartup 文件（如果不存在）
  local vnc_dir="/home/${TARGET_USER}/.vnc"
  local xstartup="${vnc_dir}/xstartup"
  if [ ! -f "$xstartup" ]; then
    mkdir -p "$vnc_dir"
    cat > "$xstartup" << 'EOF'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4 2>/dev/null || exec xfce4-session 2>/dev/null || exec gnome-session 2>/dev/null || exec startkde 2>/dev/null || exec startlxde 2>/dev/null || exec xterm
EOF
    chmod +x "$xstartup"
    ok "已创建 xstartup 启动脚本"
  fi

  vncserver :1 -geometry 1920x1080 -depth 24 2>&1
  ok "VNC 服务器已启动"
  
  local ip
  ip=$(hostname -I | awk '{print $1}')
  echo
  info "连接信息:"
  echo "  地址: ${ip}:5901"
  echo "  或: ${ip}:1"
}

stop_vnc() {
  step "停止 VNC 服务器..."
  vncserver -kill :1 2>/dev/null && ok "VNC 服务器已停止" || warn "VNC 服务器可能未运行"
}

restart_vnc() {
  stop_vnc
  sleep 1
  start_vnc
}

list_vnc_sessions() {
  echo -e "${BLUE}═══ VNC 会话列表 ═══${NC}"
  vncserver -list 2>/dev/null || echo "无活动会话"
}

check_vnc_status() {
  echo -e "${BLUE}═══ VNC 状态 ═══${NC}"

  if ! need_cmd vncserver && ! need_cmd Xvnc; then
    warn "VNC 服务器未安装"
    return 0
  fi

  echo
  echo "--- 安装状态 ---"
  ok "TigerVNC 已安装"
  
  echo
  echo "--- 密码配置 ---"
  if [ -f "$VNC_PASS_FILE" ]; then
    ok "VNC 密码已配置"
  else
    warn "VNC 密码未配置"
  fi

  echo
  echo "--- 活动会话 ---"
  vncserver -list 2>/dev/null || echo "无活动会话"

  echo
  echo "--- 监听端口 ---"
  ss -tlnp 2>/dev/null | grep -E ':59[0-9][0-9]' || echo "未检测到 VNC 监听端口"

  echo
  local ip
  ip=$(hostname -I | awk '{print $1}')
  echo "--- 连接信息 ---"
  echo "  默认地址: ${ip}:5901 (显示号 :1)"
  echo "  配置文件: /home/${TARGET_USER}/.vnc/"
  echo "  启动脚本: /home/${TARGET_USER}/.vnc/xstartup"
}

vnc_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== VNC 管理菜单 =====${NC}"
    echo "1) 安装 VNC 服务器 (TigerVNC)"
    echo "2) 配置 VNC 密码"
    echo "3) 启动 VNC 服务"
    echo "4) 停止 VNC 服务"
    echo "5) 重启 VNC 服务"
    echo "6) 查看活动会话"
    echo "7) 查看 VNC 状态"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1) install_vnc; pause ;;
      2) configure_vnc_password; pause ;;
      3) start_vnc; pause ;;
      4) stop_vnc; pause ;;
      5) restart_vnc; pause ;;
      6) list_vnc_sessions; pause ;;
      7) check_vnc_status; pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

# ==================== 远程访问菜单 ====================

remote_access_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== 远程访问菜单 =====${NC}"
    echo "1) SSH 管理"
    echo "2) VNC 管理"
    echo "3) 远程访问状态总览"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1) ssh_menu ;;
      2) vnc_menu ;;
      3) 
        show_remote_status
        pause
        ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

show_remote_status() {
  clear
  echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║        远程访问状态总览                ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
  echo

  local ip
  ip=$(hostname -I | awk '{print $1}')
  
  # SSH 状态
  echo -e "${CYAN}【SSH】${NC}"
  if need_cmd sshd; then
    echo -e "  ${GREEN}✓${NC} OpenSSH Server 已安装"
    if systemctl is-active ssh >/dev/null 2>&1; then
      echo -e "  ${GREEN}✓${NC} 服务运行中"
      echo "  连接命令: ssh ${TARGET_USER}@${ip}"
    else
      echo -e "  ${YELLOW}!${NC} 服务未运行"
    fi
  else
    echo -e "  ${RED}✗${NC} 未安装"
  fi
  echo

  # VNC 状态
  echo -e "${CYAN}【VNC】${NC}"
  if need_cmd vncserver || need_cmd Xvnc; then
    echo -e "  ${GREEN}✓${NC} TigerVNC 已安装"
    if [ -f "$VNC_PASS_FILE" ]; then
      echo -e "  ${GREEN}✓${NC} 密码已配置"
    else
      echo -e "  ${YELLOW}!${NC} 密码未配置"
    fi
    if ss -tlnp 2>/dev/null | grep -q ':5901'; then
      echo -e "  ${GREEN}✓${NC} 服务运行中 (:1)"
      echo "  连接地址: ${ip}:5901"
    else
      echo -e "  ${YELLOW}!${NC} 服务未运行"
    fi
  else
    echo -e "  ${RED}✗${NC} 未安装"
  fi
  echo

  # 网络信息
  echo -e "${CYAN}【网络信息】${NC}"
  echo "  主机名: $(hostname)"
  echo "  IP 地址: ${ip}"
  echo "  所有 IP: $(hostname -I)"
  echo
  
  echo -e "${BLUE}════════════════════════════════════════${NC}"
}

# ==================== SMB 管理 ====================

get_smb_share_path() {
  local path
  
  # 从配置文件读取
  if [ -f "$SMB_SHARE_PATH_FILE" ]; then
    path=$(cat "$SMB_SHARE_PATH_FILE" 2>/dev/null)
    if [ -n "$path" ]; then
      echo "$path"
      return
    fi
  fi
  
  # 返回默认路径
  echo "$SMB_DEFAULT_SHARE_PATH"
}

set_smb_share_path() {
  local current_path
  current_path=$(get_smb_share_path)
  
  echo -e "${BLUE}═══ 配置 SMB 共享路径 ═══${NC}"
  echo "当前共享路径: ${current_path}"
  echo
  read -rp "请输入新的共享路径（直接回车保持当前）: " new_path
  
  if [ -z "${new_path:-}" ]; then
    info "保持当前路径: ${current_path}"
    return 0
  fi
  
  # 安全展开 ~ 为用户 home 目录（避免 eval 命令注入）
  new_path="${new_path/#\~//home/${TARGET_USER}}"
  
  # 验证路径安全性
  if [[ "$new_path" == *'$('* ]] || [[ "$new_path" == *'`'* ]]; then
    err "路径包含不允许的字符"
    return 1
  fi
  
  # 创建配置目录
  mkdir -p "$(dirname "$SMB_SHARE_PATH_FILE")"
  
  # 保存路径
  echo "$new_path" > "$SMB_SHARE_PATH_FILE"
  ok "已保存共享路径: ${new_path}"
  
  # 询问是否创建目录
  if [ ! -d "$new_path" ]; then
    read -rp "目录不存在，是否创建？[y/N]: " cfm
    if [[ "$cfm" =~ ^[Yy]$ ]]; then
      mkdir -p "$new_path"
      ok "已创建目录: ${new_path}"
    fi
  fi

  # 连动触发：询问是否立即写入配置
  read -rp "是否立即将新路径应用到 Samba 配置文件？[y/N]: " cfm_apply
  if [[ "$cfm_apply" =~ ^[Yy]$ ]]; then
    configure_smb_share
  fi
}

install_smb() {
  ensure_root || return 1

  if need_cmd smbd; then
    ok "Samba 已安装"
    return 0
  fi

  step "安装 Samba..."
  run_cmd_retry "更新 apt 索引" 3 as_root apt-get update || return 1
  run_cmd_retry "安装 Samba" 3 as_root apt-get install -y samba samba-common-bin || return 1

  if need_cmd smbd; then
    ok "Samba 安装完成"
    info "请配置共享路径并设置 Samba 密码"
  else
    err "Samba 安装失败"
    return 1
  fi
}

configure_smb_user() {
  ensure_root || return 1

  if ! need_cmd smbd; then
    err "请先安装 Samba"
    return 1
  fi

  step "为当前用户 ${TARGET_USER} 配置 Samba 密码..."
  info "注意：Samba 密码可以与系统密码不同"
  
  # 添加 Samba 用户
  if as_root smbpasswd -a "$TARGET_USER"; then
    ok "Samba 用户 ${TARGET_USER} 配置成功"
    # 连动触发
    read -rp "是否立即重启 Samba 服务以应用新用户配置？[y/N]: " cfm_restart
    if [[ "$cfm_restart" =~ ^[Yy]$ ]]; then
      restart_smb
    fi
  else
    err "Samba 用户配置失败"
    return 1
  fi
}

configure_smb_share() {
  ensure_root || return 1

  if ! need_cmd smbd; then
    err "请先安装 Samba"
    return 1
  fi

  local share_path
  share_path=$(get_smb_share_path)
  
  step "配置 Samba 共享..."
  echo "共享名称: ${SMB_SHARE_NAME}"
  echo "共享路径: ${share_path}"
  echo "访问用户: ${TARGET_USER}"
  echo
  
  read -rp "确认配置？[y/N]: " cfm
  if [[ ! "$cfm" =~ ^[Yy]$ ]]; then
    warn "已取消"
    return 0
  fi

  # 关键修复：确保父目录有执行权限，否则 Windows 无法访问隐藏文件夹
  as_root chmod 755 "/home/${TARGET_USER}" 2>/dev/null || true

  # 创建共享目录
  if [ ! -d "$share_path" ]; then
    mkdir -p "$share_path"
    ok "已创建共享目录: ${share_path}"
  fi

  # 设置权限
  chown -R "${TARGET_USER}:${TARGET_USER}" "$share_path"
  chmod -R 755 "$share_path"

  # 备份原配置
  if [ -f "$SMB_CONF" ]; then
    cp "$SMB_CONF" "${SMB_CONF}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  # 检查是否已存在该共享配置
  if grep -q "^\[${SMB_SHARE_NAME}\]" "$SMB_CONF" 2>/dev/null; then
    warn "共享配置已存在，将更新配置"
    # 安全删除旧的共享配置块（使用 awk 更可靠）
    local tmp_conf
    tmp_conf=$(mktemp)
    awk -v share="${SMB_SHARE_NAME}" '
      $0 == "["share"]" { in_share=1; next }
      /^\[/ { in_share=0 }
      !in_share { print }
    ' "$SMB_CONF" > "$tmp_conf" && as_root mv "$tmp_conf" "$SMB_CONF"
  fi

  # 添加共享配置（需要 root 权限写入 /etc/samba/smb.conf）
  as_root tee -a "$SMB_CONF" >/dev/null << EOF

[${SMB_SHARE_NAME}]
   comment = OpenClaw SMB Share
   path = ${share_path}
   browseable = yes
   read only = no
   create mask = 0755
   directory mask = 0755
   valid users = ${TARGET_USER}
   force user = ${TARGET_USER}
   force group = ${TARGET_USER}
   public = no
   writable = yes
EOF

  ok "Samba 共享配置已写入 ${SMB_CONF}"
  
  # 测试配置
  if as_root testparm -s 2>/dev/null | grep -q "\[${SMB_SHARE_NAME}\]"; then
    ok "配置语法检查通过"
  else
    warn "配置可能存在问题，请检查 ${SMB_CONF}"
  fi

  # 连动触发：询问是否立即重启服务
  read -rp "是否立即重启 Samba 服务以生效？[y/N]: " cfm_restart
  if [[ "$cfm_restart" =~ ^[Yy]$ ]]; then
    restart_smb
  fi
}

start_smb() {
  ensure_root || return 1

  if ! need_cmd smbd; then
    err "请先安装 Samba"
    return 1
  fi

  run_cmd "启动 Samba 服务" as_root systemctl start smbd nmbd
}

stop_smb() {
  ensure_root || return 1
  run_cmd "停止 Samba 服务" as_root systemctl stop smbd nmbd
}

restart_smb() {
  ensure_root || return 1
  run_cmd "重启 Samba 服务" as_root systemctl restart smbd nmbd
}

enable_smb_autostart() {
  ensure_root || return 1
  run_cmd "设置 Samba 开机自启" as_root systemctl enable smbd nmbd
}

disable_smb_autostart() {
  ensure_root || return 1
  run_cmd "禁用 Samba 开机自启" as_root systemctl disable smbd nmbd
}

check_smb_status() {
  echo -e "${BLUE}═══ Samba 状态 ═══${NC}"

  if ! need_cmd smbd; then
    warn "Samba 未安装"
    return 0
  fi

  echo
  echo "--- 服务状态 ---"
  systemctl status smbd --no-pager 2>/dev/null | head -10 || true
  
  echo
  echo "--- 共享配置 ---"
  as_root testparm -s 2>/dev/null | grep -A 20 "Share Definitions" || true

  echo
  local share_path
  share_path=$(get_smb_share_path)
  echo "--- 共享信息 ---"
  echo "  共享名称: ${SMB_SHARE_NAME}"
  echo "  共享路径: ${share_path}"
  echo "  访问用户: ${TARGET_USER}"
  
  echo
  local ip
  ip=$(hostname -I | awk '{print $1}')
  echo "--- 连接信息 ---"
  echo "  Windows: \\\\${ip}\\${SMB_SHARE_NAME}"
  echo "  macOS: smb://${ip}/${SMB_SHARE_NAME}"
  echo "  Linux: smb://${ip}/${SMB_SHARE_NAME}"
}

smb_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== SMB 共享管理菜单 =====${NC}"
    local share_path
    share_path=$(get_smb_share_path)
    echo "当前共享路径: ${share_path}"
    echo
    echo "1) 安装 Samba"
    echo "2) 配置共享路径"
    echo "3) 配置 Samba 用户密码"
    echo "4) 配置共享（写入配置文件）"
    echo "5) 启动 Samba 服务"
    echo "6) 停止 Samba 服务"
    echo "7) 重启 Samba 服务"
    echo "8) 设置开机自启"
    echo "9) 禁用开机自启"
    echo "10) 查看 Samba 状态"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1) install_smb; pause ;;
      2) set_smb_share_path; pause ;;
      3) configure_smb_user; pause ;;
      4) configure_smb_share; pause ;;
      5) start_smb; pause ;;
      6) stop_smb; pause ;;
      7) restart_smb; pause ;;
      8) enable_smb_autostart; pause ;;
      9) disable_smb_autostart; pause ;;
      10) check_smb_status; pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

# ==================== 文件共享菜单 ====================

file_share_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== 文件共享菜单 =====${NC}"
    echo "1) SMB 共享管理"
    echo "2) 文件共享状态总览"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1) smb_menu ;;
      2) 
        show_fileshare_status
        pause
        ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

show_fileshare_status() {
  clear
  echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║        文件共享状态总览                ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
  echo

  local ip
  ip=$(hostname -I | awk '{print $1}')

  # SMB 状态
  echo -e "${CYAN}【SMB/Samba】${NC}"
  if need_cmd smbd; then
    echo -e "  ${GREEN}✓${NC} Samba 已安装"
    if systemctl is-active smbd >/dev/null 2>&1; then
      echo -e "  ${GREEN}✓${NC} 服务运行中"
      local share_path
      share_path=$(get_smb_share_path)
      echo "  共享路径: ${share_path}"
      echo
      echo "  连接方式:"
      echo "    Windows: \\\\${ip}\\${SMB_SHARE_NAME}"
      echo "    macOS: smb://${ip}/${SMB_SHARE_NAME}"
      echo "    Linux: smb://${ip}/${SMB_SHARE_NAME}"
    else
      echo -e "  ${YELLOW}!${NC} 服务未运行"
    fi
  else
    echo -e "  ${RED}✗${NC} 未安装"
  fi
  echo
  
  echo -e "${BLUE}════════════════════════════════════════${NC}"
}

uninstall_openclaw() {
  warn "此操作将从系统中移除 OpenClaw。"
  read -rp "确认卸载 OpenClaw？[y/N]: " cfm
  if [[ ! "$cfm" =~ ^[Yy]$ ]]; then
    return 0
  fi

  step "1. 正在停止并卸载系统服务..."
  as_root systemctl stop openclaw 2>/dev/null || true
  as_root systemctl disable openclaw 2>/dev/null || true
  as_root rm -f /etc/systemd/system/openclaw.service 2>/dev/null || true
  as_root systemctl daemon-reload

  step "2. 正在移除全局包..."
  if need_cmd pnpm; then
    pnpm remove -g openclaw 2>/dev/null
  fi
  if need_cmd npm; then
    npm uninstall -g openclaw 2>/dev/null
  fi

  step "3. 清理配置选项..."
  read -rp "是否删除所有配置文件、数据库和工作空间 (~/.openclaw)？[y/N]: " cfm_clean
  if [[ "$cfm_clean" =~ ^[Yy]$ ]]; then
    rm -rf "/home/${TARGET_USER}/.openclaw"
    ok "配置已完全清理"
  fi

  ok "OpenClaw 卸载完成"
}

# ==================== 系统环境菜单 ====================

system_env_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== 系统环境管理 =====${NC}"
    echo "1) 配置 sudo 免密 (方案A)"
    echo "2) 配置快捷启动别名 (alias y)"
    echo "3) Docker 管理"
    echo "4) SSH 管理"
    echo "5) VNC 管理"
    echo "6) SMB 共享管理"
    echo "0) 返回主菜单"
    read -rp "请选择: " n

    case "$n" in
      1) configure_nopasswd; pause ;;
      2) setup_shortcut; pause ;;
      3) docker_menu ;;
      4) ssh_menu ;;
      5) vnc_menu ;;
      6) smb_menu ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

# ==================== 一键初始化 ====================

full_init() {
  clear
  echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║        系统一键初始化                  ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
  echo
  warn "此操作将依次执行："
  echo "  1. 配置 sudo 免密"
  echo "  2. 配置快捷启动别名 (alias y)"
  echo "  3. 安装 Node.js (v22.22+)"
  echo "  4. 安装 pnpm 包管理器"
  echo "  5. 安装 Docker"
  echo "  6. 用户加入 docker 组"
  echo "  7. 安装并引导配置 OpenClaw (setup + doctor + onboard)"
  echo
  read -rp "确认执行一键初始化？[y/N]: " cfm
  if [[ ! "$cfm" =~ ^[Yy]$ ]]; then
    warn "已取消"
    return 0
  fi

  local failed=0

  step "[1/7] 配置 sudo 免密..."
  configure_nopasswd || { warn "sudo 免密配置失败，继续..."; failed=$((failed+1)); }

  step "[2/7] 配置快捷启动别名..."
  setup_shortcut || { warn "别名配置失败，继续..."; failed=$((failed+1)); }

  step "[3/7] 安装 Node.js..."
  install_nodejs || { warn "Node.js 安装失败，继续..."; failed=$((failed+1)); }

  step "[4/7] 安装 pnpm..."
  install_pnpm || { warn "pnpm 安装失败，继续..."; failed=$((failed+1)); }

  step "[5/7] 安装 Docker..."
  install_docker || { warn "Docker 安装失败，继续..."; failed=$((failed+1)); }

  step "[6/7] 用户加入 docker 组..."
  add_user_to_docker_group || { warn "添加用户到 docker 组失败，继续..."; failed=$((failed+1)); }

  step "[7/7] 安装并引导配置 OpenClaw..."
  if install_openclaw; then
    init_openclaw
    echo
    step "启动交互式配置向导..."
    info "请在接下来的提示中配置模型、渠道，并在最后一步选 'Yes' 安装系统服务。"
    onboard_openclaw
  else
    warn "OpenClaw 安装失败"; failed=$((failed+1))
  fi

  echo
  echo -e "${BLUE}════════════════════════════════════════${NC}"
  if [ $failed -eq 0 ]; then
    ok "一键初始化完成，全部成功！"
  else
    warn "一键初始化完成，有 $failed 个步骤失败，请检查日志: $LOG_FILE"
  fi
  echo -e "${BLUE}════════════════════════════════════════${NC}"
  pause
}

# ==================== 主菜单 ====================

main_menu() {
  check_debian
  while true; do
    clear
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║    Debian OpenClaw 一键菜单 v${VERSION}      ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo "当前用户: ${TARGET_USER}"
    echo "日志文件: ${LOG_FILE}"
    echo
    echo "1) 🚀 系统一键初始化"
    echo "   (sudo免密 + Alias别名 + Node + Docker + OpenClaw安装与配置)"
    echo "2) 🔧 系统环境管理 (Alias/Docker/SSH/VNC/SMB)"
    echo "3) 🦞 OpenClaw 安装与初始化"
    echo "4) 🌐 OpenClaw 网关运维 (启动/重启/日志/Dashboard)"
    echo "5) 📱 聊天与节点管理 (配对/渠道/iOS/二维码)"
    echo "6) 🛠️ 诊断与高级工具 (Doctor/修复/审计/模型/更新)"
    echo "7) 📊 状态总览"
    echo "0) 🚪 退出"
    read -rp "请选择: " n

    case "$n" in
      1) full_init ;;
      2) system_env_menu ;;
      3) openclaw_install_menu ;;
      4) openclaw_gateway_menu ;;
      5) openclaw_chat_nodes_menu ;;
      6) openclaw_advanced_menu ;;
      7) show_status_summary ;;
      0)
        info "已退出。"
        exit 0
        ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

main_menu
