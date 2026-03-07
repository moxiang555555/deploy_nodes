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

check_system() {
    log "检查系统..."
    sysname="$(uname)"
    if [[ "$sysname" == "Darwin" ]]; then
        chip=$(sysctl -n machdep.cpu.brand_string)
        log "检测到 macOS，芯片信息：$chip"
        export OS_TYPE="macos"
    elif [[ "$sysname" == "Linux" ]]; then
        cpu=$(lscpu | grep 'Model name' | awk -F: '{print $2}' | xargs)
        log "检测到 Linux，CPU 型号：$cpu"
        export OS_TYPE="linux"
    else
        error "此脚本仅适用于 macOS 或 Ubuntu/Linux"
    fi
}

install_missing_dependencies() {
    log "检查并安装缺失依赖..."
    if [[ "$OS_TYPE" == "macos" ]]; then
        dependencies=("curl" "git" "wget" "jq" "python3" "node")
        if ! command -v brew >/dev/null 2>&1; then
            log "Homebrew 未安装，正在安装..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || error "Homebrew 安装失败"
            eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
        else
            log "Homebrew 已安装"
        fi
        for dep in "${dependencies[@]}"; do
            if ! command -v "$dep" >/dev/null 2>&1; then
                log "安装 $dep ..."
                brew install "$dep" || error "$dep 安装失败"
            else
                log "$dep 已安装"
            fi
        done
    elif [[ "$OS_TYPE" == "linux" ]]; then
        dependencies=("curl" "git" "wget" "jq" "python3" "nodejs")
        if ! command -v apt-get >/dev/null 2>&1; then
            error "未检测到 apt-get，请确认你使用的是 Ubuntu 或 Debian 系统"
        fi
        sudo apt-get update
        for dep in "${dependencies[@]}"; do
            if ! command -v "$dep" >/dev/null 2>&1; then
                log "安装 $dep ..."
                sudo apt-get install -y "$dep" || error "$dep 安装失败"
            else
                log "$dep 已安装"
            fi
        done
    fi
}

# 检查并删除 ~/.wombo 目录
cleanup_wombo() {
    if [ -d "$HOME/.wombo" ]; then
        log "检测到 ~/.wombo 目录，正在删除..."
        rm -rf "$HOME/.wombo"
        log "~/.wombo 目录已删除"
    else
        log "未检测到 ~/.wombo 目录，继续执行"
    fi
}

install_wai_cli() {
    if ! command -v wai >/dev/null 2>&1; then
        log "安装 WAI CLI..."

        # ----- 修改部分：安装新版 bash 并使用它执行安装脚本 -----
        if [[ "$OS_TYPE" == "macos" ]]; then
            # 检查是否已经安装了较新版本的 bash（通过 brew）
            if ! command -v "$(brew --prefix)/bin/bash" >/dev/null 2>&1; then
                log "安装新版 bash..."
                brew install bash || error "bash 安装失败"
            else
                log "新版 bash 已安装"
            fi
            # 获取 brew bash 的路径
            BREW_BASH="$(brew --prefix)/bin/bash"
            if [[ ! -x "$BREW_BASH" ]]; then
                error "无法找到 brew 安装的 bash"
            fi
            log "使用 brew bash: $BREW_BASH"
        else
            # Linux 下默认系统 bash 通常较新，直接使用系统 bash
            BREW_BASH="bash"
        fi

        # 使用指定的 bash 执行安装脚本
        curl -fsSL https://app.w.ai/install.sh | "$BREW_BASH" || error "WAI CLI 安装失败"
        # ----------------------------------------------------

        echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
        export PATH="$HOME/.local/bin:$PATH"
        source ~/.zshrc 2>/dev/null || true
        source ~/.bashrc 2>/dev/null || true
        log "WAI CLI 安装成功"
    else
        log "WAI CLI 已安装，版本：$(wai --version)"
    fi
}

configure_env() {
    BASH_CONFIG="$HOME/.bashrc"
    ZSH_CONFIG="$HOME/.zshrc"
    
    # 检查是否已存在 WAI API KEY
    if grep -q "^export W_AI_API_KEY=" "$BASH_CONFIG" 2>/dev/null; then
        export W_AI_API_KEY=$(grep "^export W_AI_API_KEY=" "$BASH_CONFIG" | sed 's/.*=//;s/\"//g')
        log "已从 ~/.bashrc 加载 W_AI_API_KEY: ${W_AI_API_KEY:0:8}..."
        
        # 询问用户是否要更换 API KEY（5秒超时，默认不更换）
        echo -n "是否要更换 WAI API 密钥？(y/n, 5秒后默认n): "
        read -t 5 -r change_key
        change_key=${change_key:-n}  # 默认值为 n
        if [[ "$change_key" =~ ^[Yy]$ ]]; then
            read -r -p "请输入新的 WAI API 密钥: " api_key
            [[ -z "$api_key" ]] && error "W_AI_API_KEY 不能为空"
            
            # 更新配置文件中的 API KEY（不创建备份）
            sed -i "s/^export W_AI_API_KEY=.*/export W_AI_API_KEY=\"$api_key\"/" "$BASH_CONFIG"
            sed -i "s/^export W_AI_API_KEY=.*/export W_AI_API_KEY=\"$api_key\"/" "$ZSH_CONFIG"
            export W_AI_API_KEY="$api_key"
            log "W_AI_API_KEY 已更新并加载"
        else
            log "保持现有 WAI API KEY 不变"
        fi
    elif grep -q "^export W_AI_API_KEY=" "$ZSH_CONFIG" 2>/dev/null; then
        export W_AI_API_KEY=$(grep "^export W_AI_API_KEY=" "$ZSH_CONFIG" | sed 's/.*=//;s/\"//g')
        log "已从 ~/.zshrc 加载 W_AI_API_KEY: ${W_AI_API_KEY:0:8}..."
        
        # 询问用户是否要更换 API KEY（5秒超时，默认不更换）
        echo -n "是否要更换 WAI API 密钥？(y/n, 5秒后默认n): "
        read -t 5 -r change_key
        change_key=${change_key:-n}  # 默认值为 n
        if [[ "$change_key" =~ ^[Yy]$ ]]; then
            read -r -p "请输入新的 WAI API 密钥: " api_key
            [[ -z "$api_key" ]] && error "W_AI_API_KEY 不能为空"
            
            # 更新配置文件中的 API KEY（不创建备份）
            sed -i "s/^export W_AI_API_KEY=.*/export W_AI_API_KEY=\"$api_key\"/" "$BASH_CONFIG"
            sed -i "s/^export W_AI_API_KEY=.*/export W_AI_API_KEY=\"$api_key\"/" "$ZSH_CONFIG"
            export W_AI_API_KEY="$api_key"
            log "W_AI_API_KEY 已更新并加载"
        else
            log "保持现有 WAI API KEY 不变"
        fi
    else
        read -r -p "请输入你的 WAI API 密钥: " api_key
        [[ -z "$api_key" ]] && error "W_AI_API_KEY 不能为空"
        echo "export W_AI_API_KEY=\"$api_key\"" >> "$BASH_CONFIG"
        echo "export W_AI_API_KEY=\"$api_key\"" >> "$ZSH_CONFIG"
        export W_AI_API_KEY="$api_key"
        log "W_AI_API_KEY 已保存并加载"
    fi
}

run_wai_worker() {
    RETRY=1
    log "开始运行 WAI Worker..."
    while true; do
        log "🔁 准备开始新一轮挖矿..."
        log "🧹 清理旧进程..."
        if pgrep -f "[p]ython -m model.main" >/dev/null; then
            pkill -9 -f "[p]ython -m model.main" 2>/dev/null
            log "✅ 旧python model.main进程清理完成"
        else
            log "✅ 无旧python model.main进程需要清理"
        fi
        # 新增wai run进程清理
        if pgrep -f "wai run" >/dev/null; then
            pkill -9 -f "wai run" 2>/dev/null
            log "✅ 旧wai run进程清理完成"
        else
            log "✅ 无wai run进程需要清理"
        fi
        log "✅ 启动 Worker..."
        env POSTHOG_DISABLED=true wai run
        EXIT_CODE=$?
        if [ $EXIT_CODE -ne 0 ]; then
            warn "⚠️ Worker 异常退出（退出码 $EXIT_CODE），等待 10 秒后重试..."
            sleep 10
            RETRY=$(( RETRY < 8 ? RETRY+1 : 8 ))
        else
            log "✅ Worker 正常退出，重置重试计数"
            RETRY=1
            sleep 10
        fi
    done
}

main() {
    check_system
    install_missing_dependencies
    cleanup_wombo
    install_wai_cli
    configure_env
    log "✅ 所有准备就绪，启动 Worker..."
    run_wai_worker
}

main
