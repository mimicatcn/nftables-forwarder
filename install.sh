cat > /usr/local/bin/nat <<'EOF'
#!/bin/bash

CONF_DIR=/etc/natmeter
CONF=$CONF_DIR/ports.conf
STATE=/var/lib/natmeter
LOCK=/run/natmeter.lock
GIB=1073741824

mkdir -p "$CONF_DIR" "$STATE"
touch "$CONF"

locked() { ( flock 9; "$@" ) 9>"$LOCK"; }

isport() { [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
isip()   { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
isnum()  { [[ $1 =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
isint()  { [[ $1 =~ ^[0-9]+$ ]]; }

hum() {
    awk -v b="$1" 'BEGIN{split("B KB MB GB TB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++}printf "%.2f %s",b,u[i]}'
}

st()      { cat "$STATE/$1.$2" 2>/dev/null || echo 0; }
cur_ctr() {
    nft list counter ip fwmeter "p${1}_${2}" 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="bytes") v=$(i+1)} END{print v+0}'
}

cfg_get() { awk -v p="$1" '$1==p{print $2" "$3}' "$CONF"; }
cfg_put() { # port rate quota ; 两者都为0则删除该端口配置
    local t; t=$(mktemp)
    awk -v p="$1" '$1!=p' "$CONF" > "$t"
    if [ "$2" != 0 ] || [ "$3" != 0 ]; then
        echo "$1 $2 $3" >> "$t"
    else
        rm -f "$STATE/$1.up" "$STATE/$1.dn" "$STATE/$1.blocked"
    fi
    cat "$t" > "$CONF"; rm -f "$t"
}

# 生成并原子加载 fwmeter 表
_rebuild() {
    local f=/run/natmeter.nft port rate quota m rk burst
    {
        echo "table ip fwmeter"
        echo "delete table ip fwmeter"
        echo "table ip fwmeter {"
        while read -r port rate quota; do
            [ -z "$port" ] && continue
            echo "  counter p${port}_up { }"
            echo "  counter p${port}_dn { }"
        done < "$CONF"
        echo "  chain forward {"
        echo "    type filter hook forward priority -5; policy accept;"
        while read -r port rate quota; do
            [ -z "$port" ] && continue
            m="meta l4proto { tcp, udp } ct original proto-dst $port"
            if [ -e "$STATE/$port.blocked" ]; then
                echo "    $m drop"
            fi
            if [ "${rate:-0}" != 0 ]; then
                rk=$(( rate * 125 ))
                burst=$(( rk / 2 )); [ "$burst" -lt 64 ] && burst=64
                echo "    $m ct direction original limit rate over $rk kbytes/second burst $burst kbytes drop"
                echo "    $m ct direction reply limit rate over $rk kbytes/second burst $burst kbytes drop"
            fi
            echo "    $m ct direction original counter name \"p${port}_up\""
            echo "    $m ct direction reply counter name \"p${port}_dn\""
        done < "$CONF"
        echo "  }"
        echo "}"
    } > "$f"
    nft -f "$f"
}

# 读取计数器累加到状态文件，并按额度决定是否暂停端口
_collect() {
    local need=0 port rate quota d b up dn want
    if ! nft list table ip fwmeter >/dev/null 2>&1; then
        need=1
    else
        while read -r port rate quota; do
            [ -z "$port" ] && continue
            for d in up dn; do
                b=$(nft reset counter ip fwmeter "p${port}_${d}" 2>/dev/null |
                    awk '{for(i=1;i<=NF;i++) if($i=="bytes") v=$(i+1)} END{print v+0}')
                echo $(( $(st "$port" "$d") + ${b:-0} )) > "$STATE/$port.$d"
            done
        done < "$CONF"
    fi
    while read -r port rate quota; do
        [ -z "$port" ] && continue
        up=$(st "$port" up); dn=$(st "$port" dn)
        want=0
        if awk -v u=$((up+dn)) -v q="${quota:-0}" -v g=$GIB 'BEGIN{exit !(q>0 && u>=q*g)}'; then
            want=1
        fi
        if [ $want = 1 ] && [ ! -e "$STATE/$port.blocked" ]; then
            touch "$STATE/$port.blocked"; need=1
        elif [ $want = 0 ] && [ -e "$STATE/$port.blocked" ]; then
            rm -f "$STATE/$port.blocked"; need=1
        fi
    done < "$CONF"
    if [ $need = 1 ]; then _rebuild; fi
}

do_set_rate() { # port mbps
    local cur q; cur=$(cfg_get "$1"); q=${cur#* }; [ -z "$cur" ] && q=0
    _collect
    cfg_put "$1" "$2" "$q"; _rebuild
}
do_set_quota() { # port gb
    local cur r; cur=$(cfg_get "$1"); r=${cur%% *}; [ -z "$cur" ] && r=0
    _collect
    cfg_put "$1" "$r" "$2"; _collect; _rebuild
}
do_reset_usage() { # port
    nft reset counter ip fwmeter "p${1}_up" >/dev/null 2>&1
    nft reset counter ip fwmeter "p${1}_dn" >/dev/null 2>&1
    rm -f "$STATE/$1.up" "$STATE/$1.dn" "$STATE/$1.blocked"
    _rebuild
}
do_del_port_cfg() { # port
    _collect; cfg_put "$1" 0 0; _rebuild
}

show_usage() {
    locked _collect
    if [ ! -s "$CONF" ]; then
        echo "尚未配置任何端口的限速/流量额度（请先用菜单 5 或 6）"
        return
    fi
    declare -A u1 d1
    local port rate quota
    while read -r port rate quota; do
        [ -z "$port" ] && continue
        u1[$port]=$(cur_ctr "$port" up); d1[$port]=$(cur_ctr "$port" dn)
    done < "$CONF"
    sleep 2
    local u2 d2 su sd bwu bwd pct status
    while read -r port rate quota; do
        [ -z "$port" ] && continue
        u2=$(cur_ctr "$port" up); d2=$(cur_ctr "$port" dn)
        su=$(( $(st "$port" up) + u2 )); sd=$(( $(st "$port" dn) + d2 ))
        bwu=$(awk -v a="${u1[$port]}" -v b="$u2" 'BEGIN{x=(b-a)*8/2/1000000; if(x<0)x=0; printf "%.2f",x}')
        bwd=$(awk -v a="${d1[$port]}" -v b="$d2" 'BEGIN{x=(b-a)*8/2/1000000; if(x<0)x=0; printf "%.2f",x}')
        echo "----------------------------------------"
        echo "端口 $port"
        if [ "$rate" != 0 ]; then echo "  限速: 上下行各 ${rate} Mbps"; else echo "  限速: 不限"; fi
        if [ "$quota" != 0 ]; then
            pct=$(awk -v u=$((su+sd)) -v q="$quota" -v g=$GIB 'BEGIN{printf "%.1f",u*100/(q*g)}')
            if [ -e "$STATE/$port.blocked" ]; then status="⛔ 已超额，转发已暂停"; else status="✅ 正常"; fi
            echo "  额度: ${quota} GB   已用 $(hum $((su+sd))) (${pct}%)   $status"
        else
            echo "  额度: 不限   已用 $(hum $((su+sd)))"
        fi
        echo "  累计: 上行(客户端→目标) $(hum "$su")   下行(目标→客户端) $(hum "$sd")"
        echo "  实时: 上行 ${bwu} Mbps   下行 ${bwd} Mbps"
    done < "$CONF"
    echo "----------------------------------------"
}

# ---- 非交互子命令（给 systemd 用） ----
case "$1" in
    collect) locked _collect; exit 0 ;;
    rebuild) locked _collect; locked _rebuild; exit 0 ;;
esac

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
    echo "5. 设置端口限速（上下行各 Mbps）"
    echo "6. 设置累计流量额度（输入100即100GB）"
    echo "7. 查看流量和带宽使用情况"
    echo "0. 退出"
    echo "========================================"
    read -p "请选择 [0-7]: " choice

    case $choice in
        1)
            read -p "本地端口: " local_port
            read -p "目标IP: " dest_ip
            read -p "目标端口: " dest_port
            if ! isport "$local_port" || ! isport "$dest_port" || ! isip "$dest_ip"; then
                echo "❌ 输入有误"
            else
                nft add rule ip nat prerouting tcp dport $local_port dnat to $dest_ip:$dest_port
                nft add rule ip nat prerouting udp dport $local_port dnat to $dest_ip:$dest_port
                if ! nft list chain ip nat postrouting 2>/dev/null | grep -q "ip daddr $dest_ip masquerade"; then
                    nft add rule ip nat postrouting ip daddr $dest_ip masquerade
                fi
                echo "✅ 已添加"
            fi
            ;;
        2)
            read -p "本地端口: " local_port
            if ! isport "$local_port"; then
                echo "❌ 输入有误"
            else
                handles=$(nft -a list chain ip nat prerouting 2>/dev/null | grep -E "dport $local_port dnat" | awk '{print $NF}')
                for h in $handles; do
                    nft delete rule ip nat prerouting handle $h 2>/dev/null
                done
                if [ -n "$(cfg_get "$local_port")" ]; then
                    locked do_del_port_cfg "$local_port"
                    echo "（已同时清除该端口的限速/额度配置）"
                fi
                echo "✅ 已删除"
            fi
            ;;
        3)
            nft list table ip nat
            ;;
        4)
            { echo "flush ruleset"; nft list table ip nat; } > /etc/nftables.conf
            systemctl enable nftables >/dev/null 2>&1
            echo "✅ 已保存（当前规则已生效，无需重启，转发不中断）"
            ;;
        5)
            read -p "端口: " p
            read -p "限速 Mbps（上下行各，输入 0 取消限速）: " r
            if ! isport "$p" || ! isint "$r"; then
                echo "❌ 输入有误（限速请输入整数）"
            else
                locked do_set_rate "$p" "$r"
                if [ "$r" = 0 ]; then echo "✅ 端口 $p 已取消限速"; else echo "✅ 端口 $p 已限速：上下行各 ${r} Mbps"; fi
            fi
            ;;
        6)
            read -p "端口: " p
            if ! isport "$p"; then
                echo "❌ 输入有误"
            else
                echo "  a. 设置额度（输入100就是100GB）"
                echo "  b. 清零已用流量并恢复转发"
                echo "  c. 取消额度"
                read -p "请选择 [a/b/c]: " sub
                case $sub in
                    a)
                        read -p "额度 GB（输入100就是100GB）: " q
                        if ! isnum "$q" || [ "$q" = 0 ]; then
                            echo "❌ 输入有误"
                        else
                            locked do_set_quota "$p" "$q"
                            echo "✅ 端口 $p 额度已设为 ${q} GB（TCP+UDP 双向合计，超额后仅暂停该端口）"
                        fi
                        ;;
                    b) locked do_reset_usage "$p"; echo "✅ 端口 $p 已用流量清零并恢复转发" ;;
                    c) locked do_set_quota "$p" 0; echo "✅ 端口 $p 已取消额度" ;;
                    *) echo "❌ 输入有误" ;;
                esac
            fi
            ;;
        7)
            show_usage
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

cat > /etc/systemd/system/natmeter.service <<'UNIT'
[Unit]
Description=nat traffic meter collector
After=nftables.service network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nat collect
UNIT

cat > /etc/systemd/system/natmeter.timer <<'UNIT'
[Unit]
Description=nat traffic meter timer

[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=1s

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now natmeter.timer
echo -e "\033[32m✅ 安装完成！输入 nat 打开菜单。\033[0m"
