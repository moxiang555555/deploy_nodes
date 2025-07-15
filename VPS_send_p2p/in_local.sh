# 1. 修改P2P配置文件
# 假设项目目录为 ~/rgym_exp，编辑 rg-swarm.yaml 文件
cat << EOF > ~/rgym_exp/config/rg-swarm.yaml
communications:
  initial_peers:
    - '/ip4/YOUR_CLOUD_SERVER_IP/tcp/30011/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ'
    - '/ip4/YOUR_CLOUD_SERVER_IP/tcp/30012/p2p/QmWhiaLrx3HRZfgXc2i7KW5nMUNK7P9tRc71yFJdGEZKkC'
    - '/ip4/YOUR_CLOUD_SERVER_IP/tcp/30013/p2p/QmQa1SCfYTxx7RvU7qJJRo79Zm1RAwPpkeLueDVJuBBmFp'
EOF

# 2. 创建测试脚本 proxy_test.sh
mkdir -p ~/scripts
cat << EOF > ~/scripts/proxy_test.sh
#!/bin/bash

echo "=== RL Swarm代理连接测试 ==="

# 测试代理服务器地址
TARGETS=("YOUR_CLOUD_SERVER_IP:30011" "YOUR_CLOUD_SERVER_IP:30012" "YOUR_CLOUD_SERVER_IP:30013")

for target in "\${TARGETS[@]}"; do
    echo -n "测试连接 \$target ... "
    
    # 使用nc测试TCP连接
    if timeout 5 nc -z \${target/:/ } 2>/dev/null; then
        echo "✓ 连接成功"
    else
        echo "✗ 连接失败"
    fi
    
    # 测试延迟
    echo -n "  延迟测试: "
    ping_result=\$(ping -c 1 -W 3 \${target%:*} 2>/dev/null | grep 'time=' | awk -F'time=' '{print \$2}' | awk '{print \$1}')
    if [ -n "\$ping_result" ]; then
        echo "\${ping_result}ms"
    else
        echo "超时"
    fi
    
    echo
done

echo "=== 测试完成 ==="
EOF

# 3. 赋予测试脚本执行权限
chmod +x ~/scripts/proxy_test.sh

# 4. 安装必要的测试工具（netcat和ping）
sudo apt update
sudo apt install netcat-openbsd iputils-ping -y

# 5. 运行测试脚本
bash ~/scripts/proxy_test.sh

# 6. 运行RL Swarm项目
# 假设项目启动脚本为 run_rl_swarm.sh
cd ~/rgym_exp
./run_rl_swarm.sh