#!/bin/bash

# WAI Protocol 部署脚本
# 功能：安装依赖、配置环境变量、运行 WAI Worker 并自动重启，日志输出到终端

# ANSI 颜色代码
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 日志函数
log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1${NC}"; }
error() { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1${NC}"; }

# 通用超时函数（替代timeout/gtimeout）
run_with_timeout() {
  local duration=$1
  shift
  "$@" &
  cmd_pid=$!
  ( sleep "$duration" && kill -9 $cmd_pid 2>/dev/null ) &
  watcher_pid=$!
  wait $cmd_pid 2>/dev/null
  status=$?
  kill -9 $watcher_pid 2>/dev/null
  return $status
}

# 检查系统并安装依赖
log "检查系统..."
OS_TYPE="$(uname)"
if [[ "$OS_TYPE" == "Darwin" ]]; then
    TIMEOUT_CMD="gtimeout"
    log "检测到 macOS 系统"
    # 检查 Homebrew
    if ! command -v brew >/dev/null 2>&1; then
        log "Homebrew 未安装，正在安装..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        if [[ $? -ne 0 ]]; then
            error "Homebrew 安装失败，请手动安装 Homebrew 后重试"
        fi
        if [[ "$(uname -m)" == "arm64" ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        else
            eval "$(/usr/local/bin/brew shellenv)"
        fi
        brew install curl git wget jq python3 node
    else
        log "Homebrew 已安装，跳过 Homebrew 安装与更新"
        for dep in curl git wget jq python3 node; do
            if ! command -v $dep >/dev/null 2>&1; then
                log "$dep 未安装，正在用brew安装..."
                brew install $dep
            else
                log "$dep 已安装，跳过"
            fi
        done
    fi
elif [[ "$OS_TYPE" == "Linux" ]]; then
    TIMEOUT_CMD="timeout"
    log "检测到 Linux 系统"
    # 检查是否为 Ubuntu
    if grep -qi ubuntu /etc/os-release; then
        log "检测到 Ubuntu 系统"
        sudo apt update
        for dep in curl git wget jq python3 python3-pip nodejs npm; do
            if ! command -v $dep >/dev/null 2>&1; then
                log "$dep 未安装，正在用apt安装..."
                sudo apt install -y $dep
            else
                log "$dep 已安装，跳过"
            fi
        done
    else
        log "非 Ubuntu Linux，尝试直接安装依赖"
        sudo apt update
        sudo apt install -y curl git wget jq python3 python3-pip nodejs npm
    fi
else
    error "不支持的操作系统: $OS_TYPE"
fi

# 检查并删除 ~/.wombo 目录
if [ -d "$HOME/.wombo" ]; then
    log "检测到 ~/.wombo 目录，正在删除..."
    rm -rf "$HOME/.wombo"
    log "~/.wombo 目录已删除"
else
    log "未检测到 ~/.wombo 目录，继续执行"
fi

# 检查并安装wai cli
if ! command -v wai >/dev/null 2>&1; then
    log "安装 WAI CLI..."
    curl -fsSL https://app.w.ai/install.sh | bash
    if [[ $? -ne 0 ]]; then
        error "WAI CLI 安装失败，请检查网络或手动安装"
    fi
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
    export PATH="$HOME/.local/bin:$PATH"
    log "WAI CLI 安装成功"
else
    log "WAI CLI 已安装，版本：$(wai --version)"
fi

# 配置环境变量
ZSH_CONFIG_FILE="$HOME/.zshrc"
BASH_CONFIG_FILE="$HOME/.bashrc"
if grep -q "^export W_AI_API_KEY=" "$ZSH_CONFIG_FILE" || grep -q "^export W_AI_API_KEY=" "$BASH_CONFIG_FILE"; then
    export W_AI_API_KEY=$(grep "^export W_AI_API_KEY=" "$ZSH_CONFIG_FILE" "$BASH_CONFIG_FILE" | head -n1 | sed 's/.*=//;s/"//g')
    log "检测到 W_AI_API_KEY，已从配置文件加载"
else
    read -r -p "请输入你的 WAI API 密钥: " api_key
    if [[ -z "$api_key" ]]; then
        error "W_AI_API_KEY 不能为空"
    fi
    echo "export W_AI_API_KEY=\"$api_key\"" >> "$ZSH_CONFIG_FILE"
    echo "export W_AI_API_KEY=\"$api_key\"" >> "$BASH_CONFIG_FILE"
    export W_AI_API_KEY="$api_key"
    log "W_AI_API_KEY 已写入 ~/.zshrc 和 ~/.bashrc 并加载"
fi

# 运行wai worker
WAI_CMD="$HOME/.local/bin/wai"
RETRY=1
log "开始运行 WAI Worker..."
while true; do
    log "🔁 准备开始新一轮挖矿..."
    log "🧹 清理旧进程..."
    if pgrep -f "[p]ython -m model.main" >/dev/null; then
        pkill -9 -f "[p]ython -m model.main" 2>/dev/null
        log "✅ 旧进程清理完成"
    else
        log "✅ 无旧进程需要清理"
    fi
    log "✅ 启动 Worker（限时5分钟）..."
    run_with_timeout 300 env POSTHOG_DISABLED=true "$WAI_CMD" run
    WAI_PID=$!
    wait $WAI_PID
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 124 ]; then
        warn "⏰ Worker 已运行5分钟，强制重启..."
        RETRY=1
        sleep 2
    elif [ $EXIT_CODE -ne 0 ]; then
        warn "⚠️ Worker 异常退出（退出码 $EXIT_CODE），等待 10 秒后重试..."
        sleep 10
        RETRY=$(( RETRY < 8 ? RETRY+1 : 8 ))
    else
        log "✅ Worker 正常退出，重置重试计数"
        RETRY=1
        sleep 10
    fi
done