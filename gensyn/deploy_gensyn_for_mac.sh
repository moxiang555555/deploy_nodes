<<<<<<< HEAD
 #!/bin/bash
=======
#!/bin/bash
>>>>>>> 198896042f925d3cef8fb6e4fe7da0cd7e2a134d

set -euo pipefail

log_file="./deploy_rl_swarm_0.5.3.log"

info() {
    echo "[INFO] $*" | tee -a "$log_file"
}

error() {
    echo "[ERROR] $*" >&2 | tee -a "$log_file"
    exit 1
}

echo "[1/15] 检查 Homebrew..." | tee -a "$log_file"
if ! command -v brew &> /dev/null; then
    info "Homebrew 未安装，正在安装..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || error "Homebrew 安装失败"
    
    if [[ $(uname -m) == "arm64" ]]; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
        eval "$(/opt/homebrew/bin/brew shellenv)"
    else
        echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.zshrc
        eval "$(/usr/local/bin/brew shellenv)"
    fi
else
    info "Homebrew 已安装，版本：$(brew --version | head -n 1)"
fi

echo "[2/15] 检查 Docker..." | tee -a "$log_file"
if ! command -v docker &> /dev/null; then
    info "Docker 未安装，正在通过 Homebrew 安装 Docker Desktop..."
    brew install --cask docker || error "Docker Desktop 安装失败，请手动从 https://www.docker.com/products/docker-desktop/ 安装"
    open -a "Docker"
    info "请等待 Docker Desktop 启动完成后再继续..."
    read -p "按 Enter 键继续（确保 Docker Desktop 已运行）..."
else
    info "Docker 已安装，版本：$(docker --version)"
fi

echo "[3/15] 检查 Docker Compose..." | tee -a "$log_file"
if ! command -v docker-compose &> /dev/null; then
    info "安装 Docker Compose..."
    brew install docker-compose || error "Docker Compose 安装失败"
else
    info "Docker Compose 已安装，版本：$(docker-compose --version)"
fi

echo "[4/15] 检查 rl-swarm-0.5.3 仓库..." | tee -a "$log_file"
if [ ! -d "$HOME/rl-swarm-0.5.3" ]; then
    info "正在克隆 Gensyn RL Swarm 0.5.3 仓库..."
    git clone https://github.com/readyName/rl-swarm-0.5.3.git "$HOME/rl-swarm-0.5.3" || error "克隆失败"
else
    info "目录已存在：$HOME/rl-swarm-0.5.3"
    read -rp "是否覆盖现有 rl-swarm-0.5.3 目录？（y/N）： " overwrite
    if [[ "$overwrite" =~ ^[Yy]$ ]]; then
        info "删除旧目录..."
        rm -rf "$HOME/rl-swarm-0.5.3" || error "删除失败"
        git clone https://github.com/readyName/rl-swarm-0.5.3.git "$HOME/rl-swarm-0.5.3" || error "克隆失败"
    else
        info "保留旧目录，跳过克隆"
    fi
fi

echo "[5/15] 检查 rl-swarm-0.5 目录..." | tee -a "$log_file"
if [ ! -d "$HOME/rl-swarm-0.5" ]; then
    info "缺少目录：$HOME/rl-swarm-0.5"
    info "请手动将以下文件放入 $HOME/rl-swarm-0.5.3/user/ 目录："
    info "- $HOME/rl-swarm-0.5.3/user/keys/swarm.pem"
    info "- $HOME/rl-swarm-0.5.3/user/modal-login/userApiKey.json"
    info "- $HOME/rl-swarm-0.5.3/user/modal-login/userData.json"
    mkdir -p "$HOME/rl-swarm-0.5.3/user/keys" "$HOME/rl-swarm-0.5.3/user/modal-login"
<<<<<<< HEAD
    read -p "按 Enter 键继续（确保文件已放入 $HOME/rl-swarm-0.5.3/user/）..."
=======
>>>>>>> 198896042f925d3cef8fb6e4fe7da0cd7e2a134d
fi

cd "$HOME/rl-swarm-0.5.3" || error "进入目录失败"

echo "[6/15] 运行 swarm-cpu 容器（后台模式）..." | tee -a "$log_file"

MAX_RETRIES=100
ATTEMPT=1

while [ $ATTEMPT -le $MAX_RETRIES ]; do
    info "尝试启动容器（第 $ATTEMPT 次）..."

    PORT_PID=$(lsof -i :3000 -t || true)
    if [ -n "$PORT_PID" ]; then
        info "释放被占用的端口 3000（PID: $PORT_PID）..."
        kill -9 "$PORT_PID" || true
    fi

    # 清理旧容器和服务
    info "清理旧的 swarm-cpu 容器和服务..."
    docker-compose rm -f swarm-cpu || true
    # 清理旧镜像（强制重建）
    if docker images -q swarm-cpu | grep -q .; then
        info "删除旧的 swarm-cpu 镜像..."
        docker rmi -f $(docker images -q swarm-cpu) || true
    fi

    # 启动容器（后台模式，强制重建）
    if docker-compose up -d --build --force-recreate swarm-cpu; then
        info "容器启动成功（后台运行）"

        echo "[7/15] 等待 user 文件夹生成..." | tee -a "$log_file"
        TARGET_DIR="$HOME/rl-swarm-0.5.3/user"
        until [ -d "$TARGET_DIR" ]; do
            sleep 3
            info "等待中..."
        done
        info "检测到目录：$TARGET_DIR"

<<<<<<< HEAD
        echo "[8/15] 复制 user 文件到临时目录..." | tee -a "$log_file"
        # 检查并复制 swarm.pem
        if [ -f "$HOME/rl-swarm-0.5/user/keys/swarm.pem" ]; then
            mkdir -p "$HOME/tmp"
            cp "$HOME/rl-swarm-0.5/user/keys/swarm.pem" "$HOME/tmp" && info "复制 swarm.pem 到 tmp 成功" || info "警告：复制 swarm.pem 到 tmp 失败"
        else
            info "警告：缺少文件：$HOME/rl-swarm-0.5/user/keys/swarm.pem"
            info "请手动将 swarm.pem 放入 $HOME/rl-swarm-0.5.3/user/keys/"
        fi
        # 检查并复制 JSON 文件
        if ls "$HOME/rl-swarm-0.5/user/modal-login/"*.json >/dev/null 2>&1; then
            mkdir -p "$HOME/tmp"
            cp "$HOME/rl-swarm-0.5/user/modal-login/"*.json "$HOME/tmp" && info "复制 JSON 文件到 tmp 成功" || info "警告：复制 JSON 文件到 tmp 失败"
        else
            info "警告：缺少 JSON 文件：$HOME/rl-swarm-0.5/user/modal-login/*.json"
            info "请手动将 userApiKey.json 和 userData.json 放入 $HOME/rl-swarm-0.5.3/user/modal-login/"
        fi
        # 提示用户放置文件并按回车继续
        if [ ! -f "$HOME/rl-swarm-0.5/user/keys/swarm.pem" ] || ! ls "$HOME/rl-swarm-0.5/user/modal-login/"*.json >/dev/null 2>&1; then
            info "请手动将以下文件放入 $HOME/rl-swarm-0.5.3/user/ 目录："
            info "- $HOME/rl-swarm-0.5.3/user/keys/swarm.pem"
            info "- $HOME/rl-swarm-0.5.3/user/modal-login/userApiKey.json"
            info "- $HOME/rl-swarm-0.5.3/user/modal-login/userData.json"
            mkdir -p "$HOME/rl-swarm-0.5.3/user/keys" "$HOME/rl-swarm-0.5.3/user/modal-login"
            read -p "按 Enter 键继续（确保文件已放入 $HOME/rl-swarm-0.5.3/user/）..."
        fi
        # 复制到目标目录
        mkdir -p "$HOME/rl-swarm-0.5.3/user/keys" "$HOME/rl-swarm-0.5.3/user/modal-login"
        if [ -f "$HOME/tmp/swarm.pem" ]; then
            cp "$HOME/tmp/swarm.pem" "$HOME/rl-swarm-0.5.3/user/keys" && info "复制 swarm.pem 到目标目录成功" || info "警告：复制 swarm.pem 到目标目录失败"
        fi
        if ls "$HOME/tmp/"*.json >/dev/null 2>&1; then
            cp "$HOME/tmp/"*.json "$HOME/rl-swarm-0.5.3/user/modal-login/" && info "复制 JSON 文件到目标目录成功" || info "警告：复制 JSON 文件到目标目录失败"
        fi

        echo "[9/15] 复制 user 文件..." | tee -a "$log_file"
=======
        echo "[8/15] 检查 user 文件..." | tee -a "$log_file"
        # 检查所需文件
>>>>>>> 198896042f925d3cef8fb6e4fe7da0cd7e2a134d
        FILES=(
            "keys/swarm.pem"
            "modal-login/userApiKey.json"
            "modal-login/userData.json"
        )
<<<<<<< HEAD
        missing_files=false
        for relpath in "${FILES[@]}"; do
            src="$HOME/rl-swarm-0.5/user/$relpath"
            dst="$HOME/rl-swarm-0.5.3/user/$relpath"
            if [ -f "$src" ]; then
                mkdir -p "$(dirname "$dst")"
                cp "$src" "$dst"
                info "复制成功：$relpath"
            else
                info "警告：缺少文件：$src"
                info "请手动将 $relpath 放入 $HOME/rl-swarm-0.5.3/user/$relpath"
                missing_files=true
            fi
        done
        if [ "$missing_files" = true ]; then
            info "请手动将以下文件放入 $HOME/rl-swarm-0.5.3/user/ 目录："
            info "- $HOME/rl-swarm-0.5.3/user/keys/swarm.pem"
            info "- $HOME/rl-swarm-0.5.3/user/modal-login/userApiKey.json"
            info "- $HOME/rl-swarm-0.5.3/user/modal-login/userData.json"
            mkdir -p "$HOME/rl-swarm-0.5.3/user/keys" "$HOME/rl-swarm-0.5.3/user/modal-login"
            read -p "按 Enter 键继续（确保文件已放入 $HOME/rl-swarm-0.5.3/user/）..."
        fi

        echo "[10/15] 跳过权限修改..." | tee -a "$log_file"

        echo "[11/15] 查看 Docker 日志..." | tee -a "$log_file"
        info "正在显示 swarm-cpu 容器实时日志（按 Ctrl+C 停止查看日志，容器将继续运行）..."
        docker-compose logs -f swarm-cpu | tee -a "$log_file"

        echo "[12/15] 启动完成，容器运行中..." | tee -a "$log_file"
        info "容器在后台运行，按 Ctrl+C 停止脚本（容器将继续运行）"
        info "可使用 'docker-compose down' 停止容器"
        break
=======
        all_files_present=true
        for relpath in "${FILES[@]}"; do
            if [ ! -f "$HOME/rl-swarm-0.5/user/$relpath" ]; then
                all_files_present=false
                info "警告：缺少文件：$HOME/rl-swarm-0.5/user/$relpath"
                info "请手动将 $relpath 放入 $HOME/rl-swarm-0.5.3/user/$relpath"
            fi
        done
        if [ "$all_files_present" = false ]; then
            mkdir -p "$HOME/rl-swarm-0.5.3/user/keys" "$HOME/rl-swarm-0.5.3/user/modal-login"
            info "缺少必要文件，将在最后查看 Docker 日志..."
            skip_copy=true
        else
            # 复制文件
            for relpath in "${FILES[@]}"; do
                src="$HOME/rl-swarm-0.5/user/$relpath"
                dst="$HOME/rl-swarm-0.5.3/user/$relpath"
                if [ -f "$src" ]; then
                    mkdir -p "$(dirname "$dst")"
                    cp "$src" "$dst" && info "复制成功：$relpath" || info "警告：复制 $relpath 失败"
                fi
            done
            skip_copy=false
        fi

        echo "[9/15] 跳过权限修改..." | tee -a "$log_file"
        echo "[10/15] 占位..." | tee -a "$log_file"
        echo "[11/15] 占位..." | tee -a "$log_file"
        echo "[12/15] 占位..." | tee -a "$log_file"
        echo "[13/15] 占位..." | tee -a "$log_file"
        echo "[14/15] 占位..." | tee -a "$log_file"

        echo "[15/15] 查看 Docker 日志..." | tee -a "$log_file"
        info "正在显示 swarm-cpu 容器实时日志（按 Ctrl+C 停止查看日志，容器将继续运行）..."
        exec docker-compose logs -f swarm-cpu
>>>>>>> 198896042f925d3cef8fb6e4fe7da0cd7e2a134d
    else
        info "第 $ATTEMPT 次启动失败，3 秒后重试..."
        ((ATTEMPT++))
        sleep 3
    fi
done

if [ $ATTEMPT -gt $MAX_RETRIES ]; then
    error "连续失败 $MAX_RETRIES 次，终止。请检查 Docker 配置或网络"
fi
<<<<<<< HEAD

echo "[DONE] RL Swarm 容器部署完成" | tee -a "$log_file"
=======
>>>>>>> 198896042f925d3cef8fb6e4fe7da0cd7e2a134d
