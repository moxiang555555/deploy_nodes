#!/bin/bash

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
    git clone https://github.com/readyName/rl-swarm-0.5.6.git "$HOME/rl-swarm-0.5.6" || error "克隆失败"
else
    info "目录已存在：$HOME/rl-swarm-0.5.3"
    read -rp "是否覆盖现有 rl-swarm-0.5.3 目录？（y/N）： " overwrite
    if [[ "$overwrite" =~ ^[Yy]$ ]]; then
        info "删除旧目录..."
        rm -rf "$HOME/rl-swarm-0.5.3" || error "删除失败"
        git clone https://github.com/readyName/rl-swarm-0.5.6.git "$HOME/rl-swarm-0.5.6" || error "克隆失败"
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
    #mkdir -p "$HOME/rl-swarm-0.5.3/user/keys" "$HOME/rl-swarm-0.5.3/user/modal-login"
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

    # 新增：先 down 一下
    info "停止并清理所有旧的 Docker Compose 服务..."
    docker-compose down || info "docker-compose down 执行失败，继续..."

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

        echo "[7/9] 等待 user 文件夹生成..." | tee -a "$log_file"
        TARGET_DIR="$HOME/rl-swarm-0.5.3/user"
        until [ -d "$TARGET_DIR" ]; do
            sleep 3
            info "等待中..."
        done
        info "检测到目录：$TARGET_DIR"

        echo "[8/15] 检查 user 文件..." | tee -a "$log_file"
        # 检查所需文件
        FILES=(
            "keys/swarm.pem"
            "modal-login/userApiKey.json"
            "modal-login/userData.json"
        )
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

        echo "[9/9] 查看 Docker 日志..." | tee -a "$log_file"
        info "正在显示 swarm-cpu 容器实时日志（按 Ctrl+C 停止查看日志，容器将继续运行）..."
        exec docker-compose logs -f swarm-cpu
    else
        info "第 $ATTEMPT 次启动失败，3 秒后重试..."
        ((ATTEMPT++))
        sleep 3
    fi
done

if [ $ATTEMPT -gt $MAX_RETRIES ]; then
    error "连续失败 $MAX_RETRIES 次，终止。请检查 Docker 配置或网络"
fi
