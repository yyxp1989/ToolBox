#!/usr/bin/env bash
set -u
set -o pipefail

# OpenClaw Debian Menu Installer / Operator v3
# 作者: YY
# GitHub: yyxp1989/ToolBox
# 仓库: https://github.com/yyxp1989/ToolBox
# 
# 功能：
# 1) 为当前登录用户配置 sudo 免密（方案A，NOPASSWD）
# 2) 安装 Docker / SSH / SMB 等系统依赖
# 3) 安装与部署 OpenClaw CLI
# 4) 部署后常用 CLI 配置（模型、供应商、approvals）
# 5) OpenClaw 菜单化日常运维（网关/doctor/配对等）

TOOLBOX_VERSION="3.0.0"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
MAGENTA='\033[35m'
NC='\033[0m'

# 安全检测目标用户
_detect_target_user() {
  local user=""
  # 优先使用 logname（基于 utmp，不受环境变量影响）
  user="$(logname 2>/dev/null)" || true
  if [ -z "$user" ]; then
    user="${SUDO_USER:-}"
  fi
  if [ -z "$user" ]; then
    user="${USER:-$(whoami)}"
  fi
  echo "$user"
}

TARGET_USER="$(_detect_target_user)"

# 验证用户名合法性
if [[ ! "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo "FATAL: 非法用户名 '${TARGET_USER}'，中止执行。" >&2
  exit 1
fi

# 安全日志文件位置
LOG_DIR="/home/${TARGET_USER}/.local/log"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="${LOG_DIR}/openclaw-menu.log"
touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null || {
  # 回退到 /tmp（但使用 mktemp 防止符号链接攻击）
  LOG_FILE="$(mktemp /tmp/openclaw-menu-XXXXXX.log)"
  chmod 600 "$LOG_FILE"
}

# 扩展 PATH 确保能找到 sbin 下的系统命令（如 smbd, sshd）
export PATH="$PATH:/usr/sbin:/sbin:/usr/local/sbin"

# SMB 配置（默认路径改为 ~/.openclaw）
SMB_CONF="/etc/samba/smb.conf"
SMB_SHARE_NAME="openclaw"
SMB_DEFAULT_SHARE_PATH="/home/${TARGET_USER}/.openclaw"
SMB_SHARE_PATH_FILE="/home/${TARGET_USER}/.config/openclaw-menu/smb-share-path.conf"

# CLI Proxy API (Docker)
CLIPROXY_CONTAINER_NAME="cli-proxy-api"
CLIPROXY_IMAGE="eceasy/cli-proxy-api:latest"
CLIPROXY_DEFAULT_CONFIG_DIR="/home/${TARGET_USER}/.cli-proxy-api"
CLIPROXY_DEFAULT_CONFIG_FILE="${CLIPROXY_DEFAULT_CONFIG_DIR}/config.yaml"
CLIPROXY_DEFAULT_AUTH_DIR="/home/${TARGET_USER}/.cli-proxy-api/auth"
CLIPROXY_CONFIG_DIR="$CLIPROXY_DEFAULT_CONFIG_DIR"
CLIPROXY_CONFIG_FILE="$CLIPROXY_DEFAULT_CONFIG_FILE"
CLIPROXY_AUTH_DIR="$CLIPROXY_DEFAULT_AUTH_DIR"
CLIPROXY_SERVICE_NAME="cli-proxy-api"
CLIPROXY_SERVICE_CANDIDATES=("cliproxyapi.service" "cli-proxy-api.service" "cli-proxy-api")
VNC_MANAGED_SERVICE="openclaw-vnc.service"
VNC_DISPLAY=":1"
VNC_GEOMETRY="1920x1080"
VNC_DEPTH="24"

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
  local _dummy
  read -rp "按回车继续..." _dummy
}

confirm_dangerous_cleanup_three_times() {
  local prompt_text="$1"
  local confirm_input=""
  local round_label=""

  for round_label in "第一次确认" "第二次确认" "第三次确认"; do
    read -rp "${round_label}：${prompt_text} [Y/N]: " confirm_input
    if [[ ! "$confirm_input" =~ ^[Yy]$ ]]; then
      warn "已取消危险清理操作"
      return 1
    fi
  done

  return 0
}

run_cmd() {
  local desc="$1"
  shift
  info "$desc"
  if "$@"; then
    ok "$desc 成功"
    return 0
  else
    local rc=$?
    err "$desc 失败 (exit code: $rc)"
    return $rc
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

# 安全写入文件（原子操作）
safe_write() {
  local target="$1"
  local content="$2"
  local tmpf
  tmpf="$(mktemp "${target}.tmp.XXXXXX")"
  if ! echo "$content" > "$tmpf"; then
    rm -f "$tmpf"
    return 1
  fi
  if ! mv "$tmpf" "$target"; then
    rm -f "$tmpf"
    return 1
  fi
  return 0
}

append_unique_block() {
  local target="$1"
  local begin_marker="$2"
  local end_marker="$3"
  local block_content="$4"
  local tmpf
  local target_dir

  target_dir="$(dirname "$target")"
  mkdir -p "$target_dir" 2>/dev/null || true
  [ -f "$target" ] || touch "$target"

  tmpf="$(mktemp)"
  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skipping=1; next }
    $0 == end { skipping=0; next }
    !skipping { print }
  ' "$target" > "$tmpf" || {
    rm -f "$tmpf"
    return 1
  }

  {
    cat "$tmpf"
    if [ -s "$tmpf" ]; then
      printf '\n'
    fi
    printf '%s\n' "$begin_marker"
    printf '%s\n' "$block_content"
    printf '%s\n' "$end_marker"
  } > "${tmpf}.new" || {
    rm -f "$tmpf" "${tmpf}.new"
    return 1
  }

  mv "${tmpf}.new" "$target" || {
    rm -f "$tmpf" "${tmpf}.new"
    return 1
  }
  rm -f "$tmpf"
  return 0
}

remove_managed_block() {
  local target="$1"
  local begin_marker="$2"
  local end_marker="$3"
  local tmpf

  [ -f "$target" ] || return 0

  tmpf="$(mktemp)"
  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skipping=1; next }
    $0 == end { skipping=0; next }
    !skipping { print }
  ' "$target" > "$tmpf" || {
    rm -f "$tmpf"
    return 1
  }

  mv "$tmpf" "$target" || {
    rm -f "$tmpf"
    return 1
  }
  return 0
}

# 路径验证（防注入）
_validate_path() {
  local path="$1"
  if [[ "$path" == *".."* ]]; then
    err "路径不允许包含 '..' (禁止路径穿越)"
    return 1
  fi
  if [[ "$path" == *'$('* ]] || [[ "$path" == *'`'* ]] || [[ "$path" == *$'\n'* ]] || [[ "$path" == *$'\r'* ]]; then
    err "路径包含不允许的字符（禁止命令注入）"
    return 1
  fi
  if [[ "$path" != /* ]]; then
    err "路径必须为绝对路径"
    return 1
  fi
  return 0
}

_pnpm_shell_block() {
  cat <<EOF
# Managed by openclaw-menu: pnpm
export PNPM_HOME="/home/${TARGET_USER}/.local/share/pnpm"
case ":\$PATH:" in
  *":\$PNPM_HOME:"*) ;;
  *) export PATH="\$PNPM_HOME:\$PATH" ;;
esac
# End managed by openclaw-menu: pnpm
EOF
}

_persist_pnpm_shell_env() {
  local begin_marker="# >>> openclaw-menu pnpm >>>"
  local end_marker="# <<< openclaw-menu pnpm <<<"
  local block_content
  local target

  block_content="$(_pnpm_shell_block)"
  for target in "/home/${TARGET_USER}/.bashrc" "/home/${TARGET_USER}/.profile"; do
    append_unique_block "$target" "$begin_marker" "$end_marker" "$block_content" || return 1
  done
  return 0
}

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

  # 2. 注入别名到 .bashrc（原子操作）
  if grep -q "alias y=" "$bashrc"; then
    # 如果已存在，则更新
    local tmpf
    tmpf="$(mktemp)"
    sed "s|alias y=.*|alias y='$script_dest'|" "$bashrc" > "$tmpf" && mv "$tmpf" "$bashrc"
    ok "快捷别名 'y' 已更新"
  else
    echo "alias y='$script_dest'" >> "$bashrc"
    ok "快捷别名 'y' 已添加"
  fi

  if [ -f "/home/${TARGET_USER}/.bash_aliases" ]; then
    local tmp_aliases
    tmp_aliases="$(mktemp)"
    awk '$0 !~ /^alias y=/' "/home/${TARGET_USER}/.bash_aliases" > "$tmp_aliases" && mv "$tmp_aliases" "/home/${TARGET_USER}/.bash_aliases"
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

docker_as_root() {
  ensure_root || return 1
  as_root docker "$@"
}

run_as_target_user() {
  if [ "${USER:-$(whoami)}" = "$TARGET_USER" ]; then
    "$@"
    return $?
  fi

  if need_cmd sudo; then
    sudo -u "$TARGET_USER" "$@"
    return $?
  fi

  su - "$TARGET_USER" -c "$(printf '%q ' "$@")"
}

check_debian() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "${ID:-}" != "debian" && "${ID_LIKE:-}" != *"debian"* ]]; then
      warn "当前系统看起来不是 Debian，脚本仍可尝试执行，但可能存在兼容风险。"
    fi
  fi
}

ensure_whiptail_available() {
  if need_cmd whiptail; then
    return 0
  fi

  if [ ! -f /etc/os-release ]; then
    return 1
  fi

  local os_id="" os_like=""
  os_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
  os_like="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"

  case "${os_id}:${os_like}" in
    debian:*|ubuntu:*|linuxmint:*|raspbian:*|*:*debian*)
      ensure_root || return 1
      info "首次运行缺少 whiptail，正在自动安装..."
      run_cmd_retry "更新 apt 索引" 3 as_root apt-get update || return 1
      run_cmd_retry "安装 whiptail" 3 as_root apt-get install -y whiptail || return 1
      need_cmd whiptail
      return $?
      ;;
    *)
      return 1
      ;;
  esac
}

verify_pnpm_runtime() {
  local pnpm_home="/home/${TARGET_USER}/.local/share/pnpm"
  local login_pnpm=""
  local login_openclaw=""
  local global_bin_dir=""
  local verify_rc=0

  step "验证 pnpm 部署环境..."

  if ! need_cmd pnpm; then
    err "当前 shell 未检测到 pnpm"
    return 1
  fi

  if ! run_as_target_user bash -lc "command -v pnpm" >/dev/null 2>&1; then
    err "目标用户登录 shell 中未检测到 pnpm"
    return 1
  fi

  login_pnpm="$(run_as_target_user bash -lc "command -v pnpm" 2>/dev/null | tail -n 1)"
  if [ -z "$login_pnpm" ]; then
    err "无法解析目标用户登录 shell 中的 pnpm 路径"
    return 1
  fi

  if ! run_as_target_user bash -lc "pnpm config get global-bin-dir" >/dev/null 2>&1; then
    err "无法读取 pnpm global-bin-dir"
    return 1
  fi

  global_bin_dir="$(run_as_target_user bash -lc "pnpm config get global-bin-dir" 2>/dev/null | tail -n 1)"
  if [ "$global_bin_dir" != "$pnpm_home" ]; then
    err "pnpm global-bin-dir 异常: ${global_bin_dir:-<empty>} (期望: $pnpm_home)"
    return 1
  fi

  if ! run_as_target_user bash -lc "pnpm root -g" >/dev/null 2>&1; then
    err "目标用户登录 shell 中执行 pnpm root -g 失败"
    return 1
  fi

  if run_as_target_user bash -lc "command -v openclaw" >/dev/null 2>&1; then
    login_openclaw="$(run_as_target_user bash -lc "command -v openclaw" 2>/dev/null | tail -n 1)"
    case "$login_openclaw" in
      "${pnpm_home}/"*) ;;
      *)
        err "openclaw 未优先走 pnpm 目录: ${login_openclaw:-<empty>}"
        verify_rc=1
        ;;
    esac
  fi

  if [ $verify_rc -eq 0 ]; then
    ok "pnpm 部署环境验证通过"
  fi
  return $verify_rc
}

repair_pnpm_runtime() {
  local pnpm_home="/home/${TARGET_USER}/.local/share/pnpm"

  step "尝试自动修复 pnpm 部署环境..."

  if ! need_cmd pnpm; then
    warn "当前未检测到 pnpm，尝试重新安装..."
    install_pnpm
    return $?
  fi

  mkdir -p "$pnpm_home" || return 1
  export PNPM_HOME="$pnpm_home"
  if [[ ":$PATH:" != *":${pnpm_home}:"* ]]; then
    export PATH="${pnpm_home}:${PATH}"
  fi

  _persist_pnpm_shell_env || return 1
  pnpm config set global-bin-dir "$pnpm_home" || return 1
  hash -r 2>/dev/null || true

  ok "pnpm 环境已尝试自动修复"
  return 0
}

ensure_npm_global_bin_low_priority() {
  local bashrc_file="/home/${TARGET_USER}/.bashrc"
  local tmpf

  [ -f "$bashrc_file" ] || return 0
  tmpf="$(mktemp)"
  awk '
    $0 == "export PATH=\"$HOME/.npm-global/bin:$PATH\"" { next }
    { print }
  ' "$bashrc_file" > "$tmpf" || {
    rm -f "$tmpf"
    return 1
  }
  mv "$tmpf" "$bashrc_file" || {
    rm -f "$tmpf"
    return 1
  }
  return 0
}

repair_openclaw_deploy() {
  local pnpm_home="/home/${TARGET_USER}/.local/share/pnpm"
  local npm_global_root=""
  local npm_openclaw_dir=""

  step "尝试自动修复 OpenClaw 部署状态..."

  repair_pnpm_runtime || return 1
  ensure_npm_global_bin_low_priority || true

  if need_cmd npm; then
    npm_global_root="$(run_as_target_user bash -lc "npm root -g" 2>/dev/null | tail -n 1)"
    npm_openclaw_dir="${npm_global_root%/}/openclaw"
    if [ -n "$npm_global_root" ] && run_as_target_user bash -lc "test -d \"$npm_openclaw_dir\"" >/dev/null 2>&1; then
      warn "检测到 npm 全局残留 openclaw，尝试清理..."
      run_as_target_user bash -lc "npm uninstall -g openclaw >/dev/null 2>&1 || true"
    fi
  fi

  if ! run_as_target_user bash -lc "command -v openclaw" >/dev/null 2>&1; then
    warn "登录 shell 中未检测到 openclaw，尝试用 pnpm 重新安装..."
    if ! run_as_target_user bash -lc "export PNPM_HOME='${pnpm_home}'; export PATH=\"\$PNPM_HOME:\$PATH\"; pnpm add -g openclaw@latest"; then
      return 1
    fi
  fi

  hash -r 2>/dev/null || true
  ok "OpenClaw 部署已尝试自动修复"
  return 0
}

verify_openclaw_deploy() {
  local version_out=""
  local login_openclaw=""

  step "验证 OpenClaw 部署状态..."

  if ! verify_pnpm_runtime; then
    warn "pnpm 环境验证失败，尝试自动修复后复检..."
    repair_pnpm_runtime || return 1
    verify_pnpm_runtime || return 1
  fi

  if ! run_as_target_user bash -lc "command -v openclaw" >/dev/null 2>&1; then
    warn "目标用户登录 shell 中未检测到 openclaw，尝试自动修复..."
    repair_openclaw_deploy || return 1
    if ! run_as_target_user bash -lc "command -v openclaw" >/dev/null 2>&1; then
      err "目标用户登录 shell 中未检测到 openclaw"
      return 1
    fi
  fi

  login_openclaw="$(run_as_target_user bash -lc "command -v openclaw" 2>/dev/null | tail -n 1)"
  case "$login_openclaw" in
    "/home/${TARGET_USER}/.local/share/pnpm/"*) ;;
    *)
      warn "openclaw 入口未优先走 pnpm，尝试自动修复..."
      repair_openclaw_deploy || return 1
      login_openclaw="$(run_as_target_user bash -lc "command -v openclaw" 2>/dev/null | tail -n 1)"
      case "$login_openclaw" in
        "/home/${TARGET_USER}/.local/share/pnpm/"*) ;;
        *)
          err "openclaw 入口仍未优先走 pnpm: ${login_openclaw:-<empty>}"
          return 1
          ;;
      esac
      ;;
  esac

  version_out="$(run_as_target_user bash -lc "openclaw --version" 2>/dev/null | tail -n 1)"
  if [ -z "$version_out" ]; then
    warn "openclaw --version 执行失败，尝试自动修复..."
    repair_openclaw_deploy || return 1
    version_out="$(run_as_target_user bash -lc "openclaw --version" 2>/dev/null | tail -n 1)"
    if [ -z "$version_out" ]; then
      err "openclaw --version 执行失败"
      return 1
    fi
  fi

  ok "OpenClaw 部署验证通过: $version_out"
  info "命令入口: $login_openclaw"
  return 0
}

prompt_optional() {
  local prompt_text="$1"
  local __resultvar="$2"
  local value=""
  read -rp "$prompt_text" value
  printf -v "$__resultvar" '%s' "$value"
}

prompt_with_default() {
  local prompt_text="$1"
  local default_value="$2"
  local __resultvar="$3"
  local value=""
  read -rp "$prompt_text" value
  if [ -z "$value" ]; then
    value="$default_value"
  fi
  printf -v "$__resultvar" '%s' "$value"
}

menu_section() {
  local title="$1"
  echo
  echo -e "${MAGENTA}>>> ${CYAN}${title}${MAGENTA} <<<${NC}"
}

render_status_badge() {
  local label="$1"
  local state="$2"
  if [ "$state" = "ok" ]; then
    printf '%b' "${GREEN}${label}:OK${NC}"
  elif [ "$state" = "warn" ]; then
    printf '%b' "${YELLOW}${label}:WARN${NC}"
  else
    printf '%b' "${RED}${label}:NO${NC}"
  fi
}

render_status_chip() {
  local label="$1"
  local state="$2"
  if [ "$state" = "ok" ]; then
    printf '%b' "${GREEN}[ ${label}: NORMAL ]${NC}"
  elif [ "$state" = "warn" ]; then
    printf '%b' "${YELLOW}[ ${label}: ATTENTION ]${NC}"
  else
    printf '%b' "${RED}[ ${label}: NOT READY ]${NC}"
  fi
}

print_summary_row() {
  local label="$1"
  local value="$2"
  printf '  %-14s %s\n' "$label" "$value"
}

print_status_row() {
  local label="$1"
  local state="$2"
  local detail="$3"
  local marker=""
  if [ "$state" = "ok" ]; then
    marker="${GREEN}● NORMAL${NC}"
  elif [ "$state" = "warn" ]; then
    marker="${YELLOW}● ATTENTION${NC}"
  else
    marker="${RED}● NOT READY${NC}"
  fi
  printf '  %-14s %-24b %s\n' "$label" "$marker" "$detail"
}

render_main_banner() {
  printf '%b\n' "${MAGENTA}   ____                   ________                    ${NC}"
  printf '%b\n' "${MAGENTA}  / __ \\____  ___  ____  / ____/ /___ __      ______ _${NC}"
  printf '%b\n' "${CYAN} / / / / __ \\/ _ \\/ __ \\/ /   / / __ \`/ | /| / / __ \`/${NC}"
  printf '%b\n' "${CYAN}/ /_/ / /_/ /  __/ / / / /___/ / /_/ /| |/ |/ / /_/ / ${NC}"
  printf '%b\n' "${YELLOW}\\____/ .___/\\___/_/ /_/\\____/_/\\__,_/ |__/|__/\\__,_/  ${NC}"
  printf '%b\n' "${YELLOW}    /_/                                                ${NC}"
  echo
  echo -e "${GREEN}OpenClaw ToolBox v${TOOLBOX_VERSION}${NC}"
  echo -e "${CYAN}Author YY  GitHub @yyxp1989/ToolBox${NC}"
}

reset_cliproxy_paths() {
  CLIPROXY_CONFIG_DIR="$CLIPROXY_DEFAULT_CONFIG_DIR"
  CLIPROXY_CONFIG_FILE="$CLIPROXY_DEFAULT_CONFIG_FILE"
  CLIPROXY_AUTH_DIR="$CLIPROXY_DEFAULT_AUTH_DIR"
}

get_cliproxy_mode_label() {
  case "${CLIPROXY_RUNTIME_MODE:-none}" in
    docker) echo "Docker" ;;
    service) echo "Linux/systemd" ;;
    binary) echo "Linux/手工进程" ;;
    config) echo "仅检测到配置" ;;
    *) echo "未安装" ;;
  esac
}

resolve_cliproxy_paths() {
  local service_name="" service_fragment="" working_dir="" exec_start="" binary_dir="" auth_dir=""
  reset_cliproxy_paths

  if [ -f "$CLIPROXY_CONFIG_FILE" ]; then
    :
  fi

  if need_cmd systemctl; then
    for service_name in "${CLIPROXY_SERVICE_CANDIDATES[@]}"; do
      if run_as_target_user bash -lc "systemctl --user cat ${service_name}" >/dev/null 2>&1; then
        service_fragment="$(run_as_target_user bash -lc "systemctl --user show -p FragmentPath --value ${service_name}" 2>/dev/null | tail -n 1)"
        working_dir="$(run_as_target_user bash -lc "systemctl --user show -p WorkingDirectory --value ${service_name}" 2>/dev/null | tail -n 1)"
        exec_start="$(run_as_target_user bash -lc "systemctl --user show -p ExecStart --value ${service_name}" 2>/dev/null | tail -n 1)"
        [ -z "$working_dir" ] && [ -n "$service_fragment" ] && working_dir="$(dirname "$service_fragment")"
        if [ -n "$working_dir" ] && [ -f "${working_dir}/config.yaml" ]; then
          CLIPROXY_CONFIG_FILE="${working_dir}/config.yaml"
          CLIPROXY_CONFIG_DIR="$(dirname "$CLIPROXY_CONFIG_FILE")"
        fi
        if [ -z "$working_dir" ] && [ -n "$exec_start" ]; then
          binary_dir="$(printf '%s\n' "$exec_start" | sed -nE 's/^([^ ;]+).*/\1/p')"
          [ -n "$binary_dir" ] && binary_dir="$(dirname "$binary_dir")"
          if [ -n "$binary_dir" ] && [ -f "${binary_dir}/config.yaml" ]; then
            CLIPROXY_CONFIG_FILE="${binary_dir}/config.yaml"
            CLIPROXY_CONFIG_DIR="$(dirname "$CLIPROXY_CONFIG_FILE")"
          fi
        fi
        break
      fi
    done
  fi

  if [ ! -f "$CLIPROXY_CONFIG_FILE" ] && [ -f "/home/${TARGET_USER}/cliproxyapi/config.yaml" ]; then
    CLIPROXY_CONFIG_FILE="/home/${TARGET_USER}/cliproxyapi/config.yaml"
    CLIPROXY_CONFIG_DIR="$(dirname "$CLIPROXY_CONFIG_FILE")"
  fi

  if [ -f "$CLIPROXY_CONFIG_FILE" ]; then
    auth_dir="$(sed -nE 's/^[[:space:]]*auth-dir:[[:space:]]*"?([^"#]+)"?.*/\1/p' "$CLIPROXY_CONFIG_FILE" | head -n 1 | sed 's/[[:space:]]*$//')"
    if [ -n "$auth_dir" ]; then
      auth_dir="${auth_dir/#\~//home/${TARGET_USER}}"
      CLIPROXY_AUTH_DIR="$auth_dir"
    fi
  fi
}

CLIPROXY_RUNTIME_MODE="none"
CLIPROXY_RUNTIME_STATE="down"
CLIPROXY_RUNTIME_DETAIL="未安装"
VNC_SERVICE_NAME=""

detect_cliproxy_runtime() {
  CLIPROXY_RUNTIME_MODE="none"
  CLIPROXY_RUNTIME_STATE="down"
  CLIPROXY_RUNTIME_DETAIL="未安装"
  resolve_cliproxy_paths

  if need_cmd docker && as_root docker inspect -f '{{.State.Status}}' "${CLIPROXY_CONTAINER_NAME}" >/dev/null 2>&1; then
    local docker_state=""
    docker_state="$(as_root docker inspect -f '{{.State.Status}}' "${CLIPROXY_CONTAINER_NAME}" 2>/dev/null || true)"
    CLIPROXY_RUNTIME_MODE="docker"
    CLIPROXY_RUNTIME_STATE="warn"
    CLIPROXY_RUNTIME_DETAIL="Docker 容器 | state=${docker_state:-unknown}"
    if [ "$docker_state" = "running" ]; then
      CLIPROXY_RUNTIME_STATE="ok"
      CLIPROXY_RUNTIME_DETAIL="Docker 容器运行中 | http://127.0.0.1:8317"
    fi
    return 0
  fi

  if need_cmd systemctl; then
    local service_name=""
    for service_name in "${CLIPROXY_SERVICE_CANDIDATES[@]}"; do
      if run_as_target_user bash -lc "systemctl --user cat ${service_name}" >/dev/null 2>&1; then
        CLIPROXY_SERVICE_NAME="$service_name"
        CLIPROXY_RUNTIME_MODE="service"
        CLIPROXY_RUNTIME_STATE="warn"
        CLIPROXY_RUNTIME_DETAIL="systemd --user 已安装 | service=${service_name}"
        if run_as_target_user bash -lc "systemctl --user is-active ${service_name}" >/dev/null 2>&1; then
          CLIPROXY_RUNTIME_STATE="ok"
          CLIPROXY_RUNTIME_DETAIL="systemd --user 运行中 | http://127.0.0.1:8317 | service=${service_name}"
        fi
        return 0
      fi
    done
  fi

  if need_cmd cli-proxy-api; then
    CLIPROXY_RUNTIME_MODE="binary"
    CLIPROXY_RUNTIME_STATE="warn"
    CLIPROXY_RUNTIME_DETAIL="检测到 cli-proxy-api 命令 | 服务方式未知"
    if pgrep -f '(^|/| )cli-proxy-api( |$)' >/dev/null 2>&1; then
      CLIPROXY_RUNTIME_STATE="ok"
      CLIPROXY_RUNTIME_DETAIL="检测到 cli-proxy-api 进程 | 可能为手工/脚本部署"
    fi
    return 0
  fi

  if [ -f "$CLIPROXY_CONFIG_FILE" ] || [ -d "$CLIPROXY_AUTH_DIR" ]; then
    CLIPROXY_RUNTIME_MODE="config"
    CLIPROXY_RUNTIME_STATE="warn"
    CLIPROXY_RUNTIME_DETAIL="存在配置或认证目录 | 尚未检测到运行实例"
    return 0
  fi

  return 1
}

get_current_openclaw_version() {
  if need_cmd openclaw; then
    openclaw --version 2>/dev/null | sed -nE 's/^OpenClaw[[:space:]]+([0-9]+(\.[0-9]+){1,3}).*/\1/p'
  fi
}

get_latest_openclaw_version() {
  local cache_file="/tmp/openclaw-menu-openclaw-latest.cache"
  local now ts=0
  now=$(date +%s)
  [ -f "$cache_file" ] && ts=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
  if [ $((now - ts)) -lt 1800 ] && [ -s "$cache_file" ]; then
    cat "$cache_file"
    return 0
  fi
  curl -fsSL --connect-timeout 2 --max-time 3 https://api.github.com/repos/openclaw/openclaw/releases/latest 2>/dev/null \
    | sed -nE 's/.*"tag_name":[[:space:]]*"v?([^"]+)".*/\1/p' | head -n 1 | tee "$cache_file"
}

get_cached_latest_openclaw_version() {
  local cache_file="/tmp/openclaw-menu-openclaw-latest.cache"
  if [ -s "$cache_file" ]; then
    cat "$cache_file"
  fi
}

get_current_node_version() {
  if need_cmd node; then
    node --version 2>/dev/null
  fi
}

get_current_pnpm_version() {
  if need_cmd pnpm; then
    pnpm --version 2>/dev/null
  fi
}

get_current_pnpm_path() {
  if need_cmd pnpm; then
    command -v pnpm 2>/dev/null
  fi
}

get_latest_pnpm_version() {
  local cache_file="/tmp/openclaw-menu-pnpm-latest.cache"
  local now ts=0
  now=$(date +%s)
  [ -f "$cache_file" ] && ts=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
  if [ $((now - ts)) -lt 1800 ] && [ -s "$cache_file" ]; then
    cat "$cache_file"
    return 0
  fi
  npm view pnpm version 2>/dev/null | tee "$cache_file"
}

get_cached_latest_pnpm_version() {
  local cache_file="/tmp/openclaw-menu-pnpm-latest.cache"
  if [ -s "$cache_file" ]; then
    cat "$cache_file"
  fi
}

get_latest_node_lts_version() {
  local cache_file="/tmp/openclaw-menu-node22-latest.cache"
  local now ts=0
  now=$(date +%s)
  [ -f "$cache_file" ] && ts=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
  if [ $((now - ts)) -lt 1800 ] && [ -s "$cache_file" ]; then
    cat "$cache_file"
    return 0
  fi
  curl -fsSL --connect-timeout 2 --max-time 3 https://nodejs.org/dist/index.tab 2>/dev/null \
    | awk 'NR > 1 && $1 ~ /^v22\./ { print $1; exit }' | tee "$cache_file"
}

get_cached_latest_node_lts_version() {
  local cache_file="/tmp/openclaw-menu-node22-latest.cache"
  if [ -s "$cache_file" ]; then
    cat "$cache_file"
  fi
}

get_current_docker_version() {
  if need_cmd docker; then
    docker --version 2>/dev/null | sed -nE 's/^Docker version ([^,]+),.*/\1/p'
  fi
}

get_latest_docker_package_version() {
  local cache_file="/tmp/openclaw-menu-docker-latest.cache"
  local now ts=0
  now=$(date +%s)
  [ -f "$cache_file" ] && ts=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
  if [ $((now - ts)) -lt 1800 ] && [ -s "$cache_file" ]; then
    cat "$cache_file"
    return 0
  fi
  if need_cmd apt-cache; then
    apt-cache madison docker-ce 2>/dev/null | awk 'NR == 1 { print $3 }' | tee "$cache_file"
  fi
}

get_cached_latest_docker_package_version() {
  local cache_file="/tmp/openclaw-menu-docker-latest.cache"
  if [ -s "$cache_file" ]; then
    cat "$cache_file"
  fi
}

get_gateway_state() {
  if need_cmd systemctl && run_as_target_user bash -lc "systemctl --user is-active openclaw-gateway.service" >/dev/null 2>&1; then
    echo "运行中"
  elif need_cmd openclaw && openclaw gateway status >/dev/null 2>&1; then
    echo "运行中"
  else
    echo "未运行"
  fi
}

detect_vnc_runtime() {
  VNC_SERVICE_NAME=""
  local candidate=""
  local candidates="${VNC_MANAGED_SERVICE} vncserver@:1.service tigervncserver@:1.service x11vnc.service vino-server.service"
  if ! need_cmd systemctl; then
    return 1
  fi
  for candidate in $candidates; do
    if systemctl cat "$candidate" >/dev/null 2>&1 || run_as_target_user bash -lc "systemctl --user cat $candidate" >/dev/null 2>&1; then
      VNC_SERVICE_NAME="$candidate"
      return 0
    fi
  done
  return 1
}

install_vnc_server() {
  ensure_root || return 1

  step "安装 Debian VNC 服务及桌面环境..."
  run_cmd_retry "更新 apt 索引" 3 as_root apt-get update || return 1
  run_cmd_retry "安装 TigerVNC / XFCE" 3 as_root apt-get install -y tigervnc-standalone-server tigervnc-common xfce4 xfce4-goodies dbus-x11 xfonts-base || return 1

  local user_home="/home/${TARGET_USER}"
  local vnc_dir="${user_home}/.vnc"
  mkdir -p "$vnc_dir" || return 1
  chown -R "${TARGET_USER}:${TARGET_USER}" "$vnc_dir" || true

  safe_write "${vnc_dir}/xstartup" "#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_SESSION_DESKTOP=xfce
export XDG_CURRENT_DESKTOP=XFCE
exec startxfce4" || return 1
  chmod 700 "${vnc_dir}/xstartup" || true
  chown "${TARGET_USER}:${TARGET_USER}" "${vnc_dir}/xstartup" || true

  local vnc_password=""
  prompt_optional "请输入 VNC 登录密码（留空则跳过密码初始化）: " vnc_password
  if [ -n "$vnc_password" ]; then
    local vnc_password_b64=""
    vnc_password_b64="$(printf '%s' "$vnc_password" | base64 -w0)"
    run_as_target_user env VNC_PASSWORD_B64="$vnc_password_b64" bash -lc "mkdir -p ~/.vnc && printf '%s' \"\$VNC_PASSWORD_B64\" | base64 -d | vncpasswd -f > ~/.vnc/passwd && chmod 600 ~/.vnc/passwd" || return 1
    ok "VNC 密码已写入"
  else
    warn "已跳过密码初始化，首次启动前请记得设置 VNC 密码。"
  fi

  safe_write "/tmp/${VNC_MANAGED_SERVICE}" "[Unit]
Description=OpenClaw Managed TigerVNC Server
After=network.target systemd-user-sessions.service

[Service]
Type=forking
User=${TARGET_USER}
PAMName=login
PIDFile=${user_home}/.vnc/%H${VNC_DISPLAY}.pid
ExecStartPre=-/usr/bin/vncserver -kill ${VNC_DISPLAY}
ExecStart=/usr/bin/vncserver ${VNC_DISPLAY} -geometry ${VNC_GEOMETRY} -depth ${VNC_DEPTH} -localhost no
ExecStop=/usr/bin/vncserver -kill ${VNC_DISPLAY}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target" || return 1

  as_root install -o root -g root -m 0644 "/tmp/${VNC_MANAGED_SERVICE}" "/etc/systemd/system/${VNC_MANAGED_SERVICE}" || return 1
  rm -f "/tmp/${VNC_MANAGED_SERVICE}" 2>/dev/null || true
  run_cmd "刷新 systemd 配置" as_root systemctl daemon-reload || return 1

  ok "Debian VNC 服务安装完成"
  info "服务名: ${VNC_MANAGED_SERVICE}"
  info "显示编号: ${VNC_DISPLAY}"
  info "桌面环境: XFCE"
}

reset_vnc_password() {
  if ! need_cmd vncpasswd; then
    warn "未检测到 vncpasswd，请先安装 VNC 服务。"
    return 1
  fi
  local vnc_password=""
  prompt_optional "请输入新的 VNC 登录密码: " vnc_password
  if [ -z "$vnc_password" ]; then
    warn "未输入密码"
    return 1
  fi
  local vnc_password_b64=""
  vnc_password_b64="$(printf '%s' "$vnc_password" | base64 -w0)"
  run_as_target_user env VNC_PASSWORD_B64="$vnc_password_b64" bash -lc "mkdir -p ~/.vnc && printf '%s' \"\$VNC_PASSWORD_B64\" | base64 -d | vncpasswd -f > ~/.vnc/passwd && chmod 600 ~/.vnc/passwd" || return 1
  ok "VNC 密码已更新"
}

get_vnc_state() {
  if detect_vnc_runtime; then
    if systemctl is-active "$VNC_SERVICE_NAME" >/dev/null 2>&1 || run_as_target_user bash -lc "systemctl --user is-active $VNC_SERVICE_NAME" >/dev/null 2>&1; then
      echo "运行中"
    else
      echo "已配置"
    fi
  else
    echo "未配置"
  fi
}

get_vnc_status_detail() {
  if detect_vnc_runtime; then
    if systemctl is-active "$VNC_SERVICE_NAME" >/dev/null 2>&1 || run_as_target_user bash -lc "systemctl --user is-active $VNC_SERVICE_NAME" >/dev/null 2>&1; then
      echo "运行中 | ${VNC_SERVICE_NAME} | ${VNC_DISPLAY}"
    else
      echo "已配置 | ${VNC_SERVICE_NAME} | ${VNC_DISPLAY}"
    fi
  else
    echo "未配置"
  fi
}

get_user_identity_summary() {
  local groups_line sudo_state docker_group_state
  groups_line="$(id -nG "$TARGET_USER" 2>/dev/null)"
  if run_as_target_user bash -lc "sudo -n true" >/dev/null 2>&1; then
    sudo_state="yes"
  else
    sudo_state="no"
  fi
  case " ${groups_line} " in
    *" docker "*) docker_group_state="yes" ;;
    *) docker_group_state="no" ;;
  esac
  echo "当前用户: ${TARGET_USER} | sudo: ${sudo_state} | docker组: ${docker_group_state}"
}

show_main_status_banner() {
  local openclaw_current openclaw_latest gateway_state
  local node_current node_latest docker_current docker_state
  local cliproxy_mode cliproxy_state vnc_state

  openclaw_current="$(get_current_openclaw_version)"
  openclaw_latest="$(get_cached_latest_openclaw_version)"
  gateway_state="$(get_gateway_state)"
  node_current="$(get_current_node_version)"
  node_latest="$(get_cached_latest_node_lts_version)"
  docker_current="$(get_current_docker_version)"
  if need_cmd docker && systemctl is-active docker >/dev/null 2>&1; then
    docker_state="运行中"
  elif need_cmd docker; then
    docker_state="已安装"
  else
    docker_state="未安装"
  fi
  if detect_cliproxy_runtime; then
    cliproxy_mode="$CLIPROXY_RUNTIME_MODE"
    cliproxy_state="$CLIPROXY_RUNTIME_STATE"
  else
    cliproxy_mode="none"
    cliproxy_state="down"
  fi
  vnc_state="$(get_vnc_state)"

  echo "OpenClaw: ${openclaw_current:-未安装} | Latest: ${openclaw_latest:-缓存未生成} | Gateway: ${gateway_state}"
  echo "Node.js: ${node_current:-未安装} | Target: ${node_latest:-缓存未生成} | Docker: ${docker_current:-未安装} (${docker_state})"
  echo "CLIProxy: ${cliproxy_mode}/${cliproxy_state} | VNC: $(get_vnc_status_detail)"
}

show_openclaw_deploy_banner() {
  local openclaw_current openclaw_latest gateway_state install_state
  openclaw_current="$(get_current_openclaw_version)"
  openclaw_latest="$(get_latest_openclaw_version)"
  gateway_state="$(get_gateway_state)"
  if need_cmd openclaw; then
    install_state="已安装"
  else
    install_state="未安装"
  fi
  echo "状态: ${install_state} | 当前版本: ${openclaw_current:-未知} | 最新版本: ${openclaw_latest:-未知} | Gateway: ${gateway_state}"
}

show_env_support_banner() {
  local node_current node_latest pnpm_current docker_current docker_latest docker_state
  detect_cliproxy_runtime >/dev/null 2>&1 || true
  node_current="$(get_current_node_version)"
  node_latest="$(get_cached_latest_node_lts_version)"
  pnpm_current="$(get_current_pnpm_version)"
  docker_current="$(get_current_docker_version)"
  docker_latest="$(get_cached_latest_docker_package_version)"
  if need_cmd docker && systemctl is-active docker >/dev/null 2>&1; then
    docker_state="运行中"
  elif need_cmd docker; then
    docker_state="已安装"
  else
    docker_state="未安装"
  fi
  echo "Node.js: ${node_current:-未安装} | Latest: ${node_latest:-缓存未生成}"
  echo "pnpm: ${pnpm_current:-未安装}"
  echo "Docker: ${docker_current:-未安装} | Repo: ${docker_latest:-缓存未生成} | 状态: ${docker_state}"
  echo "CLIProxy: ${CLIPROXY_RUNTIME_MODE:-none}/${CLIPROXY_RUNTIME_STATE:-down} | VNC: $(get_vnc_status_detail)"
}

openclaw_approvals_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== Agent Tool 工具权限审批策略 =====${NC}"
    echo "1) 查看当前 approvals 快照"
    echo "2) 一键设置执行权限（full + ask off + strictInlineEval false）"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1)
        ensure_openclaw_installed && openclaw approvals get
        pause ;;
      2)
        ensure_openclaw_installed || { pause; continue; }
        if openclaw config set tools.exec.security full \
          && openclaw config set tools.exec.ask off \
          && openclaw config set tools.exec.strictInlineEval false \
          && openclaw config validate; then
          ok "已完成一键权限设置：tools.exec.security=full, tools.exec.ask=off, tools.exec.strictInlineEval=false"
        else
          warn "一键权限设置失败"
        fi
        pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

common_config_shortcuts_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== 常用配置快捷项 =====${NC}"
    echo "1) 查看默认模型"
    echo "2) 设置默认模型"
    echo "3) 查看图像模型"
    echo "4) 设置图像模型"
    echo "5) 查看网关端口"
    echo "6) 设置网关端口"
    echo "7) 查看配置文件路径"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1)
        ensure_openclaw_installed && openclaw config get agents.defaults.model.primary
        pause ;;
      2)
        ensure_openclaw_installed || { pause; continue; }
        local quick_default_model
        echo "--- 当前已配置模型 ---"
        openclaw models list 2>/dev/null || true
        echo
        select_configured_model_ref quick_default_model || { pause; continue; }
        [ -n "$quick_default_model" ] && openclaw models set "$quick_default_model"
        pause ;;
      3)
        ensure_openclaw_installed && openclaw config get agents.defaults.imageModel
        pause ;;
      4)
        ensure_openclaw_installed || { pause; continue; }
        local quick_image_model
        echo "--- 当前已配置模型 ---"
        openclaw models list 2>/dev/null || true
        echo
        select_configured_model_ref quick_image_model || { pause; continue; }
        [ -n "$quick_image_model" ] && openclaw models set-image "$quick_image_model"
        pause ;;
      5)
        ensure_openclaw_installed && openclaw config get gateway.port
        pause ;;
      6)
        ensure_openclaw_installed || { pause; continue; }
        local gateway_port
        prompt_optional "请输入新的网关端口: " gateway_port
        if [[ "$gateway_port" =~ ^[0-9]+$ ]]; then
          openclaw config set gateway.port "$gateway_port"
        else
          warn "端口必须是数字"
        fi
        pause ;;
      7)
        ensure_openclaw_installed && openclaw config file
        pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

get_provider_ids() {
  ensure_openclaw_installed >/dev/null 2>&1 || return 1
  openclaw config get models.providers 2>/dev/null | node -e 'let raw=""; process.stdin.setEncoding("utf8"); process.stdin.on("data", c => raw += c); process.stdin.on("end", () => { try { const data = JSON.parse(raw || "{}"); for (const key of Object.keys(data || {})) { if (key) console.log(key); } } catch {} });'
}

get_model_alias_names() {
  ensure_openclaw_installed >/dev/null 2>&1 || return 1
  openclaw config get agents.defaults.models 2>/dev/null | node -e 'let raw=""; process.stdin.setEncoding("utf8"); process.stdin.on("data", c => raw += c); process.stdin.on("end", () => { try { const data = JSON.parse(raw || "{}"); const seen = new Set(); for (const modelRef of Object.keys(data || {})) { const alias = typeof data?.[modelRef]?.alias === "string" ? data[modelRef].alias.trim() : ""; if (alias && !seen.has(alias)) { seen.add(alias); console.log(alias); } } } catch {} });'
}

get_configured_model_ids() {
  ensure_openclaw_installed >/dev/null 2>&1 || return 1
  openclaw config get models.providers 2>/dev/null | node -e 'let raw=""; process.stdin.setEncoding("utf8"); process.stdin.on("data", c => raw += c); process.stdin.on("end", () => { try { const data = JSON.parse(raw || "{}"); const seen = new Set(); for (const provider of Object.values(data || {})) { const models = Array.isArray(provider?.models) ? provider.models : []; for (const model of models) { const id = typeof model?.id === "string" ? model.id.trim() : ""; if (id && !seen.has(id)) { seen.add(id); console.log(id); } } } } catch {} });'
}

select_from_list_text() {
  local title="$1"
  local __resultvar="$2"
  shift 2
  local -a items=("$@")
  local choice="" idx=""

  if [ "${#items[@]}" -eq 0 ]; then
    warn "当前没有可选项"
    printf -v "$__resultvar" '%s' ""
    return 1
  fi

  echo "--- ${title} ---"
  for idx in "${!items[@]}"; do
    printf '  %2d) %s\n' "$((idx + 1))" "${items[$idx]}"
  done
  echo
  read -rp "请选择编号: " choice

  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#items[@]}" ]; then
    printf -v "$__resultvar" '%s' "${items[$((choice - 1))]}"
    return 0
  fi

  warn "无效选择"
  printf -v "$__resultvar" '%s' ""
  return 1
}

select_from_list() {
  local title="$1"
  local __resultvar="$2"
  shift 2
  local -a items=("$@")
  select_from_list_with_prompt "$title" "请选择一项（方向键移动，回车确认）" "$__resultvar" "${items[@]}"
}

select_from_list_with_prompt() {
  local title="$1"
  local prompt_text="$2"
  local __resultvar="$3"
  shift 3
  local -a items=("$@")
  local -a menu_args=()
  local selection=""
  local item=""

  if [ "${#items[@]}" -eq 0 ]; then
    warn "当前没有可选项"
    printf -v "$__resultvar" '%s' ""
    return 1
  fi

  if ! ensure_whiptail_available || [ ! -t 0 ] || [ ! -t 1 ]; then
    select_from_list_text "$title" "$__resultvar" "${items[@]}"
    return $?
  fi

  for item in "${items[@]}"; do
    menu_args+=("$item" "")
  done

  selection="$(
    whiptail \
      --title "$title" \
      --menu "$prompt_text" \
      22 100 14 \
      "${menu_args[@]}" \
      3>&1 1>&2 2>&3
  )" || {
    warn "已取消"
    printf -v "$__resultvar" '%s' ""
    return 1
  }

  printf -v "$__resultvar" '%s' "$selection"
  return 0
}

select_multiple_from_list_text() {
  local title="$1"
  local __resultvar="$2"
  shift 2
  local -a items=("$@")
  local selection="" idx="" value=""
  local -a selected_items=()
  local seen="|"

  if [ "${#items[@]}" -eq 0 ]; then
    warn "当前没有可选项"
    printf -v "$__resultvar" '%s' ""
    return 1
  fi

  echo "--- ${title} ---"
  for idx in "${!items[@]}"; do
    printf '  %2d) %s\n' "$((idx + 1))" "${items[$idx]}"
  done
  echo
  read -rp "请选择编号（支持逗号/空格/all）: " selection
  if [ -z "$selection" ]; then
    warn "未选择任何项"
    printf -v "$__resultvar" '%s' ""
    return 1
  fi

  if [[ "$selection" =~ ^[Aa][Ll][Ll]$ ]]; then
    printf -v "$__resultvar" '%s' "$(printf '%s\n' "${items[@]}")"
    return 0
  fi

  selection="${selection//,/ }"
  for idx in $selection; do
    if [[ ! "$idx" =~ ^[0-9]+$ ]]; then
      continue
    fi
    if [ "$idx" -lt 1 ] || [ "$idx" -gt "${#items[@]}" ]; then
      continue
    fi
    value="${items[$((idx - 1))]}"
    if [[ "$seen" != *"|${value}|"* ]]; then
      selected_items+=("$value")
      seen="${seen}${value}|"
    fi
  done

  if [ "${#selected_items[@]}" -eq 0 ]; then
    warn "无效选择"
    printf -v "$__resultvar" '%s' ""
    return 1
  fi

  printf -v "$__resultvar" '%s' "$(printf '%s\n' "${selected_items[@]}")"
  return 0
}

select_multiple_with_whiptail() {
  local title="$1"
  local prompt_text="$2"
  local __resultvar="$3"
  shift 3
  local -a items=("$@")
  local -a menu_args=()
  local selection=""
  local item=""
  local parsed=""

  if [ "${#items[@]}" -eq 0 ]; then
    warn "当前没有可选项"
    printf -v "$__resultvar" '%s' ""
    return 1
  fi

  if ! ensure_whiptail_available || [ ! -t 0 ] || [ ! -t 1 ]; then
    select_multiple_from_list_text "$title" "$__resultvar" "${items[@]}"
    return $?
  fi

  for item in "${items[@]}"; do
    menu_args+=("$item" "" "OFF")
  done

  selection="$(
    whiptail \
      --title "$title" \
      --checklist "$prompt_text" \
      22 100 14 \
      "${menu_args[@]}" \
      3>&1 1>&2 2>&3
  )" || {
    warn "已取消"
    printf -v "$__resultvar" '%s' ""
    return 1
  }

  parsed="$(printf '%s' "$selection" | sed 's/" "/"\n"/g' | tr -d '"')"
  if [ -z "$parsed" ]; then
    warn "未选择任何项"
    printf -v "$__resultvar" '%s' ""
    return 1
  fi

  printf -v "$__resultvar" '%s' "$parsed"
  return 0
}

select_multiple_from_list() {
  local title="$1"
  local __resultvar="$2"
  shift 2
  select_multiple_with_whiptail "$title" "请选择一项或多项（空格勾选，Tab 切换到确定）" "$__resultvar" "$@"
}

select_configured_model_ref() {
  local __resultvar="$1"
  local -a models=()
  mapfile -t models < <(get_configured_model_ids)
  if [ "${#models[@]}" -eq 0 ]; then
    warn "未能从当前 OpenClaw 配置中提取可选模型"
    printf -v "$__resultvar" '%s' ""
    return 1
  fi
  select_from_list "当前已配置模型" "$__resultvar" "${models[@]}"
}

select_provider_id() {
  local __resultvar="$1"
  local -a providers=()
  mapfile -t providers < <(get_provider_ids)
  select_from_list "当前 Providers" "$__resultvar" "${providers[@]}"
}

select_alias_name() {
  local __resultvar="$1"
  local -a aliases=()
  mapfile -t aliases < <(get_model_alias_names)
  select_from_list "当前模型别名" "$__resultvar" "${aliases[@]}"
}

get_agent_ids() {
  ensure_openclaw_installed >/dev/null 2>&1 || return 1
  openclaw config get agents 2>/dev/null | node -e 'let raw=""; process.stdin.setEncoding("utf8"); process.stdin.on("data", c => raw += c); process.stdin.on("end", () => { try { const data = JSON.parse(raw || "{}"); const list = Array.isArray(data?.list) ? data.list : []; const seen = new Set(); for (const item of list) { const id = typeof item?.id === "string" ? item.id.trim() : ""; if (id && !seen.has(id)) { seen.add(id); console.log(id); } } if (!seen.has("main")) console.log("main"); } catch {} });'
}

select_agent_id() {
  local __resultvar="$1"
  local -a agents=()
  mapfile -t agents < <(get_agent_ids)
  select_from_list "当前 Agent" "$__resultvar" "${agents[@]}"
}

get_provider_model_refs() {
  ensure_openclaw_installed >/dev/null 2>&1 || return 1
  openclaw config get models.providers 2>/dev/null | node -e 'let raw=""; process.stdin.setEncoding("utf8"); process.stdin.on("data", c => raw += c); process.stdin.on("end", () => { try { const data = JSON.parse(raw || "{}"); for (const [providerId, provider] of Object.entries(data || {})) { const models = Array.isArray(provider?.models) ? provider.models : []; for (const model of models) { const id = typeof model?.id === "string" ? model.id.trim() : ""; if (id) console.log(`${providerId}/${id}`); } } } catch {} });'
}

get_provider_model_ids() {
  local provider_id="$1"
  ensure_openclaw_installed >/dev/null 2>&1 || return 1
  openclaw config get "models.providers.${provider_id}" 2>/dev/null | node -e 'const providerId = process.argv[1] || ""; let raw=""; process.stdin.setEncoding("utf8"); process.stdin.on("data", c => raw += c); process.stdin.on("end", () => { try { const data = JSON.parse(raw || "{}"); const models = Array.isArray(data?.models) ? data.models : []; for (const model of models) { const id = typeof model?.id === "string" ? model.id.trim() : ""; if (id) console.log(`${providerId}/${id}`); } } catch {} });' "$provider_id"
}

default_alias_for_model_ref() {
  local model_ref="$1"
  printf '%s\n' "${model_ref##*/}"
}

merge_models_into_agents_defaults() {
  local models_blob="$1"
  local current_json next_json
  current_json="$(openclaw config get agents.defaults.models 2>/dev/null || echo '{}')"
  next_json="$(
    CURRENT_JSON="$current_json" MODELS_BLOB="$models_blob" node - <<'EOF'
const parseJson = (raw, fallback) => {
  try { return JSON.parse(raw || ""); } catch { return fallback; }
};
const current = parseJson(process.env.CURRENT_JSON, {});
const lines = String(process.env.MODELS_BLOB || "")
  .split(/\r?\n/)
  .map((s) => s.trim())
  .filter(Boolean);
for (const ref of lines) {
  if (!current[ref] || typeof current[ref] !== "object") current[ref] = {};
  if (typeof current[ref].alias !== "string" || !current[ref].alias.trim()) {
    const alias = ref.includes("/") ? ref.split("/").pop() : ref;
    current[ref].alias = alias;
  }
}
process.stdout.write(JSON.stringify(current));
EOF
  )" || return 1
  openclaw config set "agents.defaults.models" "$next_json" --strict-json
}

set_agent_model_config() {
  local agent_id="$1"
  local primary_model="$2"
  local fallbacks_blob="$3"
  local current_agents_json next_agents_json

  current_agents_json="$(openclaw config get agents 2>/dev/null || echo '{}')"
  next_agents_json="$(
    AGENT_ID="$agent_id" PRIMARY_MODEL="$primary_model" FALLBACKS_BLOB="$fallbacks_blob" CURRENT_JSON="$current_agents_json" node - <<'EOF'
const parseJson = (raw, fallback) => {
  try { return JSON.parse(raw || ""); } catch { return fallback; }
};
const data = parseJson(process.env.CURRENT_JSON, {});
const agentId = process.env.AGENT_ID || "main";
const primary = (process.env.PRIMARY_MODEL || "").trim();
const fallbacks = String(process.env.FALLBACKS_BLOB || "")
  .split(/\r?\n/)
  .map((s) => s.trim())
  .filter(Boolean)
  .filter((s, idx, arr) => arr.indexOf(s) === idx && s !== primary);
const modelCfg = fallbacks.length ? { primary, fallbacks } : { primary };
if (agentId === "main") {
  if (!data.defaults || typeof data.defaults !== "object") data.defaults = {};
  data.defaults.model = modelCfg;
} else {
  const list = Array.isArray(data.list) ? data.list : [];
  const idx = list.findIndex((entry) => entry && entry.id === agentId);
  if (idx >= 0) {
    list[idx] = { ...list[idx], model: modelCfg };
    data.list = list;
  }
}
process.stdout.write(JSON.stringify(data));
EOF
  )" || return 1
  openclaw config set "agents" "$next_agents_json" --strict-json
}

get_agent_model_refs() {
  local agent_id="$1"
  local current_agents_json output=""
  current_agents_json="$(openclaw config get agents 2>/dev/null || echo '{}')"
  output="$(
    AGENT_ID="$agent_id" CURRENT_JSON="$current_agents_json" node - <<'EOF'
const parseJson = (raw, fallback) => {
  try { return JSON.parse(raw || ""); } catch { return fallback; }
};
const data = parseJson(process.env.CURRENT_JSON, {});
const agentId = process.env.AGENT_ID || "main";
let modelCfg = undefined;
if (agentId === "main") {
  modelCfg = data?.defaults?.model;
} else {
  const entry = (Array.isArray(data?.list) ? data.list : []).find((item) => item && item.id === agentId);
  modelCfg = entry?.model;
}
if (typeof modelCfg === "string") {
  console.log(modelCfg);
  process.exit(0);
}
const primary = typeof modelCfg?.primary === "string" ? modelCfg.primary.trim() : "";
if (primary) console.log(primary);
for (const item of Array.isArray(modelCfg?.fallbacks) ? modelCfg.fallbacks : []) {
  if (typeof item === "string" && item.trim() && item.trim() !== primary) console.log(item.trim());
}
EOF
  )" || true
  printf '%s\n' "$output"
}

remove_model_from_provider() {
  local provider_id="$1"
  local model_id="$2"
  local current_json next_json
  current_json="$(openclaw config get "models.providers.${provider_id}" 2>/dev/null || echo '{}')"
  next_json="$(
    CURRENT_JSON="$current_json" MODEL_ID="$model_id" node - <<'EOF'
const parseJson = (raw, fallback) => {
  try { return JSON.parse(raw || ""); } catch { return fallback; }
};
const data = parseJson(process.env.CURRENT_JSON, {});
const removeId = (process.env.MODEL_ID || "").trim();
data.models = (Array.isArray(data.models) ? data.models : []).filter((entry) => (entry?.id || "") !== removeId);
process.stdout.write(JSON.stringify(data));
EOF
  )" || return 1
  openclaw config set "models.providers.${provider_id}" "$next_json" --strict-json
}

model_ref_is_primary_anywhere() {
  local model_ref="$1"
  local current_agents_json match
  current_agents_json="$(openclaw config get agents 2>/dev/null || echo '{}')"
  match="$(
    MODEL_REF="$model_ref" CURRENT_JSON="$current_agents_json" node - <<'EOF'
const parseJson = (raw, fallback) => {
  try { return JSON.parse(raw || ""); } catch { return fallback; }
};
const data = parseJson(process.env.CURRENT_JSON, {});
const target = (process.env.MODEL_REF || "").trim();
if ((data?.defaults?.model?.primary || "") === target) {
  process.stdout.write("defaults");
  process.exit(0);
}
for (const entry of Array.isArray(data?.list) ? data.list : []) {
  const model = entry?.model;
  const primary = typeof model === "string" ? model : (model?.primary || "");
  if (primary === target) {
    process.stdout.write(entry?.id || "agent");
    process.exit(0);
  }
}
EOF
  )" || true
  [ -n "$match" ]
}

remove_model_references_from_agents() {
  local model_ref="$1"
  local current_agents_json next_agents_json
  current_agents_json="$(openclaw config get agents 2>/dev/null || echo '{}')"
  next_agents_json="$(
    MODEL_REF="$model_ref" CURRENT_JSON="$current_agents_json" node - <<'EOF'
const parseJson = (raw, fallback) => {
  try { return JSON.parse(raw || ""); } catch { return fallback; }
};
const data = parseJson(process.env.CURRENT_JSON, {});
const target = (process.env.MODEL_REF || "").trim();
if (data?.defaults?.models && typeof data.defaults.models === "object") {
  delete data.defaults.models[target];
}
const cleanModelCfg = (cfg) => {
  if (!cfg) return cfg;
  if (typeof cfg === "string") return cfg === target ? "" : cfg;
  const fallbacks = Array.isArray(cfg.fallbacks) ? cfg.fallbacks.filter((item) => item && item !== target) : [];
  let primary = typeof cfg.primary === "string" ? cfg.primary : "";
  if (primary === target) {
    primary = fallbacks.shift() || "";
  }
  return primary ? { primary, ...(fallbacks.length ? { fallbacks } : {}) } : undefined;
};
if (data?.defaults) {
  const cleaned = cleanModelCfg(data.defaults.model);
  if (cleaned) data.defaults.model = cleaned; else delete data.defaults.model;
}
if (Array.isArray(data?.list)) {
  data.list = data.list.map((entry) => {
    const cleaned = cleanModelCfg(entry?.model);
    const next = { ...entry };
    if (cleaned) next.model = cleaned; else delete next.model;
    return next;
  });
}
process.stdout.write(JSON.stringify(data));
EOF
  )" || return 1
  openclaw config set "agents" "$next_agents_json" --strict-json
}

openclaw_provider_model_management_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== 供应商模型管理 =====${NC}"
    echo "1) 从供应商接口同步模型到 OpenClaw"
    echo "2) 从 OpenClaw 删除已配置的供应商模型"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1)
        ensure_openclaw_installed || { pause; continue; }
        local provider_id provider_json provider_base_url provider_api provider_auth_header provider_api_key profile_id model_context model_max_tokens
        echo "--- 当前 Providers ---"
        openclaw config get models.providers 2>/dev/null || true
        echo
        select_provider_id provider_id || { pause; continue; }
        provider_json="$(openclaw config get "models.providers.${provider_id}" 2>/dev/null || echo '{}')"
        provider_base_url="$(printf '%s' "$provider_json" | node -e 'let raw=""; process.stdin.setEncoding("utf8"); process.stdin.on("data", c => raw += c); process.stdin.on("end", () => { try { const data = JSON.parse(raw || "{}"); process.stdout.write(data?.baseUrl || ""); } catch {} });')"
        provider_api="$(printf '%s' "$provider_json" | node -e 'let raw=""; process.stdin.setEncoding("utf8"); process.stdin.on("data", c => raw += c); process.stdin.on("end", () => { try { const data = JSON.parse(raw || "{}"); process.stdout.write(data?.api || "openai-completions"); } catch {} });')"
        provider_auth_header="$(printf '%s' "$provider_json" | node -e 'let raw=""; process.stdin.setEncoding("utf8"); process.stdin.on("data", c => raw += c); process.stdin.on("end", () => { try { const data = JSON.parse(raw || "{}"); process.stdout.write(data?.authHeader ? "Y" : "N"); } catch { process.stdout.write("Y"); } });')"
        provider_api_key="$(openclaw config get "models.providers.${provider_id}.apiKey" 2>/dev/null || true)"
        provider_api_key="$(normalize_provider_api_key "$provider_api_key" "$provider_base_url")"
        profile_id="${provider_id}:manual"
        model_context="128000"
        model_max_tokens="8192"
        if [ -z "$provider_base_url" ]; then
          warn "当前 Provider 未配置 Base URL，无法自动更新模型列表"
          pause
          continue
        fi
        info "当前 Provider: ${provider_id}"
        info "Base URL: ${provider_base_url}"
        if [ -n "$provider_api_key" ]; then
          info "API Token: 已检测到，默认沿用可用配置"
        else
          warn "当前 Provider 未检测到 API Token，需要手工补充"
          prompt_optional "请输入 API Token: " provider_api_key
        fi
        if ! select_and_add_remote_models \
          "$provider_id" "$provider_base_url" "$provider_api" "$provider_auth_header" "$provider_api_key" "$profile_id" \
          "$model_context" "$model_max_tokens"; then
          warn "更新供应商模型列表失败"
        fi
        pause ;;
      2)
        ensure_openclaw_installed || { pause; continue; }
        local del_provider_id
        echo "--- 当前 Providers ---"
        openclaw config get models.providers 2>/dev/null || true
        echo
        select_provider_id del_provider_id || { pause; continue; }
        if ! select_and_remove_provider_models "$del_provider_id"; then
          warn "删除供应商模型失败"
        fi
        pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

openclaw_agent_model_management_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== Agent 模型管理 =====${NC}"
    echo "1) 设置 Agent 主模型（单选）"
    echo "2) 设置 Agent Fallback 模型（多选）"
    echo "3) 查看 Agent 模型状态"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1)
        ensure_openclaw_installed || { pause; continue; }
        local agent_id primary_model current_primary fallback_blob current_fallbacks_prompt=""
        local -a current_agent_models=()
        echo "--- 当前 Agent 列表 ---"
        openclaw config get agents.list 2>/dev/null || true
        echo
        select_agent_id agent_id || { pause; continue; }
        echo
        mapfile -t current_agent_models < <(get_agent_model_refs "$agent_id")
        current_primary="${current_agent_models[0]:-}"
        if [ "${#current_agent_models[@]}" -gt 1 ]; then
          current_fallbacks_prompt="$(printf '%s, ' "${current_agent_models[@]:1}")"
          current_fallbacks_prompt="${current_fallbacks_prompt%, }"
        else
          current_fallbacks_prompt="无"
        fi
        info "当前 ${agent_id} 主模型: ${current_primary:-未设置}"
        info "当前 ${agent_id} Fallback: ${current_fallbacks_prompt}"
        mapfile -t provider_refs < <(get_provider_model_refs)
        if [ "${#provider_refs[@]}" -eq 0 ]; then
          warn "当前还没有可用的供应商模型，请先在“供应商模型管理”中同步模型"
          pause
          continue
        fi
        select_from_list_with_prompt \
          "请选择 ${agent_id} 的主模型" \
          "当前主模型: ${current_primary:-未设置}\n当前 Fallback: ${current_fallbacks_prompt}\n\n请选择新的主模型（单选）" \
          primary_model \
          "${provider_refs[@]}" || { pause; continue; }
        merge_models_into_agents_defaults "$(printf '%s\n' "$primary_model")" || { warn "写入 Agent 可用模型失败"; pause; continue; }
        fallback_blob="$(printf '%s\n' "${current_agent_models[@]:1}")" || true
        set_agent_model_config "$agent_id" "$primary_model" "$fallback_blob" || { warn "写入 Agent 模型配置失败"; pause; continue; }
        ok "Agent 主模型已更新: ${agent_id} -> ${primary_model}"
        pause ;;
      2)
        ensure_openclaw_installed || { pause; continue; }
        local fallback_agent_id fallback_primary fallback_blob current_fallbacks_display="无"
        local -a fallback_candidates=() current_agent_models=()
        echo "--- 当前 Agent 列表 ---"
        openclaw config get agents.list 2>/dev/null || true
        echo
        select_agent_id fallback_agent_id || { pause; continue; }
        mapfile -t current_agent_models < <(get_agent_model_refs "$fallback_agent_id")
        fallback_primary="${current_agent_models[0]:-}"
        if [ -z "$fallback_primary" ]; then
          warn "当前 Agent 还没有主模型，请先设置主模型"
          pause
          continue
        fi
        if [ "${#current_agent_models[@]}" -gt 1 ]; then
          current_fallbacks_display="$(printf '%s, ' "${current_agent_models[@]:1}")"
          current_fallbacks_display="${current_fallbacks_display%, }"
        fi
        info "当前 ${fallback_agent_id} 主模型: ${fallback_primary}"
        info "当前 ${fallback_agent_id} Fallback: ${current_fallbacks_display}"
        mapfile -t provider_refs < <(get_provider_model_refs)
        if [ "${#provider_refs[@]}" -eq 0 ]; then
          warn "当前还没有可用的供应商模型，请先在“供应商模型管理”中同步模型"
          pause
          continue
        fi
        for model_ref in "${provider_refs[@]}"; do
          if [ "$model_ref" != "$fallback_primary" ]; then
            fallback_candidates+=("$model_ref")
          fi
        done
        if [ "${#fallback_candidates[@]}" -eq 0 ]; then
          warn "当前没有可用的 fallback 模型候选项"
          pause
          continue
        fi
        if select_multiple_with_whiptail \
          "请选择 ${fallback_agent_id} 的 Fallback 模型" \
          "当前主模型: ${fallback_primary}\n当前 Fallback: ${current_fallbacks_display}\n\n请选择 0 个或多个 Fallback 模型" \
          fallback_blob \
          "${fallback_candidates[@]}"; then
          merge_models_into_agents_defaults "$fallback_blob" || { warn "写入 Agent 可用模型失败"; pause; continue; }
        else
          fallback_blob=""
        fi
        set_agent_model_config "$fallback_agent_id" "$fallback_primary" "$fallback_blob" || { warn "写入 Agent 模型配置失败"; pause; continue; }
        ok "Agent Fallback 已更新: ${fallback_agent_id}"
        pause ;;
      3)
        ensure_openclaw_installed && openclaw models status
        pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

openclaw_model_aliases_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== 模型别名管理 =====${NC}"
    echo "提示: 对已有别名统一使用“先查看、再选择”的方式"
    echo
    echo "1) 查看模型别名"
    echo "2) 新增模型别名"
    echo "3) 更新已有别名"
    echo "4) 删除模型别名"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1) ensure_openclaw_installed && openclaw models aliases list; pause ;;
      2)
        ensure_openclaw_installed || { pause; continue; }
        local alias_name alias_model
        echo "--- 当前已配置模型 ---"
        openclaw models list 2>/dev/null || true
        echo
        prompt_optional "请输入新的别名名称: " alias_name
        select_configured_model_ref alias_model || { pause; continue; }
        if [ -n "$alias_name" ] && [ -n "$alias_model" ]; then
          openclaw models aliases add "$alias_name" "$alias_model"
        else
          warn "别名名称和模型 ID 都不能为空"
        fi
        pause ;;
      3)
        ensure_openclaw_installed || { pause; continue; }
        local alias_update alias_target
        echo "--- 当前别名 ---"
        openclaw models aliases list 2>/dev/null || true
        echo
        select_alias_name alias_update || { pause; continue; }
        echo
        echo "--- 当前已配置模型 ---"
        openclaw models list 2>/dev/null || true
        echo
        select_configured_model_ref alias_target || { pause; continue; }
        [ -n "$alias_update" ] && [ -n "$alias_target" ] && openclaw models aliases add "$alias_update" "$alias_target" || warn "未完成别名更新"
        pause ;;
      4)
        ensure_openclaw_installed || { pause; continue; }
        local alias_remove
        echo "--- 当前别名 ---"
        openclaw models aliases list 2>/dev/null || true
        echo
        select_alias_name alias_remove || { pause; continue; }
        [ -n "$alias_remove" ] && openclaw models aliases remove "$alias_remove" || warn "未选择别名"
        pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

manual_upsert_provider_model() {
  local provider_id="$1"
  local provider_base_url="$2"
  local provider_api="$3"
  local provider_auth_header="$4"
  local provider_api_key="$5"
  local profile_id="$6"
  local model_id="$7"
  local model_name="$8"
  local model_reasoning="$9"
  local model_context="${10}"
  local model_max_tokens="${11}"
  local current_provider_json merged_provider_json auth_profile_json

  current_provider_json="$(openclaw config get "models.providers.${provider_id}" 2>/dev/null || echo '{}')"

  merged_provider_json="$(
    CURRENT_JSON="$current_provider_json" \
    PROVIDER_BASE_URL="$provider_base_url" \
    PROVIDER_API="$provider_api" \
    PROVIDER_AUTH_HEADER="$provider_auth_header" \
    MODEL_ID="$model_id" \
    MODEL_NAME="$model_name" \
    MODEL_REASONING="$model_reasoning" \
    MODEL_CONTEXT="$model_context" \
    MODEL_MAX_TOKENS="$model_max_tokens" \
    node - <<'EOF'
const parseJson = (raw, fallback) => {
  try {
    return JSON.parse(raw);
  } catch {
    return fallback;
  }
};
const current = parseJson(process.env.CURRENT_JSON || "{}", {});
const models = Array.isArray(current.models) ? current.models.filter(Boolean) : [];
const nextModel = {
  id: process.env.MODEL_ID,
  name: process.env.MODEL_NAME,
  reasoning: /^(true|1|yes|y)$/i.test(process.env.MODEL_REASONING || ""),
  input: ["text"],
  cost: {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
  },
  contextWindow: Number.parseInt(process.env.MODEL_CONTEXT || "128000", 10),
  maxTokens: Number.parseInt(process.env.MODEL_MAX_TOKENS || "8192", 10),
};
const filtered = models.filter((entry) => entry && entry.id !== nextModel.id);
filtered.push(nextModel);
const next = {
  ...current,
  baseUrl: process.env.PROVIDER_BASE_URL,
  api: process.env.PROVIDER_API,
  authHeader: /^(true|1|yes|y)$/i.test(process.env.PROVIDER_AUTH_HEADER || ""),
  models: filtered,
};
process.stdout.write(JSON.stringify(next));
EOF
  )" || return 1

  auth_profile_json="$(
    PROFILE_PROVIDER="$provider_id" node - <<'EOF'
process.stdout.write(JSON.stringify({
  provider: process.env.PROFILE_PROVIDER,
  mode: "api_key",
}));
EOF
  )" || return 1

  openclaw config set "auth.profiles.${profile_id}" "$auth_profile_json" --strict-json || return 1
  openclaw config set "models.providers.${provider_id}" "$merged_provider_json" --strict-json || return 1
  if [ -n "$provider_api_key" ]; then
    openclaw config set "models.providers.${provider_id}.apiKey" "$provider_api_key" || return 1
  fi
  return 0
}

infer_model_reasoning_flag() {
  local model_id="$1"
  local lowered
  lowered="$(printf '%s' "$model_id" | tr '[:upper:]' '[:lower:]')"
  case "$lowered" in
    *reason*|*thinking*|o1*|o3*|o4*|*sonnet*thinking*|*opus*thinking*)
      echo "Y"
      ;;
    *)
      echo "N"
      ;;
  esac
}

resolve_models_endpoint() {
  local base_url="$1"
  local trimmed="${base_url%/}"
  case "$trimmed" in
    */models) printf '%s\n' "$trimmed" ;;
    */chat/completions) printf '%s/models\n' "${trimmed%/chat/completions}" ;;
    */completions) printf '%s/models\n' "${trimmed%/completions}" ;;
    */messages) printf '%s/models\n' "${trimmed%/messages}" ;;
    */v1) printf '%s/models\n' "$trimmed" ;;
    *) printf '%s/models\n' "$trimmed" ;;
  esac
}

fetch_remote_model_ids() {
  local base_url="$1"
  local api_key="$2"
  local models_endpoint
  models_endpoint="$(resolve_models_endpoint "$base_url")"

  if [ -z "$api_key" ]; then
    curl -fsSL "$models_endpoint" 2>/dev/null | node -e 'let raw=""; process.stdin.setEncoding("utf8"); process.stdin.on("data", c => raw += c); process.stdin.on("end", () => { try { const data = JSON.parse(raw || "{}"); const items = Array.isArray(data?.data) ? data.data : Array.isArray(data?.models) ? data.models : []; for (const item of items) { const id = typeof item?.id === "string" ? item.id.trim() : ""; if (id) console.log(id); } } catch {} });'
  else
    curl -fsSL -H "Authorization: Bearer ${api_key}" "$models_endpoint" 2>/dev/null | node -e 'let raw=""; process.stdin.setEncoding("utf8"); process.stdin.on("data", c => raw += c); process.stdin.on("end", () => { try { const data = JSON.parse(raw || "{}"); const items = Array.isArray(data?.data) ? data.data : Array.isArray(data?.models) ? data.models : []; for (const item of items) { const id = typeof item?.id === "string" ? item.id.trim() : ""; if (id) console.log(id); } } catch {} });'
  fi
}

get_cliproxy_first_api_key() {
  resolve_cliproxy_paths
  if [ ! -f "$CLIPROXY_CONFIG_FILE" ]; then
    return 1
  fi

  awk '
    /^[[:space:]]*api-keys:[[:space:]]*$/ { in_keys=1; next }
    in_keys && /^[[:space:]]*-[[:space:]]*/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      gsub(/^"|"$/, "", line)
      print line
      exit
    }
    in_keys && /^[^[:space:]-]/ { exit }
  ' "$CLIPROXY_CONFIG_FILE"
}

normalize_provider_api_key() {
  local provider_api_key="$1"
  local provider_base_url="$2"
  local normalized="$provider_api_key"

  case "$normalized" in
    ""|"__OPENCLAW_REDACTED__")
      normalized=""
      ;;
  esac

  if [ -z "$normalized" ]; then
    case "$provider_base_url" in
      http://127.0.0.1:8317*|http://localhost:8317*)
        normalized="$(get_cliproxy_first_api_key 2>/dev/null || true)"
        ;;
    esac
  fi

  printf '%s\n' "$normalized"
}

select_and_add_remote_models() {
  local provider_id="$1"
  local provider_base_url="$2"
  local provider_api="$3"
  local provider_auth_header="$4"
  local provider_api_key="$5"
  local profile_id="$6"
  local default_context="$7"
  local default_max_tokens="$8"
  local selected_count=0
  local idx=""
  local model_id=""
  local model_name=""
  local reasoning_default=""
  local -a remote_models=()
  local -a existing_model_refs=()
  local -a selectable_models=()
  local -a selected_models=()
  local model_ref=""
  local color_prefix=""
  local selected_blob=""

  mapfile -t remote_models < <(fetch_remote_model_ids "$provider_base_url" "$provider_api_key")
  mapfile -t existing_model_refs < <(get_provider_model_ids "$provider_id" 2>/dev/null || true)
  if [ "${#remote_models[@]}" -eq 0 ]; then
    warn "未能从远端接口获取模型列表，将回退到手工录入。"
    return 1
  fi

  echo
  info "已获取到以下模型："
  echo -e "  ${GREEN}绿色${NC} = 已存在于 openclaw.json"
  echo -e "  ${RED}红色${NC} = 当前缺少，可在多选框中勾选添加"
  for idx in "${!remote_models[@]}"; do
    model_ref="${provider_id}/${remote_models[$idx]}"
    color_prefix="$RED"
    if [[ " ${existing_model_refs[*]} " == *" ${model_ref} "* ]]; then
      color_prefix="$GREEN"
    fi
    printf '  - %b%s%b\n' "$color_prefix" "${remote_models[$idx]}" "$NC"
    if [ "$color_prefix" = "$RED" ]; then
      selectable_models+=("${remote_models[$idx]}")
    fi
  done
  echo
  if [ "${#selectable_models[@]}" -eq 0 ]; then
    warn "当前 Provider 的模型都已存在，无需新增"
    return 1
  fi

  if ! select_multiple_with_whiptail \
    "同步供应商模型" \
    "请选择要同步到 OpenClaw 的模型（空格勾选，Tab 切换到确定）" \
    selected_blob \
    "${selectable_models[@]}"; then
    return 1
  fi
  readarray -t selected_models <<< "$selected_blob"

  if [ "${#selected_models[@]}" -eq 0 ]; then
    warn "没有可添加的新模型"
    return 1
  fi

  for model_id in "${selected_models[@]}"; do
    model_name="$model_id"
    reasoning_default="$(infer_model_reasoning_flag "$model_id")"
    if manual_upsert_provider_model \
      "$provider_id" "$provider_base_url" "$provider_api" "$provider_auth_header" "$provider_api_key" "$profile_id" \
      "$model_id" "$model_name" "$reasoning_default" "$default_context" "$default_max_tokens"; then
      ok "已添加模型: $model_id"
      selected_count=$((selected_count + 1))
    else
      warn "添加模型失败: $model_id"
    fi
  done

  if [ "$selected_count" -eq 0 ]; then
    warn "没有成功添加任何模型"
    return 1
  fi
  ok "已完成 ${selected_count} 个模型的添加/更新"
  return 0
}

select_and_remove_provider_models() {
  local provider_id="$1"
  local model_ref=""
  local model_id=""
  local color_prefix=""
  local marker=""
  local removed_count=0
  local selected_blob=""
  local -a provider_model_refs=()
  local -a selectable_models=()
  local -a selected_models=()

  mapfile -t provider_model_refs < <(get_provider_model_ids "$provider_id" 2>/dev/null || true)
  if [ "${#provider_model_refs[@]}" -eq 0 ]; then
    warn "当前 Provider 还没有可删除的模型"
    return 1
  fi

  echo
  info "当前 Provider 模型如下："
  echo -e "  ${RED}红色${NC} = 可删除"
  echo -e "  ${YELLOW}黄色${NC} = 当前被某个 Agent 主模型使用，不会出现在多选框中"
  for model_ref in "${provider_model_refs[@]}"; do
    model_id="${model_ref#*/}"
    color_prefix="$RED"
    marker=""
    if model_ref_is_primary_anywhere "$model_ref"; then
      color_prefix="$YELLOW"
      marker="  [主模型占用中]"
    else
      selectable_models+=("$model_id")
    fi
    printf '  - %b%s%b%s\n' "$color_prefix" "$model_id" "$NC" "$marker"
  done
  echo

  if [ "${#selectable_models[@]}" -eq 0 ]; then
    warn "当前 Provider 的模型都处于主模型占用状态，暂无可删除项"
    return 1
  fi

  if ! select_multiple_with_whiptail \
    "删除供应商模型" \
    "请选择要从 OpenClaw 删除的模型（空格勾选，Tab 切换到确定）" \
    selected_blob \
    "${selectable_models[@]}"; then
    return 1
  fi
  readarray -t selected_models <<< "$selected_blob"

  if [ "${#selected_models[@]}" -eq 0 ]; then
    warn "没有可删除的模型"
    return 1
  fi

  for model_id in "${selected_models[@]}"; do
    model_ref="${provider_id}/${model_id}"
    remove_model_from_provider "$provider_id" "$model_id" || {
      warn "删除供应商模型失败: ${model_ref}"
      continue
    }
    remove_model_references_from_agents "$model_ref" || true
    ok "已删除供应商模型: ${model_ref}"
    removed_count=$((removed_count + 1))
  done

  if [ "$removed_count" -eq 0 ]; then
    warn "没有成功删除任何模型"
    return 1
  fi

  ok "已完成 ${removed_count} 个模型的删除"
  return 0
}

openclaw_manual_provider_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== 手工供应商 / 模型配置 =====${NC}"
    echo "1) 查看当前 providers 配置"
    echo "2) 自动拉取 models list 并选择添加"
    echo "3) 手工新增/更新单个模型"
    echo "4) 单独更新 API Key"
    echo "5) 单独更新 Base URL"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1)
        ensure_openclaw_installed && openclaw config get models.providers
        pause ;;
      2)
        ensure_openclaw_installed || { pause; continue; }
        local provider_id provider_base_url provider_api provider_auth_header provider_api_key profile_id
        local model_context model_max_tokens
        prompt_with_default "Provider ID（默认 cli-api）: " "cli-api" provider_id
        prompt_with_default "Base URL（默认 http://localhost:8317）: " "http://localhost:8317" provider_base_url
        prompt_with_default "API 类型（默认 openai-completions，可填 anthropic-messages）: " "openai-completions" provider_api
        prompt_with_default "是否使用 authHeader？[Y/N]: " "Y" provider_auth_header
        prompt_optional "API Token（请填写）: " provider_api_key
        prompt_optional "Auth Profile ID（默认 <provider>:manual）: " profile_id
        prompt_with_default "contextWindow（默认 128000）: " "128000" model_context
        prompt_with_default "maxTokens（默认 8192）: " "8192" model_max_tokens
        [ -z "$profile_id" ] && profile_id="${provider_id}:manual"
        if [ -n "$provider_id" ] && [ -n "$provider_base_url" ]; then
          if ! select_and_add_remote_models \
            "$provider_id" "$provider_base_url" "$provider_api" "$provider_auth_header" "$provider_api_key" "$profile_id" \
            "$model_context" "$model_max_tokens"; then
            warn "自动获取模型列表失败，可改用手工新增单个模型。"
          fi
        else
          warn "Provider ID 和 Base URL 不能为空"
        fi
        pause ;;
      3)
        ensure_openclaw_installed || { pause; continue; }
        local provider_id provider_base_url provider_api provider_auth_header provider_api_key profile_id
        local model_id model_name model_reasoning model_context model_max_tokens
        prompt_with_default "Provider ID（默认 cli-api）: " "cli-api" provider_id
        prompt_with_default "Base URL（默认 http://localhost:8317）: " "http://localhost:8317" provider_base_url
        prompt_with_default "API 类型（默认 openai-completions，可填 anthropic-messages）: " "openai-completions" provider_api
        prompt_with_default "是否使用 authHeader？[Y/N]: " "Y" provider_auth_header
        prompt_optional "API Token（可直接粘贴，留空则不改）: " provider_api_key
        prompt_optional "Auth Profile ID（默认 <provider>:manual）: " profile_id
        prompt_optional "模型 ID: " model_id
        prompt_optional "模型显示名称（留空默认同模型 ID）: " model_name
        prompt_with_default "是否 reasoning 模型？[Y/N]: " "N" model_reasoning
        prompt_with_default "contextWindow（默认 128000）: " "128000" model_context
        prompt_with_default "maxTokens（默认 8192）: " "8192" model_max_tokens
        [ -z "$profile_id" ] && profile_id="${provider_id}:manual"
        [ -z "$model_name" ] && model_name="$model_id"
        if [ -n "$provider_id" ] && [ -n "$provider_base_url" ] && [ -n "$model_id" ]; then
          manual_upsert_provider_model \
            "$provider_id" "$provider_base_url" "$provider_api" "$provider_auth_header" "$provider_api_key" "$profile_id" \
            "$model_id" "$model_name" "$model_reasoning" "$model_context" "$model_max_tokens"
        else
          warn "Provider ID、Base URL、模型 ID 不能为空"
        fi
        pause ;;
      4)
        ensure_openclaw_installed || { pause; continue; }
        local key_provider_id key_value
        echo "--- 当前 Providers ---"
        openclaw config get models.providers 2>/dev/null || true
        echo
        select_provider_id key_provider_id || { pause; continue; }
        prompt_optional "新的 API Key: " key_value
        if [ -n "$key_provider_id" ] && [ -n "$key_value" ]; then
          openclaw config set "models.providers.${key_provider_id}.apiKey" "$key_value"
        else
          warn "Provider ID 和 API Key 都不能为空"
        fi
        pause ;;
      5)
        ensure_openclaw_installed || { pause; continue; }
        local url_provider_id url_value
        echo "--- 当前 Providers ---"
        openclaw config get models.providers 2>/dev/null || true
        echo
        select_provider_id url_provider_id || { pause; continue; }
        prompt_optional "新的 Base URL: " url_value
        if [ -n "$url_provider_id" ] && [ -n "$url_value" ]; then
          openclaw config set "models.providers.${url_provider_id}.baseUrl" "$url_value"
        else
          warn "Provider ID 和 Base URL 都不能为空"
        fi
        pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

openclaw_add_cliproxy_models_menu() {
  local provider_id="cli-api"
  local provider_base_url="http://localhost:8317"
  local provider_api="openai-completions"
  local provider_auth_header="Y"
  local provider_api_key=""
  local profile_id=""
  local model_context="128000"
  local model_max_tokens="8192"

  ensure_openclaw_installed || return 1
  detect_cliproxy_runtime >/dev/null 2>&1 || true
  if [ "${CLIPROXY_RUNTIME_MODE:-none}" = "none" ]; then
    warn "未检测到 CLI Proxy API 安装。"
    info "请先进入“系统环境与依赖 -> CLI Proxy API”完成安装或部署。"
    return 1
  fi

  resolve_cliproxy_paths
  provider_api_key="$(get_cliproxy_first_api_key 2>/dev/null || true)"
  if [ -z "$provider_api_key" ]; then
    warn "未能从 CLI Proxy API 配置文件读取 API Token。"
    info "请先检查配置文件中的 api-keys: ${CLIPROXY_CONFIG_FILE}"
    return 1
  fi

  echo -e "${BLUE}===== 一键添加 CLI Proxy API 模型 =====${NC}"
  echo "检测方式: $(get_cliproxy_mode_label)"
  echo "配置文件: ${CLIPROXY_CONFIG_FILE}"
  echo

  prompt_with_default "供应商名称（默认 cli-api）: " "$provider_id" provider_id
  prompt_with_default "API URL（默认 http://localhost:8317）: " "$provider_base_url" provider_base_url
  prompt_with_default "API Token（默认读取配置文件中的第一个 key）: " "$provider_api_key" provider_api_key
  prompt_with_default "contextWindow（默认 128000）: " "$model_context" model_context
  prompt_with_default "maxTokens（默认 8192）: " "$model_max_tokens" model_max_tokens

  [ -z "$profile_id" ] && profile_id="${provider_id}:manual"
  if ! select_and_add_remote_models \
    "$provider_id" "$provider_base_url" "$provider_api" "$provider_auth_header" "$provider_api_key" "$profile_id" \
    "$model_context" "$model_max_tokens"; then
    warn "从 CLI Proxy API 获取模型列表失败。"
    info "如需继续，可改用“手工配置自定义供应商 / API / Base URL”。"
    return 1
  fi

  return 0
}

openclaw_models_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== 模型与供应商配置 =====${NC}"
    menu_section "【向导】"
    echo "1) 打开官方模型配置向导"
    echo "2) 一键添加 CLI Proxy API 模型"
    echo "3) 手工配置自定义供应商 / API / Base URL"

    menu_section "【查看】"
    echo "4) 查看 OpenClaw 已配置模型"
    echo "5) 查看 Agent 模型配置"

    menu_section "【维护】"
    echo "6) 供应商模型管理"
    echo "7) Agent 模型管理"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1) ensure_openclaw_installed && openclaw configure --section model; pause ;;
      2) openclaw_add_cliproxy_models_menu; pause ;;
      3) openclaw_manual_provider_menu ;;
      4) ensure_openclaw_installed && openclaw models list; pause ;;
      5) ensure_openclaw_installed && openclaw models status; pause ;;
      6) openclaw_provider_model_management_menu ;;
      7) openclaw_agent_model_management_menu ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

openclaw_config_values_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== 配置查看 / 设置 =====${NC}"
    menu_section "【快捷项】"
    echo "1) 常用配置快捷项"

    menu_section "【高级路径操作】"
    echo "2) 查看完整配置 (config get)"
    echo "3) 按路径查看配置值"
    echo "4) 按路径设置配置值"
    echo "5) 按路径删除配置值"
    echo "6) 校验当前配置文件"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1) common_config_shortcuts_menu ;;
      2)
        ensure_openclaw_installed && openclaw config get
        pause ;;
      3)
        ensure_openclaw_installed || { pause; continue; }
        local get_path
        prompt_optional "请输入配置路径（如 gateway.port / agents.defaults.model.primary）: " get_path
        if [ -n "$get_path" ]; then
          openclaw config get "$get_path"
        else
          warn "未输入配置路径"
        fi
        pause ;;
      4)
        ensure_openclaw_installed || { pause; continue; }
        local set_path set_value set_strict set_argv
        prompt_optional "请输入配置路径: " set_path
        prompt_optional "请输入配置值: " set_value
        prompt_optional "是否按严格 JSON 写入？[Y/N]: " set_strict
        if [ -n "$set_path" ] && [ -n "$set_value" ]; then
          set_argv=(openclaw config set "$set_path" "$set_value")
          [[ "$set_strict" =~ ^[Yy]$ ]] && set_argv+=(--strict-json)
          "${set_argv[@]}"
        else
          warn "配置路径和值都不能为空"
        fi
        pause ;;
      5)
        ensure_openclaw_installed || { pause; continue; }
        local unset_path
        prompt_optional "请输入要删除的配置路径: " unset_path
        if [ -n "$unset_path" ]; then
          openclaw config unset "$unset_path"
        else
          warn "未输入配置路径"
        fi
        pause ;;
      6)
        ensure_openclaw_installed && openclaw config validate
        pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

openclaw_business_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== OpenClaw 业务配置 =====${NC}"
    echo "当前: 模型 / 渠道 / 节点 / 权限"
    echo
    echo "1) 自定义模型"
    echo "2) Agent Tool 权限"
    echo "3) 聊天与节点管理"

    echo
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1) openclaw_models_menu ;;
      2) openclaw_approvals_menu ;;
      3) openclaw_chat_nodes_menu ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

show_status_summary() {
  clear
  local os_name kernel_version primary_ip
  local docker_state="down" cliproxy_state="down" openclaw_state="down"
  local node_state="down" ssh_state="down" vnc_state="down"
  local docker_version="未安装" node_version="未安装"
  local docker_detail="Docker 未安装"
  local cliproxy_detail="未部署容器"
  local openclaw_detail="OpenClaw 未安装"
  local node_detail="Node.js 未安装"
  local ssh_detail="OpenSSH Server 未安装"
  local vnc_detail="VNC 未配置"
  local current_ver="" remote_ver="" gateway_state="未运行"
  local overall_state="ok"

  os_name="$(. /etc/os-release && echo "${PRETTY_NAME:-$ID}")"
  kernel_version="$(uname -r)"
  primary_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "未知")"

  if need_cmd docker; then
    docker_version="$(docker --version 2>/dev/null || echo '已安装')"
    docker_state="warn"
    docker_detail="${docker_version}"
    if systemctl is-active docker >/dev/null 2>&1; then
      docker_state="ok"
      docker_detail="${docker_version} | daemon active"
    fi
    if ! id -nG "$TARGET_USER" 2>/dev/null | grep -qw docker; then
      docker_state="warn"
      docker_detail="${docker_detail} | user not in docker group"
    fi
  fi

  if detect_cliproxy_runtime; then
    cliproxy_state="$CLIPROXY_RUNTIME_STATE"
    cliproxy_detail="$CLIPROXY_RUNTIME_DETAIL"
    if [ "$CLIPROXY_RUNTIME_MODE" = "docker" ]; then
      cliproxy_detail="${cliproxy_detail} | config=${CLIPROXY_CONFIG_FILE}"
    elif [ "$CLIPROXY_RUNTIME_MODE" = "service" ]; then
      cliproxy_detail="${cliproxy_detail} | service=${CLIPROXY_SERVICE_NAME}"
    fi
  elif ! need_cmd docker; then
    cliproxy_detail="未安装（非 Docker / 非脚本部署）"
  fi

  if need_cmd openclaw; then
    openclaw_state="warn"
    current_ver="$(openclaw --version 2>/dev/null | sed -nE 's/^OpenClaw[[:space:]]+([0-9]+(\.[0-9]+){1,3}).*/\1/p')"
    remote_ver="$(curl -s --connect-timeout 2 https://api.github.com/repos/openclaw/openclaw/releases/latest | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/' || echo "")"
    if openclaw gateway status >/dev/null 2>&1; then
      gateway_state="运行中"
      openclaw_state="ok"
    fi
    if [ -z "$current_ver" ]; then
      openclaw_detail="$(openclaw --version 2>/dev/null || echo '已安装') | gateway=${gateway_state}"
    elif [ -n "$remote_ver" ] && [ "$current_ver" != "$remote_ver" ]; then
      openclaw_detail="v${current_ver} | gateway=${gateway_state} | latest=v${remote_ver}"
    else
      openclaw_detail="v${current_ver} | gateway=${gateway_state}"
    fi
  fi

  if need_cmd node; then
    node_state="ok"
    node_version="$(node --version 2>/dev/null || echo '已安装')"
    node_detail="${node_version}"
  fi

  if need_cmd sshd; then
    ssh_state="warn"
    ssh_detail="OpenSSH Server 已安装"
    if systemctl is-active ssh >/dev/null 2>&1; then
      ssh_state="ok"
      ssh_detail="OpenSSH Server active"
    fi
  fi

  if detect_vnc_runtime; then
    vnc_state="warn"
    vnc_detail="$(get_vnc_status_detail)"
    if systemctl is-active "$VNC_SERVICE_NAME" >/dev/null 2>&1 || run_as_target_user bash -lc "systemctl --user is-active $VNC_SERVICE_NAME" >/dev/null 2>&1; then
      vnc_state="ok"
    fi
  fi

  for state in "$docker_state" "$cliproxy_state" "$openclaw_state" "$node_state" "$ssh_state" "$vnc_state"; do
    if [ "$state" = "down" ]; then
      overall_state="down"
      break
    fi
    if [ "$state" = "warn" ] && [ "$overall_state" != "down" ]; then
      overall_state="warn"
    fi
  done

  echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║               OpenClaw Operations Dashboard             ║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
  echo
  echo -e "关键服务:   $(render_status_chip "Docker" "$docker_state")  $(render_status_chip "CLIProxy" "$cliproxy_state")  $(render_status_chip "OpenClaw" "$openclaw_state")"
  echo

  menu_section "【主机概览】"
  print_summary_row "版本" "v${TOOLBOX_VERSION}"
  print_summary_row "当前用户" "${TARGET_USER}"
  print_summary_row "系统" "${os_name}"
  print_summary_row "内核" "${kernel_version}"
  print_summary_row "主 IP" "${primary_ip}"
  print_summary_row "日志文件" "${LOG_FILE}"

  menu_section "【核心组件】"
  print_status_row "Docker" "$docker_state" "$docker_detail"
  print_status_row "CLI Proxy API" "$cliproxy_state" "$cliproxy_detail"
  print_status_row "OpenClaw" "$openclaw_state" "$openclaw_detail"
  print_status_row "Node.js" "$node_state" "$node_detail"

  menu_section "【系统服务】"
  print_status_row "SSH" "$ssh_state" "$ssh_detail"
  print_status_row "VNC" "$vnc_state" "$vnc_detail"

  menu_section "【运维提示】"
  if [ "$openclaw_state" = "down" ]; then
    echo "  - OpenClaw 尚未安装，可从主菜单进入“OpenClaw 安装与升级”。"
  elif [ "$openclaw_state" = "warn" ]; then
    echo "  - OpenClaw 已安装但网关未运行，可进入“网关与服务运维”处理。"
  else
    echo "  - OpenClaw 运行状态正常。"
  fi

  if [ "$cliproxy_state" = "down" ]; then
    echo "  - CLI Proxy API 尚未部署，如需本地模型中转可在“系统准备与环境管理”中部署。"
  elif [ "$cliproxy_state" = "warn" ]; then
    echo "  - CLI Proxy API 已安装但未完全运行，建议检查服务状态或日志。"
  else
    echo "  - CLI Proxy API 已处于可用状态。"
  fi

  if [ "$docker_state" = "warn" ]; then
    echo "  - Docker 已安装但宿主环境仍需关注 daemon 或 docker 组权限。"
  elif [ "$docker_state" = "down" ]; then
    echo "  - Docker 未安装，CLI Proxy API 和部分自动化能力暂不可用。"
  fi

  echo
  echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
  pause
}

write_cliproxy_config() {
  local api_token="$1"
  local listen_port="${2:-8317}"

  mkdir -p "$CLIPROXY_CONFIG_DIR" "$CLIPROXY_AUTH_DIR" || return 1
  chown -R "${TARGET_USER}:${TARGET_USER}" "$CLIPROXY_CONFIG_DIR" 2>/dev/null || true

  safe_write "$CLIPROXY_CONFIG_FILE" "host: \"\"
port: ${listen_port}
tls:
  enable: false
  cert: \"\"
  key: \"\"
remote-management:
  allow-remote: false
  secret-key: \"\"
  disable-control-panel: false
  panel-github-repository: \"https://github.com/router-for-me/Cli-Proxy-API-Management-Center\"
auth-dir: \"~/.cli-proxy-api\"
api-keys:
  - \"${api_token}\"
debug: false
pprof:
  enable: false
  addr: \"127.0.0.1:8316\"
commercial-mode: false
logging-to-file: false
logs-max-total-size-mb: 0
error-logs-max-files: 10
usage-statistics-enabled: false
proxy-url: \"\"
force-model-prefix: false
passthrough-headers: false
request-retry: 3
max-retry-credentials: 0
max-retry-interval: 30
quota-exceeded:
  switch-project: true
  switch-preview-model: true
routing:
  strategy: \"round-robin\"
ws-auth: false
nonstream-keepalive-interval: 0
" || return 1

  chmod 600 "$CLIPROXY_CONFIG_FILE" 2>/dev/null || true
  return 0
}

ensure_cliproxy_config() {
  local api_token=""
  local listen_port=""

  resolve_cliproxy_paths
  if [ -f "$CLIPROXY_CONFIG_FILE" ]; then
    return 0
  fi

  warn "未检测到 CLI Proxy API 配置文件。"
  info "将按当前推荐模板生成最小可用配置。"
  info "配置文件: ${CLIPROXY_CONFIG_FILE}"
  info "认证目录: ${CLIPROXY_AUTH_DIR}"
  read -rp "确认生成最小配置文件？[Y/N]: " cfm_config
  if [[ ! "$cfm_config" =~ ^[Yy]$ ]]; then
    warn "已取消"
    return 1
  fi

  step "生成 CLI Proxy API 最小配置..."
  prompt_optional "API Token（必填，供客户端访问 CLI Proxy API）: " api_token
  if [ -z "$api_token" ]; then
    err "API Token 不能为空"
    return 1
  fi

  prompt_with_default "监听端口（默认 8317）: " "8317" listen_port
  if [[ ! "$listen_port" =~ ^[0-9]+$ ]]; then
    err "端口必须是数字"
    return 1
  fi

  write_cliproxy_config "$api_token" "$listen_port" || {
    err "写入 CLI Proxy API 配置失败"
    return 1
  }

  ok "CLI Proxy API 最小配置已生成"
  info "配置文件: ${CLIPROXY_CONFIG_FILE}"
  info "认证目录: ${CLIPROXY_AUTH_DIR}"
  info "Docker 文档: https://help.router-for.me/cn/introduction/quick-start"
  return 0
}

deploy_cliproxyapi_docker() {
  ensure_root || return 1

  resolve_cliproxy_paths
  if ! need_cmd docker; then
    err "请先安装 Docker"
    return 1
  fi

  ensure_cliproxy_config || return 1

  mkdir -p "$CLIPROXY_AUTH_DIR" || return 1
  chown -R "${TARGET_USER}:${TARGET_USER}" "$CLIPROXY_AUTH_DIR" 2>/dev/null || true

  step "拉取 CLI Proxy API Docker 镜像..."
  docker_as_root pull "$CLIPROXY_IMAGE" || return 1

  if docker_as_root inspect "$CLIPROXY_CONTAINER_NAME" >/dev/null 2>&1; then
    warn "检测到已存在的 CLI Proxy API 容器，将先重建。"
    docker_as_root rm -f "$CLIPROXY_CONTAINER_NAME" >/dev/null 2>&1 || true
  fi

  step "部署 CLI Proxy API Docker 容器..."
  docker_as_root run -d \
    --name "$CLIPROXY_CONTAINER_NAME" \
    --restart unless-stopped \
    -p 8317:8317 \
    -v "${CLIPROXY_CONFIG_FILE}:/CLIProxyAPI/config.yaml" \
    -v "${CLIPROXY_AUTH_DIR}:/root/.cli-proxy-api" \
    "$CLIPROXY_IMAGE" || return 1

  ok "CLI Proxy API Docker 部署完成"
  info "访问地址: http://127.0.0.1:8317"
  info "配置文件: ${CLIPROXY_CONFIG_FILE}"
  info "认证目录: ${CLIPROXY_AUTH_DIR}"
  return 0
}

install_cliproxyapi_linux() {
  step "按官方 Linux 一键安装脚本部署 CLI Proxy API..."
  info "参考文档: https://help.router-for.me/cn/introduction/quick-start"
  run_as_target_user bash -lc "curl -fsSL https://raw.githubusercontent.com/brokechubb/cliproxyapi-installer/refs/heads/master/cliproxyapi-installer | bash" || return 1
  ensure_cliproxy_config || return 1
  detect_cliproxy_runtime || true
  ok "CLI Proxy API Linux 安装流程已执行完成"
}

start_cliproxyapi_linux() {
  if ! detect_cliproxy_runtime || [ "$CLIPROXY_RUNTIME_MODE" != "service" ]; then
    warn "未检测到 CLI Proxy API 的 Linux/systemd 安装"
    return 1
  fi
  run_as_target_user bash -lc "systemctl --user enable --now ${CLIPROXY_SERVICE_NAME}" || return 1
  ok "CLI Proxy API 用户服务已启动"
}

stop_cliproxyapi_linux() {
  if ! detect_cliproxy_runtime || [ "$CLIPROXY_RUNTIME_MODE" != "service" ]; then
    warn "未检测到 CLI Proxy API 的 Linux/systemd 安装"
    return 1
  fi
  run_as_target_user bash -lc "systemctl --user stop ${CLIPROXY_SERVICE_NAME}" || return 1
  ok "CLI Proxy API 用户服务已停止"
}

restart_cliproxyapi_linux() {
  if ! detect_cliproxy_runtime || [ "$CLIPROXY_RUNTIME_MODE" != "service" ]; then
    warn "未检测到 CLI Proxy API 的 Linux/systemd 安装"
    return 1
  fi
  run_as_target_user bash -lc "systemctl --user restart ${CLIPROXY_SERVICE_NAME}" || return 1
  ok "CLI Proxy API 用户服务已重启"
}

logs_cliproxyapi_linux() {
  if ! detect_cliproxy_runtime || [ "$CLIPROXY_RUNTIME_MODE" != "service" ]; then
    warn "未检测到 CLI Proxy API 的 Linux/systemd 安装"
    return 1
  fi
  run_as_target_user bash -lc "journalctl --user -u ${CLIPROXY_SERVICE_NAME} -n 200 --no-pager" || return 1
}

start_cliproxyapi_docker() {
  ensure_root || return 1
  docker_as_root start "$CLIPROXY_CONTAINER_NAME" || return 1
  ok "CLI Proxy API 已启动"
}

stop_cliproxyapi_docker() {
  ensure_root || return 1
  docker_as_root stop "$CLIPROXY_CONTAINER_NAME" || return 1
  ok "CLI Proxy API 已停止"
}

restart_cliproxyapi_docker() {
  ensure_root || return 1
  docker_as_root restart "$CLIPROXY_CONTAINER_NAME" || return 1
  ok "CLI Proxy API 已重启"
}

logs_cliproxyapi_docker() {
  ensure_root || return 1
  docker_as_root logs --tail 200 "$CLIPROXY_CONTAINER_NAME"
}

status_cliproxyapi_docker() {
  resolve_cliproxy_paths
  echo -e "${BLUE}═══ CLI Proxy API 状态 ═══${NC}"
  echo "访问地址: http://127.0.0.1:8317"
  echo "配置文件: ${CLIPROXY_CONFIG_FILE}"
  echo "认证目录: ${CLIPROXY_AUTH_DIR}"
  echo
  if ! detect_cliproxy_runtime; then
    warn "未检测到 CLI Proxy API（Docker / 官方一键脚本 / 手工进程）"
    return 0
  fi

  echo "部署方式: ${CLIPROXY_RUNTIME_MODE}"
  echo "状态说明: ${CLIPROXY_RUNTIME_DETAIL}"
  echo

  if [ "$CLIPROXY_RUNTIME_MODE" = "docker" ]; then
    ensure_root || return 1
    echo "容器名: ${CLIPROXY_CONTAINER_NAME}"
    echo "镜像: ${CLIPROXY_IMAGE}"
    echo "--- 容器状态 ---"
    docker_as_root inspect -f 'Status={{.State.Status}} StartedAt={{.State.StartedAt}}' "$CLIPROXY_CONTAINER_NAME"
    echo
    echo "--- 端口映射 ---"
    docker_as_root port "$CLIPROXY_CONTAINER_NAME" 2>/dev/null || true
  elif [ "$CLIPROXY_RUNTIME_MODE" = "service" ]; then
    echo "服务名: ${CLIPROXY_SERVICE_NAME}"
    echo "运行方式: systemd --user"
    echo "--- 用户服务状态 ---"
    run_as_target_user bash -lc "systemctl --user status ${CLIPROXY_SERVICE_NAME} --no-pager" 2>/dev/null || true
  elif [ "$CLIPROXY_RUNTIME_MODE" = "binary" ]; then
    echo "运行方式: 手工 / 直接进程"
    echo "命令路径: $(command -v cli-proxy-api 2>/dev/null || echo '未知')"
    echo "--- 进程列表 ---"
    pgrep -af '(^|/| )cli-proxy-api( |$)' 2>/dev/null || true
  fi
}

remove_cliproxyapi_docker() {
  ensure_root || return 1

  warn "此操作将删除 CLI Proxy API Docker 容器。"
  read -rp "确认删除容器？[Y/N]: " cfm
  if [[ ! "$cfm" =~ ^[Yy]$ ]]; then
    warn "已取消"
    return 0
  fi

  docker_as_root rm -f "$CLIPROXY_CONTAINER_NAME" 2>/dev/null || true

  read -rp "是否同时删除配置与认证目录 (${CLIPROXY_CONFIG_DIR})？[Y/N]: " cfm_clean
  if [[ "$cfm_clean" =~ ^[Yy]$ ]]; then
    rm -rf "$CLIPROXY_CONFIG_DIR"
    ok "配置与认证目录已清理"
  fi

  ok "CLI Proxy API Docker 容器已删除"
}

cliproxyapi_linux_menu() {
  while true; do
    clear
    resolve_cliproxy_paths
    echo -e "${BLUE}===== CLI Proxy API · Linux 安装 =====${NC}"
    detect_cliproxy_runtime >/dev/null 2>&1 || true
    echo "部署方式: ${CLIPROXY_RUNTIME_MODE:-none} | 服务: ${CLIPROXY_SERVICE_NAME:-未检测到}"
    echo "配置文件: ${CLIPROXY_CONFIG_FILE}"
    echo
    echo "1) 安装 / 更新（官方一键脚本）"
    echo "2) 启动用户服务"
    echo "3) 停止用户服务"
    echo "4) 重启用户服务"
    echo "5) 查看状态"
    echo "6) 查看日志"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1) install_cliproxyapi_linux; pause ;;
      2) start_cliproxyapi_linux; pause ;;
      3) stop_cliproxyapi_linux; pause ;;
      4) restart_cliproxyapi_linux; pause ;;
      5) status_cliproxyapi_docker; pause ;;
      6) logs_cliproxyapi_linux; pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

cliproxyapi_docker_menu() {
  while true; do
    clear
    resolve_cliproxy_paths
    echo -e "${BLUE}===== CLI Proxy API · Docker 容器安装 =====${NC}"
    echo "镜像: ${CLIPROXY_IMAGE} | 容器: ${CLIPROXY_CONTAINER_NAME}"
    echo "配置文件: ${CLIPROXY_CONFIG_FILE}"
    echo
    echo "1) 首次部署 Docker 容器"
    echo "2) 更新并重建容器"
    echo "3) 启动容器"
    echo "4) 停止容器"
    echo "5) 重启容器"
    echo "6) 查看状态"
    echo "7) 查看日志"
    echo "8) 删除容器"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1) deploy_cliproxyapi_docker; pause ;;
      2)
        warn "该操作会重新拉取镜像并删除重建现有容器。"
        read -rp "确认继续更新并重建容器？[Y/N]: " cfm_redeploy
        if [[ "$cfm_redeploy" =~ ^[Yy]$ ]]; then
          deploy_cliproxyapi_docker
        else
          warn "已取消"
        fi
        pause ;;
      3) start_cliproxyapi_docker; pause ;;
      4) stop_cliproxyapi_docker; pause ;;
      5) restart_cliproxyapi_docker; pause ;;
      6) status_cliproxyapi_docker; pause ;;
      7) logs_cliproxyapi_docker; pause ;;
      8) remove_cliproxyapi_docker; pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

cliproxyapi_menu() {
  while true; do
    clear
    resolve_cliproxy_paths
    echo -e "${BLUE}===== CLI Proxy API =====${NC}"
    detect_cliproxy_runtime >/dev/null 2>&1 || true
    echo "当前检测: $(get_cliproxy_mode_label) | ${CLIPROXY_RUNTIME_DETAIL:-未安装}"
    echo
    menu_section "【安装方式】"
    echo "1) Linux 方式管理（官方脚本 / systemd）"
    echo "2) Docker 方式管理"

    menu_section "【通用】"
    echo "3) 查看状态"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1) cliproxyapi_linux_menu ;;
      2) cliproxyapi_docker_menu ;;
      3) status_cliproxyapi_docker; pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
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

  read -rp "将为用户 ${TARGET_USER} 启用 sudo 免密（NOPASSWD），是否继续？[Y/N]: " cfm
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

  if as_root install -o root -g root -m 0440 "$tmpf" "$sudoers_file"; then
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
      
      # 确保是数字再比较
      if [[ "$major" =~ ^[0-9]+$ ]] && [[ "$minor" =~ ^[0-9]+$ ]]; then
        if [ "$major" -ge 24 ] || { [ "$major" -eq 22 ] && [ "$minor" -ge 22 ]; }; then
          ok "Node.js 版本满足要求 (≥22.22)"
          return 0
        else
          warn "Node.js 版本较低 ($node_ver)，建议升级到 v22.22.0 或更高版本"
          read -rp "是否尝试安装 Node.js 22.x LTS? [Y/N]: " cfm
          if [[ ! "$cfm" =~ ^[Yy]$ ]]; then
            return 0
          fi
        fi
      else
        warn "版本号解析结果非数字，跳过自动比对"
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
    _setup_pnpm_global || true
    ok "pnpm 已安装: $(pnpm --version 2>/dev/null || echo '未知')"
    if ! verify_pnpm_runtime; then
      warn "pnpm 环境验证失败，尝试自动修复后复检..."
      repair_pnpm_runtime || return 1
      verify_pnpm_runtime || return 1
    fi
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
        _setup_pnpm_global || return 1
        ok "已通过 corepack 安装 pnpm: $(pnpm --version)"
        if ! verify_pnpm_runtime; then
          warn "pnpm 环境验证失败，尝试自动修复后复检..."
          repair_pnpm_runtime || return 1
          verify_pnpm_runtime || return 1
        fi
        return 0
      fi
    fi
    warn "corepack 方式失败，尝试 npm 安装..."
  fi

  # 方式 2：npm 全局安装
  run_cmd_retry "npm 安装 pnpm" 3 npm install -g pnpm || return 1

  if need_cmd pnpm; then
    _setup_pnpm_global || return 1
    ok "pnpm 安装完成: $(pnpm --version)"
    if ! verify_pnpm_runtime; then
      warn "pnpm 环境验证失败，尝试自动修复后复检..."
      repair_pnpm_runtime || return 1
      verify_pnpm_runtime || return 1
    fi
  else
    err "pnpm 安装失败"
    return 1
  fi
}

uninstall_pnpm() {
  if ! need_cmd pnpm; then
    warn "系统中未检测到 pnpm，无需卸载。"
    return 0
  fi

  warn "此操作将从系统中移除 pnpm。"
  read -rp "确认卸载 pnpm？[Y/N]: " cfm
  if [[ ! "$cfm" =~ ^[Yy]$ ]]; then
    return 0
  fi

  step "1. 正在清理 pnpm 程序..."
  
  # 尝试 corepack disable
  if need_cmd corepack; then
    as_root corepack disable pnpm 2>/dev/null || true
  fi

  # 尝试 npm uninstall
  if need_cmd npm; then
    run_cmd "npm 卸载 pnpm" npm uninstall -g pnpm 2>/dev/null
  fi

  step "2. 清理全局配置..."
  local pnpm_home="/home/${TARGET_USER}/.local/share/pnpm"
  read -rp "是否删除 pnpm 全局目录和配置 ($pnpm_home)? [Y/N]: " cfm_clean
  if [[ "$cfm_clean" =~ ^[Yy]$ ]]; then
    rm -rf "$pnpm_home"
    rm -f "/home/${TARGET_USER}/.pnpmrc"
    remove_managed_block "/home/${TARGET_USER}/.bashrc" "# >>> openclaw-menu pnpm >>>" "# <<< openclaw-menu pnpm <<<" || true
    remove_managed_block "/home/${TARGET_USER}/.profile" "# >>> openclaw-menu pnpm >>>" "# <<< openclaw-menu pnpm <<<" || true
    ok "pnpm 相关数据已清理"
  fi

  ok "pnpm 卸载完成"
}

uninstall_nodejs() {
  if ! need_cmd node; then
    warn "系统中未检测到 Node.js，无需卸载。"
    return 0
  fi

  warn "此操作将从系统中移除 Node.js 和 npm。"
  read -rp "确认卸载 Node.js？[Y/N]: " cfm
  if [[ ! "$cfm" =~ ^[Yy]$ ]]; then
    return 0
  fi

  ensure_root || return 1

  step "1. 卸载 Node.js 软件包..."
  run_cmd "移除 nodejs" as_root apt-get remove -y nodejs || true
  run_cmd "清理依赖" as_root apt-get autoremove -y || true

  step "2. 移除 NodeSource 仓库..."
  as_root rm -f /etc/apt/sources.list.d/nodesource.list 2>/dev/null || true
  as_root rm -f /etc/apt/keyrings/nodesource.gpg 2>/dev/null || true

  step "3. 清理缓存..."
  as_root apt-get update 2>/dev/null || true

  if ! need_cmd node; then
    ok "Node.js 卸载完成"
  else
    warn "Node.js 可能未完全卸载，请手动检查"
  fi
}

nodejs_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== Node.js 环境 =====${NC}"
    echo "当前版本: $(get_current_node_version || echo '未安装') | 最新 LTS: $(get_latest_node_lts_version || echo '未知')"
    echo
    echo "1) 安装 / 更新 Node.js"
    echo "2) 卸载 Node.js"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1) install_nodejs; pause ;;
      2) uninstall_nodejs; pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

pnpm_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== pnpm 环境 =====${NC}"
    echo "当前版本: $(get_current_pnpm_version || echo '未安装') | 最新版本: $(get_latest_pnpm_version || echo '未知')"
    echo "安装路径: $(get_current_pnpm_path || echo '未安装')"
    echo
    echo "1) 查看 pnpm 状态"
    echo "2) 安装 / 更新 pnpm"
    echo "3) 修复 pnpm 环境"
    echo "4) 卸载 pnpm"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1)
        if need_cmd pnpm; then
          pnpm --version
          echo
          verify_pnpm_runtime || true
        else
          warn "pnpm 未安装"
        fi
        pause ;;
      2) install_pnpm; pause ;;
      3) repair_pnpm_runtime; pause ;;
      4) uninstall_pnpm; pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

# 配置 pnpm 全局 bin 目录（解决 ERR_PNPM_NO_GLOBAL_BIN_DIR）
_setup_pnpm_global() {
  need_cmd pnpm || return 1

  # 设置 PNPM_HOME
  local pnpm_home="/home/${TARGET_USER}/.local/share/pnpm"
  mkdir -p "$pnpm_home"
  export PNPM_HOME="$pnpm_home"

  # 显式设置全局 bin 目录 (关键修复)
  pnpm config set global-bin-dir "$pnpm_home" || return 1

  # 持久化 shell 环境，避免只在当前会话生效
  _persist_pnpm_shell_env || return 1

  # 确保 PNPM_HOME 在当前 session 的 PATH 中
  if [[ ":$PATH:" != *":${pnpm_home}:"* ]]; then
    export PATH="${pnpm_home}:${PATH}"
  fi

  hash -r 2>/dev/null || true
  info "pnpm 全局目录已配置: ${pnpm_home}"
  info "已写入 ~/.bashrc 与 ~/.profile，新的 shell 会自动加载 PNPM_HOME"
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
  if curl -fsSL https://download.docker.com/linux/debian/gpg | as_root gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
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
  warn "组变更需要重新登录后生效。你也可以尝试执行：newgrp docker"
  info "提示：如果不重新登录，当前 shell 中 docker 命令仍需 sudo。"
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

uninstall_docker() {
  ensure_root || return 1
  if ! need_cmd docker; then
    warn "未检测到 Docker，无需卸载。"
    return 0
  fi
  warn "此操作将卸载 Docker 组件。"
  read -rp "确认卸载 Docker？[Y/N]: " cfm
  if [[ ! "$cfm" =~ ^[Yy]$ ]]; then
    return 0
  fi
  as_root systemctl stop docker 2>/dev/null || true
  as_root apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
  ok "Docker 卸载流程已完成"
}

show_docker_containers() {
  if ! need_cmd docker; then
    warn "未安装 Docker"
    return 0
  fi
  docker ps -a
}

show_docker_images() {
  if ! need_cmd docker; then
    warn "未安装 Docker"
    return 0
  fi
  docker images
}

start_docker_service() {
  ensure_root || return 1
  as_root systemctl start docker
}

stop_docker_service() {
  ensure_root || return 1
  as_root systemctl stop docker
}

restart_docker_service() {
  ensure_root || return 1
  as_root systemctl restart docker
}

# ==================== OpenClaw 安装 ====================

install_openclaw() {
  if need_cmd openclaw; then
    local ver
    ver=$(openclaw --version 2>/dev/null || echo "未知")
    ok "OpenClaw 已安装: $ver"
    read -rp "是否重新安装/更新到最新版？[Y/N]: " cfm
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
  info "固定安装方式: pnpm（不再回退到 npm，避免后续 update 混用）"

  if ! need_cmd pnpm; then
    warn "未检测到 pnpm，将先安装 pnpm..."
    install_pnpm || return 1
  fi

  if ! need_cmd pnpm; then
    err "pnpm 仍不可用，无法继续安装 OpenClaw"
    return 1
  fi

  # 确保 pnpm 全局目录已配置
  _setup_pnpm_global || {
    err "pnpm 全局目录配置失败，无法继续安装 OpenClaw"
    return 1
  }

  if ! run_cmd_retry "pnpm 安装 openclaw" 3 pnpm add -g openclaw@latest; then
    err "pnpm 安装 openclaw 失败；已停止，避免回退到 npm 造成混装"
    return 1
  fi

  if need_cmd openclaw; then
    ok "OpenClaw 安装完成: $(openclaw --version 2>/dev/null || echo '未知')"
    verify_openclaw_deploy || return 1
    info "下一步: 主菜单 → OpenClaw 部署管理"
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
  verify_openclaw_deploy || return 1

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

  step "运行 OpenClaw Onboarding 交互式向导..."
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
    echo -e "${BLUE}===== OpenClaw 部署管理 =====${NC}"
    show_openclaw_deploy_banner

    menu_section "【安装维护】"
    echo "1) 安装 / 更新 OpenClaw"

    menu_section "【初始化&配置修改】"
    echo "2) 官方初始化 OpenClaw（推荐，执行: openclaw onboard --install-daemon）"
    echo "3) 打开官方配置向导（执行: openclaw configure）"

    menu_section "【部署后管理】"
    echo "4) OpenClaw 业务配置（模型/频道/权限）"
    echo "5) 部署健康检查（自动修复）"

    menu_section "【卸载】"
    echo "6) 卸载 OpenClaw"

    echo
    echo "0) 返回主菜单"
    read -rp "请选择: " n

    case "$n" in
      1) install_openclaw; pause ;;
      2) onboard_openclaw; pause ;;
      3) ensure_openclaw_installed && openclaw configure; pause ;;
      4) openclaw_business_menu ;;
      5) ensure_openclaw_installed && verify_openclaw_deploy; pause ;;
      6) uninstall_openclaw; pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

openclaw_gateway_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== 网关与服务运维 =====${NC}"
    echo "Gateway: $(get_gateway_state) | Config: $(ensure_openclaw_installed >/dev/null 2>&1 && openclaw config file 2>/dev/null || echo '未安装')"
    echo
    menu_section "【网关控制】"
    echo "1) 查看网关状态"
    echo "2) 启动网关"
    echo "3) 重启网关"
    echo "4) 停止网关"
    echo "5) 查看网关日志"
    echo "6) 打开 Web Dashboard"

    menu_section "【诊断与修复】"
    echo "7) 执行 doctor 诊断"
    echo "8) 执行 doctor --fix"
    echo "9) 安全审计 (security audit)"
    echo "10) 查看/维护会话 (sessions)"
    echo "11) 查看渠道日志 (channels logs)"
    echo "12) 验证当前配置文件"
    echo "13) 修复 OpenClaw 系统服务（官方 onboard）"
    echo "0) 返回主菜单"
    read -rp "请选择: " n

    case "$n" in
      1) ensure_openclaw_installed && openclaw gateway status; pause ;;
      2) ensure_openclaw_installed && openclaw gateway start; pause ;;
      3) ensure_openclaw_installed && openclaw gateway restart; pause ;;
      4) ensure_openclaw_installed && openclaw gateway stop; pause ;;
      5) ensure_openclaw_installed && openclaw logs; pause ;;
      6) ensure_openclaw_installed && openclaw dashboard; pause ;;
      7) ensure_openclaw_installed && openclaw doctor; pause ;;
      8) ensure_openclaw_installed && openclaw doctor --fix; pause ;;
      9) ensure_openclaw_installed && openclaw security audit; pause ;;
      10) ensure_openclaw_installed && openclaw sessions; pause ;;
      11) ensure_openclaw_installed && openclaw channels logs; pause ;;
      12) ensure_openclaw_installed && openclaw config validate; pause ;;
      13) onboard_openclaw; pause ;;
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
    echo -e "${BLUE}===== Docker 环境 =====${NC}"
    echo "当前版本: $(get_current_docker_version || echo '未安装') | 仓库版本: $(get_latest_docker_package_version || echo '未知')"
    echo "服务状态: $(need_cmd docker && systemctl is-active docker >/dev/null 2>&1 && echo '运行中' || echo '未运行/未安装')"
    echo
    echo "1) 安装 / 更新 Docker"
    echo "2) 卸载 Docker"
    echo "3) 当前用户加入 docker 组"
    echo "4) 查看容器"
    echo "5) 查看镜像"
    echo "6) 重启 Docker 服务"
    echo "7) 停止 Docker 服务"
    echo "8) 查看 Docker 状态"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1) install_docker; pause ;;
      2) uninstall_docker; pause ;;
      3) add_user_to_docker_group; pause ;;
      4) show_docker_containers; pause ;;
      5) show_docker_images; pause ;;
      6) restart_docker_service; pause ;;
      7) stop_docker_service; pause ;;
      8) check_docker_status; pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

vnc_menu() {
  while true; do
    clear
    detect_vnc_runtime >/dev/null 2>&1 || true
    echo -e "${BLUE}===== VNC 服务 =====${NC}"
    echo "当前状态: $(get_vnc_state)${VNC_SERVICE_NAME:+ | 服务: ${VNC_SERVICE_NAME}} | 显示: ${VNC_DISPLAY}"
    echo
    echo "1) 安装 / 初始化 Debian VNC 服务"
    echo "2) 启用 / 启动 VNC"
    echo "3) 停止 VNC"
    echo "4) 重启 VNC"
    echo "5) 查看 VNC 状态"
    echo "6) 重置 VNC 密码"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1) install_vnc_server; pause ;;
      2)
        if detect_vnc_runtime; then
          ensure_root || { pause; continue; }
          as_root systemctl enable --now "$VNC_SERVICE_NAME" 2>/dev/null || run_as_target_user bash -lc "systemctl --user enable --now $VNC_SERVICE_NAME"
        else
          warn "未检测到已配置的 VNC 服务单元，请先完成系统侧 VNC 安装与配置。"
        fi
        pause ;;
      3)
        if detect_vnc_runtime; then
          ensure_root || { pause; continue; }
          as_root systemctl stop "$VNC_SERVICE_NAME" 2>/dev/null || run_as_target_user bash -lc "systemctl --user stop $VNC_SERVICE_NAME"
        else
          warn "未检测到 VNC 服务"
        fi
        pause ;;
      4)
        if detect_vnc_runtime; then
          ensure_root || { pause; continue; }
          as_root systemctl restart "$VNC_SERVICE_NAME" 2>/dev/null || run_as_target_user bash -lc "systemctl --user restart $VNC_SERVICE_NAME"
        else
          warn "未检测到 VNC 服务"
        fi
        pause ;;
      5)
        if detect_vnc_runtime; then
          echo "服务名: ${VNC_SERVICE_NAME}"
          systemctl status "$VNC_SERVICE_NAME" --no-pager 2>/dev/null || run_as_target_user bash -lc "systemctl --user status $VNC_SERVICE_NAME --no-pager"
        else
          warn "未检测到 VNC 服务"
        fi
        pause ;;
      6) reset_vnc_password; pause ;;
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
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "未知")
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

# ==================== SMB 管理 ====================

get_smb_share_path() {
  echo "$SMB_DEFAULT_SHARE_PATH"
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
    info "默认共享目录: ${SMB_DEFAULT_SHARE_PATH}"
    info "共享名称: ${SMB_SHARE_NAME}"
    info "下一步建议: 设置 Samba 密码并写入共享配置"
  else
    err "Samba 安装失败"
    return 1
  fi
}

set_smb_password() {
  ensure_root || return 1

  if ! need_cmd smbd; then
    err "请先安装 Samba"
    return 1
  fi

  step "为当前用户 ${TARGET_USER} 配置 Samba 密码..."
  info "请输入你希望用于 Samba 登录的自定义密码"
  
  # 添加 Samba 用户
  if as_root smbpasswd -a "$TARGET_USER"; then
    ok "Samba 用户 ${TARGET_USER} 配置成功"
    # 连动触发
    read -rp "是否立即重启 Samba 服务以应用新用户配置？[Y/N]: " cfm_restart
    if [[ "$cfm_restart" =~ ^[Yy]$ ]]; then
      restart_smb
    fi
  else
    err "Samba 用户配置失败"
    return 1
  fi
}

change_smb_password() {
  ensure_root || return 1

  if ! need_cmd smbd; then
    err "请先安装 Samba"
    return 1
  fi

  step "修改当前用户 ${TARGET_USER} 的 Samba 密码..."
  info "请输入新的 Samba 登录密码"

  if as_root smbpasswd "$TARGET_USER"; then
    ok "Samba 密码已修改"
    read -rp "是否立即重启 Samba 服务以应用新密码？[Y/N]: " cfm_restart
    if [[ "$cfm_restart" =~ ^[Yy]$ ]]; then
      restart_smb
    fi
  else
    err "Samba 密码修改失败"
    return 1
  fi
}

configure_smb_permissions() {
  local share_path
  local perm_mode=""

  share_path="$(get_smb_share_path)"
  _validate_path "$share_path" || return 1

  if [ ! -d "$share_path" ]; then
    warn "共享目录不存在，将先创建: ${share_path}"
    mkdir -p "$share_path" || return 1
  fi

  echo -e "${BLUE}═══ Samba 文件夹权限配置 ═══${NC}"
  echo "共享目录: ${share_path}"
  echo "当前建议: 700（仅当前用户）"
  echo
  echo "1) 700 - 仅当前用户可访问"
  echo "2) 750 - 用户完全访问，组可读执行"
  echo "3) 755 - 其他用户可读执行"
  echo "4) 775 - 用户/组可写"
  echo "0) 取消"
  read -rp "请选择权限模式: " perm_choice

  case "$perm_choice" in
    1) perm_mode="700" ;;
    2) perm_mode="750" ;;
    3) perm_mode="755" ;;
    4) perm_mode="775" ;;
    0) warn "已取消"; return 0 ;;
    *) warn "无效输入"; return 1 ;;
  esac

  chown -R "${TARGET_USER}:${TARGET_USER}" "$share_path" || true
  chmod -R "$perm_mode" "$share_path" || return 1
  ok "共享目录权限已更新为 ${perm_mode}"
}

configure_smb_share() {
  ensure_root || return 1

  if ! need_cmd smbd; then
    err "请先安装 Samba"
    return 1
  fi

  local share_path
  share_path=$(get_smb_share_path)
  
  # 验证共享路径安全性
  _validate_path "$share_path" || {
    err "共享路径验证失败"
    return 1
  }
  
  step "配置 Samba 共享..."
  echo "共享名称: ${SMB_SHARE_NAME}"
  echo "共享路径: ${share_path}"
  echo "访问用户: ${TARGET_USER}"
  echo
  
  read -rp "确认配置？[Y/N]: " cfm
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

  # 设置权限 (收紧为 700，仅限所有者访问以保护隐私)
  chown -R "${TARGET_USER}:${TARGET_USER}" "$share_path"
  chmod -R 700 "$share_path"

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
    as_root awk -v share="${SMB_SHARE_NAME}" '
      $0 == "["share"]" { in_share=1; next }
      /^\[/ { in_share=0 }
      !in_share { print }
    ' "$SMB_CONF" > "$tmp_conf" && as_root mv "$tmp_conf" "$SMB_CONF"
    rm -f "$tmp_conf" 2>/dev/null  # 清理残留
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
  read -rp "是否立即重启 Samba 服务以生效？[Y/N]: " cfm_restart
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
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "未知")
  echo "--- 连接信息 ---"
  echo "  Windows: \\\\${ip}\\${SMB_SHARE_NAME}"
  echo "  macOS: smb://${ip}/${SMB_SHARE_NAME}"
  echo "  Linux: smb://${ip}/${SMB_SHARE_NAME}"
}

smb_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== Samba 文件共享 =====${NC}"
    local share_path
    share_path=$(get_smb_share_path)
    echo "共享名称: ${SMB_SHARE_NAME} | 共享路径: ${share_path} | 用户: ${TARGET_USER}"
    echo
    echo "1) 安装 Samba"
    echo "2) 设置 Samba 密码"
    echo "3) 修改 Samba 密码"
    echo "4) 文件夹权限"
    echo "5) 应用共享配置"
    echo "6) 启动 Samba 服务"
    echo "7) 停止 Samba 服务"
    echo "8) 重启 Samba 服务"
    echo "9) 设置开机自启"
    echo "10) 禁用开机自启"
    echo "11) 查看 Samba 状态"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1) install_smb; pause ;;
      2) set_smb_password; pause ;;
      3) change_smb_password; pause ;;
      4) configure_smb_permissions; pause ;;
      5) configure_smb_share; pause ;;
      6) start_smb; pause ;;
      7) stop_smb; pause ;;
      8) restart_smb; pause ;;
      9) enable_smb_autostart; pause ;;
      10) disable_smb_autostart; pause ;;
      11) check_smb_status; pause ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

ssh_fileshare_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== SSH / 文件共享 =====${NC}"
    echo "1) SSH 管理"
    echo "2) Samba 文件共享"
    echo "0) 返回上一级"
    read -rp "请选择: " n

    case "$n" in
      1) ssh_menu ;;
      2) smb_menu ;;
      0) return ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

uninstall_openclaw() {
  warn "此操作将从系统中移除 OpenClaw。"
  read -rp "确认卸载 OpenClaw？[Y/N]: " cfm
  if [[ ! "$cfm" =~ ^[Yy]$ ]]; then
    return 0
  fi

  # 确保环境变量就绪（特别是 pnpm）
  _setup_pnpm_global 2>/dev/null || true

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
    info "额外清理可能遗留的 npm 全局安装副本..."
    npm uninstall -g openclaw 2>/dev/null
  fi

  step "3. 清理配置选项..."
  if confirm_dangerous_cleanup_three_times "是否删除所有配置文件、数据库和工作空间 (~/.openclaw)？此操作不可恢复"; then
    rm -rf "/home/${TARGET_USER}/.openclaw"
    ok "配置已完全清理"
  fi

  ok "OpenClaw 卸载完成"
}

# ==================== 系统环境菜单 ====================

system_env_menu() {
  while true; do
    clear
    echo -e "${BLUE}===== 系统环境与依赖 =====${NC}"
    show_env_support_banner

    menu_section "【核心环境】"
    echo "1) Node.js"
    echo "2) pnpm"
    echo "3) Docker"
    echo "4) VNC"
    echo "5) CLI Proxy API"

    menu_section "【辅助环境】"
    echo "6) SSH / 文件共享"
    echo "7) sudo 免密"
    echo "8) 快捷启动别名 (alias y)"

    echo
    echo "0) 返回主菜单"
    read -rp "请选择: " n

    case "$n" in
      1) nodejs_menu ;;
      2) pnpm_menu ;;
      3) docker_menu ;;
      4) vnc_menu ;;
      5) cliproxyapi_menu ;;
      6) ssh_fileshare_menu ;;
      7) configure_nopasswd; pause ;;
      8) setup_shortcut; pause ;;
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
  warn "此操作将依次执行部署必需步骤："
  echo "  1. 配置 sudo 免密"
  echo "  2. 配置快捷启动别名 (alias y)"
  echo "  3. 安装 Node.js (v22.22+)"
  echo "  4. 安装 pnpm 包管理器"
  echo "  5. 安装 Docker"
  echo "  6. 用户加入 docker 组"
  echo "  7. 安装并引导配置 OpenClaw (setup + doctor + onboard)"
  echo
  read -rp "确认执行一键初始化？[Y/N]: " cfm
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
    if init_openclaw; then
      echo
      step "启动交互式配置向导..."
      info "请在接下来的提示中配置模型、渠道，并在最后一步选 'Yes' 安装系统服务。"
      onboard_openclaw || { warn "OpenClaw onboarding 失败"; failed=$((failed+1)); }
    else
      warn "OpenClaw 初始化失败"
      failed=$((failed+1))
    fi
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
    render_main_banner
    echo "$(get_user_identity_summary)"
    show_main_status_banner

    menu_section "【部署】"
    echo "1) 一键部署 OpenClaw"
    echo "2) OpenClaw 部署管理"
    echo "3) 系统环境与依赖"
    echo "4) 网关与服务运维"

    menu_section "【快捷操作】"
    echo "8) 一键查看网关状态"
    echo "9) 一键重启网关"
    echo "10) 一键执行 doctor --fix"
    echo "11) 进入 TUI 聊天界面"
    echo "12) 状态总览"

    echo
    echo "0) 🚪 退出"
    read -rp "请选择: " n

    case "$n" in
      1) full_init ;;
      2) openclaw_install_menu ;;
      3) system_env_menu ;;
      4) openclaw_gateway_menu ;;
      8) ensure_openclaw_installed && openclaw gateway status; pause ;;
      9) ensure_openclaw_installed && openclaw gateway restart; pause ;;
      10) ensure_openclaw_installed && openclaw doctor --fix; pause ;;
      11) ensure_openclaw_installed && openclaw tui; pause ;;
      12) show_status_summary ;;
      0)
        info "已退出。"
        exit 0
        ;;
      *) warn "无效输入"; pause ;;
    esac
  done
}

main_menu
