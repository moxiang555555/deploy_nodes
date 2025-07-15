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
fi

# ----------- Configure Brew Environment Variable ----------- 
BREW_ENV='eval "$(/opt/homebrew/bin/brew shellenv)"'
if ! grep -q "$BREW_ENV" ~/.zshrc; then
  echo "$BREW_ENV" >> ~/.zshrc
fi
eval "$(/opt/homebrew/bin/brew shellenv)"

# ----------- Install Dependencies ----------- 
echo "📦 Installing Node.js, Python3.12, curl, screen, git, yarn..."
brew install node python@3.12 curl screen git yarn

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
if [[ -d "rl-swarm" ]]; then
  echo "⚠️ 'rl-swarm' directory already exists."
  read -p "Overwrite the existing directory? (y/n): " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    rm -rf rl-swarm
  else
    echo "❌ Cancelled."
    exit 1
  fi
fi

echo "📥 Cloning the rl-swarm repository..."
git clone https://github.com/readyName/rl-swarm-0.5.3.git

# ----------- Clean Port 3000 ----------- 
echo "🧹 Cleaning up port 3000..."
pid=$(lsof -ti:3000) && [ -n "$pid" ] && kill -9 $pid && echo "✅ Killed: $pid" || echo "✅ Port 3000 is free."

# ----------- Launch screen session and enter it ----------- 
echo "🖥️ Launching RL-Swarm in screen session..."

screen -S gensyn -d -m bash -c '
  cd rl-swarm || exit 1

  echo "🐍 Creating virtual environment..."
  /opt/homebrew/bin/python3.12 -m venv .venv

  source .venv/bin/activate

  echo "🔧 Setting PyTorch MPS env..."
  export PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0
  export PYTORCH_ENABLE_MPS_FALLBACK=1

  echo "🚀 Running RL-Swarm..."
  chmod +x run_rl_swarm.sh
  echo -e "y\nA\n0.5\nN" | ./run_rl_swarm.sh

  echo "✅ RL-Swarm launched."
  exec bash
'

# ----------- Auto-attach to the screen session ----------- 
sleep 2
echo "🔗 Attaching to screen session..."
screen -r gensyn