#!/bin/bash

# BlockAssist 部署脚本
# 功能：克隆仓库、安装依赖、配置环境、运行 BlockAssist

# ANSI 颜色代码
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1${NC}"; }
error() { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1${NC}"; }
info() { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1${NC}"; }

# 检查系统
check_system() {
    log "检查系统..."
    if [[ "$(uname -s)" != "Darwin" ]]; then
        error "此脚本仅适用于 macOS 系统"
    fi
    log "检测到 macOS 系统"
}

# 检查并安装 Homebrew
install_homebrew() {
    info "检查 Homebrew 安装状态..."
    if ! command -v brew &>/dev/null; then
        log "Homebrew 未安装，正在安装..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        
        # 配置 Homebrew 环境变量
        if [[ -f /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
        elif [[ -f /usr/local/bin/brew ]]; then
            eval "$(/usr/local/bin/brew shellenv)"
            echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.zshrc
        fi
        
        # 加载环境变量
        source ~/.zshrc 2>/dev/null || source ~/.bashrc 2>/dev/null || true
        
        log "✅ Homebrew 安装完成"
    else
        log "✅ Homebrew 已安装，跳过安装步骤"
    fi
}

# 克隆 BlockAssist 仓库
clone_repository() {
    info "克隆 BlockAssist 仓库..."
    
    if [ -d "blockassist" ]; then
        read -p "⚠️ 目录 blockassist 已存在，是否删除？(y/n): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            log "🗑️ 正在删除原目录..."
            rm -rf blockassist
        else
            log "✅ 使用现有目录继续"
            return
        fi
    fi
    
    # 克隆仓库
    while true; do
        if git clone https://github.com/gensyn-ai/blockassist.git; then
            log "✅ BlockAssist 仓库克隆成功"
            break
        else
            warn "⚠️ 仓库克隆失败，3秒后重试..."
            sleep 3
        fi
    done
    
    # 进入目录
    cd blockassist || error "进入 blockassist 目录失败"
}

# 安装 Java 1.8.0_152
install_java() {
    info "检查 Java 安装状态..."
    
    # 检查是否已安装 Java 1.8
    if command -v java &>/dev/null; then
        JAVA_VERSION=$(java -version 2>&1 | head -n 1 | cut -d'"' -f2)
        log "当前 Java 版本: $JAVA_VERSION"
        
        if [[ "$JAVA_VERSION" == "1.8.0_152" ]]; then
            log "✅ Java 1.8.0_152 已安装，跳过安装步骤"
            return
        else
            warn "⚠️ 检测到其他版本的 Java，建议安装 Java 1.8.0_152"
        fi
    fi
    
    log "📥 安装 Java 1.8.0_152..."
    
    # 检测芯片架构
    ARCH=$(uname -m)
    if [[ "$ARCH" == "arm64" ]]; then
        log "检测到 Apple Silicon (ARM64) 架构"
        # 对于 Apple Silicon，使用 temurin@8
        if brew list --cask | grep -q "temurin@8"; then
            log "✅ Temurin8 已安装，跳过安装步骤"
        else
            log "📥 安装 Temurin8 (适用于 Apple Silicon)..."
            brew install --cask temurin@8 || error "Temurin8 安装失败"
        fi
        
        # 配置 Java 环境变量
        JAVA_HOME_PATH="/Library/Java/JavaVirtualMachines/temurin-8.jdk/Contents/Home"
        if [ -d "$JAVA_HOME_PATH" ]; then
            echo "export JAVA_HOME=$JAVA_HOME_PATH" >> ~/.zshrc
            echo "export PATH=\$JAVA_HOME/bin:\$PATH" >> ~/.zshrc
            
            # 加载环境变量
            export JAVA_HOME="$JAVA_HOME_PATH"
            export PATH="$JAVA_HOME/bin:$PATH"
            
            log "✅ Java 安装完成 (Temurin8)"
        else
            error "Temurin8 安装路径未找到"
        fi
    else
        log "检测到 Intel (x86_64) 架构"
        # 对于 Intel Mac，使用 OpenJDK 8
        brew install openjdk@8 || error "Java 安装失败"
        
        # 配置 Java 环境变量
        JAVA_HOME_PATH=$(brew --prefix openjdk@8)
        echo "export JAVA_HOME=$JAVA_HOME_PATH" >> ~/.zshrc
        echo "export PATH=\$JAVA_HOME/bin:\$PATH" >> ~/.zshrc
        
        # 加载环境变量
        export JAVA_HOME="$JAVA_HOME_PATH"
        export PATH="$JAVA_HOME/bin:$PATH"
        
        log "✅ Java 安装完成 (OpenJDK 8)"
    fi
}

# 运行 setup.sh
run_setup() {
    info "检查 setup.sh 是否已运行..."
    
    # 检查是否已经运行过 setup.sh（通过检查某些标志文件或目录）
    if [ -f ".setup_completed" ]; then
        log "✅ setup.sh 已运行过，跳过执行步骤"
        return
    fi
    
    if [ -f "setup.sh" ]; then
        log "📥 运行 setup.sh..."
        chmod +x setup.sh
        ./setup.sh || error "setup.sh 执行失败"
        
        # 创建标志文件表示已运行
        touch .setup_completed
        log "✅ setup.sh 执行完成"
    else
        error "未找到 setup.sh 文件"
    fi
}

# 安装 pyenv
install_pyenv() {
    info "检查 pyenv 安装状态..."
    
    if ! command -v pyenv &>/dev/null; then
        log "📥 安装 pyenv..."
        brew install pyenv || error "pyenv 安装失败"
        
        # 配置 pyenv 环境变量
        echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.zshrc
        echo 'command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.zshrc
        echo 'eval "$(pyenv init -)"' >> ~/.zshrc
        
        # 加载环境变量
        export PYENV_ROOT="$HOME/.pyenv"
        export PATH="$PYENV_ROOT/bin:$PATH"
        eval "$(pyenv init -)"
        
        log "✅ pyenv 安装完成"
    else
        log "✅ pyenv 已安装，跳过安装步骤"
    fi
}

# 安装 Python 3.10
install_python() {
    info "检查 Python 3.10 安装状态..."
    
    if pyenv versions | grep -q "3.10"; then
        log "✅ Python 3.10 已安装，跳过安装步骤"
    else
        log "📥 安装 Python 3.10..."
        pyenv install 3.10 || error "Python 3.10 安装失败"
        log "✅ Python 3.10 安装完成"
    fi
    
    # 设置本地 Python 版本
    pyenv local 3.10
    log "✅ 已设置本地 Python 版本为 3.10"
}

# 安装 Python 依赖
install_python_deps() {
    info "检查 Python 依赖安装状态..."
    
    # 检查是否已安装 psutil 和 readchar
    if pyenv exec pip list | grep -q "psutil" && pyenv exec pip list | grep -q "readchar"; then
        log "✅ Python 依赖 (psutil, readchar) 已安装，跳过安装步骤"
    else
        log "📥 安装 Python 依赖..."
        # 安装 psutil 和 readchar
        pyenv exec pip install psutil readchar || error "Python 依赖安装失败"
        log "✅ Python 依赖安装完成"
    fi
}

# 配置 Hugging Face API 令牌
configure_hf_token() {
    info "检查 Hugging Face API 令牌..."
    
    # 检查是否已存在 HF_TOKEN
    if grep -q "^export HF_TOKEN=" ~/.zshrc 2>/dev/null; then
        export HF_TOKEN=$(grep "^export HF_TOKEN=" ~/.zshrc | sed 's/.*=//;s/\"//g')
        log "已从 ~/.zshrc 加载 HF_TOKEN: ${HF_TOKEN:0:8}..."
        
        # 询问用户是否要更换 API 令牌
        echo -n "是否要更换 Hugging Face API 令牌？(y/n, 5秒后默认n): "
        read -t 5 -r change_token
        change_token=${change_token:-n}  # 默认值为 n
        if [[ "$change_token" =~ ^[Yy]$ ]]; then
            read -r -p "请输入新的 Hugging Face API 令牌: " new_token
            [[ -z "$new_token" ]] && error "HF_TOKEN 不能为空"
            
            # 更新配置文件中的 API 令牌（不创建备份）
            sed -i "s/^export HF_TOKEN=.*/export HF_TOKEN=\"$new_token\"/" ~/.zshrc
            export HF_TOKEN="$new_token"
            log "HF_TOKEN 已更新并加载"
        else
            log "保持现有 HF_TOKEN 不变"
        fi
    else
        read -r -p "请输入你的 Hugging Face API 令牌: " hf_token
        [[ -z "$hf_token" ]] && error "HF_TOKEN 不能为空"
        echo "export HF_TOKEN=\"$hf_token\"" >> ~/.zshrc
        export HF_TOKEN="$hf_token"
        log "HF_TOKEN 已保存并加载"
    fi
}

# 运行 BlockAssist
run_blockassist() {
    info "启动 BlockAssist..."
    
    if [ -f "run.py" ]; then
        log "🚀 运行 pyenv exec python run.py..."
        # 设置环境变量并运行
        HF_TOKEN="$HF_TOKEN" pyenv exec python run.py
    else
        error "未找到 run.py 文件"
    fi
}

# 主函数
main() {
    echo "======================================="
    echo "🚀 BlockAssist 部署脚本"
    echo "======================================="
    
    check_system
    install_homebrew
    clone_repository
    install_java
    run_setup
    install_pyenv
    install_python
    install_python_deps
    configure_hf_token
    
    log "✅ 所有依赖安装完成，准备启动 BlockAssist..."
    echo "======================================="
    
    run_blockassist
}

# 执行主函数
main
