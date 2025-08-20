#!/bin/bash

echo "🚀 开始安装 Dria..."

# 下载并安装 Ollama
echo "📥 正在下载 Ollama..."
curl -L -o ~/Downloads/Ollama.dmg https://ollama.com/download/Ollama.dmg

if [ $? -eq 0 ]; then
    echo "✅ Ollama 下载完成"
    echo "🔧 正在挂载 Ollama.dmg..."
    
    # 挂载 DMG 文件
    hdiutil attach ~/Downloads/Ollama.dmg
    
    # 复制应用到 Applications 文件夹
    echo "📦 正在安装 Ollama 到 Applications 文件夹..."
    cp -R "/Volumes/Ollama/Ollama.app" /Applications/
    
    # 卸载 DMG
    echo "🗑️ 清理临时文件..."
    hdiutil detach "/Volumes/Ollama"
    rm ~/Downloads/Ollama.dmg
    
    echo "✅ Ollama 安装完成！"
    echo "💡 你可以在 Applications 文件夹中找到 Ollama"
    
    # 可选：自动打开 Ollama
    echo "🚀 正在启动 Ollama..."
    open /Applications/Ollama.app
    
    # 等待几秒让 Ollama 启动
    echo "⏳ 等待 Ollama 启动完成..."
    sleep 5
else
    echo "❌ Ollama 下载失败，但继续安装 Dria..."
fi

echo ""
echo "📱 现在开始安装 Dria..."

# 使用官方安装脚本
echo "📥 正在下载并安装 Dria..."
curl -fsSL https://dria.co/launcher | bash

# 重新加载 zsh 配置
echo "🔄 重新加载 shell 配置..."
source ~/.zshrc

echo "✅ Dria 安装完成！"
echo ""
echo "🔗 获取邀请码步骤："
echo "请在新的终端窗口中运行以下命令获取你的邀请码："
echo ""
echo "   dkn-compute-launcher referrals"
echo ""
echo "然后选择：Get referral code to refer someone"
echo ""
echo "📝 获取邀请码后，请回到这里按回车键继续..."
read -p "按回车键继续..."

echo ""
echo "🚀 正在启动 Dria 节点..."
dkn-compute-launcher start