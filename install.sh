#!/bin/bash

# =========================================================
# nftables 端口转发管理脚本
# 功能：添加/删除/查看/保存 nftables 端口转发规则
# 适配：Debian / Ubuntu
# 快捷指令：安装后输入 nat 即可打开菜单
# =========================================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 检查是否为 root 用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# 第一步：安装 nftables
echo -e "${GREEN}正在安装 nftables...${PLAIN}"

# 检测系统并更换国内源（国内用户加速）
if grep -qi "debian" /etc/os-release; then
    sed -i 's/deb.debian.org/mirrors.aliyun.com/g' /etc/apt/sources.list
elif grep -qi "ubuntu" /etc/os-release; then
    sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list
fi

apt update && apt install nftables -y

# 第二步：开启 IP 转发
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1

# 初始化 nat 表
nft add table ip nat 2>/dev/null
nft 'add chain ip nat prerouting { type nat hook prerouting priority -100; }' 2>/dev/null
nft 'add chain ip nat postrouting { type nat hook postrouting priority 100; }' 2>/dev/null

# 第三步：安装管理菜单到 /usr/local/bin/nat
cat > /usr/local/bin/nat <<'EOF'
#!/bin/bash

sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1

nft add table ip nat 2>/dev/null
nft 'add chain ip nat prerouting { type nat hook prerouting priority -100; }' 2>/dev/null
nft 'add chain ip nat postrouting { type nat hook postrouting priority 100; }' 2>/dev/null

while true; do
    echo "========================================"
    echo "       nftables 端口转发管理菜单"
    echo "========================================"
    echo "1. 添加转发规则"
    echo "2. 删除转发规则"
    echo "3. 查看所有规则"
    echo "4. 保存规则"
    echo "0. 退出"
    echo "========================================"
    read -p "请选择 [0-4]: " choice

    case $choice in
        1)
            read -p "本地端口: " local_port
            read -p "目标IP: " dest_ip
            read -p "目标端口: " dest_port
            nft add rule ip nat prerouting tcp dport $local_port dnat to $dest_ip:$dest_port
            nft add rule ip nat prerouting udp dport $local_port dnat to $dest_ip:$dest_port
            nft add rule ip nat postrouting ip daddr $dest_ip masquerade
            echo "✅ 已添加"
            ;;
        2)
            read -p "本地端口: " local_port
            handles=$(nft -a list chain ip nat prerouting 2>/dev/null | grep "dport $local_port " | awk '{print $NF}')
            for h in $handles; do
                nft delete rule ip nat prerouting handle $h 2>/dev/null
            done
            echo "✅ 已删除"
            ;;
        3)
            nft list ruleset
            ;;
        4)
            nft list ruleset > /etc/nftables.conf
            systemctl enable nftables 2>/dev/null
            systemctl restart nftables 2>/dev/null
            echo "✅ 已保存并重启"
            ;;
        0)
            exit 0
            ;;
        *)
            echo "❌ 输入有误"
            ;;
    esac
    echo ""
done
EOF

chmod +x /usr/local/bin/nat
echo -e "${GREEN}✅ 安装完成！输入 nat 打开菜单。${PLAIN}"
