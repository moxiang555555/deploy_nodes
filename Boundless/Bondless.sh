#!/bin/bash


set -euo pipefail

# 颜色变量
CYAN='\033[0;36m'
LIGHTBLUE='\033[1;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
PURPLE='\033[0;35m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'
GRAY='\033[0;90m'

# 常量
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/boundless_prover_setup.log"
ERROR_LOG="/var/log/boundless_prover_error.log"
INSTALL_DIR="$HOME/boundless"
COMPOSE_FILE="$INSTALL_DIR/compose.yml"
BROKER_CONFIG="$INSTALL_DIR/broker.toml"

# 退出代码
EXIT_SUCCESS=0
EXIT_OS_CHECK_FAILED=1
EXIT_DPKG_ERROR=2
EXIT_DEPENDENCY_FAILED=3
EXIT_GPU_ERROR=4
EXIT_NETWORK_ERROR=5
EXIT_USER_ABORT=6
EXIT_UNKNOWN=99
EXIT_RUST_ERROR=7

# 标志
ALLOW_ROOT=false
FORCE_RECLONE=false
START_IMMEDIATELY=false

# 兼容所有环境安全获取用户名
USER_NAME="$(logname 2>/dev/null || whoami)"
export USER_NAME

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --allow-root) ALLOW_ROOT=true; shift ;;
        --force-reclone) FORCE_RECLONE=true; shift ;;
        --start-immediately) START_IMMEDIATELY=true; shift ;;
        --help)
            echo "用法: $0 [选项]"
            echo "选项:"
            echo "  --allow-root        允许以 root 用户运行，不提示"
            echo "  --force-reclone     如果目录存在，强制删除并重新克隆"
            echo "  --start-immediately 自动运行管理脚本"
            echo "  --help              显示此帮助信息"
            exit 0
            ;;
        *) echo "未知选项: $1"; exit 1 ;;
    esac
done

# 退出时的清理函数
cleanup_on_exit() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        error "安装失败，退出代码: $exit_code"
        echo "[退出] 脚本退出，代码: $exit_code，时间: $(date)" >> "$ERROR_LOG"
        echo "[退出] 最后命令: ${BASH_COMMAND}" >> "$ERROR_LOG"
        echo "[退出] 行号: ${BASH_LINENO[0]}" >> "$ERROR_LOG"
        echo "[退出] 函数栈: ${FUNCNAME[@]}" >> "$ERROR_LOG"

        echo -e "\n${RED}${BOLD}安装失败！${RESET}"
        echo -e "${YELLOW}查看错误日志: cat $ERROR_LOG${RESET}"
        echo -e "${YELLOW}查看完整日志: cat $LOG_FILE${RESET}"

        case $exit_code in
            $EXIT_DPKG_ERROR)
                echo -e "\n${RED}检测到 DPKG 配置错误！${RESET}"
                echo -e "${YELLOW}请运行以下命令修复:${RESET}"
                echo -e "${BOLD}sudo dpkg --configure -a${RESET}"
                ;;
            $EXIT_OS_CHECK_FAILED) echo -e "\n${RED}操作系统检查失败！${RESET}" ;;
            $EXIT_DEPENDENCY_FAILED) echo -e "\n${RED}依赖安装失败！${RESET}" ;;
            $EXIT_GPU_ERROR) echo -e "\n${RED}GPU 配置错误！${RESET}" ;;
            $EXIT_NETWORK_ERROR) echo -e "\n${RED}网络配置错误！${RESET}" ;;
            $EXIT_USER_ABORT) echo -e "\n${YELLOW}用户中止安装。${RESET}" ;;
            *) echo -e "\n${RED}发生未知错误！${RESET}" ;;
        esac
    fi
}

# 设置陷阱
trap cleanup_on_exit EXIT
trap 'echo "[信号] 捕获信号 ${?} 在行 ${LINENO}" >> "$ERROR_LOG"' ERR

# 网络配置
declare -A NETWORKS
NETWORKS["base"]="Base 主网|0x0b144e07a0826182b6b59788c34b32bfa86fb711|0x26759dbB201aFbA361Bec78E097Aa3942B0b4AB8|0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760|https://base-mainnet.beboundless.xyz"
NETWORKS["base-sepolia"]="Base Sepolia|0x0b144e07a0826182b6b59788c34b32bfa86fb711|0x6B7ABa661041164b8dB98E30AE1454d2e9D5f14b|0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760|https://base-sepolia.beboundless.xyz"
NETWORKS["eth-sepolia"]="以太坊 Sepolia|0x925d8331ddc0a1F0d96E68CF073DFE1d92b69187|0x13337C76fE2d1750246B68781ecEe164643b98Ec|0x7aAB646f23D1392d4522CFaB0b7FB5eaf6821d64|https://eth-sepolia.beboundless.xyz/"

# 工具函数
info() { printf "${CYAN}[信息]${RESET} %s\n" "$1"; echo "[信息] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"; }
success() { printf "${GREEN}[成功]${RESET} %s\n" "$1"; echo "[成功] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"; }
error() { printf "${RED}[错误]${RESET} %s\n" "$1" >&2; echo "[错误] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"; echo "[错误] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$ERROR_LOG"; }
warning() { printf "${YELLOW}[警告]${RESET} %s\n" "$1"; echo "[警告] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"; }
prompt() { printf "${PURPLE}[输入]${RESET} %s" "$1"; }

# 检查 dpkg 状态
check_dpkg_status() {
    if dpkg --audit 2>&1 | grep -q "dpkg was interrupted"; then
        error "dpkg 被中断 - 需要手动修复"
        return 1
    fi
    return 0
}

# 检查命令是否存在
command_exists() { command -v "$1" &> /dev/null; }

# 检查包是否已安装
is_package_installed() { dpkg -s "$1" &> /dev/null 2>&1; }

# 无限重试安装函数
retry_forever() {
    local cmd="$1"
    local desc="$2"
    while true; do
        eval "$cmd" && break
        warning "$desc 安装失败，10 秒后重试..."
        sleep 10
    done
}

# 检查所有依赖并自动安装缺失的依赖
check_all_deps() {
    info "检查所有依赖项..."
    echo -e "\n${BOLD}${CYAN}依赖状态检查:${RESET}"
    echo -e "${GRAY}=======================================${RESET}\n"
    local errors=0

    # 1. 操作系统
    echo -e "${BOLD}1. 操作系统:${RESET}"
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "${ID,,}" == "ubuntu" && "${VERSION_ID,,}" =~ ^(20.04|22.04)$ ]]; then
            echo -e "   ${GREEN}✓ Ubuntu ${VERSION_ID} (支持)${RESET}"
        else
            echo -e "   ${YELLOW}⚠ ${PRETTY_NAME} (未完全测试)${RESET}"
            warning "操作系统: ${PRETTY_NAME}，可能不完全支持"
            ((errors++))
        fi
    else
        echo -e "   ${RED}✗ 未找到 /etc/os-release${RESET}"
        error "无法确定操作系统"
        ((errors++))
    fi

    # 2. 基本依赖
    echo -e "\n${BOLD}2. 基本依赖:${RESET}"
    local packages=(
        curl iptables build-essential git wget lz4 jq make gcc nano
        automake autoconf tmux htop nvme-cli libgbm1 pkg-config
        libssl-dev tar clang bsdmainutils ncdu unzip libleveldb-dev
        libclang-dev ninja-build nvtop ubuntu-drivers-common
        gnupg ca-certificates lsb-release postgresql-client
    )
    local missing_packages=()
    for pkg in "${packages[@]}"; do
        if is_package_installed "$pkg"; then
            echo -e "   ${GREEN}✓ $pkg 已安装${RESET}"
        else
            echo -e "   ${YELLOW}⚠ $pkg 未安装${RESET}"
            missing_packages+=("$pkg")
        fi
    done
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        warning "缺少基本依赖: ${missing_packages[*]}"
        info "自动安装缺失的基本依赖..."
        install_basic_deps
        # 重新检查基本依赖
        for pkg in "${missing_packages[@]}"; do
            if is_package_installed "$pkg"; then
                echo -e "   ${GREEN}✓ $pkg 安装成功${RESET}"
            else
                echo -e "   ${RED}✗ $pkg 安装失败${RESET}"
                error "无法安装 $pkg"
                ((errors++))
            fi
        done
    else
        success "所有基本依赖已安装"
    fi

    # 3. GPU 驱动
    echo -e "\n${BOLD}3. GPU 驱动:${RESET}"
    if command_exists nvidia-smi && nvidia-smi &> /dev/null; then
        local driver_version=$(nvidia-smi --query | grep "Driver Version" | awk '{print $3}')
        echo -e "   ${GREEN}✓ NVIDIA 驱动已安装 (版本: $driver_version)${RESET}"
    else
        echo -e "   ${YELLOW}⚠ NVIDIA GPU 驱动未安装${RESET}"
        warning "未找到 nvidia-smi 或驱动未配置"
        info "自动安装 GPU 驱动..."
        install_gpu_drivers
        if command_exists nvidia-smi && nvidia-smi &> /dev/null; then
            local driver_version=$(nvidia-smi --query | grep "Driver Version" | awk '{print $3}')
            echo -e "   ${GREEN}✓ NVIDIA 驱动安装成功 (版本: $driver_version)${RESET}"
        else
            echo -e "   ${RED}✗ NVIDIA 驱动安装失败${RESET}"
            error "无法安装 NVIDIA GPU 驱动"
            ((errors++))
        fi
    fi

    # 4. Docker
    echo -e "\n${BOLD}4. Docker:${RESET}"
    if command_exists docker && docker --version &> /dev/null; then
        local docker_version=$(docker --version | cut -d' ' -f3 | tr -d ',')
        echo -e "   ${GREEN}✓ Docker 已安装 (版本: $docker_version)${RESET}"
        if ! groups "$USER_NAME" | grep -q docker; then
            echo -e "   ${YELLOW}⚠ 用户不在 docker 组${RESET}"
            warning "用户 $USER_NAME 不在 docker 组"
            info "自动将用户添加到 docker 组..."
            usermod -aG docker "$USER_NAME" >> "$LOG_FILE" 2>&1 || {
                error "无法将用户添加到 docker 组"
                ((errors++))
            }
            echo -e "   ${GREEN}✓ 用户已添加到 docker 组${RESET}"
        fi
    else
        echo -e "   ${YELLOW}⚠ Docker 未安装${RESET}"
        warning "Docker 未安装"
        info "自动安装 Docker..."
        install_docker
        if command_exists docker && docker --version &> /dev/null; then
            local docker_version=$(docker --version | cut -d' ' -f3 | tr -d ',')
            echo -e "   ${GREEN}✓ Docker 安装成功 (版本: $docker_version)${RESET}"
        else
            echo -e "   ${RED}✗ Docker 安装失败${RESET}"
            error "无法安装 Docker"
            ((errors++))
        fi
    fi

    # 5. NVIDIA 容器工具包
    echo -e "\n${BOLD}5. NVIDIA 容器工具包:${RESET}"
    if is_package_installed "nvidia-docker2" && docker info --format '{{.Runtimes}}' | grep -q nvidia; then
        echo -e "   ${GREEN}✓ NVIDIA 容器工具包已安装${RESET}"
    else
        echo -e "   ${YELLOW}⚠ NVIDIA 容器工具包未安装或未配置${RESET}"
        warning "NVIDIA Docker 支持未配置"
        info "自动安装 NVIDIA 容器工具包..."
        install_nvidia_toolkit
        if is_package_installed "nvidia-docker2" && docker info --format '{{.Runtimes}}' | grep -q nvidia; then
            echo -e "   ${GREEN}✓ NVIDIA 容器工具包安装成功${RESET}"
        else
            echo -e "   ${RED}✗ NVIDIA 容器工具包安装失败${RESET}"
            error "无法安装 NVIDIA 容器工具包"
            ((errors++))
        fi
    fi

    # 6. Rust
    echo -e "\n${BOLD}6. Rust:${RESET}"
    if command_exists rustc && command_exists cargo && [[ -f "$HOME/.cargo/env" ]]; then
        local rust_version=$(rustc --version | awk '{print $2}')
        if [[ "$(printf '%s\n' "$rust_version" "1.74.0" | sort -V | head -n1)" == "1.74.0" ]]; then
            echo -e "   ${GREEN}✓ Rust 已安装 (版本: $rust_version)${RESET}"
        else
            echo -e "   ${YELLOW}⚠ Rust 版本过旧 (版本: $rust_version，推荐: >=1.74.0)${RESET}"
            warning "Rust 版本 $rust_version 低于推荐版本 1.74.0"
            info "自动更新 Rust..."
            install_rust
            local rust_version=$(rustc --version | awk '{print $2}')
            if [[ "$(printf '%s\n' "$rust_version" "1.74.0" | sort -V | head -n1)" == "1.74.0" ]]; then
                echo -e "   ${GREEN}✓ Rust 更新成功 (版本: $rust_version)${RESET}"
            else
                echo -e "   ${RED}✗ Rust 更新失败${RESET}"
                error "Rust 版本 $rust_version 未达到要求"
                ((errors++))
            fi
        fi
    else
        echo -e "   ${YELLOW}⚠ Rust 未安装${RESET}"
        warning "Rust 未安装或环境未配置"
        info "自动安装 Rust..."
        install_rust
        if command_exists rustc && command_exists cargo && [[ -f "$HOME/.cargo/env" ]]; then
            local rust_version=$(rustc --version | awk '{print $2}')
            echo -e "   ${GREEN}✓ Rust 安装成功 (版本: $rust_version)${RESET}"
        else
            echo -e "   ${RED}✗ Rust 安装失败${RESET}"
            error "无法安装 Rust"
            ((errors++))
        fi
    fi

    # 7. Just
    echo -e "\n${BOLD}7. Just:${RESET}"
    if command_exists just; then
        echo -e "   ${GREEN}✓ Just 已安装 (版本: $(just --version))${RESET}"
    else
        echo -e "   ${YELLOW}⚠ Just 未安装${RESET}"
        warning "Just 未安装"
        info "自动安装 Just..."
        install_just
        if command_exists just; then
            echo -e "   ${GREEN}✓ Just 安装成功 (版本: $(just --version))${RESET}"
        else
            echo -e "   ${RED}✗ Just 安装失败${RESET}"
            error "无法安装 Just"
            ((errors++))
        fi
    fi

    # 8. CUDA
    echo -e "\n${BOLD}8. CUDA:${RESET}"
    if is_package_installed "cuda-toolkit" && command_exists nvcc; then
        local cuda_version=$(nvcc --version | grep release | awk '{print $6}' | tr -d ',')
        echo -e "   ${GREEN}✓ CUDA 已安装 (版本: $cuda_version)${RESET}"
    else
        echo -e "   ${YELLOW}⚠ CUDA 未安装${RESET}"
        warning "CUDA 工具包未安装"
        info "自动安装 CUDA..."
        install_cuda
        if is_package_installed "cuda-toolkit" && command_exists nvcc; then
            local cuda_version=$(nvcc --version | grep release | awk '{print $6}' | tr -d ',')
            echo -e "   ${GREEN}✓ CUDA 安装成功 (版本: $cuda_version)${RESET}"
        else
            echo -e "   ${RED}✗ CUDA 安装失败${RESET}"
            error "无法安装 CUDA 工具包"
            ((errors++))
        fi
    fi

    # 9. Rust 依赖
    echo -e "\n${BOLD}9. Rust 依赖:${RESET}"
    local rust_deps=("rzup" "cargo-risczero" "bento_cli" "boundless-cli")
    local missing_rust_deps=()
    for dep in "${rust_deps[@]}"; do
        if command_exists "$dep"; then
            echo -e "   ${GREEN}✓ $dep 已安装${RESET}"
        else
            echo -e "   ${YELLOW}⚠ $dep 未安装${RESET}"
            missing_rust_deps+=("$dep")
        fi
    done
    if [[ ${#missing_rust_deps[@]} -gt 0 ]]; then
        warning "缺少 Rust 依赖: ${missing_rust_deps[*]}"
        info "自动安装缺失的 Rust 依赖..."
        install_rust_deps
        for dep in "${missing_rust_deps[@]}"; do
            if command_exists "$dep"; then
                echo -e "   ${GREEN}✓ $dep 安装成功${RESET}"
            else
                echo -e "   ${RED}✗ $dep 安装失败${RESET}"
                error "无法安装 $dep"
                ((errors++))
            fi
        done
    else
        success "所有 Rust 依赖已安装"
    fi

    # 10. 总结
    echo -e "\n${BOLD}检查总结:${RESET}"
    if [[ $errors -eq 0 ]]; then
        echo -e "   ${GREEN}✓ 所有依赖已满足${RESET}"
    else
        echo -e "   ${RED}✗ 检测到 $errors 个问题${RESET}"
        error "依赖检查和安装失败"
        exit $EXIT_DEPENDENCY_FAILED
    fi
}

# 更新系统
update_system() {
    info "更新系统软件包..."
    if ! check_dpkg_status; then
        exit $EXIT_DPKG_ERROR
    fi
    {
        apt update -y && apt upgrade -y &
        wait $!
    } >> "$LOG_FILE" 2>&1 || {
        error "系统更新失败"
        exit $EXIT_DPKG_ERROR
    }
    success "系统软件包已更新"
}

# 安装基本依赖
install_basic_deps() {
    info "检查并安装基本依赖..."
    local packages=(
        curl iptables build-essential git wget lz4 jq make gcc nano
        automake autoconf tmux htop nvme-cli libgbm1 pkg-config
        libssl-dev tar clang bsdmainutils ncdu unzip libleveldb-dev
        libclang-dev ninja-build nvtop ubuntu-drivers-common
        gnupg ca-certificates lsb-release postgresql-client
    )
    local to_install=()
    for pkg in "${packages[@]}"; do
        if ! is_package_installed "$pkg"; then
            to_install+=("$pkg")
        else
            info "$pkg 已安装，跳过"
        fi
    done
    if [[ ${#to_install[@]} -eq 0 ]]; then
        success "所有基本依赖已安装"
        return
    fi
    info "安装缺失依赖: ${to_install[*]}"
    if ! check_dpkg_status; then
        exit $EXIT_DPKG_ERROR
    fi
    {
        apt install -y "${to_install[@]}" &
        wait $!
    } >> "$LOG_FILE" 2>&1 || {
        error "无法安装基本依赖"
        exit $EXIT_DPKG_ERROR
    }
    success "基本依赖已安装"
}

# 安装 GPU 驱动
install_gpu_drivers() {
    info "检查 GPU 驱动..."
    if command_exists nvidia-smi && nvidia-smi &> /dev/null; then
        info "NVIDIA GPU 驱动已安装 (版本: $(nvidia-smi --query | grep "Driver Version" | awk '{print $3}'))，跳过"
        return
    fi
    info "安装 GPU 驱动..."
    if ! check_dpkg_status; then
        exit $EXIT_DPKG_ERROR
    fi
    {
        ubuntu-drivers install &
        wait $!
    } >> "$LOG_FILE" 2>&1 || {
        error "无法安装 GPU 驱动"
        exit $EXIT_GPU_ERROR
    }
    success "GPU 驱动已安装"
}

# 安装 Docker
install_docker() {
    if command_exists docker && docker --version &> /dev/null; then
        info "Docker 已安装 (版本: $(docker --version | cut -d' ' -f3 | tr -d ',')), 跳过"
        if ! groups "$USER_NAME" | grep -q docker; then
            info "将用户添加到 docker 组"
            usermod -aG docker "$USER_NAME"
        fi
        return
    fi
    info "安装 Docker..."
    if ! check_dpkg_status; then
        exit $EXIT_DPKG_ERROR
    fi
    {
        apt install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common &
        wait $!
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt update -y
        apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin &
        wait $!
        systemctl enable docker
        systemctl start docker
        usermod -aG docker "$USER_NAME"
    } >> "$LOG_FILE" 2>&1 || {
        error "无法安装 Docker"
        exit $EXIT_DPKG_ERROR
    }
    success "Docker 已安装"
}

# 安装 NVIDIA 容器工具包
install_nvidia_toolkit() {
    if is_package_installed "nvidia-docker2" && docker info --format '{{.Runtimes}}' | grep -q nvidia; then
        info "NVIDIA 容器工具包已安装，跳过"
        return
    fi
    info "安装 NVIDIA 容器工具包..."
    if ! check_dpkg_status; then
        exit $EXIT_DPKG_ERROR
    fi
    {
        distribution=$(grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')$(grep '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
        curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | apt-key add -
        curl -s -L https://nvidia.github.io/nvidia-docker/"$distribution"/nvidia-docker.list | tee /etc/apt/sources.list.d/nvidia-docker.list
        apt update -y
        apt install -y nvidia-docker2 &
        wait $!
        mkdir -p /etc/docker
        tee /etc/docker/daemon.json <<EOF
{
    "default-runtime": "nvidia",
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
EOF
        systemctl restart docker
    } >> "$LOG_FILE" 2>&1 || {
        error "无法安装 NVIDIA 容器工具包"
        exit $EXIT_DPKG_ERROR
    }
    success "NVIDIA 容器工具包已安装"
}

# 安装 Rust
install_rust() {
    if command_exists rustc && command_exists cargo && [[ -f "$HOME/.cargo/env" ]]; then
        local rust_version=$(rustc --version | awk '{print $2}')
        if [[ "$(printf '%s\n' "$rust_version" "1.74.0" | sort -V | head -n1)" == "1.74.0" ]]; then
            info "Rust 已安装 (版本: $rust_version)，跳过"
            source "$HOME/.cargo/env"
            rustup update >> "$LOG_FILE" 2>&1 || warning "Rust 更新失败，继续执行"
            return
        else
            warning "Rust 版本 $rust_version 过旧，更新中"
        fi
    fi
    info "安装 Rust..."
    {
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
        rustup update
    } >> "$LOG_FILE" 2>&1 || {
        error "无法安装 Rust"
        exit $EXIT_DEPENDENCY_FAILED
    }
    success "Rust 已安装"
}

# 安装 Just
install_just() {
    if command_exists just; then
        info "Just 已安装 (版本: $(just --version))，跳过"
        return
    fi
    info "安装 Just 命令运行器..."
    {
        curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin
    } >> "$LOG_FILE" 2>&1 || {
        error "无法安装 Just"
        exit $EXIT_DEPENDENCY_FAILED
    }
    success "Just 已安装"
}

# 安装 CUDA
install_cuda() {
    if command_exists nvcc; then
        local cuda_version=$(nvcc --version | grep release | awk '{print $6}' | tr -d ',')
        info "CUDA 已安装 (版本: $cuda_version)，跳过"
        return
    fi
    info "安装 CUDA 工具包..."
    if ! check_dpkg_status; then
        error "DPKG 配置错误，请运行 'sudo dpkg --configure -a'"
        exit $EXIT_DPKG_ERROR
    fi
    {
        distribution=ubuntu2204
        info "添加 NVIDIA CUDA 软件源..."
        wget -q https://developer.download.nvidia.com/compute/cuda/repos/$distribution/x86_64/cuda-keyring_1.1-1_all.deb -O /tmp/cuda-keyring_1.1-1_all.deb || {
            error "无法下载 CUDA 密钥环"
            exit $EXIT_NETWORK_ERROR
        }
        sudo dpkg -i /tmp/cuda-keyring_1.1-1_all.deb || {
            error "无法安装 CUDA 密钥环"
            exit $EXIT_DPKG_ERROR
        }
        rm /tmp/cuda-keyring_1.1-1_all.deb
        info "更新软件源..."
        sudo apt-get update -y || {
            error "无法更新软件源"
            exit $EXIT_DPKG_ERROR
        }
        info "安装 cuda-toolkit..."
        sudo apt-get install -y cuda-toolkit || {
            error "无法安装 cuda-toolkit"
            exit $EXIT_DPKG_ERROR
        }
        info "安装 nvidia-cuda-toolkit..."
        sudo apt-get install -y nvidia-cuda-toolkit || {
            error "无法安装 nvidia-cuda-toolkit"
            exit $EXIT_DPKG_ERROR
        }
        info "配置 CUDA 环境变量..."
        echo 'export PATH=/usr/local/cuda/bin:$PATH' >> ~/.bashrc
        echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
        source ~/.bashrc
    } >> "$LOG_FILE" 2>&1
    if command_exists nvcc; then
        local cuda_version=$(nvcc --version | grep release | awk '{print $6}' | tr -d ',')
        success "CUDA 工具包已安装 (版本: $cuda_version)"
    else
        error "CUDA 工具包安装失败"
        exit $EXIT_DPKG_ERROR
    fi
}

# 安装 Rust 依赖
install_rust_deps() {
    info "检查并安装 Rust 依赖..."
    source "$HOME/.cargo/env" 2>/dev/null || {
        warning "无法加载 $HOME/.cargo/env，正在尝试重新配置 Rust 环境..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y >> "$LOG_FILE" 2>&1 || {
            error "无法安装 Rust"
            exit $EXIT_RUST_ERROR
        }
        source "$HOME/.cargo/env"
    }
    local rust_deps=("rzup" "cargo-risczero" "bento_cli" "boundless-cli")
    for dep in "${rust_deps[@]}"; do
        if command_exists "$dep"; then
            info "$dep 已安装，跳过"
            continue
        fi
        info "安装 $dep..."
        case $dep in
            rzup)
                retry_forever "curl -L https://risczero.com/install | bash" "rzup"
                export PATH="$PATH:/root/.risc0/bin"
                PS1='' source ~/.bashrc >> "$LOG_FILE" 2>&1 || {
                    error "安装 rzup 后无法加载 ~/.bashrc"
                    exit $EXIT_RUST_ERROR
                }
                rzup install rust >> "$LOG_FILE" 2>&1 || {
                    error "无法安装 RISC Zero Rust 工具链"
                    exit $EXIT_RUST_ERROR
                }
                ;;
            cargo-risczero)
                retry_forever "cargo install --locked cargo-risczero" "cargo-risczero"
                ;;
            bento_cli)
                retry_forever "RUSTUP_TOOLCHAIN=$(rustup toolchain list | grep risc0 | head -1) cargo install --git https://github.com/risc0/risc0 bento-client --branch release-2.1 --bin bento_cli" "bento_cli"
                ;;
            boundless-cli)
                retry_forever "cargo install --locked boundless-cli --force" "boundless-cli"
                ;;
        esac
        if command_exists "$dep"; then
            success "$dep 安装成功"
        else
            error "安装 $dep 失败"
            exit $EXIT_RUST_ERROR
        fi
    done
    info "配置 Rust 环境变量..."
    if ! echo $PATH | grep -q "/root/.cargo/bin"; then
        echo 'export PATH=$PATH:/root/.cargo/bin' >> ~/.bashrc
        PS1='' source ~/.bashrc >> "$LOG_FILE" 2>&1 || {
            error "无法加载 ~/.bashrc"
            exit $EXIT_RUST_ERROR
        }
    fi
    success "所有 Rust 依赖已安装"
}

# 克隆 Boundless 仓库
clone_repository() {
    info "设置 Boundless 仓库..."
    if [[ -d "$INSTALL_DIR" ]]; then
        if [[ "$FORCE_RECLONE" == "true" ]]; then
            warning "删除现有目录 $INSTALL_DIR (--force-reclone)"
            rm -rf "$INSTALL_DIR"
        else
            warning "Boundless 目录已存在于 $INSTALL_DIR"
            prompt "是否删除并重新克隆？(y/N): "
            read -r response
            if [[ "$response" =~ ^[yY]$ ]]; then
                rm -rf "$INSTALL_DIR"
            else
                cd "$INSTALL_DIR"
                git pull origin release-0.10 >> "$LOG_FILE" 2>&1 || {
                    error "无法更新仓库"
                    exit $EXIT_DEPENDENCY_FAILED
                }
                return
            fi
        fi
    fi
    {
        git clone https://github.com/boundless-xyz/boundless "$INSTALL_DIR"
        cd "$INSTALL_DIR"
        git checkout release-0.10
        git submodule update --init --recursive
    } >> "$LOG_FILE" 2>&1 || {
        error "无法克隆或初始化仓库"
        exit $EXIT_DEPENDENCY_FAILED
    }
    success "仓库已克隆并初始化"
}

# 检测 GPU 配置
detect_gpus() {
    info "检测 GPU 配置..."
    if ! command_exists nvidia-smi; then
        error "未找到 nvidia-smi。GPU 驱动可能未正确安装。"
        exit $EXIT_GPU_ERROR
    fi
    GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l)
    if [[ $GPU_COUNT -eq 0 ]]; then
        error "未检测到 GPU"
        exit $EXIT_GPU_ERROR
    fi
    info "找到 $GPU_COUNT 个 GPU"
    GPU_MEMORY=()
    for i in $(seq 0 $((GPU_COUNT - 1))); do
        MEM=$(nvidia-smi -i $i --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
        if [[ -z "$MEM" ]]; then
            error "无法检测 GPU $i 内存"
            exit $EXIT_GPU_ERROR
        fi
        GPU_MEMORY+=($MEM)
        info "GPU $i: ${MEM}MB 显存"
    done
    MIN_VRAM=$(printf '%s\n' "${GPU_MEMORY[@]}" | sort -n | head -1)
    if [[ $MIN_VRAM -ge 40000 ]]; then
        SEGMENT_SIZE=22
    elif [[ $MIN_VRAM -ge 20000 ]]; then
        SEGMENT_SIZE=21
    elif [[ $MIN_VRAM -ge 16000 ]]; then
        SEGMENT_SIZE=20
    elif [[ $MIN_VRAM -ge 12000 ]]; then
        SEGMENT_SIZE=19
    elif [[ $MIN_VRAM -ge 8000 ]]; then
        SEGMENT_SIZE=18
    else
        SEGMENT_SIZE=17
    fi
    info "根据最小显存 ${MIN_VRAM}MB 设置 SEGMENT_SIZE=$SEGMENT_SIZE"
}

# 配置 compose.yml
configure_compose() {
    info "为 $GPU_COUNT 个 GPU 配置 compose.yml..."
    if [[ $GPU_COUNT -eq 1 ]]; then
        info "检测到单个 GPU，使用默认 compose.yml"
        return
    fi
    cat > "$COMPOSE_FILE" << 'EOF'
name: bento
x-base-environment: &base-environment
  DATABASE_URL: postgresql://${POSTGRES_USER:-worker}:${POSTGRES_PASSWORD:-password}@${POSTGRES_HOST:-postgres}:${POSTGRES_PORT:-5432}/${POSTGRES_DB:-taskdb}
  REDIS_URL: redis://${REDIS_HOST:-redis}:6379
  S3_URL: http://${MINIO_HOST:-minio}:9000
  S3_BUCKET: ${MINIO_BUCKET:-workflow}
  S3_ACCESS_KEY: ${MINIO_ROOT_USER:-admin}
  S3_SECRET_KEY: ${MINIO_ROOT_PASS:-password}
  RUST_LOG: ${RUST_LOG:-info}
  RUST_BACKTRACE: 1

x-agent-common: &agent-common
  image: risczero/risc0-bento-agent:stable@sha256:c6fcc92686a5d4b20da963ebba3045f09a64695c9ba9a9aa984dd98b5ddbd6f9
  restart: always
  runtime: nvidia
  depends_on:
    - postgres
    - redis
    - minio
  environment:
    <<: *base-environment

x-exec-agent-common: &exec-agent-common
  <<: *agent-common
  mem_limit: 4G
  cpus: 3
  environment:
    <<: *base-environment
    RISC0_KECCAK_PO2: ${RISC0_KECCAK_PO2:-17}
  entrypoint: /app/agent -t exec --segment-po2 ${SEGMENT_SIZE:-21}

services:
  redis:
    hostname: ${REDIS_HOST:-redis}
    image: ${REDIS_IMG:-redis:7.2.5-alpine3.19}
    restart: always
    ports:
      - 6379:6379
    volumes:
      - redis-data:/data

  postgres:
    hostname: ${POSTGRES_HOST:-postgres}
    image: ${POSTGRES_IMG:-postgres:16.3-bullseye}
    restart: always
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-taskdb}
      POSTGRES_USER: ${POSTGRES_USER:-worker}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-password}
    expose:
      - '${POSTGRES_PORT:-5432}'
    ports:
      - '${POSTGRES_PORT:-5432}:${POSTGRES_PORT:-5432}'
    volumes:
      - postgres-data:/var/lib/postgresql/data
    command: -p ${POSTGRES_PORT:-5432}

  minio:
    hostname: ${MINIO_HOST:-minio}
    image: ${MINIO_IMG:-minio/minio:RELEASE.2024-05-28T17-19-04Z}
    ports:
      - '9000:9000'
      - '9001:9001'
    volumes:
      - minio-data:/data
    command: server /data --console-address ":9001"
    environment:
      - MINIO_ROOT_USER=${MINIO_ROOT_USER:-admin}
      - MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASS:-password}
      - MINIO_DEFAULT_BUCKETS=${MINIO_BUCKET:-workflow}
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 5s
      timeout: 5s
      retries: 5

  grafana:
    image: ${GRAFANA_IMG:-grafana/grafana:11.0.0}
    restart: unless-stopped
    ports:
      - '3000:3000'
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_LOG_LEVEL=WARN
      - POSTGRES_HOST=${POSTGRES_HOST:-postgres}
      - POSTGRES_DB=${POSTGRES_DB:-taskdb}
      - POSTGRES_PORT=${POSTGRES_PORT:-5432}
      - POSTGRES_USER=${POSTGRES_USER:-worker}
      - POSTGRES_PASS=${POSTGRES_PASSWORD:-password}
      - GF_INSTALL_PLUGINS=frser-sqlite-datasource
    volumes:
      - ./dockerfiles/grafana:/etc/grafana/provisioning/
      - grafana-data:/var/lib/grafana
      - broker-data:/db
    depends_on:
      - postgres
      - redis
      - minio

  exec_agent0:
    <<: *exec-agent-common

  exec_agent1:
    <<: *exec-agent-common

  aux_agent:
    <<: *agent-common
    mem_limit: 256M
    cpus: 1
    entrypoint: /app/agent -t aux --monitor-requeue

EOF
    for i in $(seq 0 $((GPU_COUNT - 1))); do
        cat >> "$COMPOSE_FILE" << EOF
  gpu_prove_agent$i:
    <<: *agent-common
    mem_limit: 4G
    cpus: 4
    entrypoint: /app/agent -t prove
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              device_ids: ['$i']
              capabilities: [gpu]

EOF
    done
    cat >> "$COMPOSE_FILE" << 'EOF'
  snark_agent:
    <<: *agent-common
    entrypoint: /app/agent -t snark
    ulimits:
      stack: 90000000

  rest_api:
    image: risczero/risc0-bento-rest-api:stable@sha256:7b5183811675d0aa3646d079dec4a7a6d47c84fab4fa33d3eb279135f2e59207
    restart: always
    depends_on:
      - postgres
      - minio
    mem_limit: 1G
    cpus: 1
    environment:
      <<: *base-environment
    ports:
      - '8081:8081'
    entrypoint: /app/rest_api --bind-addr 0.0.0.0:8081 --snark-timeout ${SNARK_TIMEOUT:-180}

  broker:
    restart: always
    depends_on:
      - rest_api
EOF
    for i in $(seq 0 $((GPU_COUNT - 1))); do
        echo "      - gpu_prove_agent$i" >> "$COMPOSE_FILE"
    done
    cat >> "$COMPOSE_FILE" << 'EOF'
      - exec_agent0
      - exec_agent1
      - aux_agent
      - snark_agent
      - redis
      - postgres
    profiles: [broker]
    build:
      context: .
      dockerfile: dockerfiles/broker.dockerfile
    mem_limit: 2G
    cpus: 2
    stop_grace_period: 3h
    volumes:
      - type: bind
        source: ./broker.toml
        target: /app/broker.toml
      - broker-data:/db/
    network_mode: host
    environment:
      RUST_LOG: ${RUST_LOG:-info,broker=debug,boundless_market=debug}
      PRIVATE_KEY: ${PRIVATE_KEY}
      RPC_URL: ${RPC_URL}
      ORDER_STREAM_URL:
      POSTGRES_HOST:
      POSTGRES_DB:
      POSTGRES_PORT:
      POSTGRES_USER:
      POSTGRES_PASS:
    entrypoint: /app/broker --db-url 'sqlite:///db/broker.db' --set-verifier-address ${SET_VERIFIER_ADDRESS} --boundless-market-address ${BOUNDLESS_MARKET_ADDRESS} --config-file /app/broker.toml --bento-api-url http://localhost:8081

volumes:
  redis-data:
  postgres-data:
  minio-data:
  grafana-data:
  broker-data:
EOF
    success "为 $GPU_COUNT 个 GPU 配置了 compose.yml"
}

# 配置网络
configure_network() {
    info "配置网络设置..."
    echo -e "\n${BOLD}可用网络:${RESET}"
    echo "1) Base 主网"
    echo "2) Base Sepolia (测试网)"
    echo "3) 以太坊 Sepolia (测试网)"
    prompt "选择网络 (1-3): "
    read -r network_choice
    case $network_choice in
        1) NETWORK="base" ;;
        2) NETWORK="base-sepolia" ;;
        3) NETWORK="eth-sepolia" ;;
        *) error "无效的网络选择"; exit $EXIT_NETWORK_ERROR ;;
    esac
    IFS='|' read -r NETWORK_NAME VERIFIER_ADDRESS BOUNDLESS_MARKET_ADDRESS SET_VERIFIER_ADDRESS ORDER_STREAM_URL <<< "${NETWORKS[$NETWORK]}"
    info "已选择: $NETWORK_NAME"
    echo -e "\n${BOLD}RPC 配置:${RESET}"
    echo "RPC 必须支持 eth_newBlockFilter。推荐的提供商:"
    echo "- Alchemy (设置 lookback_block=<120>)"
    echo "- BlockPi (Base 网络免费)"
    echo "- Chainstack (设置 lookback_blocks=0)"
    echo "- 您自己的节点 RPC"
    prompt "输入 RPC URL: "
    read -r RPC_URL
    if [[ -z "$RPC_URL" ]]; then
        error "RPC URL 不能为空"
        exit $EXIT_NETWORK_ERROR
    fi
    prompt "输入钱包私钥 (不含 0x 前缀): "
    read -rs PRIVATE_KEY
    echo
    if [[ -z "$PRIVATE_KEY" ]]; then
        error "私钥不能为空"
        exit $EXIT_NETWORK_ERROR
    fi
    cat > "$INSTALL_DIR/.env.broker" << EOF
# 网络: $NETWORK_NAME
export VERIFIER_ADDRESS=$VERIFIER_ADDRESS
export BOUNDLESS_MARKET_ADDRESS=$BOUNDLESS_MARKET_ADDRESS
export SET_VERIFIER_ADDRESS=$SET_VERIFIER_ADDRESS
export ORDER_STREAM_URL="$ORDER_STREAM_URL"
export RPC_URL="$RPC_URL"
export PRIVATE_KEY=$PRIVATE_KEY
export SEGMENT_SIZE=$SEGMENT_SIZE

# 证明者节点配置
RUST_LOG=info
REDIS_HOST=redis
REDIS_IMG=redis:7.2.5-alpine3.19
POSTGRES_HOST=postgres
POSTGRES_IMG=postgres:16.3-bullseye
POSTGRES_DB=taskdb
POSTGRES_PORT=5432
POSTGRES_USER=worker
POSTGRES_PASSWORD=password
MINIO_HOST=minio
MINIO_IMG=minio/minio:RELEASE.2024-05-28T17-19-04Z
MINIO_ROOT_USER=admin
MINIO_ROOT_PASS=password
MINIO_BUCKET=workflow
GRAFANA_IMG=grafana/grafana:11.0.0
RISC0_KECCAK_PO2=17
EOF
    cat > "$INSTALL_DIR/.env.base" << EOF
export VERIFIER_ADDRESS=0x0b144e07a0826182b6b59788c34b32bfa86fb711
export BOUNDLESS_MARKET_ADDRESS=0x26759dbB201aFbA361Bec78E097Aa3942B0b4AB8
export SET_VERIFIER_ADDRESS=0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760
export ORDER_STREAM_URL="https://base-mainnet.beboundless.xyz"
export RPC_URL="$RPC_URL"
export PRIVATE_KEY=$PRIVATE_KEY
export SEGMENT_SIZE=$SEGMENT_SIZE
EOF
    cat > "$INSTALL_DIR/.env.base-sepolia" << EOF
export VERIFIER_ADDRESS=0x0b144e07a0826182b6b59788c34b32bfa86fb711
export BOUNDLESS_MARKET_ADDRESS=0x6B7ABa661041164b8dB98E30AE1454d2e9D5f14b
export SET_VERIFIER_ADDRESS=0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760
export ORDER_STREAM_URL="https://base-sepolia.beboundless.xyz"
export RPC_URL="$RPC_URL"
export PRIVATE_KEY=$PRIVATE_KEY
export SEGMENT_SIZE=$SEGMENT_SIZE
EOF
    cat > "$INSTALL_DIR/.env.eth-sepolia" << EOF
export VERIFIER_ADDRESS=0x925d8331ddc0a1F0d96E68CF073DFE1d92b69187
export BOUNDLESS_MARKET_ADDRESS=0x13337C76fE2d1750246B68781ecEe164643b98Ec
export SET_VERIFIER_ADDRESS=0x7aAB646f23D1392d4522CFaB0b7FB5eaf6821d64
export ORDER_STREAM_URL="https://eth-sepolia.beboundless.xyz/"
export RPC_URL="$RPC_URL"
export PRIVATE_KEY=$PRIVATE_KEY
export SEGMENT_SIZE=$SEGMENT_SIZE
EOF
    chmod 600 "$INSTALL_DIR/.env.broker" "$INSTALL_DIR/.env.base" "$INSTALL_DIR/.env.base-sepolia" "$INSTALL_DIR/.env.eth-sepolia"
    success "网络配置已保存"
}

# 配置 broker.toml
configure_broker() {
    info "配置 Broker 设置..."
    cp "$INSTALL_DIR/broker-template.toml" "$BROKER_CONFIG"
    echo -e "\n${BOLD}Broker 配置:${RESET}"
    echo "设置关键参数 (按 Enter 使用默认值):"
    prompt "mcycle_price (每百万周期价格，建议 0.0000005): "
    read -r mcycle_price
    mcycle_price=${mcycle_price:-0.0000005}
    prompt "peak_prove_khz (最大证明速度 kHz，建议 100): "
    read -r peak_prove_khz
    peak_prove_khz=${peak_prove_khz:-100}
    prompt "max_mcycle_limit (最大周期数，百万，建议 8000): "
    read -r max_mcycle_limit
    max_mcycle_limit=${max_mcycle_limit:-8000}
    prompt "min_deadline (最短截止时间秒数，建议 300): "
    read -r min_deadline
    min_deadline=${min_deadline:-300}
    prompt "max_concurrent_proofs (最大并行证明数，建议 2): "
    read -r max_concurrent_proofs
    max_concurrent_proofs=${max_concurrent_proofs:-2}
    prompt "lockin_priority_gas (锁定交易额外 Gas，Gwei，建议 0): "
    read -r lockin_priority_gas
    sed -i "s/mcycle_price = \"[^\"]*\"/mcycle_price = \"$mcycle_price\"/" "$BROKER_CONFIG"
    sed -i "s/peak_prove_khz = [0-9]*/peak_prove_khz = $peak_prove_khz/" "$BROKER_CONFIG"
    sed -i "s/max_mcycle_limit = [0-9]*/max_mcycle_limit = $max_mcycle_limit/" "$BROKER_CONFIG"
    sed -i "s/min_deadline = [0-9]*/min_deadline = $min_deadline/" "$BROKER_CONFIG"
    sed -i "s/max_concurrent_proofs = [0-9]*/max_concurrent_proofs = $max_concurrent_proofs/" "$BROKER_CONFIG"
    if [[ -n "$lockin_priority_gas" ]]; then
        sed -i "s/#lockin_priority_gas = [0-9]*/lockin_priority_gas = $lockin_priority_gas/" "$BROKER_CONFIG"
    fi
    success "Broker 配置已保存"
}

# 创建管理脚本
create_management_script() {
    info "创建管理脚本..."
    cat > "$INSTALL_DIR/prover.sh" << 'EOF'
#!/bin/bash

export PATH="$HOME/.cargo/bin:$PATH"

INSTALL_DIR="$(dirname "$0")"
cd "$INSTALL_DIR"

# 颜色变量
CYAN='\033[0;36m'
LIGHTBLUE='\033[1;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
ORANGE='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'
GRAY='\033[0;90m'

# 菜单项
declare -a menu_items=(
    "服务:服务管理"
    "启动 Broker"
    "启动 Bento (仅测试)"
    "停止服务"
    "查看日志"
    "健康检查"
    "分隔符:"
    "配置:配置管理"
    "更改网络"
    "更改私钥"
    "编辑 Broker 配置"
    "分隔符:"
    "质押:质押管理"
    "存款质押"
    "检查质押余额"
    "分隔符:"
    "性能测试:性能测试"
    "运行基准测试 (订单 ID)"
    "分隔符:"
    "监控:监控"
    "监控 GPU"
    "分隔符:"
    "退出"
)

# 绘制菜单
draw_menu() {
    local current=$1
    clear
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║      Boundless 证明者管理                ║${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${RESET}"
    echo

    local index=0
    for item in "${menu_items[@]}"; do
        if [[ $item == *":"* ]]; then
            if [[ $item == "分隔符:" ]]; then
                echo -e "${GRAY}──────────────────────────────────────────${RESET}"
            else
                local category=$(echo $item | cut -d: -f1)
                local desc=$(echo $item | cut -d: -f2)
                case $category in
                    "服务") echo -e "\n${BOLD}${GREEN}▶ $desc${RESET}" ;;
                    "配置") echo -e "\n${BOLD}${YELLOW}▶ $desc${RESET}" ;;
                    "质押") echo -e "\n${BOLD}${PURPLE}▶ $desc${RESET}" ;;
                    "性能测试") echo -e "\n${BOLD}${ORANGE}▶ $desc${RESET}" ;;
                    "监控") echo -e "\n${BOLD}${LIGHTBLUE}▶ $desc${RESET}" ;;
                esac
            fi
        else
            if [ $index -eq $current ]; then
                echo -e "  ${BOLD}${CYAN}→ $item${RESET}"
            else
                echo -e "    $item"
            fi
            ((index++))
        fi
    done
    echo -e "\n${GRAY}使用 ↑/↓ 箭头导航，Enter 键选择，q 退出${RESET}"
}

# 获取菜单项
get_menu_item() {
    local current=$1
    local index=0
    for item in "${menu_items[@]}"; do
        if [[ ! $item == *":"* ]]; then
            if [ $index -eq $current ]; then
                echo "$item"
                return
            fi
            ((index++))
        fi
    done
}

# 获取按键
get_key() {
    local key
    IFS= read -rsn1 key 2>/dev/null >&2
    if [[ $key = "" ]]; then echo enter; fi
    if [[ $key = $'\x1b' ]]; then
        read -rsn2 key
        if [[ $key = [A ]]; then echo up; fi
        if [[ $key = [B ]]; then echo down; fi
    fi
    if [[ $key = "q" || $key = "Q" ]]; then echo quit; fi
}

# 验证配置
validate_config() {
    local errors=0
    if [[ ! -f .env.broker ]]; then
        echo -e "${RED}✗ 未找到 .env.broker 文件${RESET}"
        ((errors++))
    else
        source .env.broker
        if [[ ! "$PRIVATE_KEY" =~ ^[0-9a-fA-F]{64}$ ]]; then
            echo -e "${RED}✗ 私钥格式无效${RESET}"
            ((errors++))
        fi
        if [[ -z "$RPC_URL" ]]; then
            echo -e "${RED}✗ 未配置 RPC URL${RESET}"
            ((errors++))
        fi
        if [[ -z "$BOUNDLESS_MARKET_ADDRESS" || -z "$SET_VERIFIER_ADDRESS" ]]; then
            echo -e "${RED}✗ 缺少必需的合约地址${RESET}"
            ((errors++))
        fi
    fi
    return $errors
}

# 子菜单导航
arrow_menu() {
    local -a options=("$@")
    local current=0
    local key
    while true; do
        clear
        for i in "${!options[@]}"; do
            if [ $i -eq $current ]; then
                echo -e "${BOLD}${CYAN}→ ${options[$i]}${RESET}"
            else
                echo -e "  ${options[$i]}"
            fi
        done
        echo -e "\n${GRAY}使用 ↑/↓ 箭头导航，Enter 键选择，q 返回${RESET}"
        key=$(get_key)
        case $key in
            up) ((current--)); [ $current -lt 0 ] && current=$((${#options[@]}-1)) ;;
            down) ((current++)); [ $current -ge ${#options[@]} ] && current=0 ;;
            enter) return $current ;;
            quit) return 255 ;;
        esac
    done
}

# 检查容器是否运行
is_container_running() {
    local container=$1
    local status=$(docker compose ps -q $container 2>/dev/null)
    [[ -n "$status" ]] && docker compose ps $container 2>/dev/null | grep -q "Up" && return 0
    return 1
}

# 获取容器退出代码
get_container_exit_code() {
    local container=$1
    docker compose ps $container 2>/dev/null | grep -oP 'Exit \K\d+' || echo "N/A"
}

# 检查容器状态
check_container_status() {
    local containers=("broker" "rest_api" "postgres" "redis" "minio" "gpu_prove_agent0" "exec_agent0" "exec_agent1" "aux_agent" "snark_agent")
    local statuses=$(docker compose ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null)
    local has_issues=false
    for container in "${containers[@]}"; do
        if ! echo "$statuses" | grep -q "^$container.*Up"; then
            has_issues=true
            break
        fi
    done
    if [[ "$has_issues" == true ]]; then
        echo -e "${RED}${BOLD}⚠ 警告：部分容器未正常运行${RESET}"
        echo -e "${YELLOW}选择 '容器状态' 查看详情${RESET}\n"
    fi
}

# 显示容器状态
show_container_status() {
    clear
    echo -e "${BOLD}${CYAN}容器状态概览${RESET}"
    echo -e "${GRAY}════════════════════════════════════════${RESET}\n"
    local containers=$(docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Service}}" 2>/dev/null | tail -n +2)
    if [[ -z "$containers" ]]; then
        echo -e "${RED}未找到容器。服务可能未启动。${RESET}"
    else
        printf "%-30s %-20s %s\n" "容器" "状态" "服务"
        echo -e "${GRAY}────────────────────────────────────────────────────────────${RESET}"
        while IFS= read -r line; do
            local name=$(echo "$line" | awk '{print $1}')
            local status=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ *//')
            local service=$(echo "$line" | awk '{print $NF}')
            if echo "$status" | grep -q "Up"; then
                printf "${GREEN}%-30s${RESET} %-20s %s\n" "$name" "✓ 运行中" "$service"
            elif echo "$status" | grep -q "Exit"; then
                printf "${RED}%-30s${RESET} ${RED}%-20s${RESET} %s\n" "$name" "✗ 已退出" "$service"
                if [[ "$service" == "broker" ]]; then
                    echo -e "${YELLOW}  └─ 最后错误: $(docker compose logs --tail=1 broker 2>&1 | grep -oE 'error:.*' | head -1)${RESET}"
                fi
            elif echo "$status" | grep -q "Restarting"; then
                printf "${YELLOW}%-30s${RESET} ${YELLOW}%-20s${RESET} %s\n" "$name" "↻ 正在重启" "$service"
            else
                printf "%-30s %-20s %s\n" "$name" "$status" "$service"
            fi
        done <<< "$containers"
    fi
    echo -e "\n${GRAY}按任意键继续...${RESET}"
    read -n 1
}

# 分析 Broker 错误
analyze_broker_errors() {
    local last_errors=$(docker compose logs --tail=100 broker 2>&1 | grep -i "error" | tail -5)
    if [[ -z "$last_errors" ]]; then
        return
    fi
    echo -e "\n${BOLD}${YELLOW}检测到的问题:${RESET}"
    if echo "$last_errors" | grep -q "odd number of digits"; then
        echo -e "${RED}✗ 私钥格式无效${RESET}"
        echo -e "  ${YELLOW}→ 私钥必须是 64 个十六进制字符 (不含 0x 前缀)${RESET}"
        echo -e "  ${YELLOW}→ 使用 '更改私钥' 选项修复${RESET}"
    fi
    if echo "$last_errors" | grep -q "connection refused"; then
        echo -e "${RED}✗ 连接被拒绝${RESET}"
        echo -e "  ${YELLOW}→ 检查所有必需服务是否运行${RESET}"
        echo -e "  ${YELLOW}→ 验证 RPC URL 是否可访问${RESET}"
    fi
    if echo "$last_errors" | grep -q "insufficient funds"; then
        echo -e "${RED}✗ 资金不足${RESET}"
        echo -e "  ${YELLOW}→ 检查钱包余额是否足够支付 Gas${RESET}"
        echo -e "  ${YELLOW}→ 确保已存入 USDC 质押${RESET}"
    fi
    if echo "$last_errors" | grep -q "RPC.*error\|eth_.*not supported"; then
        echo -e "${RED}✗ RPC 连接问题${RESET}"
        echo -e "  ${YELLOW}→ 验证 RPC URL 是否正确且可访问${RESET}"
        echo -e "  ${YELLOW}→ 检查 RPC 是否支持 eth_newBlockFilter${RESET}"
    fi
    if echo "$last_errors" | grep -q "database.*connection\|postgres"; then
        echo -e "${RED}✗ 数据库连接问题${RESET}"
        echo -e "  ${YELLOW}→ 检查 postgres 容器是否运行${RESET}"
        echo -e "  ${YELLOW}→ 尝试重启所有服务${RESET}"
    fi
    if echo "$last_errors" | grep -q "stake.*required\|minimum.*stake"; then
        echo -e "${RED}✗ 质押不足${RESET}"
        echo -e "  ${YELLOW}→ 使用 '存款质押' 选项添加 USDC 质押${RESET}"
    fi
    if echo "$last_errors" | grep -q "invalid.*address\|checksum"; then
        echo -e "${RED}✗ 无效的合约地址${RESET}"
        echo -e "  ${YELLOW}→ 网络配置可能已损坏${RESET}"
        echo -e "  ${YELLOW}→ 尝试切换网络${RESET}"
    fi
    echo -e "\n${GRAY}最后错误消息:${RESET}"
    echo "$last_errors" | while IFS= read -r line; do
        echo -e "${GRAY}  $line${RESET}"
    done
}

# 查看 Broker 日志
view_broker_logs() {
    clear
    echo -e "${CYAN}${BOLD}Broker 日志${RESET}"
    echo -e "${GRAY}════════════════════════════════════════${RESET}\n"
    if is_container_running "broker"; then
        echo -e "${GREEN}Broker 正在运行。显示实时日志 (按 Ctrl+C 退出)...${RESET}\n"
        docker compose logs -f broker
    else
        echo -e "${RED}${BOLD}⚠ Broker 容器未运行！${RESET}"
        echo -e "${YELLOW}显示可用日志...${RESET}\n"
        docker compose logs broker 2>&1 || echo -e "${RED}Broker 无可用日志${RESET}"
        echo -e "\n${GRAY}────────────────────────────────────────${RESET}"
        analyze_broker_errors
    fi
}

# 查看最后 100 行 Broker 日志
view_broker_logs_tail() {
    clear
    echo -e "${CYAN}${BOLD}最后 100 行 Broker 日志${RESET}"
    echo -e "${GRAY}════════════════════════════════════════${RESET}\n"
    if is_container_running "broker"; then
        echo -e "${GREEN}Broker 正在运行。显示最后 100 行并继续跟踪 (按 Ctrl+C 退出)...${RESET}\n"
        docker compose logs --tail=100 -f broker
    else
        echo -e "${RED}${BOLD}⚠ Broker 容器未运行！${RESET}"
        echo -e "${YELLOW}显示最后 100 行日志...${RESET}\n"
        docker compose logs --tail=100 broker 2>&1 || echo -e "${RED}Broker 无可用日志${RESET}"
        echo -e "\n${GRAY}────────────────────────────────────────${RESET}"
        analyze_broker_errors
    fi
}

# 查看日志
view_logs() {
    echo -e "${BOLD}${CYAN}日志查看器${RESET}"
    echo -e "${GRAY}──────────────────${RESET}"
    check_container_status
    local options=("所有日志" "仅 Broker 日志" "最后 100 行 Broker 日志" "容器状态" "返回菜单")
    arrow_menu "${options[@]}"
    local choice=$?
    case $choice in
        0) clear; echo -e "${CYAN}${BOLD}显示所有日志 (按 Ctrl+C 退出)...${RESET}\n"; just broker logs ;;
        1) view_broker_logs ;;
        2) view_broker_logs_tail ;;
        3) show_container_status ;;
        4|255) return ;;
    esac
}

# 启动 Broker
start_broker() {
    clear
    echo -e "${CYAN}${BOLD}验证配置...${RESET}"
    if ! validate_config; then
        echo -e "\n${RED}配置验证失败！${RESET}"
        echo -e "${YELLOW}请先修复上述问题，然后再启动 Broker。${RESET}"
        echo -e "\n按任意键返回..."
        read -n 1
        return
    fi
    source .env.broker
    echo -e "${GREEN}✓ 配置验证通过${RESET}"
    echo -e "\n${GREEN}${BOLD}启动 Broker...${RESET}"
    just broker
    sleep 3
    if ! is_container_running "broker"; then
        echo -e "\n${RED}${BOLD}⚠ Broker 启动失败！${RESET}"
        echo -e "${YELLOW}检查日志以查找错误...${RESET}\n"
        docker compose logs --tail=20 broker
        analyze_broker_errors
        echo -e "\n按任意键返回..."
        read -n 1
    fi
}

# 启动 Bento
start_bento() {
    clear
    echo -e "${GREEN}${BOLD}为测试启动 Bento...${RESET}"
    just bento
}

# 停止服务
stop_services() {
    clear
    echo -e "${YELLOW}${BOLD}停止服务...${RESET}"
    just broker down
    echo -e "\n${GREEN}服务已停止。按任意键继续...${RESET}"
    read -n 1
}

# 更改网络
change_network() {
    echo -e "${BOLD}${YELLOW}网络选择${RESET}"
    echo -e "${GRAY}──────────────────${RESET}"
    local options=("Base 主网" "Base Sepolia" "以太坊 Sepolia" "返回菜单")
    arrow_menu "${options[@]}"
    local choice=$?
    if [[ -f .env.broker ]]; then
        source .env.broker
        CURRENT_SEGMENT_SIZE=$SEGMENT_SIZE
    fi
    case $choice in
        0) cp .env.base .env.broker; echo -e "${GREEN}网络已更改为 Base 主网${RESET}"; local selected_network="base" ;;
        1) cp .env.base-sepolia .env.broker; echo -e "${GREEN}网络已更改为 Base Sepolia${RESET}"; local selected_network="base-sepolia" ;;
        2) cp .env.eth-sepolia .env.broker; echo -e "${GREEN}网络已更改为以太坊 Sepolia${RESET}"; local selected_network="eth-sepolia" ;;
        3|255) return ;;
    esac
    if [[ $choice -le 2 ]]; then
        if [[ -n "$CURRENT_SEGMENT_SIZE" ]]; then
            sed -i "s/export SEGMENT_SIZE=.*/export SEGMENT_SIZE=$CURRENT_SEGMENT_SIZE/" .env.broker
            sed -i "s/export SEGMENT_SIZE=.*/export SEGMENT_SIZE=$CURRENT_SEGMENT_SIZE/" .env.$selected_network
        fi
        echo -e "\n${BOLD}新网络的 RPC 配置:${RESET}"
        echo "RPC 必须支持 eth_newBlockFilter。推荐的提供商:"
        echo "- BlockPi (Base 网络免费)"
        echo "- Alchemy"
        echo "- Chainstack (设置 lookback_blocks=0)"
        echo "- 您自己的节点"
        read -p "输入 RPC URL: " new_rpc
        if [[ -n "$new_rpc" ]]; then
            sed -i "s|export RPC_URL=.*|export RPC_URL=\"$new_rpc\"|" .env.broker
            sed -i "s|export RPC_URL=.*|export RPC_URL=\"$new_rpc\"|" .env.$selected_network
            echo -e "${GREEN}RPC URL 已更新${RESET}"
        fi
        echo -e "${YELLOW}请重启 Broker 以应用更改${RESET}"
        echo -e "\n按任意键继续..."
        read -n 1
    fi
}

# 更改私钥
change_private_key() {
    clear
    echo -e "${BOLD}${YELLOW}更改私钥${RESET}"
    echo -e "${GRAY}──────────────────${RESET}"
    echo -e "${RED}警告: 这将更新所有网络文件中的私钥${RESET}"
    echo
    read -sp "输入新私钥 (不含 0x 前缀): " new_key
    echo
    if [[ -z "$new_key" ]]; then
        echo -e "${RED}私钥不能为空${RESET}"
        echo -e "\n按任意键继续..."
        read -n 1
        return
    fi
    if [[ ! "$new_key" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo -e "${RED}私钥格式无效！${RESET}"
        echo -e "${YELLOW}必须是 64 个十六进制字符 (不含 0x 前缀)${RESET}"
        echo -e "\n按任意键继续..."
        read -n 1
        return
    fi
    for env_file in .env.broker .env.base .env.base-sepolia .env.eth-sepolia; do
        if [[ -f "$env_file" ]]; then
            sed -i "s/export PRIVATE_KEY=.*/export PRIVATE_KEY=$new_key/" "$env_file"
        fi
    done
    echo -e "\n${GREEN}私钥在所有网络文件中更新成功${RESET}"
    echo -e "${YELLOW}请重启服务以应用更改${RESET}"
    echo -e "\n按任意键继续..."
    read -n 1
}

# 编辑 Broker 配置
edit_broker_config() {
    clear
    nano broker.toml
}

# 存款质押
deposit_stake() {
    clear
    source .env.broker
    echo -e "${BOLD}${PURPLE}存款 USDC 质押${RESET}"
    echo -e "${GRAY}──────────────────${RESET}"
    read -p "输入质押金额 (USDC): " amount
    if [[ -n "$amount" ]]; then
        boundless account deposit-stake "$amount"
        echo -e "\n按任意键继续..."
        read -n 1
    fi
}

# 检查质押余额
check_balance() {
    clear
    source .env.broker
    echo -e "${BOLD}${PURPLE}质押余额${RESET}"
    echo -e "${GRAY}──────────────────${RESET}"
    boundless account stake-balance
    echo -e "\n按任意键继续..."
    read -n 1
}

# 运行基准测试
run_benchmark_orders() {
    clear
    source .env.broker
    echo -e "${BOLD}${ORANGE}使用订单 ID 进行基准测试${RESET}"
    echo -e "${GRAY}──────────────────${RESET}"
    echo "输入来自 https://explorer.beboundless.xyz/orders 的订单 ID"
    read -p "订单 ID (逗号分隔): " ids
    if [[ -n "$ids" ]]; then
        boundless proving benchmark --request-ids "$ids"
        echo -e "\n按任意键继续..."
        read -n 1
    fi
}

# 监控 GPU
monitor_gpus() {
    clear
    nvtop
}

# 健康检查
health_check() {
    clear
    echo -e "${BOLD}${CYAN}系统健康检查${RESET}"
    echo -e "${GRAY}════════════════════════════════════════${RESET}\n"
    echo -e "${BOLD}1. 配置状态:${RESET}"
    if validate_config > /dev/null 2>&1; then
        echo -e "   ${GREEN}✓ 配置有效${RESET}"
        source .env.broker
        echo -e "   ${GRAY}网络: $(grep ORDER_STREAM_URL .env.broker | cut -d'/' -f3 | cut -d'.' -f1)${RESET}"
        echo -e "   ${GRAY}钱包: ${PRIVATE_KEY:0:6}...${PRIVATE_KEY: -4}${RESET}"
    else
        echo -e "   ${RED}✗ 检测到配置问题${RESET}"
        validate_config
    fi
    echo -e "\n${BOLD}2. 服务状态:${RESET}"
    local critical_services=("broker" "rest_api" "postgres" "redis" "minio")
    local all_healthy=true
    for service in "${critical_services[@]}"; do
        if is_container_running "$service"; then
            echo -e "   ${GREEN}✓ $service${RESET}"
        else
            echo -e "   ${RED}✗ $service${RESET}"
            all_healthy=false
        fi
    done
    echo -e "\n${BOLD}3. GPU 状态:${RESET}"
    if command_exists nvidia-smi > /dev/null 2>&1; then
        local gpu_count=$(nvidia-smi -L 2>/dev/null | wc -l)
        if [[ $gpu_count -gt 0 ]]; then
            echo -e "   ${GREEN}✓ 检测到 $gpu_count 个 GPU${RESET}"
            nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | while IFS=',' read -r idx name util mem_used mem_total; do
                echo -e "   ${GRAY}GPU $idx: $name - ${util}% 使用率, ${mem_used}MB/${mem_total}MB${RESET}"
            done
        else
            echo -e "   ${RED}✗ 未检测到 GPU${RESET}"
        fi
    else
        echo -e "   ${RED}✗ 未找到 nvidia-smi${RESET}"
    fi
    echo -e "\n${BOLD}4. 网络状态:${RESET}"
    if [[ -n "$RPC_URL" ]]; then
        echo -e "   ${GRAY}测试 RPC 连接...${RESET}"
        if curl -s -X POST "$RPC_URL" -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' --connect-timeout 5 > /dev/null 2>&1; then
            echo -e "   ${GREEN}✓ RPC 连接成功${RESET}"
        else
            echo -e "   ${RED}✗ RPC 连接失败${RESET}"
        fi
    else
        echo -e "   ${RED}✗ 未配置 RPC URL${RESET}"
    fi
    echo -e "\n${BOLD}5. 总体状态:${RESET}"
    if [[ "$all_healthy" == true ]] && validate_config > /dev/null 2>&1; then
        echo -e "   ${GREEN}✓ 系统健康且准备就绪${RESET}"
    else
        echo -e "   ${YELLOW}⚠ 检测到问题 - 请查看上述详情${RESET}"
    fi
    echo -e "\n${GRAY}按任意键继续...${RESET}"
    read -n 1
}

# 检查服务状态
echo -e "${CYAN}检查服务状态...${RESET}"
if docker compose ps 2>/dev/null | grep -q "broker"; then
    if ! is_container_running "broker"; then
        echo -e "\n${RED}${BOLD}⚠ Broker 容器未正常运行！${RESET}"
        echo -e "${YELLOW}请检查日志以了解问题原因${RESET}"
        sleep 2
    fi
fi

# 主菜单循环
current=0
menu_count=0
for item in "${menu_items[@]}"; do
    if [[ ! $item == *":"* ]]; then
        ((menu_count++))
    fi
done

while true; do
    draw_menu $current
    key=$(get_key)
    case $key in
        up) ((current--)); [ $current -lt 0 ] && current=$((menu_count-1)) ;;
        down) ((current++)); [ $current -ge $menu_count ] && current=0 ;;
        enter)
            selected=$(get_menu_item $current)
            case "$selected" in
                "启动 Broker") start_broker ;;
                "启动 Bento (仅测试)") start_bento ;;
                "停止服务") stop_services ;;
                "查看日志") view_logs ;;
                "健康检查") health_check ;;
                "更改网络") change_network ;;
                "更改私钥") change_private_key ;;
                "编辑 Broker 配置") edit_broker_config ;;
                "存款质押") deposit_stake ;;
                "检查质押余额") check_balance ;;
                "运行基准测试 (订单 ID)") run_benchmark_orders ;;
                "监控 GPU") monitor_gpus ;;
                "退出") clear; echo -e "${GREEN}再见！${RESET}"; exit 0 ;;
            esac
            ;;
                quit) clear; echo -e "${GREEN}再见！${RESET}"; exit 0 ;;
    esac
done
EOF
chmod +x "$INSTALL_DIR/prover.sh"
success "管理脚本已创建并设置为可执行"
}

# 主安装流程
main() {
    echo -e "${BOLD}${CYAN}Boundless 证明者节点设置脚本 by zakehowell${RESET}"
    echo "========================================"
    
    # 创建日志文件
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE" "$ERROR_LOG"
    echo "[开始] 安装开始于 $(date)" >> "$LOG_FILE"
    echo "[开始] 安装开始于 $(date)" >> "$ERROR_LOG"

    info "日志将保存到："
    info "  - 完整日志: cat $LOG_FILE"
    info "  - 错误日志: cat $ERROR_LOG"
    echo


    # 检查所有依赖
    check_all_deps

    # 执行安装流程
    check_os
    update_system
    info "正在安装依赖项..."
    install_basic_deps
    install_gpu_drivers
    install_docker
    install_nvidia_toolkit
    install_rust
    install_just
    install_cuda
    install_rust_deps
    clone_repository
    detect_gpus
    configure_compose
    configure_network
    configure_broker
    create_management_script

    # 安装完成提示
    echo -e "\n${GREEN}${BOLD}安装完成！${RESET}"
    echo "[成功] 安装完成于 $(date)" >> "$LOG_FILE"
    
    echo -e "\n${BOLD}后续步骤:${RESET}"
    echo "1. 使用管理脚本管理证明者节点"
    echo "2. 进入目录: cd $INSTALL_DIR"
    echo "3. 运行管理脚本: ./prover.sh"
    echo "4. 使用管理脚本完成 USDC 质押操作"

    echo -e "\n${YELLOW}重要提示:${RESET}"
    echo "启动时请务必检查日志！"
    echo "GPU 监控: nvtop"
    echo "系统监控: htop"

    echo -e "\n${CYAN}安装日志已保存至:${RESET}"
    echo "  - $LOG_FILE"
    echo "  - $ERROR_LOG"

    echo -e "\n${YELLOW}安全提醒:${RESET}"
    echo "您的私钥存储在 $INSTALL_DIR/.env.* 文件中。"
    echo "请确保这些文件不被未经授权的用户访问。"
    echo "当前权限已设置为 600 (仅所有者可读写)。"

    echo -e "\n${YELLOW}注意:${RESET}"
    echo "Docker 组更改可能需要重新登录或重启以生效。"

    if [[ "$START_IMMEDIATELY" == "true" ]]; then
        cd "$INSTALL_DIR"
        ./prover.sh
    else
        prompt "现在启动管理脚本？(y/N): "
        read -r start_now
        if [[ "$start_now" =~ ^[yY]$ ]]; then
            cd "$INSTALL_DIR"
            ./prover.sh
        fi
    fi
}

# 执行主函数
main