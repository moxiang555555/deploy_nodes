# 清理函数：终止 screen 会话和所有 nexus-network 相关进程
cleanup() {
    echo -e "[$(get_timestamp)] ${YELLOW}收到退出信号或准备重启，正在清理进程和 screen 会话...${NC}"

    # 终止所有 nexus_node 的 screen 会话
    if screen -list | grep -q "nexus_node"; then
        echo -e "[$(get_timestamp)] ${BLUE}正在终止所有 nexus_node screen 会话...${NC}"
        screen -ls | grep "nexus_node" | awk '{print $1}' | while read -r session; do
            echo -e "[$(get_timestamp)] ${BLUE}终止 screen 会话: $session${NC}"
            screen -S "$session" -X quit 2>/dev/null || {
                echo -e "[$(get_timestamp)] ${RED}无法终止 screen 会话 $session，请检查权限或会话状态。${NC}"
            }
        done
    else
        echo -e "[$(get_timestamp)] ${GREEN}未找到 nexus_node screen 会话，无需清理。${NC}"
    fi

    # 终止所有与 nexus-network 相关的进程
    echo -e "[$(get_timestamp)] ${BLUE}正在查找并终止所有 nexus-network 相关进程...${NC}"
    PIDS=$(pgrep -f "nexus-network start --node-id" | tr '\n' ' ' | xargs echo -n)
    if [[ -n "$PIDS" ]]; then
        for pid in $PIDS; do
            if ps -p "$pid" > /dev/null 2>&1; then
                echo -e "[$(get_timestamp)] ${BLUE}正在终止 Nexus 节点进程 (PID: $pid)...${NC}"
                kill -9 "$pid" 2>/dev/null || {
                    echo -e "[$(get_timestamp)] ${RED}无法终止 PID $pid 的进程，请检查进程状态。${NC}"
                }
            else
                echo -e "[$(get_timestamp)] ${YELLOW}PID $pid 已不存在，跳过。${NC}"
            }
        done
    else
        echo -e "[$(get_timestamp)] ${GREEN}未找到 nexus-network 进程。${NC}"
    fi

    # 终止所有相关的 bash 进程
    echo -e "[$(get_timestamp)] ${BLUE}正在查找并终止所有相关 bash 进程...${NC}"
    BASH_PIDS=$(pgrep -f "bash -c while true.*nexus-network start --node-id" | tr '\n' ' ' | xargs echo -n)
    if [[ -n "$BASH_PIDS" ]]; then
        for pid in $BASH_PIDS; do
            if ps -p "$pid" > /dev/null 2>&1; then
                echo -e "[$(get_timestamp)] ${BLUE}正在终止 bash 进程 (PID: $pid)...${NC}"
                kill -9 "$pid" 2>/dev/null || {
                    echo -e "[$(get_timestamp)] ${RED}无法终止 PID $pid 的 bash 进程，请检查进程状态。${NC}"
                }
            else
                echo -e "[$(get_timestamp)] ${YELLOW}PID $pid 已不存在，跳过。${NC}"
            }
        done
    else
        echo -e "[$(get_timestamp)] ${GREEN}未找到相关 bash 进程。${NC}"
    fi

    echo -e "[$(get_timestamp)] ${GREEN}清理完成，继续运行节点...${NC}"
    # 移除 exit 0，允许继续执行
}

# 运行节点
run_node() {
    print_header "运行节点"

    # 安装依赖
    if [[ "$OS_TYPE" != "Ubuntu" ]]; then
        install_homebrew
    else
        echo -e "[$(get_timestamp)] ${GREEN}在 Ubuntu 上跳过 Homebrew 安装，使用 apt。${NC}"
    fi
    install_cmake
    install_protobuf
    install_rust
    configure_rust_target
    check_nexus_version # 检查 Nexus CLI 版本，但不立即安装

    # 检查并获取 Node ID
    CONFIG_PATH="$HOME/.nexus/config.json"
    if [[ -f "$CONFIG_PATH" ]]; then
        CURRENT_NODE_ID=$(jq -r .node_id "$CONFIG_PATH" 2>/dev/null)
        if [[ -n "$CURRENT_NODE_ID" && "$CURRENT_NODE_ID" != "null" ]]; then
            echo -e "[$(get_timestamp)] ${BLUE}当前配置的 Node ID：${GREEN}$CURRENT_NODE_ID${NC}"
            echo -n "[$(get_timestamp)] 是否使用当前 Node ID？(Y/n): "
            read -r use_current
            if [[ "$use_current" =~ ^[Nn]$ ]]; then
                echo -n "[$(get_timestamp)] 请输入新的 Node ID: "
                read -r NEW_NODE_ID
                echo -e "{\n  \"node_id\": \"${NEW_NODE_ID}\"\n}" > "$CONFIG_PATH"
                echo -e "[$(get_timestamp)] ${GREEN}已更新配置文件：$CONFIG_PATH${NC}"
                NODE_ID_TO_USE="${NEW_NODE_ID}"
            else
                echo -e "[$(get_timestamp)] ${GREEN}继续使用已配置的 Node ID。${NC}"
                NODE_ID_TO_USE="${CURRENT_NODE_ID}"
            fi
        else
            echo -e "[$(get_timestamp)] ${YELLOW}配置文件存在但 Node ID 无效，将创建新配置。${NC}"
            echo -n "[$(get_timestamp)] 请输入 Node ID: "
            read -r NEW_NODE_ID
            mkdir -p "$HOME/.nexus"
            echo -e "{\n  \"node_id\": \"${NEW_NODE_ID}\"\n}" > "$CONFIG_PATH"
            echo -e "[$(get_timestamp)] ${GREEN}已创建配置文件：$CONFIG_PATH${NC}"
            NODE_ID_TO_USE="${NEW_NODE_ID}"
        fi
    else
        echo -e "[$(get_timestamp)] ${YELLOW}未找到 Node ID 配置，将创建新配置文件。${NC}"
        echo -n "[$(get_timestamp)] 请输入 Node ID: "
        read -r NEW_NODE_ID
        mkdir -p "$HOME/.nexus"
        echo -e "{\n  \"node_id\": \"${NEW_NODE_ID}\"\n}" > "$CONFIG_PATH"
        echo -e "[$(get_timestamp)] ${GREEN}已创建配置文件：$CONFIG_PATH${NC}"
        NODE_ID_TO_USE="${NEW_NODE_ID}"
    fi

    # 检查 screen 是否安装
    if ! command -v screen &> /dev/null; then
        echo -e "[$(get_timestamp)] ${RED}未找到 screen 命令，正在安装...${NC}"
        if [[ "$OS_TYPE" == "Ubuntu" ]]; then
            sudo apt-get update && sudo apt-get install -y screen || {
                echo -e "[$(get_timestamp)] ${RED}安装 screen 失败，请检查网络连接或权限。${NC}"
                exit 1
            }
        elif [[ "$OS_TYPE" == "macOS" ]]; then
            brew install screen || {
                echo -e "[$(get_timestamp)] ${RED}安装 screen 失败，请检查 Homebrew 安装。${NC}"
                exit 1
            }
        else
            echo -e "[$(get_timestamp)] ${RED}不支持的操作系统，请手动安装 screen。${NC}"
            exit 1
        fi
    fi

    # 定义启动节点的函数
    start_node() {
        # 在启动前清理旧进程
        echo -e "[$(get_timestamp)] ${BLUE}清理旧的 nexus-network 和 bash 进程...${NC}"
        PIDS=$(pgrep -f "nexus-network start --node-id" | tr '\n' ' ' | xargs echo -n)
        if [[ -n "$PIDS" ]]; then
            for pid in $PIDS; do
                if ps -p "$pid" > /dev/null 2>&1; then
                    echo -e "[$(get_timestamp)] ${BLUE}终止旧 Nexus 节点进程 (PID: $pid)...${NC}"
                    kill -9 "$pid" 2>/dev/null || {
                        echo -e "[$(get_timestamp)] ${RED}无法终止 PID $pid 的进程，请检查进程状态。${NC}"
                    }
                else
                    echo -e "[$(get_timestamp)] ${YELLOW}PID $pid 已不存在，跳过。${NC}"
                }
            done
        fi
        BASH_PIDS=$(pgrep -f "bash -c while true.*nexus-network start --node-id" | tr '\n' ' ' | xargs echo -n)
        if [[ -n "$BASH_PIDS" ]]; then
            for pid in $BASH_PIDS; do
                if ps -p "$pid" > /dev/null 2>&1; then
                    echo -e "[$(get_timestamp)] ${BLUE}终止旧 bash 进程 (PID: $pid)...${NC}"
                    kill -9 "$pid" 2>/dev/null || {
                        echo -e "[$(get_timestamp)] ${RED}无法终止 PID $pid 的 bash 进程，请检查进程状态。${NC}"
                    }
                else
                    echo -e "[$(get_timestamp)] ${YELLOW}PID $pid 已不存在，跳过。${NC}"
                fi
            done
        fi

        # 清理旧的 screen 会话
        if screen -list | grep -q "nexus_node"; then
            echo -e "[$(get_timestamp)] ${BLUE}终止旧的 nexus_node screen 会话...${NC}"
            screen -ls | grep "nexus_node" | awk '{print $1}' | while read -r session; do
                echo -e "[$(get_timestamp)] ${BLUE}终止 screen 会话: $session${NC}"
                screen -S "$session" -X quit 2>/dev/null
            done
        fi

        # 在启动节点前尝试安装/更新 Nexus CLI
        install_nexus_cli

        echo -e "[$(get_timestamp)] ${BLUE}正在启动 Nexus 节点在 screen 会话中...${NC}"
        NEXUS_VERSION=$(nexus-network --version 2>/dev/null || echo "未知版本")
        screen -dmS nexus_node bash -c 'while true; do echo "[$(date "+%Y-%m-%d %H:%M:%S")] Nexus CLI 版本: '"$NEXUS_VERSION"' - 日志:" >> ~/nexus.log; nexus-network start --node-id '"${NODE_ID_TO_USE}"' >> ~/nexus.log 2>&1; echo "[$(date "+%Y-%m-%d %H:%M:%S")] Nexus 节点异常退出，将在5秒后重试..." >> ~/nexus.log; sleep 5; done'
        sleep 2
        if screen -list | grep -q "nexus_node"; then
            echo -e "[$(get_timestamp)] ${GREEN}Nexus 节点已在 screen 会话（nexus_node）中启动，日志输出到 ~/nexus.log${NC}"
            NODE_PID=$(pgrep -f "nexus-network start --node-id ${NODE_ID_TO_USE}" | head -n 1)
            if [[ -n "$NODE_PID" ]]; then
                echo -e "[$(get_timestamp)] ${GREEN}Nexus 节点进程 PID: $NODE_PID${NC}"
            else
                echo -e "[$(get_timestamp)] ${RED}无法获取 Nexus 节点 PID，请检查日志：~/nexus.log${NC}"
                cat ~/nexus.log
                return 1
            fi
        else
            echo -e "[$(get_timestamp)] ${RED}启动 screen 会话失败，请检查日志：~/nexus.log${NC}"
            cat ~/nexus.log
            return 1
        fi
        return 0
    }

    # 主循环，持续运行节点
    while true; do
        start_node
        if [[ $? -ne 0 ]]; then
            echo -e "[$(get_timestamp)] ${RED}节点启动失败，将在30秒后重试...${NC}"
            sleep 30
            continue
        fi
        echo -e "[$(get_timestamp)] ${BLUE}节点将每隔4小时自动重启...${NC}"
        sleep 14400
        echo -e "[$(get_timestamp)] ${BLUE}准备重启节点...${NC}"
        cleanup
    done
}
