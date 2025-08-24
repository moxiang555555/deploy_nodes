#!/bin/bash

echo "🚀 开始安装 Dria (Ubuntu版本)..."

# 检查是否为Ubuntu系统
if ! grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
    echo "❌ 此脚本仅支持Ubuntu系统"
    exit 1
fi

# 更新系统包
echo "🔄 更新系统包..."
sudo apt update

# 安装基础依赖
echo "📦 安装基础依赖..."
sudo apt install -y curl wget git jq build-essential

# 检查并安装 Ollama
if command -v ollama &> /dev/null; then
    echo "✅ Ollama 已存在，跳过安装"
else
    echo "📥 正在安装 Ollama..."
    
    # 下载并安装Ollama
    curl -fsSL https://ollama.com/install.sh | sh
    
    if [ $? -eq 0 ]; then
        echo "✅ Ollama 安装完成！"
        
        # 启动Ollama服务
        echo "🚀 正在启动 Ollama 服务..."
        sudo systemctl enable ollama
        sudo systemctl start ollama
        
        # 等待服务启动
        echo "⏳ 等待 Ollama 服务启动..."
        sleep 5

        # 验证服务状态
        if sudo systemctl is-active --quiet ollama; then
            echo "✅ Ollama 服务已启动"
        else
            echo "⚠️ Ollama 服务启动失败，但继续安装 Dria..."
        fi
    else
        echo "❌ Ollama 安装失败，但继续安装 Dria..."
    fi
fi

echo ""
echo "📱 现在开始安装 Dria..."

# 检查 Dria 是否已安装
if command -v dkn-compute-launcher &> /dev/null; then
    echo "✅ Dria 已存在，跳过安装"
else
    # 使用官方安装脚本
    echo "📥 正在下载并安装 Dria..."
    curl -fsSL https://dria.co/launcher | bash
    
    # 重新加载 bash 配置
    echo "🔄 重新加载 shell 配置..."
    source ~/.bashrc
fi

echo "✅ Dria 安装完成！"
echo ""
echo "🔗 获取邀请码步骤："
echo "请在新的终端窗口中运行以下命令获取你的邀请码："
echo ""
echo "   dkn-compute-launcher referrals"
echo ""
echo "然后选择：Get referral code to refer someone"
echo ""
echo "请在新的终端窗口中运行以下命令更改端口："
echo ""
echo "   dkn-compute-launcher settings"
echo ""
echo "📝 全部设置完成后，请回到这里按回车键继续..."
read -p "按回车键继续..."

# 生成桌面启动文件
echo "📝 正在生成桌面启动文件..."

# 检查桌面目录
if [ -d "$HOME/Desktop" ]; then
    DESKTOP_DIR="$HOME/Desktop"
elif [ -d "$HOME/桌面" ]; then
    DESKTOP_DIR="$HOME/桌面"
else
    DESKTOP_DIR="$HOME"
    echo "⚠️ 未找到桌面目录，文件将保存到用户主目录"
fi

cat > "$DESKTOP_DIR/dria_start.sh" <<'EOF'
#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}🚀 启动 Dria 节点...${NC}"

# 检查 dkn-compute-launcher 是否可用
if ! command -v dkn-compute-launcher &> /dev/null; then
    echo -e "${RED}❌ dkn-compute-launcher 命令未找到，请检查安装${NC}"
    echo "按任意键退出..."
    read -n 1 -s
    exit 1
fi

# 启动 Dria 节点
echo -e "${BLUE}📡 正在启动 Dria 计算节点...${NC}"
dkn-compute-launcher start

# 如果启动失败，保持终端打开
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ 节点启动失败${NC}"
    echo "按任意键退出..."
    read -n 1 -s
fi
EOF

chmod +x "$DESKTOP_DIR/dria_start.sh"
echo "✅ 桌面启动文件已创建: $DESKTOP_DIR/dria_start.sh"

# 创建桌面快捷方式（如果支持）
if command -v gio &> /dev/null; then
    echo "📝 创建桌面快捷方式..."
    gio set "$DESKTOP_DIR/dria_start.sh" metadata::trusted true 2>/dev/null || true
fi

echo "✅ 安装和配置完成！"
echo "🚀 正在启动 Dria 节点..."
dkn-compute-launcher start

echo ""
echo "💡 使用说明："
echo "1. 双击桌面上的 dria_start.sh 启动节点"
echo "2. 或在终端中运行: ./dria_start.sh"
echo "3. 使用 'dkn-compute-launcher start' 命令启动节点"
echo "4. 使用 'dkn-compute-launcher stop' 命令停止节点" 