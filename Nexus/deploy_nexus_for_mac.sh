#!/bin/bash

# 颜色设置
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # 无颜色

# 检测操作系统
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
    *)      echo -e "${RED}不支持的操作系统: $OS。本脚本仅支持 macOS、Ubuntu 和其他 Linux 发行版。${NC}" ; exit 1 ;;
esac

# 检测 shell 并设置配置文件
if [[ -n "$ZSH_VERSION" ]]; then
    SHELL_TYPE="zsh"
    CONFIG_FILE="$HOME/.zshrc"
elif [[ -n "$BASH_VERSION" ]]; then
    SHELL_TYPE="bash"
    CONFIG_FILE="$HOME/.bashrc"
else
    echo -e "${RED}不支持的 shell。本脚本仅支持 bash 和 zsh。${NC}"
    exit 1
fi

# 打印标题
print_header() {
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}=====================================${NC}"
}

# 检查命令是否存在
check_command() {
    if command -v "$1" &> /dev/null; then
        echo -e "${GREEN}$1 已安装，跳过安装步骤。${NC}"
        return 0
    else
        echo -e "${RED}$1 未安装，开始安装...${NC}"
        return 1
    fi
}

# 配置 shell 环境变量
configure_shell() {
    local env_path="$1"
    local env_var="export PATH=$env_path:\$PATH"
    if [[ -f "$CONFIG_FILE" ]] && grep -q "$env_path" "$CONFIG_FILE"; then
        echo -e "${GREEN}环境变量已在 $CONFIG_FILE 中配置。${NC}"
    else
        echo -e "${BLUE}正在将环境变量添加到 $CONFIG_FILE...${NC}"
        echo "$env_var" >> "$CONFIG_FILE"
        echo -e "${GREEN}环境变量已添加到 $CONFIG_FILE。${NC}"
        # 应用当前会话的更改
        source "$CONFIG_FILE" 2>/dev/null || echo -e "${RED}无法加载 $CONFIG_FILE，请手动运行 'source $CONFIG_FILE'。${NC}"
    fi
}

# 安装 Homebrew（macOS 和非 Ubuntu Linux）
install_homebrew() {
    print_header "检查 Homebrew 安装"
    if check_command brew; then
        return
    fi
    echo -e "${BLUE}在 $OS_TYPE 上安装 Homebrew...${NC}"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
        echo -e "${RED}安装 Homebrew 失败，请检查网络连接或权限。${NC}"
        exit 1
    }
    if [[ "$OS_TYPE" == "macOS" ]]; then
        configure_shell "/opt/homebrew/bin"
    else
        configure_shell "$HOME/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/bin"
        # Linux 上安装 gcc（Homebrew 依赖）
        if ! check_command gcc; then
            echo -e "${BLUE}在 Linux 上安装 gcc（Homebrew 依赖）...${NC}"
            if command -v yum &> /dev/null; then
                sudo yum groupinstall 'Development Tools' || {
                    echo -e "${RED}安装 gcc 失败，请手动安装 Development Tools。${NC}"
                    exit 1
                }
            else
                echo -e "${RED}不支持的包管理器，请手动安装 gcc。${NC}"
                exit 1
            fi
        fi
    fi
}

# 安装 CMake
install_cmake() {
    print_header "检查 CMake 安装"
    if check_command cmake; then
        return
    fi
    echo -e "${BLUE}正在安装 CMake...${NC}"
    if [[ "$OS_TYPE" == "Ubuntu" ]]; then
        sudo apt-get update && sudo apt-get install -y cmake || {
            echo -e "${RED}安装 CMake 失败，请检查网络连接或权限。${NC}"
            exit 1
        }
    else
        brew install cmake || {
            echo -e "${RED}安装 CMake 失败，请检查 Homebrew 安装。${NC}"
            exit 1
        }
    fi
}

# 安装 Protobuf
install_protobuf() {
    print_header "检查 Protobuf 安装"
    if check_command protoc; then
        return
    fi
    echo -e "${BLUE}正在安装 Protobuf...${NC}"
    if [[ "$OS_TYPE" == "Ubuntu" ]]; then
        sudo apt-get update && sudo apt-get install -y protobuf-compiler || {
            echo -e "${RED}安装 Protobuf 失败，请检查网络连接或权限。${NC}"
            exit 1
        }
    else
        brew install protobuf || {
            echo -e "${RED}安装 Protobuf 失败，请检查 Homebrew 安装。${NC}"
            exit 1
        }
    fi
}

# 安装 Rust
install_rust() {
    print_header "检查 Rust 安装"
    if check_command rustc; then
        return
    fi
    echo -e "${BLUE}正在安装 Rust...${NC}"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y || {
        echo -e "${RED}安装 Rust 失败，请检查网络连接。${NC}"
        exit 1
    }
    source "$HOME/.cargo/env" 2>/dev/null || echo -e "${RED}无法加载 Rust 环境，请手动运行 'source ~/.cargo/env'。${NC}"
    # 永久添加环境变量
    configure_shell "$HOME/.cargo/bin"
}

# 配置 Rust RISC-V 目标
configure_rust_target() {
    print_header "检查 Rust RISC-V 目标"
    if rustup target list --installed | grep -q "riscv32i-unknown-none-elf"; then
        echo -e "${GREEN}RISC-V 目标 (riscv32i-unknown-none-elf) 已安装，跳过。${NC}"
        return
    fi
    echo -e "${BLUE}为 Rust 添加 RISC-V 目标...${NC}"
    rustup target add riscv32i-unknown-none-elf || {
        echo -e "${RED}添加 RISC-V 目标失败，请检查 Rust 安装。${NC}"
        exit 1
    }
}

# 检查 Nexus CLI 版本
check_nexus_version() {
    print_header "检查 Nexus CLI 版本"
    if command -v nexus-network &> /dev/null; then
        NEXUS_VERSION=$(nexus-network --version 2>/dev/null)
        echo -e "${GREEN}当前 Nexus CLI 版本：${NEXUS_VERSION}${NC}"
    else
        echo -e "${YELLOW}未安装 Nexus CLI，将尝试安装...${NC}"
    fi
}

# 安装或更新 Nexus CLI
install_nexus_cli() {
    print_header "安装或更新 Nexus CLI"
    local attempt=1
    local max_attempts=3
    local success=false

    # 检查当前版本
    check_nexus_version

    while [[ $attempt -le $max_attempts ]]; do
        echo -e "${BLUE}尝试安装/更新 Nexus CLI（第 $attempt/$max_attempts 次）...${NC}"
        if curl https://cli.nexus.xyz/ | sh; then
            echo -e "${GREEN}Nexus CLI 安装/更新成功！${NC}"
            success=true
            # 重新加载 shell 配置
            if [[ -f "$HOME/.zshrc" ]]; then
                source "$HOME/.zshrc"
                echo -e "${GREEN}已自动加载 .zshrc 配置。${NC}"
            elif [[ -f "$HOME/.bashrc" ]]; then
                source "$HOME/.bashrc"
                echo -e "${GREEN}已自动加载 .bashrc 配置。${NC}"
            else
                echo -e "${YELLOW}未找到 shell 配置文件，可能需要手动加载环境变量。${NC}"
            fi
            # 输出新版本
            check_nexus_version
            break
        else
            echo -e "${RED}第 $attempt 次安装/更新 Nexus CLI 失败。${NC}"
            ((attempt++))
            sleep 5
        fi
    done

    if [[ "$success" == false ]]; then
        echo -e "${YELLOW}Nexus CLI 安装/更新失败 $max_attempts 次，将继续运行脚本。${NC}"
    fi

    # 提示用户输入 Node ID
    if command -v nexus-network &> /dev/null; then
        echo -e "${BLUE}请输入您的节点 Node ID：${NC}"
        read -r NODE_ID
        # 写入配置文件
        NEXUS_CONFIG_DIR="$HOME/.nexus"
        CONFIG_PATH="$NEXUS_CONFIG_DIR/config.json"
        mkdir -p "$NEXUS_CONFIG_DIR"
        echo -e "{\n  \"node_id\": \"${NODE_ID}\"\n}" > "$CONFIG_PATH"
        echo -e "${GREEN}节点配置已写入：$CONFIG_PATH${NC}"
        echo -e "${BLUE}以下是当前配置内容：${NC}"
        cat "$CONFIG_PATH" | jq .
    fi
}

# 运行节点
run_node() {
    print_header "运行节点"

    # 检查并安装 Nexus CLI
    install_nexus_cli

    # 检查版本
    check_nexus_version

    # 自动加载环境变量
    if [[ -f "$HOME/.zshrc" ]]; then
        source "$HOME/.zshrc"
        echo -e "${GREEN}已加载 .zshrc 环境变量。${NC}"
    elif [[ -f "$HOME/.bashrc" ]]; then
        source "$HOME/.bashrc"
        echo -e "${GREEN}已加载 .bashrc 环境变量。${NC}"
    elif [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        echo -e "${GREEN}已加载自定义配置文件：$CONFIG_FILE${NC}"
    else
        echo -e "${YELLOW}未找到任何 shell 配置文件，可能导致环境变量缺失。${NC}"
    fi

    # 检查 Node ID 配置
    CONFIG_PATH="$HOME/.nexus/config.json"
    if [[ -f "$CONFIG_PATH" ]]; then
        CURRENT_NODE_ID=$(jq -r .node_id "$CONFIG_PATH" 2>/dev/null)
        echo -e "${BLUE}当前配置的 Node ID：${GREEN}$CURRENT_NODE_ID${NC}"
        echo -n "是否使用当前 Node ID？(Y/n): "
        read -r use_current
        if [[ "$use_current" =~ ^[Nn]$ ]]; then
            echo -n "请输入新的 Node ID: "
            read -r NEW_NODE_ID
            echo -e "{\n  \"node_id\": \"${NEW_NODE_ID}\"\n}" > "$CONFIG_PATH"
            echo -e "${GREEN}已更新配置文件：$CONFIG_PATH${NC}"
            NODE_ID_TO_USE="${NEW_NODE_ID}"
        else
            echo -e "${GREEN}继续使用已配置的 Node ID。${NC}"
            NODE_ID_TO_USE="${CURRENT_NODE_ID}"
        fi
    else
        echo -e "${YELLOW}未找到 Node ID 配置，将创建新配置文件。${NC}"
        echo -n "请输入 Node ID: "
        read -r NEW_NODE_ID
        mkdir -p "$HOME/.nexus"
        echo -e "{\n  \"node_id\": \"${NEW_NODE_ID}\"\n}" > "$CONFIG_PATH"
        echo -e "${GREEN}已创建配置文件：$CONFIG_PATH${NC}"
        NODE_ID_TO_USE="${NEW_NODE_ID}"
    fi

    # 检查 screen 是否安装
    if ! command -v screen &> /dev/null; then
        echo -e "${RED}未找到 screen 命令，正在安装...${NC}"
        if [[ "$OS_TYPE" == "Ubuntu" ]]; then
            sudo apt-get update && sudo apt-get install -y screen || {
                echo -e "${RED}安装 screen 失败，请检查网络连接或权限。${NC}"
                exit 1
            }
        elif [[ "$OS_TYPE" == "macOS" ]]; then
            brew install screen || {
                echo -e "${RED}安装 screen 失败，请检查 Homebrew 安装。${NC}"
                exit 1
            }
        else
            echo -e "${RED}不支持的操作系统，请手动安装 screen。${NC}"
            exit 1
        fi
    fi

    # 定义启动节点的函数
    start_node() {
        echo -e "${BLUE}正在启动 Nexus 节点在 screen 会话中...${NC}"
        # 获取当前 Nexus CLI 版本
        NEXUS_VERSION=$(nexus-network --version 2>/dev/null || echo "未知版本")
        # 创建一个新的 screen 会话并运行节点，日志带版本和时间戳
        screen -dmS nexus_node bash -c 'while true; do echo "[$(date "+%Y-%m-%d %H:%M:%S")] Nexus CLI 版本: '"$NEXUS_VERSION"' - 日志:" >> ~/nexus.log; nexus-network start --node-id '"${NODE_ID_TO_USE}"' >> ~/nexus.log 2>&1; sleep 5; done'
        sleep 2  # 等待 screen 会话启动
        # 检查 screen 会话是否正在运行
        if screen -list | grep -q "nexus_node"; then
            echo -e "${GREEN}Nexus 节点已在 screen 会话（nexus_node）中启动，日志输出到 ~/nexus.log${NC}"
            # 获取 screen 会话中运行的 nexus-network 进程 PID
            NODE_PID=$(pgrep -f "nexus-network start --node-id ${NODE_ID_TO_USE}")
            if [[ -n "$NODE_PID" ]]; then
                echo -e "${GREEN}Nexus 节点进程 PID: $NODE_PID${NC}"
            else
                echo -e "${RED}无法获取 Nexus 节点 PID，请检查日志：~/nexus.log${NC}"
                cat ~/nexus.log
                exit 1
            fi
        else
            echo -e "${RED}启动 screen 会话失败，请检查日志：~/nexus.log${NC}"
            cat ~/nexus.log
            exit 1
        fi
    }

    # 启动节点
    start_node

    # 循环检测并4小时重启节点
    echo -e "${BLUE}节点将每隔4小时自动重启...${NC}"
    while true; do
        sleep 14400
        if screen -list | grep -q "nexus_node"; then
            echo -e "${BLUE}检测到节点正在运行 (screen 会话：nexus_node, PID: $NODE_PID)，正在重启...${NC}"
            # 终止当前 screen 会话
            screen -S nexus_node -X quit 2>/dev/null || {
                echo -e "${RED}无法终止 screen 会话，请检查权限或会话状态。${NC}"
            }
            # 确保进程已终止
            if [[ -n "$NODE_PID" ]] && ps -p $NODE_PID > /dev/null; then
                kill $NODE_PID 2>/dev/null
                wait $NODE_PID 2>/dev/null
            fi
        else
            echo -e "${YELLOW}节点 screen 会话 (nexus_node) 已不存在，将重新启动...${NC}"
        fi
        # 重新启动节点
        start_node
    done
}

# 主菜单
main_menu() {
    clear
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${BLUE} Nexus 节点部署脚本 ($OS_TYPE, $SHELL_TYPE)${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${GREEN}请选择一个选项：${NC}"
    echo "1) 首次安装（安装所有依赖）"
    echo "2) 直接运行节点（跳过依赖安装，尝试更新 Nexus CLI）"
    echo "3) 手动更新 Nexus CLI"
    echo "4) 退出"
    echo -n "请输入您的选择 [1-4]: "
    read choice
    case $choice in
    1)
        print_header "开始首次安装"
        if [[ "$OS_TYPE" != "Ubuntu" ]]; then
            install_homebrew
        else
            echo -e "${GREEN}在 Ubuntu 上跳过 Homebrew 安装，使用 apt。${NC}"
        fi
        install_cmake
        install_protobuf
        install_rust
        configure_rust_target
        install_nexus_cli
        echo -e "${GREEN}安装成功完成！${NC}"
        echo -e "${BLUE}您现在可以通过选择选项 2 运行节点。${NC}"
        ;;
    2)
        run_node
        ;;
    3)
        print_header "手动更新 Nexus CLI"
        install_nexus_cli
        echo -e "${GREEN}Nexus CLI 更新完成！${NC}"
        echo -e "${BLUE}您可以选择选项 2 运行节点。${NC}"
        ;;
    4)
        echo -e "${BLUE}正在退出...${NC}"
        exit 0
        ;;
    *)
        echo -e "${RED}无效选择，请输入 1、2、3 或 4。${NC}"
        sleep 2
        main_menu
        ;;
    esac
}

# 启动脚本
main_menu
