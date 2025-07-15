# 0. 更新软件源并安装依赖
sudo apt update
sudo apt install -y iptables-persistent socat net-tools ufw

# 启用IP转发
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# 清理现有iptables规则（谨慎操作）
sudo iptables -F
sudo iptables -t nat -F
sudo iptables -F FORWARD

# 添加TCP端口转发规则
sudo iptables -t nat -A PREROUTING -p tcp --dport 30011 -j DNAT --to-destination 38.101.215.12:30011
sudo iptables -t nat -A PREROUTING -p tcp --dport 30012 -j DNAT --to-destination 38.101.215.13:30012
sudo iptables -t nat -A PREROUTING -p tcp --dport 30013 -j DNAT --to-destination 38.101.215.14:30013

# 添加UDP端口转发规则
sudo iptables -t nat -A PREROUTING -p udp --dport 30011 -j DNAT --to-destination 38.101.215.12:30011
sudo iptables -t nat -A PREROUTING -p udp --dport 30012 -j DNAT --to-destination 38.101.215.13:30012
sudo iptables -t nat -A PREROUTING -p udp --dport 30013 -j DNAT --to-destination 38.101.215.14:30013

# 添加MASQUERADE规则
sudo iptables -t nat -A POSTROUTING -p tcp -d 38.101.215.12 --dport 30011 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -p tcp -d 38.101.215.13 --dport 30012 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -p tcp -d 38.101.215.14 --dport 30013 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -p udp -d 38.101.215.12 --dport 30011 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -p udp -d 38.101.215.13 --dport 30012 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -p udp -d 38.101.215.14 --dport 30013 -j MASQUERADE

# 添加FORWARD规则
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

# 保存iptables规则
# sudo apt install iptables-persistent -y  # 已提前安装，无需重复
sudo iptables-save | sudo tee /etc/iptables/rules.v4

# 安装socat
# sudo apt update  # 已提前更新，无需重复
# sudo apt install socat -y  # 已提前安装，无需重复

# 启动socat端口转发（后台运行）
nohup socat TCP-LISTEN:30011,fork TCP:38.101.215.15:30011 &
nohup socat TCP-LISTEN:30012,fork TCP:38.101.215.15:30012 &
nohup socat TCP-LISTEN:30013,fork TCP:38.101.215.15:30013 &

# 配置防火墙
sudo ufw allow 30011:30013/tcp
sudo ufw allow 30011:30013/udp
sudo ufw reload

# 验证端口监听
sudo netstat -tlnp | grep -E ':30011|:30012|:30013'