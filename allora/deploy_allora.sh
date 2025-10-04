#!/bin/bash

# Allora Network 一键部署脚本 - 完整修复版
set -e

echo "🚀 Allora Network 完整部署脚本..."
echo "================================================"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 常量定义
WALLET_INFO_FILE=".allora_wallet.info"
DOCKER_START_TIMEOUT=30
PROJECT_DIR="allora-offchain-node"

# 检测操作系统
OS_TYPE="unknown"
if [[ "$(uname -s)" == "Darwin" ]]; then
    OS_TYPE="macos"
elif [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "$ID" == "ubuntu" ]]; then
        OS_TYPE="ubuntu"
    fi
fi

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}==>${NC} $1"; }

# 检查依赖
check_dependencies() {
    log_step "1. 检查系统依赖..."
    
    if ! command -v docker &> /dev/null; then
        log_error "Docker 未安装，请先安装 Docker"
        if [[ "$OS_TYPE" == "macos" ]]; then
            log_info "macOS: 请访问 https://www.docker.com/products/docker-desktop/"
            open https://www.docker.com/products/docker-desktop/
        elif [[ "$OS_TYPE" == "ubuntu" ]]; then
            log_info "Ubuntu: 请运行以下命令安装 Docker:"
            echo "  curl -fsSL https://get.docker.com -o get-docker.sh"
            echo "  sudo sh get-docker.sh"
            echo "  sudo usermod -aG docker \$USER"
        fi
        exit 1
    fi
    
    if ! command -v git &> /dev/null; then
        log_info "安装 Git..."
        if [[ "$OS_TYPE" == "macos" ]]; then
            brew install git
        elif [[ "$OS_TYPE" == "ubuntu" ]]; then
            sudo apt update && sudo apt install -y git
        fi
    fi
    
    if ! command -v allorad &> /dev/null; then
        log_info "安装 allorad..."
        curl -sSL https://raw.githubusercontent.com/allora-network/allora-chain/dev/install.sh | bash -s -- v0.12.1
        if [[ "$OS_TYPE" == "macos" ]]; then
            export PATH="$PATH:/Users/$(whoami)/.local/bin"
        else
            export PATH="$PATH:$HOME/.local/bin"
        fi
        log_info "✅ allorad 安装完成"
    else
        log_info "✅ 检测到 allorad 已安装，跳过安装"
    fi
    
    log_info "✅ 依赖检查通过"
}

# 启动Docker
start_docker_if_needed() {
    log_step "2. 检查 Docker 状态..."
    
    if docker info &> /dev/null; then
        log_info "✅ Docker 守护进程已就绪"
        return 0
    fi
    
    log_warn "Docker 未运行，正在启动..."
    
    # 检测操作系统并启动 Docker
    if [[ "$OS_TYPE" == "macos" ]]; then
        open -a Docker
        log_info "等待 Docker Desktop 启动..."
    elif [[ "$OS_TYPE" == "ubuntu" ]]; then
        log_info "启动 Docker 服务..."
        sudo systemctl start docker
        sudo systemctl enable docker
    else
        log_error "❌ 不支持的操作系统，请手动启动 Docker"
        exit 1
    fi
    
    local waited=0
    while [ $waited -lt $DOCKER_START_TIMEOUT ]; do
        if docker info &> /dev/null; then
            log_info "✅ Docker 守护进程已就绪（等待 ${waited}秒）"
            return 0
        fi
        echo -n "."
        sleep 2
        waited=$((waited + 2))
    done
    echo ""
    
    if docker info &> /dev/null; then
        log_info "✅ Docker 启动成功"
    else
        log_error "❌ Docker 启动失败，请手动启动 Docker"
        if [[ "$OS_TYPE" == "macos" ]]; then
            log_info "macOS: 请手动打开 Docker Desktop"
        elif [[ "$OS_TYPE" == "ubuntu" ]]; then
            log_info "Ubuntu: 请运行 'sudo systemctl start docker'"
        fi
        exit 1
    fi
}

# 生成钱包
generate_wallet() {
    log_info "生成新的 Allora 钱包..."
    
    local wallet_name="wallet-$(date +%s)"
    local wallet_output
    
    wallet_output=$(allorad keys add "$wallet_name" --dry-run --output json 2>&1)
    
    if [ $? -ne 0 ]; then
        log_info "dry-run 模式失败，尝试自动密码输入..."
        wallet_output=$(printf "12345678\n12345678\n" | allorad keys add "$wallet_name" --output json 2>&1)
    fi
    
    if [ $? -eq 0 ]; then
        local mnemonic=$(echo "$wallet_output" | grep -o '"mnemonic":"[^"]*' | cut -d'"' -f4)
        local address=$(echo "$wallet_output" | grep -o '"address":"[^"]*' | cut -d'"' -f4)
        
        cat > "$WALLET_INFO_FILE" << EOF
WALLET_NAME="$wallet_name"
WALLET_ADDRESS="$address"
MNEMONIC="$mnemonic"
CREATED_TIME="$(date)"
EOF
        
        chmod 600 "$WALLET_INFO_FILE"
        
        log_info "✅ 钱包生成成功！"
        log_info "钱包地址: $address"
        log_warn "⚠️  请妥善保存助记词: $mnemonic"
        
        return 0
    else
        log_error "钱包创建失败: $wallet_output"
        return 1
    fi
}

# 设置钱包
setup_wallet() {
    log_step "3. 设置钱包..."
    
    if [ -f "$WALLET_INFO_FILE" ] && \
       [ -n "$(grep 'WALLET_ADDRESS' "$WALLET_INFO_FILE")" ] && \
       [ -n "$(grep 'MNEMONIC' "$WALLET_INFO_FILE")" ]; then
        
        source "$WALLET_INFO_FILE"
        log_info "✅ 使用现有钱包: $WALLET_ADDRESS"
        return 0
    else
        log_info "创建新钱包..."
        generate_wallet
    fi
}

# 显示水龙头信息
show_faucet_info() {
    log_step "4. 获取测试代币..."
    
    if [ -f "$WALLET_INFO_FILE" ]; then
        source "$WALLET_INFO_FILE"
        log_info "💰 请获取测试代币:"
        echo "   水龙头地址: https://faucet.testnet.allora.network"
        echo "   你的钱包地址: $WALLET_ADDRESS"
        echo ""
        read -p "领取后代币后按回车键继续..."
    fi
}

# 克隆项目
clone_projects() {
    log_step "5. 克隆 Allora 项目..."
    
    if [ ! -d "$PROJECT_DIR" ]; then
        git clone https://github.com/allora-network/allora-offchain-node.git
    else
        log_info "项目已存在，更新中..."
        cd "$PROJECT_DIR"
        git pull || log_warn "更新失败，使用现有版本"
        cd ..
    fi
    log_info "✅ 项目克隆完成"
}

# 创建完整配置文件
create_complete_config() {
    log_step "6. 创建配置文件..."
    
    if [ ! -f "$WALLET_INFO_FILE" ]; then
        log_error "未找到钱包信息，请先设置钱包"
        return 1
    fi
    
    source "$WALLET_INFO_FILE"
    
    cd "$PROJECT_DIR"
    
    # 测试RPC连接
    log_info "测试 RPC 连接..."
    local rpc_url="https://allora-rpc.testnet.allora.network:443"
    
    if curl -s --connect-timeout 10 "$rpc_url/health" > /dev/null 2>&1; then
        log_info "✅ RPC 连接测试成功"
    else
        log_warn "⚠️  RPC 连接测试失败，但继续配置"
    fi
    
    # 创建完整的配置文件（包含所有必需字段）
    cat > config.json << EOF
{
    "wallet": {
        "chainId": "allora-testnet-1",
        "keyringBackend": "test",
        "addressKeyName": "$WALLET_NAME",
        "addressRestoreMnemonic": "$MNEMONIC",
        "nodeRpcs": ["https://allora-rpc.testnet.allora.network:443"],
        "nodegRpcs": ["allora-grpc.testnet.allora.network:443", "testnet-allora.lavenderfive.com:443"],
        "gasPrices": "50.0",
        "submitTx": true,
        "maxRetries": 5,
        "timeoutRPCSecondsQuery": 60,
        "timeoutRPCSecondsTx": 300,
        "windowCorrectionFactor": 0.7,
        "blockDurationEstimated": 5,
        "retryDelay": 3,
        "accountSequenceRetryDelay": 1,
        "launchRoutineDelay": 5
    },
    "worker": [
        {
            "topicId": 1,
            "inferenceEntrypointName": "apiAdapter",
            "parameters": {
                "InferenceEndpoint": "http://inference-server:8000/inference/{Token}",
                "Token": "ETH"
            }
        }
    ]
}
EOF
    
    # 验证配置文件
    if python3 -m json.tool config.json > /dev/null 2>&1; then
        log_info "✅ 配置文件语法正确"
    else
        log_error "❌ 配置文件语法错误"
        return 1
    fi
    
    cd ..
    log_info "✅ 配置文件创建完成"
}

# 创建推理服务
create_inference_service() {
    log_step "7. 创建推理服务..."
    
    cd "$PROJECT_DIR"
    
    # requirements.txt
    cat > requirements.txt << 'EOF'
flask==2.3.3
requests==2.31.0
numpy==1.24.3
EOF
    
    # main.py
    cat > main.py << 'EOF'
from flask import Flask, jsonify
import random
import time

app = Flask(__name__)

@app.route('/inference/<token>')
def inference(token):
    base_prices = {'BTC': 50000, 'ETH': 3000, 'SOL': 150}
    price = base_prices.get(token.upper(), random.uniform(0, 100))
    return jsonify({
        'token': token.upper(),
        'prediction': round(price, 4),
        'confidence': round(random.uniform(0.7, 0.95), 3),
        'timestamp': time.time()
    })

@app.route('/health')
def health():
    return jsonify({'status': 'healthy'})

@app.route('/inference')
def inference_default():
    return inference('ETH')

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000, debug=False)
EOF
    
    cd ..
    log_info "✅ 推理服务文件创建完成"
}

# 设置Docker环境
setup_docker() {
    log_step "8. 设置 Docker 环境..."
    
    cd "$PROJECT_DIR"
    
    # 清理重复的 docker-compose 文件
    if [ -f "docker-compose.yaml" ]; then
        rm docker-compose.yaml
        log_info "✅ 已删除重复的 docker-compose.yaml"
    fi
    
    # 创建 docker-compose.yml
    cat > docker-compose.yml << 'EOF'
services:
  offchain-node:
    build:
      context: .
      dockerfile: Dockerfile.offchain
    container_name: allora-offchain-node
    environment:
      - ALLORA_OFFCHAIN_NODE_CONFIG_FILE_PATH=/app/config.json
    volumes:
      - ./config.json:/app/config.json:ro
    ports:
      - "8081:8080"
    networks:
      - allora-network

  inference-server:
    image: python:3.9-slim
    container_name: allora-inference-server
    working_dir: /app
    volumes:
      - ./requirements.txt:/app/requirements.txt
      - ./main.py:/app/main.py
    ports:
      - "8000:8000"
    command: sh -c "pip install -i https://pypi.tuna.tsinghua.edu.cn/simple -r requirements.txt && python main.py"
    networks:
      - allora-network

networks:
  allora-network:
    driver: bridge
EOF
    
    # 创建 Dockerfile.offchain
    cat > Dockerfile.offchain << 'EOF'
FROM python:3.9-slim

# 安装Go
RUN apt-get update && apt-get install -y wget git && \
    wget https://golang.google.cn/dl/go1.21.7.linux-amd64.tar.gz -O go.tar.gz && \
    tar -C /usr/local -xzf go.tar.gz && \
    rm go.tar.gz

ENV PATH="/usr/local/go/bin:${PATH}"

WORKDIR /app

# 复制本地代码到容器中
COPY . .

# 设置Go代理并构建
RUN go env -w GOPROXY=https://goproxy.cn,direct && \
    go mod download && \
    go build -o allora-offchain-node .

EXPOSE 8080
CMD ["./allora-offchain-node"]
EOF
    
    cd ..
    log_info "✅ Docker 配置完成"
}

# 启动服务
start_services() {
    log_step "9. 启动 Docker 服务..."
    
    # 确保在项目目录中执行 Docker 命令
    cd "$PROJECT_DIR"
    
    # 停止现有服务
    docker compose down 2>/dev/null || true
    
    # 检查 Docker 配置文件是否存在
    if [ ! -f "docker-compose.yml" ]; then
        log_error "❌ docker-compose.yml 文件不存在"
        return 1
    fi
    
    if [ ! -f "Dockerfile.offchain" ]; then
        log_error "❌ Dockerfile.offchain 文件不存在"
        return 1
    fi
    
    log_info "检查 Docker 配置..."
    docker compose config
    
    # 构建和启动服务
    log_info "构建 Docker 镜像..."
    
    # 直接构建，不使用 --no-cache 以加快速度
    if docker compose build; then
        log_info "✅ 镜像构建成功"
    else
        log_error "❌ 镜像构建失败"
        return 1
    fi
    
    log_info "启动服务..."
    if docker compose up -d; then
        log_info "✅ 服务启动成功"
        
        # 等待服务完全启动
        log_info "等待服务启动..."
        for i in {1..30}; do
            if docker ps | grep -q "allora-offchain-node" && docker ps | grep allora-offchain-node | grep -q "Up"; then
                log_info "✅ Offchain 节点正在运行！"
                break
            fi
            echo -n "."
            sleep 1
        done
        echo ""
        
        return 0
    else
        log_error "❌ 服务启动失败"
        return 1
    fi
}

# 检查服务状态
check_services() {
    log_step "10. 检查服务状态..."
    
    # 注意：这里不需要 cd，因为已经在项目目录中
    
    echo "=== 服务状态 ==="
    docker ps
    
    if docker ps | grep -q "allora-inference-server"; then
        log_info "✅ 推理服务运行中"
        if curl -s http://localhost:8000/health > /dev/null; then
            log_info "✅ 推理服务健康检查通过"
        fi
    else
        log_warn "⚠️ 推理服务未运行"
    fi
    
    if docker ps | grep -q "allora-offchain-node"; then
        log_info "✅ Offchain 节点运行中"
        
        # 显示节点日志摘要
        echo "=== Offchain 节点日志摘要 ==="
        docker compose logs offchain-node --tail=5
    else
        log_warn "⚠️ Offchain 节点未运行"
        echo "=== 详细错误日志 ==="
        docker compose logs offchain-node
    fi
    
    # 返回到原始目录
    cd ..
}

# 显示部署完成信息
show_deployment_info() {
    log_step "🎉 Allora 部署完成！"
    echo ""
    echo "📊 服务信息:"
    echo "   - Offchain Node: http://localhost:8080"
    echo "   - Inference API: http://localhost:8000/inference/ETH"
    echo "   - Health Check:  http://localhost:8000/health"
    echo ""
    echo "🔧 管理命令:"
    echo "   - 查看日志: cd $PROJECT_DIR && docker compose logs -f"
    echo "   - 停止服务: cd $PROJECT_DIR && docker compose down"
    echo "   - 重启服务: cd $PROJECT_DIR && docker compose up -d"
    echo ""
    
    if [ -f "$WALLET_INFO_FILE" ]; then
        source "$WALLET_INFO_FILE"
        echo "💰 钱包信息:"
        echo "   - 地址: $WALLET_ADDRESS"
        echo "   - 名称: $WALLET_NAME"
        echo ""
    fi
    
    echo "📋 下一步:"
    echo "   1. 监控节点日志确保正常运行"
    echo "   2. 检查节点是否成功注册到网络"
    echo "   3. 验证推理服务是否正常工作"
    echo ""
}

# 主部署函数
main_deployment() {
    echo "================================================"
    echo "🚀 Allora Network 完整部署开始"
    echo "================================================"
    
    check_dependencies
    start_docker_if_needed
    setup_wallet
    show_faucet_info
    clone_projects
    create_complete_config
    create_inference_service
    setup_docker
    start_services
    check_services
    show_deployment_info
    
    echo "================================================"
    log_info "✅ Allora Network 部署完成！"
    echo "================================================"
}

# 诊断函数
diagnose_issues() {
    log_step "🔍 诊断 Allora 问题..."
    
    cd "$PROJECT_DIR"
    
    echo "=== 当前状态 ==="
    docker ps -a
    
    echo "=== Offchain 节点日志 ==="
    docker compose logs offchain-node --tail=20
    
    echo "=== 配置文件检查 ==="
    if [ -f "config.json" ]; then
        echo "✅ 配置文件存在"
        # 检查关键配置字段
        for field in "windowCorrectionFactor" "blockDurationEstimated" "nodeRpcs" "nodegRpcs"; do
            if grep -q "\"$field\"" config.json; then
                echo "✅ $field: 已配置"
            else
                echo "❌ $field: 缺失"
            fi
        done
    else
        echo "❌ 配置文件不存在"
    fi
}

# 显示使用说明
show_usage() {
    echo "使用方法: $0 [command]"
    echo ""
    echo "命令:"
    echo "  deploy     - 完整部署 Allora Network"
    echo "  diagnose   - 诊断现有部署问题"
    echo "  logs       - 查看服务日志"
    echo "  stop       - 停止服务"
    echo "  restart    - 重启服务"
    echo "  status     - 查看服务状态"
    echo ""
    echo "示例:"
    echo "  $0 deploy     # 完整部署"
    echo "  $0 diagnose   # 诊断问题"
    echo "  $0 logs       # 查看日志"
}

# 脚本主入口
main() {
    case "${1:-deploy}" in
        "deploy")
            main_deployment
            ;;
        "diagnose")
            diagnose_issues
            ;;
        "logs")
            cd "$PROJECT_DIR"
            docker compose logs -f
            ;;
        "stop")
            cd "$PROJECT_DIR"
            docker compose down
            log_info "✅ 服务已停止"
            ;;
        "restart")
            cd "$PROJECT_DIR"
            docker compose restart
            log_info "✅ 服务已重启"
            ;;
        "status")
            cd "$PROJECT_DIR"
            docker ps
            ;;
        "help"|"-h"|"--help")
            show_usage
            ;;
        *)
            log_error "未知命令: $1"
            show_usage
            exit 1
            ;;
    esac
}

# 脚本执行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi