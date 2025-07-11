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
    error "缺少目录：$HOME/rl-swarm-0.5，请先创建并包含 user/ 所需文件"
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

        while true; do
            if [ -d "$HOME/rl-swarm-0.5.3/user" ]; then
                mkdir -p "$HOME/tmp"
                cp "$HOME/rl-swarm-0.5/user/keys/swarm.pem" "$HOME/rl-swarm-0.5/user/modal-login/"*.json "$HOME/tmp" || error "复制文件到 tmp 失败"
                cp "$HOME/tmp/swarm.pem" "$HOME/rl-swarm-0.5.3/user/keys" || error "复制 swarm.pem 失败"
                cp "$HOME/tmp/"*.json "$HOME/rl-swarm-0.5.3/user/modal-login/" || error "复制 JSON 文件失败"
                break
            else
                info "等待 user 文件夹生成..."
                sleep 5
            fi
        done

        echo "[8/15] 复制 user 文件..." | tee -a "$log_file"
        FILES=(
            "keys/swarm.pem"
            "modal-login/userApiKey.json"
            "modal-login/userData.json"
        )

        for relpath in "${FILES[@]}"; do
            src="$HOME/rl-swarm-0.5/user/$relpath"
            dst="$HOME/rl-swarm-0.5.3/user/$relpath"
            if [ -f "$src" ]; then
                mkdir -p "$(dirname "$dst")"
                cp "$src" "$dst"
                info "复制成功：$relpath"
            else
                info "警告：缺少文件：$src"
            fi
        done

        echo "[9/15] 跳过权限修改..." | tee -a "$log_file"

        echo "[10/15] 查看 Docker 日志..." | tee -a "$log_file"
        info "正在显示 swarm-cpu 容器实时日志（按 Ctrl+C 停止查看日志，容器将继续运行）..."
        docker-compose logs -f swarm-cpu | tee -a "$log_file"

        echo "[11/15] 启动完成，容器运行中..." | tee -a "$log_file"
        info "容器在后台运行，按 Ctrl+C 停止脚本（容器将继续运行）"
        info "可使用 'docker-compose down' 停止容器"
        break
    else
        info "第 $ATTEMPT 次启动失败，3 秒后重试..."
        ((ATTEMPT++))
        sleep 3
    fi
done

if [ $ATTEMPT -gt $MAX_RETRIES ]; then
    error "连续失败 $MAX_RETRIES 次，终止。请检查 Docker 配置或网络"
fi

echo "[DONE] RL Swarm 容器部署完成" | tee -a "$log_file"
