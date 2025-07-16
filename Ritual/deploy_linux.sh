#!/bin/bash

set -e

# 定义日志函数，记录到文件和终端
log_file="$HOME/infernet-deployment.log"
info() { echo "ℹ️  $1" | tee -a "$log_file"; }
warn() { echo "⚠️  $1" | tee -a "$log_file"; }
error() { echo "❌ 错误：$1" | tee -a "$log_file"; exit 1; }

echo "======================================="
echo "🚀 Infernet Hello-World 一键部署工具 🚀"
echo "=======================================" | tee -a "$log_file"

# 配置文件路径，用于存储 RPC_URL 和 PRIVATE_KEY
config_file="$HOME/.infernet_config"

# 函数：加载或提示输入 RPC_URL 和 PRIVATE_KEY
load_or_prompt_config() {
    if [ -f "$config_file" ]; then
        info "检测到已保存的配置：$config_file"
        source "$config_file"
        info "当前 RPC_URL: $RPC_URL"
        info "当前 PRIVATE_KEY: ${PRIVATE_KEY:0:4}...（已隐藏后部分）"
        read -p "是否更新 RPC_URL 和 PRIVATE_KEY？(y/n): " update_config
        if [[ "$update_config" != "y" && "$update_config" != "Y" ]]; then
            return
        fi
    fi

    info "请输入以下信息以继续部署："
    read -p "请输入你的 RPC URL（Alchemy/Infura，例如 Base Mainnet 或 Sepolia）： " RPC_URL
    read -p "请输入你的私钥（0x 开头，不要泄露）： " PRIVATE_KEY

    # 输入校验
    if [[ -z "$RPC_URL" || -z "$PRIVATE_KEY" ]]; then
        error "RPC URL 和私钥不能为空。"
    fi
    if [[ ! "$RPC_URL" =~ ^https?://[a-zA-Z0-9.-]+ ]]; then
        error "无效的 RPC URL 格式。"
    fi
    if [[ ! "$PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
        error "无效的私钥格式（必须是 0x 开头的 64 位十六进制）。"
    fi

    # 保存到配置文件
    cat <<EOF > "$config_file"
RPC_URL="$RPC_URL"
PRIVATE_KEY="$PRIVATE_KEY"
EOF
    chmod 600 "$config_file" # 设置文件权限为仅用户可读写
    info "配置已保存至 $config_file"
}

# 函数：检查并安装部署合约所需的依赖，无限重试
check_and_install_contract_depspf() {
    echo "[1/15] 🧹 检查部署合约所需依赖..." | tee -a "$log_file"

    # 检查 Homebrew
    if ! command -v brew &> /dev/null; then
        info "Homebrew 未安装，正在安装..."
        while true; do
            if /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
                echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
                eval "$(/opt/homebrew/bin/brew shellenv)"
                info "Homebrew 安装成功，版本：$(brew --version | head -n 1)"
                break
            else
                warn "Homebrew 安装失败，正在重试..."
                sleep 10
            fi
        done
    else
        info "Homebrew 已安装，版本：$(brew --version | head -n 1)"
    fi

    # 检查并安装基本依赖
    for pkg in curl jq; do
        if ! command -v $pkg &> /dev/null; then
            info "安装 $pkg..."
            while true; do
                if brew install $pkg; then
                    info "$pkg 安装成功。"
                    break
                else
                    warn "安装 $pkg 失败，正在重试..."
                    sleep 10
                fi
            done
        else
            info "$pkg 已安装。"
        fi
    done

    # 检查 Docker
    if ! command -v docker &> /dev/null; then
        info "Docker 未安装，正在通过 Homebrew 安装 Docker Desktop..."
        while true; do
            if brew install --cask docker; then
                echo "🚀 Docker 安装成功！请手动打开 Docker Desktop：open -a Docker"
                info "请等待 Docker Desktop 启动完成后再继续（可能需要几分钟）。"
                read -p "按 Enter 继续（确保 Docker Desktop 已运行）..."
                break
            else
                warn "Docker Desktop 安装失败，正在重试..."
                sleep 10
            fi
        done
    else
        info "Docker 已安装，版本：$(docker --version)"
    fi

    # 检查 Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        info "安装 Docker Compose..."
        while true; do
            if brew install docker-compose; then
                info "Docker Compose 安装成功，版本：$(docker-compose --version)"
                break
            else
                warn "Docker Compose 安装失败，正在重试..."
                sleep 10
            fi
        done
    else
        info "Docker Compose 已安装，版本：$(docker-compose --version)"
    fi

    # 检查 Foundry
    if ! command -v forge &> /dev/null; then
        info "Foundry 未安装，正在安装..."
        while true; do
            if curl -L https://foundry.paradigm.xyz | bash; then
                echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> ~/.zshrc
                source ~/.zshrc
                if foundryup; then
                    info "Foundry 安装成功，forge 版本：$(forge --version)"
                    break
                else
                    warn "Foundry 更新失败，正在重试..."
                    sleep 10
                fi
            else
                warn "Foundry 安装失败，正在重试..."
                sleep 10
            fi
        done
    else
        info "Foundry 已安装，forge 版本：$(forge --version)"
    fi
}

# ========== 依赖安装（仅适配Ubuntu） ===========
if [[ "$(uname)" != "Linux" ]]; then
    error "此脚本仅适用于 Ubuntu Linux"
fi
sudo apt update

# 先清理 containerd/containerd.io/docker 相关包，避免依赖冲突
sudo apt-get remove --purge -y containerd containerd.io docker.io docker-compose || true
sudo apt-get autoremove -y
sudo apt-get clean

# 安装常规依赖
sudo apt-get install -y curl git nano jq lz4 make coreutils

# 优先用官方脚本安装 Docker，失败则用 apt 安装 docker.io
if ! command -v docker &>/dev/null; then
    echo "尝试用官方脚本安装 Docker..."
    if curl -fsSL https://get.docker.com | sudo bash; then
        echo "✅ Docker 官方脚本安装成功"
    else
        echo "⚠️ 官方脚本安装失败，尝试用 apt 安装 docker.io"
        sudo apt-get install -y docker.io
    fi
else
    echo "✅ Docker 已安装，版本：$(docker --version)"
fi

# 安装 docker-compose
if ! command -v docker-compose &>/dev/null; then
    sudo apt-get install -y docker-compose
fi

sudo systemctl enable docker
sudo systemctl start docker

# ========== 原有脚本内容继续 ===========

# 选择部署模式
echo "[6/15] 🛠️ 选择部署模式..." | tee -a "$log_file"
info "请选择 Infernet 节点的部署模式："
select yn in "是 (全新部署，清除并重装)" "否 (继续现有环境)" "直接部署合约" "更新配置并重启容器" "退出"; do
    case $yn in
        "是 (全新部署，清除并重装)")
            info "正在清除旧节点与数据..."
            if [ -d "$HOME/infernet-container-starter" ]; then
                cd "$HOME/infernet-container-starter"
                if ! docker-compose -f deploy/docker-compose.yaml down -v; then
                    warn "停止 Docker Compose 失败，继续清理..."
                fi
                cd "$HOME"
                if ! rm -rf infernet-container-starter; then
                    warn "删除 infernet-container-starter 失败，请检查权限。"
                else
                    info "已清除旧节点数据，即将开始全新部署。"
                fi
            else
                info "未找到旧节点数据，继续全新部署..."
            fi
            skip_to_deploy=false
            full_deploy=true
            break
            ;;
        "否 (继续现有环境)")
            info "检查现有部署环境..."
            if [ ! -d "$HOME/infernet-container-starter" ] || \
               [ ! -d "$HOME/infernet-container-starter/projects/hello-world/contracts" ] || \
               [ ! -f "$HOME/infernet-container-starter/projects/hello-world/contracts/Makefile" ] || \
               [ ! -f "$HOME/infernet-container-starter/projects/hello-world/contracts/script/Deploy.s.sol" ]; then
                error "现有环境不完整（缺少目录或文件），请选择 '是 (全新部署)' 或先运行完整部署。"
            fi
            skip_to_deploy=false
            full_deploy=false
            break
            ;;
        "直接部署合约")
            info "将直接执行合约部署步骤..."
            if [ ! -d "$HOME/infernet-container-starter/projects/hello-world/contracts" ] || \
               [ ! -f "$HOME/infernet-container-starter/projects/hello-world/contracts/Makefile" ] || \
               [ ! -f "$HOME/infernet-container-starter/projects/hello-world/contracts/script/Deploy.s.sol" ]; then
                error "合约目录或文件缺失，请先运行完整部署流程。"
            fi
            skip_to_deploy=true
            full_deploy=false
            break
            ;;
        "更新配置并重启容器")
            info "将更新配置文件并重启容器..."
            if [ ! -d "$HOME/infernet-container-starter" ] || [ ! -d "$HOME/infernet-container-starter/deploy" ]; then
                error "未找到部署目录，请先运行完整部署流程。"
            fi
            update_config_and_restart=true
            skip_to_deploy=false
            full_deploy=false
            break
            ;;
        "退出")
            warn "脚本已退出，未做任何更改。"
            exit 0
            ;;
    esac
done

# 检查端口是否占用
info "检查端口占用..."
for port in 4000 6379 8545 5001; do
    if lsof -i :$port &> /dev/null; then
        info "端口 $port 被占用，尝试自动kill占用进程..."
        pids=$(lsof -t -i :$port)
        for pid in $pids; do
            if kill -9 $pid 2>/dev/null; then
                info "已kill进程 $pid (占用端口 $port)"
            else
                warn "无法kill进程 $pid (占用端口 $port)，请手动处理。"
            fi
        done
    else
        info "端口 $port 未被占用。"
    fi
done
info "Redis 端口 6379 被限制为本地访问，无需外部开放。"

# 加载或提示输入配置（仅在全量部署或直接部署合约时需要）
if [ "$skip_to_deploy" = "true" ] || ([ "$yn" != "退出" ] && [ "$update_config_and_restart" != "true" ]); then
    echo "[8/15] 📝 加载或输入配置..." | tee -a "$log_file"
    load_or_prompt_config

    # 检查 RPC URL 连通性
    echo "[9/15] 🔍 测试 RPC URL 连通性..." | tee -a "$log_file"
    while true; do
        chain_id=$(curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_chainId","id":1}' "$RPC_URL" | jq -r '.result')
        if [ -n "$chain_id" ]; then
            info "检测到链 ID: $chain_id"
            break
        else
            warn "无法连接到 RPC URL 或无效响应，正在重试..."
            sleep 10
        fi
    done
fi

# 更新配置并重启容器模式
if [ "$update_config_and_restart" = "true" ]; then
    echo "[8/8] 🔧 更新配置并重启容器..." | tee -a "$log_file"
    
    # 进入项目目录
    cd "$HOME/infernet-container-starter" || error "无法进入项目目录"
    
    # 更新配置文件
    info "正在更新配置文件..."
    if [ ! -f "deploy/config.json" ]; then
        error "未找到配置文件 deploy/config.json"
    fi
    
    # 备份原配置文件
    cp deploy/config.json deploy/config.json.backup.$(date +%Y%m%d_%H%M%S)
    info "已备份原配置文件"
    
    # 更新配置文件中的参数
    info "正在更新配置文件中的参数..."
    jq '.chain.snapshot_sync.batch_size = 10 | .chain.snapshot_sync.starting_sub_id = 262500 | .chain.snapshot_sync.retry_delay = 60' deploy/config.json > deploy/config.json.tmp
    mv deploy/config.json.tmp deploy/config.json
    
    info "已更新以下参数："
    info "- batch_size: 10"
    info "- starting_sub_id: 262500"
    info "- retry_delay: 60"
    
    # 进入deploy目录
    cd deploy || error "无法进入deploy目录"
    
    # 检查并更新 docker-compose.yml 中的 depends_on 设置
    info "检查并更新 docker-compose.yaml 中的 depends_on 设置..."
    if grep -q 'depends_on: \[ redis, infernet-anvil \]' docker-compose.yaml; then
        sed -i.bak 's/depends_on: \[ redis, infernet-anvil \]/depends_on: [ redis ]/' docker-compose.yaml
        info "已修改 depends_on 配置。备份文件保存在：docker-compose.yaml.bak"
    else
        info "depends_on 配置已正确，无需修改。"
    fi
    
    # 停止容器
    info "正在停止现有容器..."
    if docker-compose down; then
        info "容器已停止"
    else
        warn "停止容器时出现警告，继续执行..."
    fi
    
    # 启动指定服务：node、redis、fluentbit
    info "正在启动指定服务：node、redis、fluentbit..."
    attempt=1
    while true; do
        info "尝试启动容器 （第 $attempt 次）..."
        if docker-compose up node redis fluentbit; then
            info "容器启动成功"
            # 启动日志后台保存
            (docker logs -f infernet-node > "$HOME/infernet-deployment.log" 2>&1 &)
            break
        else
            warn "启动容器失败，正在重试..."
            sleep 10
        fi
        ((attempt++))
    done
    
    # 容器将在前台运行，脚本到此结束
    echo "[8/8] ✅ 配置更新完成！容器已在前台启动。" | tee -a "$log_file"
    info "容器正在前台运行，按 Ctrl+C 可停止容器"
    info "容器启动后，脚本将自动退出"
    exit 0
fi

# 直接部署合约模式：检查并安装依赖
if [ "$skip_to_deploy" = "true" ]; then
    check_and_install_contract_depspf
    echo "[9/15] 🚀 开始部署合约..." | tee -a "$log_file"
    cd "$HOME/infernet-container-starter/projects/hello-world/contracts" || error "无法进入 $HOME/infernet-container-starter/projects/hello-world/contracts 目录"

    # 安装 Forge 库，无限重试
    if ! rm -rf lib/forge-std lib/infernet-sdk; then
        warn "清理旧 Forge 库失败，继续安装..."
    fi
    while true; do
        if forge install foundry-rs/forge-std; then
            info "forge-std 安装成功。"
            break
        else
            warn "安装 forge-std 失败，正在重试..."
            sleep 10
        fi
    done
    while true; do
        if forge install ritual-net/infernet-sdk; then
            info "infernet-sdk 安装成功。"
            break
        else
            warn "安装 infernet-sdk 失败，正在重试..."
            sleep 10
        fi
    done

    # 写入部署脚本
    cat <<'EOF' > script/Deploy.s.sol
// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.13;
import {Script, console2} from "forge-std/Script.sol";
import {SaysGM} from "../src/SaysGM.sol";

contract Deploy is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        address deployerAddress = vm.addr(deployerPrivateKey);
        console2.log("Loaded deployer: ", deployerAddress);
        address registry = 0x3B1554f346DFe5c482Bb4BA31b880c1C18412170;
        SaysGM saysGm = new SaysGM(registry);
        console2.log("Deployed SaysGM: ", address(saysGm));
        vm.stopBroadcast();
    }
}
EOF

    # 写入 Makefile
    cat <<'EOF' > "$HOME/infernet-container-starter/projects/hello-world/contracts/Makefile"
.PHONY: deploy
sender := $PRIVATE_KEY
RPC_URL := $RPC_URL
deploy:
    @PRIVATE_KEY=$(sender) forge script script/Deploy.s.sol:Deploy --broadcast --rpc-url $(RPC_URL)
EOF

    # 执行合约部署，无限重试
    warn "请确保私钥有足够余额以支付 gas 费用。"
    deploy_log=$(mktemp)
    attempt=1
    while true; do
        info "尝试部署合约 （第 $attempt 次）..."
        if PRIVATE_KEY="$PRIVATE_KEY" forge script script/Deploy.s.sol:Deploy --broadcast --rpc-url "$RPC_URL" > "$deploy_log" 2>&1; then
            info "🔺 合约部署成功！✅ 输出如下："
            cat "$deploy_log"
            break
        else
            warn "合约部署失败，详细信息如下：\n$(cat "$deploy_log")\n正在重试..."
            sleep 10
        fi
        ((attempt++))
    done
    contract_address=$(grep -i "Deployed SaysGM" "$deploy_log" | awk '{print $NF}' | head -n 1)
    if [ -n "$contract_address" ] && [[ "$contract_address" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        info "部署的 SaysGM 合约地址：$contract_address"
        info "请保存此合约地址，用于后续调用！"
        call_contract_file="$HOME/infernet-container-starter/projects/hello-world/contracts/script/CallContract.s.sol"
        if [ ! -f "$call_contract_file" ]; then
            warn "未找到 CallContract.s.sol，创建默认文件..."
            cat <<'EOF' > "$call_contract_file"
// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.13;
import {Script, console2} from "forge-std/Script.sol";
import {SaysGM} from "../src/SaysGM.sol";

contract CallContract is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        SaysGM saysGm = SaysGM(ADDRESS_TO_GM);
        saysGm.sayGM("Hello, Infernet!");
        console2.log("Called sayGM function");
        vm.stopBroadcast();
    }
}
EOF
            if ! sed -i '' "s|ADDRESS_TO_GM|$contract_address|" "$call_contract_file"; then
                error "更新 CallContract.s.sol 中的合约地址失败，请检查文件内容或权限：$call_contract_file"
            fi
            info "✅ 已成功创建并更新 CallContract.s.sol 中的合约地址为 $contract_address"
        else
            if ! sed -i '' "s|SaysGM(0x[0-9a-fA-F]\{40\})|SaysGM($contract_address)|" "$call_contract_file"; then
                warn "正则替换失败，尝试占位符替换..."
                if ! sed -i '' "s|ADDRESS_TO_GM|$contract_address|" "$call_contract_file"; then
                    error "更新 CallContract.s.sol 中的合约地址失败，请检查文件内容或权限：$call_contract_file"
                fi
            fi
            info "✅ 已成功更新 CallContract.s.sol 中的合约地址为 $contract_address"
        fi
        if ! grep -q "SaysGM($contract_address)" "$call_contract_file"; then
            error "CallContract.s.sol 未正确更新合约地址，请检查文件：$call_contract_file"
        fi
        info "正在调用合约..."
        call_log=$(mktemp)
        attempt=1
        while true; do
            info "尝试调用合约 （第 $attempt 次）..."
            if PRIVATE_KEY="$PRIVATE_KEY" forge script "$call_contract_file" --broadcast --rpc-url "$RPC_URL" > "$call_log" 2>&1; then
                info "✅ 合约调用成功！输出如下："
                cat "$call_log"
                break
            else
                warn "合约调用失败，详细信息如下：\n$(cat "$call_log")\n正在重试..."
                sleep 10
            fi
            ((attempt++))
        done
        rm -f "$call_log"
    else
        warn "未找到有效合约地址，请检查部署日志或手动验证。"
    fi
    rm -f "$deploy_log"

    echo "[10/15] ✅ 部署完成！使用 \`docker ps\` 查看节点状态。" | tee -a "$log_file"
    info "请检查日志：docker logs infernet-node"
    info "下一步：可运行 'forge script script/CallContract.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY' 来再次调用合约。"
    exit 0
fi

echo "[9/15] 🧠 开始部署..." | tee -a "$log_file"

echo "[10/15] 📁 克隆仓库..." | tee -a "$log_file"
if [ "$full_deploy" = "true" ] || [ ! -d "$HOME/infernet-container-starter" ]; then
    if [ -d "$HOME/infernet-container-starter" ]; then
        info "目录 $HOME/infernet-container-starter 已存在，正在删除..."
        rm -rf "$HOME/infernet-container-starter" || error "删除 $HOME/infernet-container-starter 失败，请检查权限。"
    fi
    while true; do
        if git clone https://github.com/ritual-net/infernet-container-starter "$HOME/infernet-container-starter"; then
            info "仓库克隆成功。"
            break
        else
            warn "克隆仓库失败，正在重试..."
            sleep 10
        fi
    done
else
    info "使用现有目录 $HOME/infernet-container-starter 继续部署..."
fi
cd "$HOME/infernet-container-starter" || error "无法进入 $HOME/infernet-container-starter 目录。"

echo "[11/15] 📦 拉取 hello-world 容器..." | tee -a "$log_file"
while true; do
    if curl -s --connect-timeout 5 https://registry-1.docker.io/ > /dev/null; then
        break
    else
        warn "无法连接到 Docker Hub，正在重试..."
        sleep 10
    fi
done
attempt=1
while true; do
    info "尝试拉取 ritualnetwork/hello-world-infernet:latest （第 $attempt 次）..."
    if docker pull ritualnetwork/hello-world-infernet:latest; then
        info "镜像拉取成功。"
        break
    else
        warn "拉取 hello-world 容器失败，正在重试..."
        sleep 10
    fi
    ((attempt++))
done

echo "[12/15] 🛠️ 写入项目配置 config.json..." | tee -a "$log_file"
if [ ! -d "$HOME/infernet-container-starter/deploy" ]; then
    mkdir -p "$HOME/infernet-container-starter/deploy" || error "创建 deploy 目录失败。"
fi
if [ -d "$HOME/infernet-container-starter/deploy/config.json" ]; then
    info "检测到 deploy/config.json 是一个目录，正在删除..."
    rm -rf "$HOME/infernet-container-starter/deploy/config.json" || error "删除 deploy/config.json 目录失败。"
fi
cat <<EOF > "$HOME/infernet-container-starter/deploy/config.json"
{
  "log_path": "infernet_node.log",
  "server": {
    "port": 4001,
    "rate_limit": { "num_requests": 100, "period": 100 }
  },
  "chain": {
    "enabled": true,
    "trail_head_blocks": 3,
    "rpc_url": "$RPC_URL",
    "registry_address": "0x3B1554f346DFe5c482Bb4BA31b880c1C18412170",
    "wallet": {
      "max_gas_limit": 4000000,
      "private_key": "$PRIVATE_KEY",
      "allowed_sim_errors": []
    },
    "snapshot_sync": {
      "sleep": 3,
      "batch_size": 10,
      "starting_sub_id": 262500,
      "sync_period": 30,
      "retry_delay": 60
    }
  },
  "startup_wait": 1.0,
  "redis": { "host": "redis", "port": 6379 },
  "forward_stats": true,
  "containers": [{
    "id": "hello-world",
    "image": "ritualnetwork/hello-world-infernet:latest",
    "external": true,
    "port": "5001",
    "allowed_delegate_addresses": [],
    "allowed_addresses": [],
    "allowed_ips": [],
    "command": "--bind=0.0.0.0:5001 --workers=2",
    "env": {},
    "volumes": [],
    "accepted_payments": {},
    "generates_proofs": false
  }]
}
EOF
if ! jq . "$HOME/infernet-container-starter/deploy/config.json" > /dev/null; then
    error "config.json 格式无效，请检查文件内容。"
fi
if ! cp "$HOME/infernet-container-starter/deploy/config.json" "$HOME/infernet-container-starter/projects/hello-world/container/config.json"; then
    error "复制 config.json 到 projects/hello-world/container 失败。"
fi

echo "[13/15] 🛠️ 更新 docker-compose.yaml..." | tee -a "$log_file"
cat <<'EOF' > "$HOME/infernet-container-starter/deploy/docker-compose.yaml"
services:
  node:
    image: ritualnetwork/infernet-node:1.4.0
    ports: [ "0.0.0.0:4001:4000" ]
    volumes:
      - ./config.json:/app/config.json
      - node-logs:/logs
      - /var/run/docker.sock:/var/run/docker.sock
    tty: true
    networks: [ network ]
    depends_on: [ redis ]
    restart: on-failure
    extra_hosts: [ "host.docker.internal:host-gateway" ]
    stop_grace_period: 1m
    container_name: infernet-node
  redis:
    image: redis:7.4.0
    ports: [ "6379:6379" ]
    volumes:
      - ./redis.conf:/usr/local/etc/redis/redis.conf
      - redis-data:/data
    networks: [ network ]
    restart: on-failure
    container_name: infernet-redis
  fluentbit:
    image: fluent/fluent-bit:3.1.4
    expose: [ "24224" ]
    environment: [ "FLUENTBIT_CONFIG_PATH=/fluent-bit/etc/fluent-bit.conf" ]
    volumes:
      - ./fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf
      - /var/log:/var/log:ro
    networks: [ network ]
    restart: on-failure
    container_name: infernet-fluentbit
networks:
  network:
volumes:
  node-logs:
  redis-data:
EOF

# 全新部署流程启动容器用后台模式
if [ "$full_deploy" = "true" ]; then
    echo "[14/15] 🐳 启动 Docker 容器..." | tee -a "$log_file"
    attempt=1
    while true; do
        info "尝试启动 Docker 容器 （第 $attempt 次）..."
        if docker-compose -f "$HOME/infernet-container-starter/deploy/docker-compose.yaml" up -d; then
            info "Docker 容器启动成功。"
            # 启动日志后台保存
            (docker logs -f infernet-node > "$HOME/infernet-deployment.log" 2>&1 &)
            break
        else
            warn "启动 Docker 容器失败，正在重试..."
            sleep 10
        fi
        ((attempt++))
    done
fi

echo "[15/15] 🛠️ 安装 Foundry..." | tee -a "$log_file"
if ! command -v forge &> /dev/null; then
    info "Foundry 未安装，正在安装..."
    while true; do
        if curl -L https://foundry.paradigm.xyz | bash; then
            echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> ~/.zshrc
            source ~/.zshrc
            if foundryup; then
                info "Foundry 安装成功，forge 版本：$(forge --version)"
                break
            else
                warn "Foundry 更新失败，正在重试..."
                sleep 10
            fi
        else
            warn "Foundry 安装失败，正在重试..."
            sleep 10
        fi
    done
else
    info "Foundry 已安装，forge 版本：$(forge --version)"
fi

echo "[16/16] 📚 安装 Forge 库..." | tee -a "$log_file"
cd "$HOME/infernet-container-starter/projects/hello-world/contracts"
if ! rm -rf lib/forge-std lib/infernet-sdk; then
    warn "清理旧 Forge 库失败，继续安装..."
fi
while true; do
    if forge install foundry-rs/forge-std; then
        info "forge-std 安装成功。"
        break
    else
        warn "安装 forge-std 失败，正在重试..."
        sleep 10
    fi
done
while true; do
    if forge install ritual-net/infernet-sdk; then
        info "infernet-sdk 安装成功。"
        break
    else
        warn "安装 infernet-sdk 失败，正在重试..."
        sleep 10
    fi
done

echo "[17/17] 🔧 写入部署脚本..." | tee -a "$log_file"
cat <<'EOF' > script/Deploy.s.sol
// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.13;
import {Script, console2} from "forge-std/Script.sol";
import {SaysGM} from "../src/SaysGM.sol";

contract Deploy is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        address deployerAddress = vm.addr(deployerPrivateKey);
        console2.log("Loaded deployer: ", deployerAddress);
        address registry = 0x3B1554f346DFe5c482Bb4BA31b880c1C18412170;
        SaysGM saysGm = new SaysGM(registry);
        console2.log("Deployed SaysGM: ", address(saysGm));
        vm.stopBroadcast();
    }
}
EOF

echo "[18/18] 📦 写入 Makefile..." | tee -a "$log_file"
cat <<'EOF' > "$HOME/infernet-container-starter/projects/hello-world/contracts/Makefile"
.PHONY: deploy
sender := $PRIVATE_KEY
RPC_URL := $RPC_URL
deploy:
    @PRIVATE_KEY=$(sender) forge script script/Deploy.s.sol:Deploy --broadcast --rpc-url $(RPC_URL)
EOF

echo "[19/19] 🚀 开始部署合约..." | tee -a "$log_file"
cd "$HOME/infernet-container-starter/projects/hello-world/contracts" || error "无法进入 $HOME/infernet-container-starter/projects/hello-world/contracts 目录"
attempt=1
while true; do
    info "尝试检查 RPC URL 连通性 （第 $attempt 次）..."
    if curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_chainId","id":1}' "$RPC_URL" | jq -e '.result' > /dev/null; then
        info "RPC URL 连通性检查成功。"
        break
    else
        warn "RPC URL 无法连接，正在重试..."
        sleep 10
    fi
    ((attempt++))
done
warn "请确保私钥有足够余额以支付 gas 费用。"
deploy_log=$(mktemp)
attempt=1
while true; do
    info "尝试部署合约 （第 $attempt 次）..."
    if PRIVATE_KEY="$PRIVATE_KEY" forge script script/Deploy.s.sol:Deploy --broadcast --rpc-url "$RPC_URL" > "$deploy_log" 2>&1; then
        info "🔺 合约部署成功！✅ 输出如下："
        cat "$deploy_log"
        break
    else
        warn "合约部署失败，详细信息如下：\n$(cat "$deploy_log")\n正在重试..."
        sleep 10
    fi
    ((attempt++))
done
contract_address=$(grep -i "Deployed SaysGM" "$deploy_log" | awk '{print $NF}' | head -n 1)
if [ -n "$contract_address" ] && [[ "$contract_address" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    info "部署的 SaysGM 合约地址：$contract_address"
    info "请保存此合约地址，用于后续调用！"
    call_contract_file="$HOME/infernet-container-starter/projects/hello-world/contracts/script/CallContract.s.sol"
    if [ ! -f "$call_contract_file" ]; then
        warn "未找到 CallContract.s.sol，创建默认文件..."
        cat <<'EOF' > "$call_contract_file"
// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.13;
import {Script, console2} from "forge-std/Script.sol";
import {SaysGM} from "../src/SaysGM.sol";

contract CallContract is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        SaysGM saysGm = SaysGM(ADDRESS_TO_GM);
        saysGm.sayGM("Hello, Infernet!");
        console2.log("Called sayGM function");
        vm.stopBroadcast();
    }
}
EOF
        if ! sed -i '' "s|ADDRESS_TO_GM|$contract_address|" "$call_contract_file"; then
            error "更新 CallContract.s.sol 中的合约地址失败，请检查文件内容或权限：$call_contract_file"
        fi
        info "✅ 已成功创建并更新 CallContract.s.sol 中的合约地址为 $contract_address"
    else
        if ! sed -i '' "s|SaysGM(0x[0-9a-fA-F]\{40\})|SaysGM($contract_address)|" "$call_contract_file"; then
            warn "正则替换失败，尝试占位符替换..."
            if ! sed -i '' "s|ADDRESS_TO_GM|$contract_address|" "$call_contract_file"; then
                error "更新 CallContract.s.sol 中的合约地址失败，请检查文件内容或权限：$call_contract_file"
            fi
        fi
        info "✅ 已成功更新 CallContract.s.sol 中的合约地址为 $contract_address"
    fi
    if ! grep -q "SaysGM($contract_address)" "$call_contract_file"; then
        error "CallContract.s.sol 未正确更新合约地址，请检查文件：$call_contract_file"
    fi
    info "正在调用合约..."
    call_log=$(mktemp)
    attempt=1
    while true; do
        info "尝试调用合约 （第 $attempt 次）..."
        if PRIVATE_KEY="$PRIVATE_KEY" forge script "$call_contract_file" --broadcast --rpc-url "$RPC_URL" > "$call_log" 2>&1; then
            info "✅ 合约调用成功！输出如下："
            cat "$call_log"
            break
        else
            warn "合约调用失败，详细信息如下：\n$(cat "$call_log")\n正在重试..."
            sleep 10
        fi
        ((attempt++))
    done
    rm -f "$call_log"
else
    warn "未找到有效合约地址，请检查部署日志或手动验证。"
fi
rm -f "$deploy_log"

echo "[20/20] ✅ 部署完成！容器已在前台启动。" | tee -a "$log_file"
info "容器正在前台运行，按 Ctrl+C 可停止容器"
info "容器启动后，脚本将自动退出"

# ========== 自动跳过missing trie node区块并重启节点 ===========
monitor_and_skip_trie_error() {
    LOG_FILE="$HOME/infernet-deployment.log"
    CONFIG_FILE="$HOME/infernet-container-starter/deploy/config.json"
    COMPOSE_DIR="$HOME/infernet-container-starter/deploy"
    LAST_BATCH_FILE="/tmp/ritual_last_batch.txt"

    info "启动missing trie node自动跳过守护进程..."
    while true; do
        # 检查日志中是否有新的 missing trie node 错误
        line=$(grep "missing trie node" "$LOG_FILE" | tail -1)
        if [[ -n "$line" ]]; then
            # 提取 batch 区间
            batch=$(echo "$line" | grep -oE "batch=\\([0-9]+, [0-9]+\\)")
            if [[ $batch =~ ([0-9]+),\ ([0-9]+) ]]; then
                start=${BASH_REMATCH[1]}
                end=${BASH_REMATCH[2]}
                new_start=$((end + 1))
                # 检查是否已处理过该batch
                if [[ -f "$LAST_BATCH_FILE" ]] && grep -q "$batch" "$LAST_BATCH_FILE"; then
                    sleep 30
                    continue
                fi
                echo "$batch" > "$LAST_BATCH_FILE"
                warn "检测到missing trie node错误区块，自动跳过到 $new_start 并重启节点..."
                # 修改 config.json
                jq ".chain.snapshot_sync.starting_sub_id = $new_start" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                # 重启docker服务
                cd "$COMPOSE_DIR"
                docker-compose restart node
                sleep 60
            fi
        fi
        sleep 30
    done
}

# 主流程一开始就启动守护进程（后台运行）
nohup bash -c 'monitor_and_skip_trie_error' >/dev/null 2>&1 &
