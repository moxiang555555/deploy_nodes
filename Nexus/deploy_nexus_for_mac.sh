#!/bin/bash

OS=$(uname -s)
case "$OS" in
    Darwin) OS_TYPE="macOS" ;;
    Linux)
        if [[ -f /etc/os-release ]]; then
            . /etc/os-release
            if [[ "$ID" == "ubuntu" ]]; then
                OS_TYPE="Ubuntu"
            else
                OS_TYPE="Linux"
            fi
        else
            OS_TYPE="Linux"
        fi
        ;;
    *)      echo "不支持的操作系统$OS本脚本仅支持macOSUbuntu和其他Linux发行版"; exit 1 ;;
esac

if [[ -n "$ZSH_VERSION" ]]; then
    SHELL_TYPE="zsh"
    CONFIG_FILE="$HOME/.zshrc"
elif [[ -n "$BASH_VERSION" ]]; then
    SHELL_TYPE="bash"
    CONFIG_FILE="$HOME/.bashrc"
else
    echo "不支持的shell本脚本仅支持bash和zsh"
    exit 1
fi

print_header() {
    echo "====================================="
    echo "$1"
    echo "====================================="
}

check_command() {
    if command -v "$1" &> /dev/null; then
        echo "$1已安装跳过安装步骤"
        return 0
    else
        echo "$1未安装开始安装"
        return 1
    fi
}

configure_shell() {
    local env_path="$1"
    local env_var="export PATH=$env_path:\$PATH"
    if [[ -f "$CONFIG_FILE" ]] && grep -q "$env_path" "$CONFIG_FILE"; then
        echo "环境变量已在$CONFIG_FILE中配置"
    else
        echo "正在将环境变量添加到$CONFIG_FILE"
        echo "$env_var" >> "$CONFIG_FILE"
        echo "环境变量已添加到$CONFIG_FILE"
        source "$CONFIG_FILE" 2>/dev/null || echo "无法加载$CONFIG_FILE请手动运行source $CONFIG_FILE"
    fi
}

install_homebrew() {
    print_header "检查Homebrew安装"
    if check_command brew; then
        return
    fi
    echo "在$OS_TYPE上安装Homebrew"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
        echo "安装Homebrew失败请检查网络连接或权限"
        exit 1
    }
    if [[ "$OS_TYPE" == "macOS" ]]; then
        configure_shell "/opt/homebrew/bin"
    else
        configure_shell "$HOME/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/bin"
        if ! check_command gcc; then
            echo "在Linux上安装gccHomebrew依赖"
            if command -v yum &> /dev/null; then
                sudo yum groupinstall 'Development Tools' || {
                    echo "安装gcc失败请手动安装Development Tools"
                    exit 1
                }
            else
                echo "不支持的包管理器请手动安装gcc"
                exit 1
            fi
        fi
    fi
}

install_cmake() {
    print_header "检查CMake安装"
    if check_command cmake; then
        return
    fi
    echo "正在安装CMake"
    if [[ "$OS_TYPE" == "Ubuntu" ]]; then
        sudo apt-get update && sudo apt-get install -y cmake || {
            echo "安装CMake失败请检查网络连接或权限"
            exit 1
        }
    else
        brew install cmake || {
            echo "安装CMake失败请检查Homebrew安装"
            exit 1
        }
    fi
}

install_protobuf() {
    print_header "检查Protobuf安装"
    if check_command protoc; then
        return
    fi
    echo "正在安装Protobuf"
    if [[ "$OS_TYPE" == "Ubuntu" ]]; then
        sudo apt-get update && sudo apt-get install -y protobuf-compiler || {
            echo "安装Protobuf失败请检查网络连接或权限"
            exit 1
        }
    else
        brew install protobuf || {
            echo "安装Protobuf失败请检查Homebrew安装"
            exit 1
        }
    fi
}

install_rust() {
    print_header "检查Rust安装"
    if check_command rustc; then
        return
    fi
    echo "正在安装Rust"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y || {
        echo "安装Rust失败请检查网络连接"
        exit 1
    }
    source "$HOME/.cargo/env" 2>/dev/null || echo "无法加载Rust环境请手动运行source ~/.cargo/env"
    configure_shell "$HOME/.cargo/bin"
}

configure_rust_target() {
    print_header "检查Rust RISC-V目标"
    if rustup target list --installed | grep -q "riscv32i-unknown-none-elf"; then
        echo "RISC-V目标riscv32i-unknown-none-elf已安装跳过"
        return
    fi
    echo "为Rust添加RISC-V目标"
    rustup target add riscv32i-unknown-none-elf || {
        echo "添加RISC-V目标失败请检查Rust安装"
        exit 1
    }
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

cleanup_exit() {
    log "收到退出信号正在清理Nexus节点进程和screen会话"
    if screen -list | grep -q "nexus_node"; then
        log "正在终止nexus_node screen会话"
        screen -S nexus_node -X quit 2>/dev/null || log "无法终止screen会话请检查权限或会话状态"
    else
        log "未找到nexus_node screen会话无需清理"
    fi
    PIDS=$(pgrep -f "nexus-network start --node-id" | tr '\n' ' ' | xargs echo -n)
    if [[ -n "$PIDS" ]]; then
        for pid in $PIDS; do
            if ps -p "$pid" > /dev/null 2>&1; then
                log "正在终止Nexus节点进程PID$pid"
                kill -9 "$pid" 2>/dev/null || log "无法终止PID$pid的进程请检查进程状态"
            fi
        done
    else
        log "未找到nexus-network进程"
    fi
    log "清理完成脚本退出"
    exit 0
}

cleanup_restart() {
    log "准备重启节点先进行清理"
    if screen -list | grep -q "nexus_node"; then
        log "正在终止nexus_node screen会话"
        screen -S nexus_node -X quit 2>/dev/null || log "无法终止screen会话请检查权限或会话状态"
    else
        log "未找到nexus_node screen会话无需清理"
    fi
    PIDS=$(pgrep -f "nexus-network start --node-id" | tr '\n' ' ' | xargs echo -n)
    if [[ -n "$PIDS" ]]; then
        for pid in $PIDS; do
            if ps -p "$pid" > /dev/null 2>&1; then
                log "正在终止Nexus节点进程PID$pid"
                kill -9 "$pid" 2>/dev/null || log "无法终止PID$pid的进程请检查进程状态"
            fi
        done
    else
        log "未找到nexus-network进程"
    fi
    log "清理完成准备重启节点"
}

trap 'cleanup_exit' SIGINT SIGTERM SIGHUP

install_nexus_cli() {
    local attempt=1
    local max_attempts=3
    local success=false
    while [[ $attempt -le $max_attempts ]]; do
        log "正在安装更新NexusCLI第$attempt/$max_attempts次"
        if curl -s https://cli.nexus.xyz/ | sh &>/dev/null; then
            log "NexusCLI安装更新成功"
            success=true
            break
        else
            log "第$attempt次安装更新NexusCLI失败"
            ((attempt++))
            sleep 2
        fi
    done
    if [[ "$success" == false ]]; then
        log "NexusCLI安装更新失败$max_attempts次将尝试使用当前版本运行节点"
    fi
    if command -v nexus-network &>/dev/null; then
        log "当前NexusCLI版本$(nexus-network --version 2>/dev/null)"
    else
        log "未找到NexusCLI无法运行节点"
        exit 1
    fi
}

get_node_id() {
    CONFIG_PATH="$HOME/.nexus/config.json"
    if [[ -f "$CONFIG_PATH" ]]; then
        CURRENT_NODE_ID=$(jq -r .node_id "$CONFIG_PATH" 2>/dev/null)
        if [[ -n "$CURRENT_NODE_ID" && "$CURRENT_NODE_ID" != "null" ]]; then
            log "检测到配置文件中的NodeID$CURRENT_NODE_ID"
            read -rp "是否使用此NodeID Y/n" use_old_id
            if [[ "$use_old_id" =~ ^[Nn]$ ]]; then
                read -rp "请输入新的NodeID" NODE_ID_TO_USE
                jq --arg id "$NODE_ID_TO_USE" '.node_id = $id' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
                log "已更新NodeID$NODE_ID_TO_USE"
            else
                NODE_ID_TO_USE="$CURRENT_NODE_ID"
            fi
        else
            log "未检测到有效NodeID请输入新的NodeID"
            read -rp "请输入新的NodeID" NODE_ID_TO_USE
            mkdir -p "$HOME/.nexus"
            echo "{\"node_id\":\"${NODE_ID_TO_USE}\"}" > "$CONFIG_PATH"
            log "已写入NodeID$NODE_ID_TO_USE到$CONFIG_PATH"
        fi
    else
        log "未找到配置文件$CONFIG_PATH请输入NodeID"
        read -rp "请输入新的NodeID" NODE_ID_TO_USE
        mkdir -p "$HOME/.nexus"
        echo "{\"node_id\":\"${NODE_ID_TO_USE}\"}" > "$CONFIG_PATH"
        log "已写入NodeID$NODE_ID_TO_USE到$CONFIG_PATH"
    fi
}

start_node() {
    log "正在启动Nexus节点NodeID$NODE_ID_TO_USE"
    screen -dmS nexus_node bash -c "nexus-network start --node-id '${NODE_ID_TO_USE}' > ~/nexus.log 2>&1"
    sleep 2
    if screen -list | grep -q "nexus_node"; then
        log "Nexus节点已在screen会话nexus_node中启动日志输出到~/nexus.log"
    else
        log "启动screen会话失败请检查日志~/nexus.log"
        cat ~/nexus.log
        exit 1
    fi
}

main() {
    get_node_id
    while true; do
        install_nexus_cli
        cleanup_restart
        start_node
        log "节点将每隔4小时自动重启"
        sleep 14400
        cleanup_restart
    done
}

main
