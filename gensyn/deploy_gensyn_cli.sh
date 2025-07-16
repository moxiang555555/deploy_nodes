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

# ----------- 克隆前备份关键文件（优先0.5.3，无则0.5） -----------
TMP_USER_FILES="/tmp/rl-swarm-user-files"
mkdir -p "$TMP_USER_FILES"

BACKUP_SRC=""
if [[ -d "rl-swarm-0.5.3" ]]; then
  echo "🔍 检测到已存在 rl-swarm-0.5.3，备份关键文件到临时目录..."
  BACKUP_SRC="rl-swarm-0.5.3"
elif [[ -d "$HOME/rl-swarm-0.5/user" ]]; then
  echo "🔍 未检测到 rl-swarm-0.5.3，尝试从 $HOME/rl-swarm-0.5/user 备份关键文件..."
  BACKUP_SRC="$HOME/rl-swarm-0.5/user"
fi

if [[ -n "$BACKUP_SRC" ]]; then
  # swarm.pem
  if [ -f "$BACKUP_SRC/swarm.pem" ]; then
    cp "$BACKUP_SRC/swarm.pem" "$TMP_USER_FILES/swarm.pem" && echo "✅ 已备份 swarm.pem"
  elif [ -f "$BACKUP_SRC/keys/swarm.pem" ]; then
    cp "$BACKUP_SRC/keys/swarm.pem" "$TMP_USER_FILES/swarm.pem" && echo "✅ 已备份 keys/swarm.pem"
  fi
  # userApiKey.json
  if [ -f "$BACKUP_SRC/modal-login/temp-data/userApiKey.json" ]; then
    cp "$BACKUP_SRC/modal-login/temp-data/userApiKey.json" "$TMP_USER_FILES/userApiKey.json" && echo "✅ 已备份 userApiKey.json"
  elif [ -f "$BACKUP_SRC/modal-login/userApiKey.json" ]; then
    cp "$BACKUP_SRC/modal-login/userApiKey.json" "$TMP_USER_FILES/userApiKey.json" && echo "✅ 已备份 userApiKey.json"
  fi
  # userData.json
  if [ -f "$BACKUP_SRC/modal-login/temp-data/userData.json" ]; then
    cp "$BACKUP_SRC/modal-login/temp-data/userData.json" "$TMP_USER_FILES/userData.json" && echo "✅ 已备份 userData.json"
  elif [ -f "$BACKUP_SRC/modal-login/userData.json" ]; then
    cp "$BACKUP_SRC/modal-login/userData.json" "$TMP_USER_FILES/userData.json" && echo "✅ 已备份 userData.json"
  fi
else
  echo "⚠️ 未检测到 rl-swarm-0.5.3 或 $HOME/rl-swarm-0.5/user，关键文件将缺失，请后续手动补齐。"
fi

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

# ----------- 复制临时目录中的 user 关键文件 -----------
KEY_DST="rl-swarm-0.5.3/swarm.pem"
MODAL_DST="rl-swarm-0.5.3/modal-login/temp-data"
mkdir -p "$MODAL_DST"

if [ -f "$TMP_USER_FILES/swarm.pem" ]; then
  cp "$TMP_USER_FILES/swarm.pem" "$KEY_DST" && echo "✅ 恢复 swarm.pem 到新目录" || echo "⚠️ 恢复 swarm.pem 失败"
else
  echo "⚠️ 临时目录缺少 swarm.pem，如有需要请手动补齐。"
fi

for fname in userApiKey.json userData.json; do
  if [ -f "$TMP_USER_FILES/$fname" ]; then
    cp "$TMP_USER_FILES/$fname" "$MODAL_DST/$fname" && echo "✅ 恢复 $fname 到新目录" || echo "⚠️ 恢复 $fname 失败"
  else
    echo "⚠️ 临时目录缺少 $fname，如有需要请手动补齐。"
  fi
  
done

# ----------- 生成桌面可双击运行的 .command 文件 -----------
PROJECT_DIR="$HOME/rl-swarm-0.5.3"
DESKTOP_DIR="$HOME/Desktop"

for script in gensyn_cli.sh nexus.sh ritual.sh wai.sh startAll.sh; do
  cmd_name="${script%.sh}.command"
  cat > "$DESKTOP_DIR/$cmd_name" <<EOF
#!/bin/bash
cd "$PROJECT_DIR"
./$script
EOF
  chmod +x "$DESKTOP_DIR/$cmd_name"
done

echo "✅ 已在桌面生成可双击运行的 .command 文件。"

# ----------- Clean Port 3000 ----------- 
echo "🧹 Cleaning up port 3000..."
pid=$(lsof -ti:3000) && [ -n "$pid" ] && kill -9 $pid && echo "✅ Killed: $pid" || echo "✅ Port 3000 is free."

# ----------- 进入rl-swarm-0.5.3目录并执行go.sh -----------
cd rl-swarm-0.5.3 || { echo "❌ 进入 rl-swarm-0.5.3 目录失败"; exit 1; }
chmod +x gensyn_cli.sh
./gensyn_cli.sh
