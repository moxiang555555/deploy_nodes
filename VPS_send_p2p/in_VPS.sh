#!/bin/bash

# 遇到任何错误时退出脚本
set -e

# 0. 更新软件源并安装依赖
echo "正在更新软件源..."
sudo apt update

# 分别安装依赖包以避免冲突
echo "正在安装所需软件包..."
sudo apt install -y socat net-tools
# 单独安装 iptables-persistent
sudo apt install -y iptables-persistent
# 单独安装 ufw
sudo apt install -y ufw

# 1. 启用IP转发
echo "正在启用IP转发..."
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
fi
sudo sysctl -p

# 2. 确保iptables规则目录存在
echo "正在确保iptables规则目录存在..."
sudo mkdir -p /etc/iptables

# 3. 清除现有iptables规则
echo "正在清除现有iptables规则..."
sudo iptables -F
sudo iptables -t nat -F
sudo iptables -F FORWARD

# 4. 添加TCP端口转发规则
echo "正在添加TCP端口转发规则..."
sudo iptables -t nat -A PREROUTING -p tcp --dport 30011 -j DNAT --to-destination 38.101.215.12:30011
sudo iptables -t nat -A PREROUTING -p tcp --dport 30012 -j DNAT --to-destination 38.101.215.13:30012
sudo iptables -t nat -A PREROUTING -p tcp --dport 30013 -j DNAT --to-destination 38.101.215.14:30013

# 5. 添加UDP端口转发规则
echo "正在添加UDP端口转发规则..."
sudo iptables -t nat -A PREROUTING -p udp --dport 30011 -j DNAT --to-destination 38.101.215.12:30011
sudo iptables -t nat -A PREROUTING -p udp --dport 30012 -j DNAT --to-destination 38.101.215.13:30012
sudo iptables -t nat -A PREROUTING -p udp --dport 30013 -j DNAT --to-destination 38.101.215.14:30013

# 6. 添加MASQUERADE规则
echo "正在添加MASQUERADE规则..."
sudo iptables -t nat -A POSTROUTING -p tcp -d 38.101.215.12 --dport 30011 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -p tcp -d 38.101.215.13 --dport 30012 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -p tcp -d 38.101.215.14 --dport 30013 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -p udp -d 38.101.215.12 --dport 30011 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -p udp -d 38.101.215.13 --dport 30012 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -p udp -d 38.101.215.14 --dport 30013 -j MASQUERADE

# 7. 添加FORWARD规则
echo "正在添加FORWARD规则..."
sudo iptables -A FORWARD -p tcp -d 38.101.215.12 --dport 30011 -j ACCEPT
sudo iptables -A FORWARD -p tcp -d 38.101.215.13 --dport 30012 -j ACCEPT
sudo iptables -A FORWARD -p tcp -d 38.101.215.14 --dport 30013 -j ACCEPT
sudo iptables -A FORWARD -p tcp -s 38.101.215.12 --sport 30011 -j ACCEPT
sudo iptables -A FORWARD -p tcp -s 38.101.215.13 --sport 30012 -j ACCEPT
sudo iptables -A FORWARD -p tcp -s 38.101.215.14 --sport 30013 -j ACCEPT
sudo iptables -A FORWARD -p udp -d 38.101.215.12 --dport 30011 -j ACCEPT
sudo iptables -A FORWARD -p udp -d 38.101.215.13 --dport 30012 -j ACCEPT
sudo iptables -A FORWARD -p udp -d 38.101.215.14 --dport 30013 -j ACCEPT
sudo iptables -A FORWARD -p udp -s 38.101.215.12 --sport 30011 -j ACCEPT
sudo iptables -A FORWARD -p udp -s 38.101.215.13 --sport 30012 -j ACCEPT
sudo iptables -A FORWARD -p udp -s 38.101.215.14 --sport 30013 -j ACCEPT

# 8. 保存iptables规则
echo "正在保存iptables规则..."
sudo iptables-save | sudo tee /etc/iptables/rules.v4

# 9. 启动socat端口转发（假设38.101.215.15正确）
echo "正在启动socat端口转发..."
# 检查socat是否已安装
if ! command -v socat >/dev/null 2>&1; then
    echo "错误：socat未安装。请手动安装：'sudo apt install socat'。"
    exit 1
fi
nohup socat TCP-LISTEN:30011,fork TCP:38.101.215.15:30011 &
nohup socat TCP-LISTEN:30012,fork TCP:38.101.215.15:30012 &
nohup socat TCP-LISTEN:30013,fork TCP:38.101.215.15:30013 &

# 10. 配置并启用ufw
echo "正在配置并启用ufw..."
sudo ufw allow 30011:30013/tcp
sudo ufw allow 30011:30013/udp
# 检查ufw是否已启用
if ! sudo ufw status | grep -q "Status: active"; then
    echo "正在启用ufw..."
    echo y | sudo ufw enable
else
    echo "正在重新加载ufw..."
    sudo ufw reload
fi

# 11. 验证端口监听
echo "正在验证端口监听..."
if command -v netstat >/dev/null 2>&1; then
    sudo netstat -tlnp | grep -E ':30011|:30012|:30013' || echo "未找到匹配的端口。"
else
    echo "未找到netstat，使用ss代替..."
    sudo ss -tlnp | grep -E ':30011|:30012|:30013' || echo "未找到匹配的端口。"
fi

echo "脚本执行完成。"