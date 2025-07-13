# 海外云主机P2P代理设置指南

## 概述

本文档说明如何使用海外Ubuntu云主机的端口转发功能，解决国内无法直接访问RL Swarm P2P初始节点的问题。

**目标节点地址**:
- `38.101.215.15:30011`
- `38.101.215.15:30012` 
- `38.101.215.15:30013`

## 端口转发方案

**优点**: 
- 透明代理，无需客户端特殊配置
- 完全兼容P2P协议（支持TCP/UDP）
- 性能最佳，延迟最低
- 配置简单，维护方便

**原理**: 在海外云主机上设置端口转发规则，将本地端口的流量转发到目标P2P节点

## 云主机端配置

#### 使用iptables进行端口转发
```bash
# 启用IP转发
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# 清理现有规则（谨慎操作）
sudo iptables -F
sudo iptables -t nat -F

# 1. 清除现有规则
sudo iptables -t nat -F
sudo iptables -F FORWARD

# 2. 重新添加完整的转发规则
# TCP转发
sudo iptables -t nat -A PREROUTING -p tcp --dport 30011 -j DNAT --to-destination 38.101.215.15:30011
sudo iptables -t nat -A PREROUTING -p tcp --dport 30012 -j DNAT --to-destination 38.101.215.15:30012
sudo iptables -t nat -A PREROUTING -p tcp --dport 30013 -j DNAT --to-destination 38.101.215.15:30013

# UDP转发
sudo iptables -t nat -A PREROUTING -p udp --dport 30011 -j DNAT --to-destination 38.101.215.15:30011
sudo iptables -t nat -A PREROUTING -p udp --dport 30012 -j DNAT --to-destination 38.101.215.15:30012
sudo iptables -t nat -A PREROUTING -p udp --dport 30013 -j DNAT --to-destination 38.101.215.15:30013

# MASQUERADE规则
sudo iptables -t nat -A POSTROUTING -p tcp -d 38.101.215.15 --dport 30011:30013 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -p udp -d 38.101.215.15 --dport 30011:30013 -j MASQUERADE

# FORWARD规则
sudo iptables -A FORWARD -p tcp -d 38.101.215.15 --dport 30011:30013 -j ACCEPT
sudo iptables -A FORWARD -p tcp -s 38.101.215.15 --sport 30011:30013 -j ACCEPT
sudo iptables -A FORWARD -p udp -d 38.101.215.15 --dport 30011:30013 -j ACCEPT
sudo iptables -A FORWARD -p udp -s 38.101.215.15 --sport 30011:30013 -j ACCEPT

# 保存规则
sudo iptables-save | sudo tee /etc/iptables/rules.v4


# 安装socat
sudo apt install socat -y

# 创建本地端口转发（在后台运行）
nohup socat TCP-LISTEN:30011,fork TCP:38.101.215.15:30011 &
nohup socat TCP-LISTEN:30012,fork TCP:38.101.215.15:30012 &
nohup socat TCP-LISTEN:30013,fork TCP:38.101.215.15:30013 &

# 现在测试本地连接
telnet localhost 30011
```


#### 配置防火墙
```bash
# 开放代理端口
sudo ufw allow 30011:30013/tcp
sudo ufw allow 30011:30013/udp

# 重新加载
sudo ufw reload
```

## 本地客户端配置

修改 `rgym_exp/config/rg-swarm.yaml` 文件，将 `initial_peers` 地址改为您的云主机IP:

```yaml
communications:
  initial_peers:
    - '/ip4/YOUR_CLOUD_SERVER_IP/tcp/30011/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ'
    - '/ip4/YOUR_CLOUD_SERVER_IP/tcp/30012/p2p/QmWhiaLrx3HRZfgXc2i7KW5nMUNK7P9tRc71yFJdGEZKkC'
    - '/ip4/YOUR_CLOUD_SERVER_IP/tcp/30013/p2p/QmQa1SCfYTxx7RvU7qJJRo79Zm1RAwPpkeLueDVJuBBmFp'
```

**注意**: 请将 `YOUR_CLOUD_SERVER_IP` 替换为您的实际云主机公网IP地址。

## 测试和验证

### 连接测试脚本
创建 `scripts/proxy_test.sh` 来测试代理连接:
```bash
#!/bin/bash

echo "=== RL Swarm代理连接测试 ==="

# 测试代理服务器地址
TARGETS=("YOUR_CLOUD_SERVER_IP:30011" "YOUR_CLOUD_SERVER_IP:30012" "YOUR_CLOUD_SERVER_IP:30013")

for target in "${TARGETS[@]}"; do
    echo -n "测试连接 $target ... "
    
    # 使用nc测试TCP连接
    if timeout 5 nc -z ${target/:/ } 2>/dev/null; then
        echo "✓ 连接成功"
    else
        echo "✗ 连接失败"
    fi
    
    # 测试延迟
    echo -n "  延迟测试: "
    ping_result=$(ping -c 1 -W 3 ${target%:*} 2>/dev/null | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}')
    if [ -n "$ping_result" ]; then
        echo "${ping_result}ms"
    else
        echo "超时"
    fi
    
    echo
done

echo "=== 测试完成 ==="
```

**使用方法**:
1. 将 `YOUR_CLOUD_SERVER_IP` 替换为您的云主机IP
2. 运行测试: `bash scripts/proxy_test.sh`

## 故障排除

### 常见问题

#### 问题1: 端口转发连接失败
```bash
# 检查云主机防火墙
sudo ufw status
sudo iptables -L -n

# 检查端口转发服务状态
sudo systemctl status rl-swarm-proxy

# 检查端口监听
sudo netstat -tlnp | grep :30011
sudo netstat -tlnp | grep :30012
sudo netstat -tlnp | grep :30013
```

#### 问题2: P2P连接仍然失败
```bash
# 测试直连代理服务器
telnet YOUR_CLOUD_SERVER_IP 30011

# 检查路由
traceroute YOUR_CLOUD_SERVER_IP

# 验证端口转发规则
sudo iptables -t nat -L -n | grep 30011
```

#### 问题3: 性能问题
```bash
# 检查延迟
ping -c 10 YOUR_CLOUD_SERVER_IP

# 优化网络参数
echo 'net.ipv4.tcp_congestion_control = bbr' | sudo tee -a /etc/sysctl.conf
echo 'net.core.default_qdisc = fq' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

## 在项目中使用

### 1. 启动代理服务
在云主机上启动端口转发服务:
```bash
# 启动服务
sudo systemctl start rl-swarm-proxy

# 检查状态
sudo systemctl status rl-swarm-proxy
```

### 2. 修改项目配置
编辑 `rgym_exp/config/rg-swarm.yaml`，将IP地址改为您的云主机IP:
```yaml
communications:
  initial_peers:
    - '/ip4/YOUR_CLOUD_SERVER_IP/tcp/30011/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ'
    - '/ip4/YOUR_CLOUD_SERVER_IP/tcp/30012/p2p/QmWhiaLrx3HRZfgXc2i7KW5nMUNK7P9tRc71yFJdGEZKkC'
    - '/ip4/YOUR_CLOUD_SERVER_IP/tcp/30013/p2p/QmQa1SCfYTxx7RvU7qJJRo79Zm1RAwPpkeLueDVJuBBmFp'
```

### 3. 运行RL Swarm
正常运行项目:
```bash
./run_rl_swarm.sh
```

### 4. 验证连接
使用测试脚本验证代理是否正常工作:
```bash
bash scripts/proxy_test.sh
```

## 使用建议

- **云主机选择**: 选择地理位置接近、带宽充足的云主机
- **性能优化**: 启用BBR拥塞控制算法提升网络性能
- **监控维护**: 定期检查代理服务状态，确保稳定运行
- **安全考虑**: 配置防火墙规则，只开放必要的端口

---

**注意**: 请将文档中的 `YOUR_CLOUD_SERVER_IP` 替换为您的实际云主机IP地址。