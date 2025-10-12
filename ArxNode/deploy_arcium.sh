#!/bin/bash

# Arcium 节点部署脚本
# 专注运行 Arx 验证节点

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 日志函数
log() { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warning() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }
info() { echo -e "${CYAN}ℹ${NC} $1"; }

# 检查命令是否存在
check_cmd() {
    if command -v "$1" > /dev/null 2>&1; then
        success "找到 $1"
        return 0
    else
        warning "未找到 $1"
        return 1
    fi
}

# 安装依赖
install_dependencies() {
    log "安装系统依赖..."
    
    # 检测系统类型
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux - 安装基础包
        sudo apt update && sudo apt upgrade -y
        sudo apt install curl iptables build-essential git wget lz4 jq make gcc nano automake autoconf tmux htop nvme-cli pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip libleveldb-dev libudev-dev protobuf-compiler bc -y
        
        # 安装 Node.js 22.x
        log "安装 Node.js 22.x..."
        curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -
        sudo apt install -y nodejs
        
        # 验证 Node.js 安装
        if command -v node > /dev/null 2>&1; then
            success "Node.js 安装完成: $(node -v)"
        else
            error "Node.js 安装失败"
            return 1
        fi
        
        # 安装 Yarn (使用官方安装器，避免权限问题)
        log "安装 Yarn..."
        curl -o- -L https://yarnpkg.com/install.sh | bash
        
        # 配置 Yarn PATH
        export PATH="$HOME/.yarn/bin:$HOME/.config/yarn/global/node_modules/.bin:$PATH"
        
        # 添加到 shell 配置文件
        if ! grep -q "yarn/bin" ~/.bashrc; then
            echo 'export PATH="$HOME/.yarn/bin:$HOME/.config/yarn/global/node_modules/.bin:$PATH"' >> ~/.bashrc
        fi
        if [ -f ~/.zshrc ] && ! grep -q "yarn/bin" ~/.zshrc; then
            echo 'export PATH="$HOME/.yarn/bin:$HOME/.config/yarn/global/node_modules/.bin:$PATH"' >> ~/.zshrc
        fi
        
        # 重新加载环境变量
        source ~/.bashrc 2>/dev/null || true
        
        if command -v yarn > /dev/null 2>&1; then
            success "Yarn 安装完成: $(yarn -v)"
        else
            error "Yarn 安装失败"
            return 1
        fi
        
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # Mac OSX
        if ! check_cmd "brew"; then
            log "安装 Homebrew..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        brew update || true
        
        # 安装基础包
        brew install curl git wget jq make gcc automake autoconf tmux htop pkg-config openssl protobuf bc || {
            warning "部分包安装失败，尝试继续执行..."
            # 尝试单独安装失败的包
            brew install bc || warning "bc 安装失败，脚本将继续运行但可能影响功能"
        }
        
        # 安装 Node.js
        if ! check_cmd "node"; then
            log "安装 Node.js..."
            brew install node
            success "Node.js 安装完成: $(node -v)"
        else
            success "Node.js 已安装: $(node -v)"
        fi
        
        # 安装 Yarn
        if ! check_cmd "yarn"; then
            log "安装 Yarn..."
            brew install yarn
            success "Yarn 安装完成: $(yarn -v)"
        else
            success "Yarn 已安装: $(yarn -v)"
        fi
    fi
}

# 安装 Rust
install_rust() {
    if ! check_cmd "cargo"; then
        log "安装 Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
        success "Rust 安装完成"
    fi
    
    # 设置 Rust 镜像
    log "设置 Rust 镜像..."
    mkdir -p ~/.cargo
    cat > ~/.cargo/config.toml << 'EOF'
[source.crates-io]
replace-with = 'ustc'

[source.ustc]
registry = "git://mirrors.ustc.edu.cn/crates.io-index"

[net]
git-fetch-with-cli = true
EOF
    success "Rust 镜像设置完成"
}

# 安装 Solana CLI
install_solana() {
    if ! check_cmd "solana"; then
        log "安装 Solana CLI..."
        if [[ "$OSTYPE" == "linux-gnu"* ]]; then
            sh -c "$(curl --proto '=https' --tlsv1.2 -sSfL https://solana-install.solana.workers.dev)"
        elif [[ "$OSTYPE" == "darwin"* ]]; then
            sh -c "$(curl --proto '=https' --tlsv1.2 -sSfL https://solana-install.solana.workers.dev)"
        fi
        
        # 添加到 PATH
        echo 'export PATH="$HOME/.local/share/solana/install/active_release/bin:$PATH"' >> ~/.bashrc
        echo 'export PATH="$HOME/.local/share/solana/install/active_release/bin:$PATH"' >> ~/.zshrc
        export PATH="$HOME/.local/share/solana/install/active_release/bin:$PATH"
        
        success "Solana 安装完成"
    fi
    
    # 配置 Solana
    log "配置 Solana Devnet..."
    solana config set --url https://api.devnet.solana.com
    success "Solana 配置完成"
}

# 安装 Docker
install_docker() {
    # 先检查 Docker 是否已经安装
    if check_cmd "docker"; then
        success "Docker 已安装: $(docker --version)"
        
        # 检查 Docker 是否在运行 (macOS)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            if ! docker info > /dev/null 2>&1; then
                warning "Docker 已安装但未运行"
                info "请启动 Docker Desktop 后继续"
                return 1
            fi
        fi
        return 0
    fi
    
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        log "安装 Docker..."
        sudo apt install -y ca-certificates curl gnupg software-properties-common
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        sudo apt update
        sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
        sudo systemctl start docker
        sudo systemctl enable docker
        sudo usermod -aG docker $USER
        
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        log "请手动安装 Docker Desktop for Mac"
        info "访问: https://docs.docker.com/desktop/setup/install/mac-install/"
        info "安装后重新运行此脚本"
        return 1
    fi
    
    success "Docker 安装完成"
}

# 安装 Anchor
install_anchor() {
    if ! check_cmd "anchor"; then
        log "安装 Anchor..."
        
        # 克隆 Anchor 仓库
        git clone https://github.com/coral-xyz/anchor.git
        cd anchor
        
        # 切换到指定版本
        git checkout v0.31.1
        
        # 安装 Anchor CLI
        cargo install --path cli --force
        
        # 返回上级目录并清理
        cd .. && rm -rf anchor
        
        success "Anchor 安装完成"
    else
        success "Anchor 已安装: $(anchor --version)"
    fi
}

# 安装 Arcium - 使用官方安装器
install_arcium() {
    if ! check_cmd "arcium"; then
        log "安装 Arcium..."
        
        # 创建安装目录
        mkdir -p arcium-node-setup
        cd arcium-node-setup
        
        # 使用官方安装器
        curl --proto '=https' --tlsv1.2 -sSfL https://arcium-install.arcium.workers.dev/ | bash
        
        # 验证安装
        if command -v arcium > /dev/null 2>&1; then
            success "Arcium 安装完成: $(arcium --version)"
        else
            error "Arcium 安装失败"
            cd ..
            return 1
        fi
        
        # 检查 arcup 是否可用
        if command -v arcup > /dev/null 2>&1; then
            success "Arcup 可用: $(arcup --version)"
        else
            warning "Arcup 未找到，但 Arcium 安装成功"
        fi
        
        # 返回上级目录
        cd ..
        
        # 添加到 PATH（如果需要）
        if ! echo "$PATH" | grep -q "$HOME/.cargo/bin"; then
            echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> ~/.bashrc
            echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> ~/.zshrc
            export PATH="$HOME/.cargo/bin:$PATH"
        fi
        
    else
        success "Arcium 已安装: $(arcium --version)"
        if command -v arcup > /dev/null 2>&1; then
            success "Arcup 可用: $(arcup --version)"
        fi
    fi
}

# 检查 SOL 余额并领水
check_and_fund_account() {
    local address=$1
    local account_type=$2
    
    log "检查 $account_type 账户余额..."
    local balance=$(solana balance $address --url https://api.devnet.solana.com 2>/dev/null | cut -d' ' -f1 || echo "0")
    
    if (( $(echo "$balance < 2.5" | bc -l) )); then
        warning "$account_type 余额不足 ($balance SOL)，需要至少 2.5 SOL"
        log "尝试自动领水..."
        
        if solana airdrop 5 $address -u devnet 2>/dev/null; then
            success "领水成功，当前余额: $(solana balance $address --url https://api.devnet.solana.com)"
        else
            warning "自动领水失败，请手动领水"
            info "账户地址: $address"
            info "请访问: https://faucet.solana.com/"
            info "领取至少 2.5 SOL 后按回车键继续..."
            read -r
            
            # 再次检查余额
            local new_balance=$(solana balance $address --url https://api.devnet.solana.com | cut -d' ' -f1)
            if (( $(echo "$new_balance < 2.5" | bc -l) )); then
                error "余额仍然不足 ($new_balance SOL)，请确保有足够 SOL 后再运行节点"
                return 1
            fi
        fi
    else
        success "$account_type 余额充足: $balance SOL"
    fi
    return 0
}

# 设置 Arx 节点
# 设置 Arx 节点
setup_arx_node() {
    local node_offset=${1:-$(( RANDOM % 1000000000 + 1000000000 ))}
    local cluster_offset=${2:-"47359763"}
    local public_ip=$(curl -s ipv4.icanhazip.com)
    
    log "开始设置 Arx 节点..."
    log "节点 Offset: $node_offset"
    log "集群 Offset: $cluster_offset" 
    log "公网 IP: $public_ip"
    
    # 生成密钥对
    log "生成节点密钥对..."
    solana-keygen new --outfile node-keypair.json --no-bip39-passphrase --silent
    solana-keygen new --outfile callback-kp.json --no-bip39-passphrase --silent
    openssl genpkey -algorithm Ed25519 -out identity.pem
    
    # 获取公钥
    local node_pubkey=$(solana address --keypair node-keypair.json)
    local callback_pubkey=$(solana address --keypair callback-kp.json)
    
    success "节点地址: $node_pubkey"
    success "回调地址: $callback_pubkey"
    
    # 检查节点地址余额，决定是否需要领水
    log "检查节点地址余额..."
    local node_balance=$(solana balance $node_pubkey --url https://api.devnet.solana.com 2>/dev/null | cut -d' ' -f1 || echo "0")
    success "节点地址当前余额: $node_balance SOL"
    
    # 如果节点地址余额小于 3.5 SOL，则领水
    if (( $(echo "$node_balance < 3.5" | bc -l) )); then
        log "节点地址余额不足，开始领水..."
        
        if ! solana airdrop 5 $node_pubkey -u devnet 2>/dev/null; then
            warning "自动领水失败，请手动领水"
            info "节点地址: $node_pubkey"
            info "请访问: https://faucet.solana.com/"
            info "领取至少 5 SOL 后按回车键继续..."
            read -r
        else
            success "领水请求已提交，等待到账..."
            
            # 等待并检查余额
            local max_checks=10
            local check_count=0
            
            while [ $check_count -lt $max_checks ]; do
                sleep 10
                node_balance=$(solana balance $node_pubkey --url https://api.devnet.solana.com 2>/dev/null | cut -d' ' -f1 || echo "0")
                check_count=$((check_count + 1))
                
                if (( $(echo "$node_balance >= 4.5" | bc -l) )); then
                    success "节点地址领水到账: $node_balance SOL"
                    break
                else
                    info "等待领水到账... ($check_count/$max_checks) 当前余额: $node_balance SOL"
                fi
            done
            
            if (( $(echo "$node_balance < 4.5" | bc -l) )); then
                warning "领水未完全到账，当前余额: $node_balance SOL"
                info "可能因网络费用导致金额不足，尝试继续..."
            fi
        fi
    else
        success "节点地址余额充足，跳过领水"
    fi
    
    # 检查回调地址余额，决定是否需要转账
    log "检查回调地址余额..."
    local callback_balance=$(solana balance $callback_pubkey --url https://api.devnet.solana.com 2>/dev/null | cut -d' ' -f1 || echo "0")
    success "回调地址当前余额: $callback_balance SOL"
    
    # 如果回调地址余额小于 0.5 SOL，且节点地址有足够余额，则转账
    if (( $(echo "$callback_balance < 0.5" | bc -l) )); then
        if (( $(echo "$node_balance >= 1.1" | bc -l) )); then
            log "回调地址余额不足，从节点地址转账 1 SOL..."
            if solana transfer $callback_pubkey 1 --keypair node-keypair.json --url https://api.devnet.solana.com --allow-unfunded-recipient 2>/dev/null; then
                success "转账成功，等待回调地址到账..."
                
                # 等待回调地址到账
                local callback_checks=0
                while [ $callback_checks -lt 5 ]; do
                    sleep 5
                    callback_balance=$(solana balance $callback_pubkey --url https://api.devnet.solana.com 2>/dev/null | cut -d' ' -f1 || echo "0")
                    callback_checks=$((callback_checks + 1))
                    
                    if (( $(echo "$callback_balance >= 0.5" | bc -l) )); then
                        success "回调地址资金到位: $callback_balance SOL"
                        break
                    else
                        info "等待回调地址到账... ($callback_checks/5) 当前余额: $callback_balance SOL"
                    fi
                done
            else
                warning "转账失败，请手动处理"
                info "手动执行: solana transfer $callback_pubkey 1 --keypair node-keypair.json --url https://api.devnet.solana.com --allow-unfunded-recipient"
                info "按回车键继续..."
                read -r
            fi
        else
            warning "节点地址余额不足 ($node_balance SOL)，无法给回调地址转账"
            info "回调地址需要至少 0.5 SOL 才能运行节点"
            return 1
        fi
    else
        success "回调地址余额充足，跳过转账"
    fi
    
    # 最终检查回调地址余额
    local final_callback_balance=$(solana balance $callback_pubkey --url https://api.devnet.solana.com 2>/dev/null | cut -d' ' -f1 || echo "0")
    if (( $(echo "$final_callback_balance < 0.5" | bc -l) )); then
        error "回调地址余额不足 ($final_callback_balance SOL)，无法运行节点"
        return 1
    fi
    
    # 初始化账户
    log "初始化节点账户..."
    arcium init-arx-accs \
        --keypair-path node-keypair.json \
        --callback-keypair-path callback-kp.json \
        --peer-keypair-path identity.pem \
        --node-offset $node_offset \
        --ip-address $public_ip \
        --rpc-url https://api.devnet.solana.com
    
    # 加入集群
    log "加入集群..."
    arcium join-cluster true \
        --keypair-path node-keypair.json \
        --node-offset $node_offset \
        --cluster-offset $cluster_offset \
        --rpc-url https://api.devnet.solana.com
    
    # 创建节点配置
    log "创建节点配置文件..."
    cat > node-config.toml << EOF
[node]
offset = $node_offset
hardware_claim = 0
starting_epoch = 0
ending_epoch = 9223372036854775807

[network]
address = "0.0.0.0"

[solana]
endpoint_rpc = "https://api.devnet.solana.com"
endpoint_wss = "wss://api.devnet.solana.com"
cluster = "Devnet"
commitment.commitment = "confirmed"
EOF
    
    # 创建 Docker Compose 配置
    cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  arx-node:
    image: arcium/arx-node
    container_name: arx-node
    environment:
      - NODE_IDENTITY_FILE=/usr/arx-node/node-keys/node_identity.pem
      - NODE_KEYPAIR_FILE=/usr/arx-node/node-keys/node_keypair.json
      - OPERATOR_KEYPAIR_FILE=/usr/arx-node/node-keys/operator_keypair.json
      - CALLBACK_AUTHORITY_KEYPAIR_FILE=/usr/arx-node/node-keys/callback_authority_keypair.json
      - NODE_CONFIG_PATH=/usr/arx-node/arx/node_config.toml
    volumes:
      - ./node-config.toml:/usr/arx-node/arx/node_config.toml
      - ./node-keypair.json:/usr/arx-node/node-keys/node_keypair.json:ro
      - ./node-keypair.json:/usr/arx-node/node-keys/operator_keypair.json:ro
      - ./callback-kp.json:/usr/arx-node/node-keys/callback_authority_keypair.json:ro
      - ./identity.pem:/usr/arx-node/node-keys/node_identity.pem:ro
      - ./arx-node-logs:/usr/arx-node/logs
    ports:
      - "8082:8080"
    restart: unless-stopped
EOF
    
    # 启动节点
    log "启动节点容器..."
    docker compose up -d
    
    # 检查节点状态
    sleep 5
    if docker ps | grep -q arx-node; then
        success "Arx 节点启动成功！"
        success "节点 Offset: $node_offset"
        success "节点地址: $node_pubkey"
        success "回调地址: $callback_pubkey"
    else
        error "节点启动失败，请检查日志"
        return 1
    fi
}

# 验证安装
verify_installation() {
    log "验证节点运行环境..."
    
    local all_success=true
    
    if check_cmd "solana"; then
        success "Solana CLI: $(solana --version)"
    else
        error "Solana CLI: 未安装"
        all_success=false
    fi
    
    if check_cmd "arcium"; then
        success "Arcium: $(arcium --version)"
    else
        error "Arcium: 未安装"
        all_success=false
    fi
    
    if check_cmd "anchor"; then
        success "Anchor: $(anchor --version)"
    else
        error "Anchor: 未安装"
        all_success=false
    fi
    
    if docker info > /dev/null 2>&1; then
        success "Docker: 正在运行"
    else
        error "Docker: 未运行"
        all_success=false
    fi
    
    if check_cmd "node"; then
        success "Node.js: $(node --version)"
    else
        error "Node.js: 未安装"
        all_success=false
    fi
    
    if check_cmd "yarn"; then
        success "Yarn: $(yarn --version)"
    else
        error "Yarn: 未安装"
        all_success=false
    fi
    
    if [ "$all_success" = true ]; then
        success "🎉 节点环境准备完成！"
    else
        error "❌ 节点环境配置失败"
        exit 1
    fi
}

# 显示节点信息
show_node_info() {
    echo
    info "=== Arcium 节点部署完成 ==="
    echo
    info "节点配置信息:"
    echo "  - 节点 Offset: 查看上方输出"
    echo "  - 公网 IP: $(curl -s ipv4.icanhazip.com)"
    echo "  - 运行端口: 8080"
    echo
    info "节点管理命令:"
    echo "  - 查看节点日志: docker compose logs -f"
    echo "  - 停止节点: docker compose down"
    echo "  - 重启节点: docker compose restart"
    echo "  - 查看容器状态: docker ps"
    echo
    info "节点状态检查:"
    echo "  - 使用节点 Offset 检查状态: arcium arx-info <node_offset>"
    echo
    info "重要提醒:"
    echo "  - 保持 Docker 持续运行"
    echo "  - 确保端口 8080 对外开放"
    echo "  - 监控节点日志确保正常运行"
    echo "  - 节点需要持续在线以获得奖励"
    echo
    warning "请妥善保存生成的密钥文件！"
}

# 主函数
main() {
    echo
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════╗"
    echo "║          Arcium 节点部署脚本         ║"
    echo "║          专注节点运行                ║"
    echo "╚══════════════════════════════════════╝"
    echo -e "${NC}"
    
    # 显示系统信息
    log "系统信息: $(uname -s) $(uname -m)"
    log "工作目录: $(pwd)"
    
    # 检查安装状态
    info "检查节点运行所需组件..."
    local skip_install=false
    if check_cmd "solana" && check_cmd "arcium" && check_cmd "docker" && check_cmd "anchor" && check_cmd "node" && check_cmd "yarn"; then
        echo
        info "检测到组件已安装，是否跳过安装步骤？ (y/n)"
        read -r skip_install
        if [[ $skip_install =~ ^[Yy]$ ]]; then
            success "跳过安装步骤，直接设置节点..."
            skip_install=true
        fi
    fi
    
    if [ "$skip_install" = false ]; then
        # 安装节点运行必需的组件
        install_dependencies
        install_rust
        install_solana
        install_docker
        install_anchor
        install_arcium
        verify_installation
    fi
    
    # 直接设置节点
    log "开始部署 Arx 节点..."
    if setup_arx_node; then
        show_node_info
    else
        error "节点部署失败，请检查错误信息"
        exit 1
    fi
}

# 运行主函数
main "$@"