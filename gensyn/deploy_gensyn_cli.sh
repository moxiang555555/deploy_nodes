#!/bin/bash

set -e
set -o pipefail

echo "🚀 Starting one-click RL-Swarm environment deployment..."

# ----------- Architecture Check ----------- 
if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "❌ This script only supports macOS with Apple Silicon (M1/M2/M3/M4). Exiting."
  exit 1
fi

# ----------- /etc/hosts Patch ----------- 
echo "🔧 Checking /etc/hosts configuration..."
if ! grep -q "raw.githubusercontent.com" /etc/hosts; then
  echo "📝 Writing GitHub accelerated Hosts entries..."
  sudo tee -a /etc/hosts > /dev/null <<EOL
199.232.68.133 raw.githubusercontent.com
199.232.68.133 user-images.githubusercontent.com
199.232.68.133 avatars2.githubusercontent.com
199.232.68.133 avatars1.githubusercontent.com
EOL
else
  echo "✅ Hosts are already configured."
fi

# ----------- Install Homebrew ----------- 
echo "🍺 Checking Homebrew..."
if ! command -v brew &>/dev/null; then
  echo "📥 Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
else
  echo "✅ Homebrew 已安装，跳过安装。"
fi

# ----------- Configure Brew Environment Variable ----------- 
BREW_ENV='eval "$(/opt/homebrew/bin/brew shellenv)"'
if ! grep -q "$BREW_ENV" ~/.zshrc; then
  echo "$BREW_ENV" >> ~/.zshrc
fi
eval "$(/opt/homebrew/bin/brew shellenv)"

# ----------- Install Dependencies ----------- 
echo "📦 检查并安装 Node.js, Python3.12, curl, screen, git, yarn..."
for dep in node python3.12 curl screen git yarn; do
  if ! command -v $dep &>/dev/null; then
    echo "📥 安装 $dep..."
    brew install $dep
  else
    echo "✅ $dep 已安装，跳过安装。"
  fi
done

# ----------- Set Python 3.12 Alias ----------- 
PYTHON_ALIAS="# Python3.12 Environment Setup"
if ! grep -q "$PYTHON_ALIAS" ~/.zshrc; then
  cat << 'EOF' >> ~/.zshrc

# Python3.12 Environment Setup
if [[ $- == *i* ]]; then
  alias python="/opt/homebrew/bin/python3.12"
  alias python3="/opt/homebrew/bin/python3.12"
  alias pip="/opt/homebrew/bin/pip3.12"
  alias pip3="/opt/homebrew/bin/pip3.12"
fi
EOF
fi

source ~/.zshrc || true

# ----------- Clone Repo ----------- 
if [[ -d "rl-swarm-0.5.3" ]]; then
  echo "⚠️ 检测到已存在目录 'rl-swarm-0.5.3'。"
  read -p "是否覆盖（删除后重新克隆）该目录？(y/n): " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "🗑️ 正在删除旧目录..."
    rm -rf rl-swarm-0.5.3
    echo "📥 正在克隆 rl-swarm 仓库..."
    git clone https://github.com/readyName/rl-swarm-0.5.3.git
  else
    echo "❌ 跳过克隆，继续后续流程。"
  fi
else
  echo "📥 正在克隆 rl-swarm 仓库..."
  git clone https://github.com/readyName/rl-swarm-0.5.3.git
fi

# ----------- 复制 user 关键文件 -----------
USER_SRC="$HOME/rl-swarm-0.5/user"
KEY_SRC="$USER_SRC/keys/swarm.pem"
KEY_DST="rl-swarm-0.5.3/swarm.pem"
APIKEY_SRC="$USER_SRC/modal-login/userApiKey.json"
APIDATA_SRC="$USER_SRC/modal-login/userData.json"
MODAL_DST="rl-swarm-0.5.3/modal-login/temp-data"

# 复制 keys/swarm.pem
if [ -f "$KEY_SRC" ]; then
  cp "$KEY_SRC" "$KEY_DST" && echo "✅ 复制成功：swarm.pem" || echo "⚠️ 复制失败：swarm.pem"
else
  echo "⚠️ 缺少文件：$KEY_SRC，请手动补齐。"
fi

# 复制 modal-login 下两个文件
mkdir -p "$MODAL_DST"
for src in "$APIKEY_SRC" "$APIDATA_SRC"; do
  fname=$(basename "$src")
  if [ -f "$src" ]; then
    cp "$src" "$MODAL_DST/$fname" && echo "✅ 复制成功：$fname" || echo "⚠️ 复制失败：$fname"
  else
    echo "⚠️ 缺少文件：$src，请手动补齐。"
  fi
done
# 无论文件是否缺失，始终继续执行后续脚本

# ----------- Clean Port 3000 ----------- 
echo "🧹 Cleaning up port 3000..."
pid=$(lsof -ti:3000) && [ -n "$pid" ] && kill -9 $pid && echo "✅ Killed: $pid" || echo "✅ Port 3000 is free."

# ----------- 进入rl-swarm-0.5.3目录并执行go.sh -----------
cd rl-swarm-0.5.3 || { echo "❌ 进入 rl-swarm-0.5.3 目录失败"; exit 1; }
chmod +x go.sh
./go.sh
