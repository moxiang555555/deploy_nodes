#!/bin/bash
set -e

# ===== 用户与目录（用真实登录用户，而不是 root）=====
TARGET_USER="${SUDO_USER:-$USER}"
if [[ "$(uname -s)" == "Darwin" ]]; then
  # macOS
  HOME_DIR="$HOME"
  OS_TYPE="macos"
  
  # 在 macOS 上检查是否以 root 身份运行
  if [[ "$EUID" -eq 0 ]]; then
    echo "错误：在 macOS 上请不要以 root 身份运行此脚本"
    echo "请以普通用户身份运行：./deploy_ubuntu.sh"
    exit 1
  fi
else
  # Linux
  HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  [ -z "$HOME_DIR" ] && HOME_DIR="$HOME"
  OS_TYPE="linux"
fi
AZTEC_DIR="$HOME_DIR/aztec"                 # 配置目录
DATA_DIR="$HOME_DIR/.aztec/testnet/data"    # CLI 使用 testnet

# 检查操作系统
if [[ "$OS_TYPE" == "macos" ]]; then
  echo "检测到 macOS 系统"
elif [[ -f /etc/os-release ]]; then
  . /etc/os-release
  if [[ "$ID" == "ubuntu" ]] || [[ "$ID" == "debian" ]]; then
    echo "检测到 Ubuntu/Debian 系统"
  else
    echo "不是 Ubuntu 或 Debian 系统，退出安装。"
    exit 1
  fi
else
  echo "不支持的操作系统，退出安装。"
  exit 1
fi

# 系统更新和依赖安装
if [[ "$OS_TYPE" == "macos" ]]; then
  # macOS
  echo "正在检查 Homebrew..."
  if ! command -v brew &> /dev/null; then
    echo "安装 Homebrew..."
    # 确保不以 root 身份运行
    if [[ "$EUID" -eq 0 ]]; then
      echo "错误：请不要以 root 身份运行此脚本"
      echo "请以普通用户身份运行：./deploy_ubuntu.sh"
      exit 1
    fi
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # 配置 Homebrew 环境变量
    if [[ -f /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
      echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
    elif [[ -f /usr/local/bin/brew ]]; then
      eval "$(/usr/local/bin/brew shellenv)"
      echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.zshrc
    fi
  fi
  
  echo "正在安装必要的依赖包..."
  # 确保以普通用户身份运行 brew
  if [[ "$EUID" -eq 0 ]]; then
    echo "错误：请不要以 root 身份运行此脚本"
    echo "请以普通用户身份运行：./deploy_ubuntu.sh"
    exit 1
  fi
  brew update || true
  brew install curl git wget jq make gcc automake autoconf tmux htop pkg-config openssl protobuf || {
    echo "部分包安装失败，尝试继续执行..."
  }
else
  # Linux
  echo "正在更新系统..."
  sudo apt update -y && sudo apt upgrade -y

  echo "正在安装必要的依赖包..."
  sudo apt install -y curl iptables build-essential git wget lz4 jq make gcc nano automake autoconf tmux htop nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip
fi

# Docker 安装
if [[ "$OS_TYPE" == "macos" ]]; then
  # macOS - 检查 Docker Desktop
  echo "检查 Docker Desktop..."
  if ! command -v docker &> /dev/null; then
    echo "请安装 Docker Desktop for Mac"
    echo "访问: https://docs.docker.com/desktop/setup/install/mac-install/"
    echo "安装后重新运行此脚本"
    exit 1
  fi
  
  # 检查 Docker 是否运行
  if ! docker info > /dev/null 2>&1; then
    echo "Docker Desktop 已安装但未运行"
    echo "请启动 Docker Desktop 后重新运行此脚本"
    exit 1
  fi
  
  echo "Docker Desktop 已就绪"
else
  # Linux
  echo "正在删除已有的 Docker 相关包..."
  for pkg in docker.io docker-doc docker-compose podman-docker containerd runc docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin; do
    sudo apt-get remove --purge -y $pkg 2>/dev/null || true
  done

  echo "正在清理不需要的包..."
  sudo apt-get autoremove -y
  sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg

  echo "正在更新 apt 源..."
  sudo apt-get update

  echo "正在安装 Docker 安装依赖..."
  sudo apt-get install -y ca-certificates curl gnupg lsb-release
  sudo install -m 0755 -d /etc/apt/keyrings

  echo "正在设置 Docker 官方源..."
  . /etc/os-release
  repo_url="https://download.docker.com/linux/$ID"
  curl -fsSL "$repo_url/gpg" | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] $repo_url $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  echo "正在安装 Docker..."
  sudo apt update -y && sudo apt upgrade -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# Docker 配置和测试
if [[ "$OS_TYPE" == "macos" ]]; then
  # macOS - Docker Desktop 不需要组配置
  echo "测试 Docker Desktop..."
  if docker run --rm hello-world >/dev/null 2>&1; then
    echo "• Docker Desktop 已就绪 ✅"
  else
    echo "Docker Desktop 测试失败，请检查 Docker Desktop 是否正常运行"
    exit 1
  fi
else
  # Linux
  echo "正在把用户 $TARGET_USER 加入 docker 组..."
  sudo groupadd -f docker
  sudo usermod -aG docker "$TARGET_USER"
  sudo systemctl enable docker >/dev/null 2>&1 || true
  sudo systemctl restart docker

  # 尝试立刻在 docker 组上下文中使用 docker；不行则给临时 ACL 以便继续脚本
  if ! sudo -H -u "$TARGET_USER" sg docker -c 'docker ps >/dev/null 2>&1'; then
    echo "当前会话尚未继承 docker 组，设置临时 ACL 让本次脚本立刻可用..."
    sudo apt-get update -y >/dev/null 2>&1 || true
    sudo apt-get install -y acl >/dev/null 2>&1 || true
    sudo setfacl -m "u:${TARGET_USER}:rw" /var/run/docker.sock || true
  fi

  # 测试 Docker（以目标用户 + docker 组上下文）
  echo "正在测试 Docker 安装（拉取/运行 hello-world）..."
  sudo -H -u "$TARGET_USER" sg docker -c 'docker run --rm hello-world' && echo -e "\u2022 Docker 已安装成功 ✅"
fi

# ===== 以目标用户身份安装 Aztec CLI（安装到该用户 HOME）=====
echo "正在安装 Aztec CLI（用户：$TARGET_USER）..."
if [[ "$OS_TYPE" == "macos" ]]; then
  # macOS - 直接以当前用户安装
  echo "安装 Aztec CLI..."
  bash <(curl -s https://install.aztec.network) <<< "y"
  
  # 配置 PATH
  if ! grep -q ".aztec/bin" ~/.zshrc; then
    echo 'export PATH="$HOME/.aztec/bin:$PATH"' >> ~/.zshrc
  fi
  if ! grep -q ".aztec/bin" ~/.bashrc; then
    echo 'export PATH="$HOME/.aztec/bin:$PATH"' >> ~/.bashrc
  fi
  
  # 加载环境变量
  export PATH="$HOME/.aztec/bin:$PATH"
  
  # 验证安装
  if command -v aztec >/dev/null 2>&1; then
    echo "Aztec CLI 安装成功: $(aztec -V)"
  else
    echo "Aztec CLI 安装失败"
    exit 1
  fi
else
  # Linux - 使用 sudo 以目标用户身份安装
  sudo -H -u "$TARGET_USER" bash -lc '
    echo "安装 Aztec CLI..."
    bash <(curl -s https://install.aztec.network) <<< "y"
    if ! grep -q ".aztec/bin" ~/.bashrc; then
      echo '\''export PATH="$HOME/.aztec/bin:$PATH"'\'' >> ~/.bashrc
    fi
    export PATH="$HOME/.aztec/bin:$PATH"
    command -v aztec >/dev/null && aztec -V || { echo "Aztec CLI 未就绪"; exit 1; }
  '
fi
echo "Aztec CLI 安装完成！"

echo "安装完成！"

# 创建 Aztec 配置目录
echo "创建 Aztec 配置目录 $AZTEC_DIR..."
if [[ "$OS_TYPE" == "macos" ]]; then
  # macOS - 直接创建
  mkdir -p "$AZTEC_DIR" "$DATA_DIR"
else
  # Linux - 使用 sudo 创建并设置属主
  sudo -u "$TARGET_USER" mkdir -p "$AZTEC_DIR" "$DATA_DIR"
  sudo chown -R "$TARGET_USER":"$TARGET_USER" "$AZTEC_DIR" "$DATA_DIR"
fi

# 配置防火墙（仅 Linux）
if [[ "$OS_TYPE" == "linux" ]]; then
  echo "配置防火墙，开放端口 22/40400/8080..."
  sudo apt install -y ufw >/dev/null 2>&1 || true
  sudo ufw allow 22/tcp
  sudo ufw allow ssh
  sudo ufw allow 40400/tcp
  sudo ufw allow 40400/udp
  sudo ufw allow 8080/tcp
  sudo ufw --force enable
  sudo ufw reload
else
  echo "macOS 系统，跳过防火墙配置（请手动配置 macOS 防火墙）"
fi

# 获取用户输入
echo "获取 RPC URL 和其他配置的说明："
echo "  - L1 执行客户端（EL）RPC URL（例如：Alchemy/Infura/drpc 的 Sepolia RPC）"
echo "  - L1 共识（CL）RPC URL（例如：drpc/ankr 的 Beacon RPC）"
echo "  - COINBASE：接收奖励的以太坊地址（0x...）"
read -p " L1 执行客户端（EL）RPC URL： " ETH_RPC
read -p " L1 共识（CL）RPC URL： " CONS_RPC
read -p " 验证者私钥（0x 开头的 64 位十六进制）： " VALIDATOR_PRIVATE_KEY
read -p " COINBASE 地址（0x 开头的 40 位十六进制）： " COINBASE
BLOB_URL=""

# 获取公共 IP（优先 IPv4）
echo "获取公共 IP..."
PUBLIC_IP="$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com || echo 127.0.0.1)"
echo "    → $PUBLIC_IP"

# 生成配置文件
echo "生成 $AZTEC_DIR/.env 文件..."
if [[ "$OS_TYPE" == "macos" ]]; then
  # macOS - 直接生成
  cat > "$AZTEC_DIR/.env" <<ENVEOF
ETHEREUM_HOSTS="$ETH_RPC"
L1_CONSENSUS_HOST_URLS="$CONS_RPC"
P2P_IP="$PUBLIC_IP"
VALIDATOR_PRIVATE_KEY="$VALIDATOR_PRIVATE_KEY"
COINBASE="$COINBASE"
DATA_DIRECTORY="$DATA_DIR"
LOG_LEVEL="debug"
ENVEOF
  chmod 600 "$AZTEC_DIR/.env"
else
  # Linux - 使用 sudo 生成
  sudo -u "$TARGET_USER" bash -lc "cat > '$AZTEC_DIR/.env' <<'ENVEOF'
ETHEREUM_HOSTS=\"$ETH_RPC\"
L1_CONSENSUS_HOST_URLS=\"$CONS_RPC\"
P2P_IP=\"$PUBLIC_IP\"
VALIDATOR_PRIVATE_KEY=\"$VALIDATOR_PRIVATE_KEY\"
COINBASE=\"$COINBASE\"
DATA_DIRECTORY=\"$DATA_DIR\"
LOG_LEVEL=\"debug\"
ENVEOF"
  sudo chmod 600 "$AZTEC_DIR/.env"
fi

# 生成启动脚本
echo "生成 $AZTEC_DIR/aztec_start.sh 文件..."
if [[ "$OS_TYPE" == "macos" ]]; then
  # macOS - 直接生成
  cat > "$AZTEC_DIR/aztec_start.sh" <<SHEOF
#!/usr/bin/env bash
set -e
source "$AZTEC_DIR/.env"
export PATH="\$HOME/.aztec/bin:\$PATH"

exec aztec start --node --archiver --sequencer \
  --network testnet \
  --l1-rpc-urls "\$ETHEREUM_HOSTS"  \
  --l1-consensus-host-urls "\$L1_CONSENSUS_HOST_URLS" \
  --sequencer.validatorPrivateKeys "\$VALIDATOR_PRIVATE_KEY" \
  --sequencer.coinbase "\$COINBASE" \
  --p2p.p2pIp "\$P2P_IP"
SHEOF
  chmod +x "$AZTEC_DIR/aztec_start.sh"
else
  # Linux - 使用 sudo 生成
  sudo -u "$TARGET_USER" bash -lc "cat > '$AZTEC_DIR/aztec_start.sh' <<'SHEOF'
#!/usr/bin/env bash
set -e
source \"$AZTEC_DIR/.env\"
export PATH=\"\$HOME/.aztec/bin:\$PATH\"

exec aztec start --node --archiver --sequencer \
  --network testnet \
  --l1-rpc-urls \"\$ETHEREUM_HOSTS\"  \
  --l1-consensus-host-urls \"\$L1_CONSENSUS_HOST_URLS\" \
  --sequencer.validatorPrivateKeys \"\$VALIDATOR_PRIVATE_KEY\" \
  --sequencer.coinbase \"\$COINBASE\" \
  --p2p.p2pIp \"\$P2P_IP\"
SHEOF
chmod +x '$AZTEC_DIR/aztec_start.sh'"
fi

# 启动 Aztec 节点
echo "启动 Aztec 节点（前台）..."
echo "配置文件已生成在: $AZTEC_DIR"
echo "启动脚本: $AZTEC_DIR/aztec_start.sh"
echo ""
echo "请手动运行以下命令启动节点："
echo "cd $AZTEC_DIR && ./aztec_start.sh"
echo ""
echo "或者按 Ctrl+C 退出，稍后手动启动节点"

echo "安装并启动 Aztec 节点完成！"