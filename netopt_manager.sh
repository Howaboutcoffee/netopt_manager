#!/usr/bin/env bash
# ==========================================
# Linux 网络优化管理器 v5（最终版-纯文本）
# ------------------------------------------
# 1. 入口节点优化（国内入口机）
# 2. 中转出口优化（国外出口机）
# 3. 终点落地优化（落地机或直连机）
# 4. 出口等于落地优化（特殊场景）
# 5. 激进优化（高性能场景）
# ==========================================

set -e
[ "$(id -u)" -eq 0 ] || { echo "[错误] 请使用 root 运行"; exit 1; }

HOST=$(hostname -s)
DATE=$(date +%F_%H%M%S)
BACKUP_DIR="/root/netopt_backup_${HOST}_${DATE}"

# ========== 工具函数 ==========
backup_configs() {
    mkdir -p "$BACKUP_DIR"
    echo "[备份] 正在备份当前配置到 $BACKUP_DIR ..."
    cp -a /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.bak" 2>/dev/null || true
    cp -a /etc/security/limits.conf "$BACKUP_DIR/limits.conf.bak" 2>/dev/null || true
    cp -a /etc/systemd/system.conf "$BACKUP_DIR/system.conf.bak" 2>/dev/null || true
    iptables-save > "$BACKUP_DIR/iptables.bak" 2>/dev/null || true

    cat > "$BACKUP_DIR/restore.sh" <<'EOF'
#!/usr/bin/env bash
set -e
[ "$(id -u)" -eq 0 ] || { echo "请以 root 运行此脚本"; exit 1; }
BASEDIR="$(dirname "$0")"
cp -a "$BASEDIR/sysctl.conf.bak" /etc/sysctl.conf 2>/dev/null || true
cp -a "$BASEDIR/limits.conf.bak" /etc/security/limits.conf 2>/dev/null || true
cp -a "$BASEDIR/system.conf.bak" /etc/systemd/system.conf 2>/dev/null || true
if [ -f "$BASEDIR/iptables.bak" ]; then iptables-restore < "$BASEDIR/iptables.bak"; fi
sysctl --system >/dev/null 2>&1 || true
systemctl daemon-reexec
echo "[成功] 已恢复至备份配置"
EOF
    chmod +x "$BACKUP_DIR/restore.sh"
    echo "[完成] 备份完成，可用 $BACKUP_DIR/restore.sh 恢复"
}

check_kernel() {
    echo "[检查] 系统信息检查"
    echo "----------------------------------------"
    echo "内核版本: $(uname -r)"
    echo "系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo '未知')"
    echo "内存: $(free -h | awk '/^Mem:/ {print $2}')"
    echo ""
    
    # 检查 BBR 支持
    if grep -q "CONFIG_TCP_CONG_BBR" /boot/config-$(uname -r) 2>/dev/null; then
        echo "[OK] 内核支持 BBR"
    else
        echo "[警告] 内核可能不支持 BBR（需要 4.9+）"
    fi
    
    # 检查 FQ 支持
    if grep -q "CONFIG_NET_SCH_FQ" /boot/config-$(uname -r) 2>/dev/null; then
        echo "[OK] 内核支持 FQ 队列"
    else
        echo "[警告] 内核可能不支持 FQ 队列"
    fi
    
    # 检查可用的拥塞控制算法
    echo ""
    echo "可用的拥塞控制算法:"
    cat /proc/sys/net/ipv4/tcp_available_congestion_control
    echo "----------------------------------------"
}

show_current() {
    echo "============ 当前网络配置 ============"
    echo ""
    echo "[拥塞控制]"
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null || echo "  未设置"
    sysctl net.core.default_qdisc 2>/dev/null || echo "  未设置"
    
    echo ""
    echo "[TCP 优化参数]"
    sysctl net.ipv4.tcp_fastopen 2>/dev/null || echo "  tcp_fastopen: 未设置"
    sysctl net.ipv4.tcp_tw_reuse 2>/dev/null || echo "  tcp_tw_reuse: 未设置"
    sysctl net.ipv4.tcp_mtu_probing 2>/dev/null || echo "  tcp_mtu_probing: 未设置"
    sysctl net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo "  tcp_slow_start_after_idle: 未设置"
    
    echo ""
    echo "[缓冲区配置]"
    sysctl net.core.rmem_max 2>/dev/null || echo "  rmem_max: 未设置"
    sysctl net.core.wmem_max 2>/dev/null || echo "  wmem_max: 未设置"
    sysctl net.ipv4.tcp_rmem 2>/dev/null || echo "  tcp_rmem: 未设置"
    sysctl net.ipv4.tcp_wmem 2>/dev/null || echo "  tcp_wmem: 未设置"
    
    echo ""
    echo "[连接队列]"
    sysctl net.core.somaxconn 2>/dev/null || echo "  somaxconn: 未设置"
    sysctl net.ipv4.tcp_max_syn_backlog 2>/dev/null || echo "  tcp_max_syn_backlog: 未设置"
    
    echo ""
    echo "======================================"
}

apply_sysctl() {
    echo "[信息] 应用 sysctl 参数中..."
    sysctl --system >/dev/null 2>&1 || sysctl -p
    echo "[完成] 参数已生效"
}

test_network() {
    echo "========== 网络性能测试建议 =========="
    echo ""
    echo "[测试1] iperf3 带宽测试："
    echo "   服务端: iperf3 -s"
    echo "   客户端: iperf3 -c <服务器IP> -t 30 -P 10"
    echo ""
    echo "[测试2] 查看实时连接统计："
    echo "   ss -s"
    echo "   ss -ti | grep bbr"
    echo "   netstat -s | grep -i retrans"
    echo ""
    echo "[测试3] 监控缓冲区使用："
    echo "   ss -tim | head -20"
    echo ""
    echo "[测试4] 测试延迟："
    echo "   ping -c 100 <目标IP>"
    echo "   mtr <目标IP>"
    echo ""
    echo "[提示] 优化后建议重启相关服务（如 soga/nginx）"
    echo "   systemctl restart soga"
    echo "======================================"
}

# ========== 优化模式 ==========

apply_entry() {  # 入口节点优化
    backup_configs
    echo "[应用] 正在应用【入口节点优化 v5】（国内入口机）..."
    
    # 清理旧配置
    sed -i '/^net.ipv4.tcp_/d; /^net.core.rmem/d; /^net.core.wmem/d; /^net.core.default_qdisc/d; /^net.core.somaxconn/d; /^net.core.netdev/d; /^net.ipv4.udp_/d; /^net.ipv4.ip_local/d' /etc/sysctl.conf
    
cat >> /etc/sysctl.conf <<'EOF'

# ===== 入口节点优化 v5（国内入口机）=====
# 适用场景: 国内入口服务器，处理用户到入口的连接
# 特点: RTT较短(10-50ms)，连接数多，单连接带宽适中

# BBR 拥塞控制（推荐）
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# 基础 TCP 优化
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=2
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_early_retrans=3

# 连接优化
net.core.somaxconn=32768
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_max_tw_buckets=200000

# 缓冲区配置（入口：128MB，适合1-2Gbps + 短RTT）
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=8192 131072 134217728
net.ipv4.tcp_wmem=8192 131072 134217728
net.core.rmem_default=262144
net.core.wmem_default=262144

# UDP 优化
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

# 其他优化
net.core.netdev_max_backlog=10000
net.ipv4.ip_local_port_range=1024 65535

# ===== 入口节点优化结束 =====
EOF

    apply_sysctl
    echo ""
    echo "[成功] 已应用【入口节点优化 v5】"
    echo "[配置] 详情:"
    echo "   - 缓冲区: 128MB"
    echo "   - 拥塞控制: BBR + FQ"
    echo "   - 适用场景: 国内入口，1-2Gbps，短RTT"
    echo ""
}

apply_exit() {  # 中转出口优化
    backup_configs
    echo "[应用] 正在应用【中转出口优化 v5】（国外出口机）..."
    
    # 清理旧配置
    sed -i '/^net.ipv4.tcp_/d; /^net.core.rmem/d; /^net.core.wmem/d; /^net.core.default_qdisc/d; /^net.core.somaxconn/d; /^net.core.netdev/d; /^net.ipv4.udp_/d; /^net.ipv4.ip_local/d' /etc/sysctl.conf
    
cat >> /etc/sysctl.conf <<'EOF'

# ===== 中转出口优化 v5（国外出口机）=====
# 适用场景: 国外中转服务器，处理双向转发
# 特点: RTT中等(50-150ms)，转发为主，需要平衡上下行

# BBR 拥塞控制（强烈推荐）
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# 基础 TCP 优化
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=2
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_early_retrans=3

# 连接优化
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=16384
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=20
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_max_tw_buckets=400000

# 缓冲区配置（中转：256MB，适合2-5Gbps + 中等RTT）
net.core.rmem_max=268435456
net.core.wmem_max=268435456
net.ipv4.tcp_rmem=8192 131072 268435456
net.ipv4.tcp_wmem=8192 131072 268435456
net.core.rmem_default=262144
net.core.wmem_default=262144

# UDP 优化
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384

# 其他优化
net.core.netdev_max_backlog=10000
net.ipv4.ip_local_port_range=1024 65535

# ===== 中转出口优化结束 =====
EOF

    apply_sysctl
    echo ""
    echo "[成功] 已应用【中转出口优化 v5】"
    echo "[配置] 详情:"
    echo "   - 缓冲区: 256MB"
    echo "   - 拥塞控制: BBR + FQ"
    echo "   - 适用场景: 国外中转，2-5Gbps，中等RTT"
    echo ""
}

apply_exit_land() {  # 终点落地优化
    backup_configs
    echo "[应用] 正在应用【终点落地优化 v5】（落地机或纯落地）..."
    
    # 清理旧配置
    sed -i '/^net.ipv4.tcp_/d; /^net.core.rmem/d; /^net.core.wmem/d; /^net.core.default_qdisc/d; /^net.core.somaxconn/d; /^net.core.netdev/d; /^net.ipv4.udp_/d; /^net.ipv4.ip_local/d' /etc/sysctl.conf
    
cat >> /etc/sysctl.conf <<'EOF'

# ===== 终点落地优化 v5（落地机或纯落地）=====
# 适用场景: 纯落地服务器，前面有专门的中转
# 特点: RTT较短，主要处理落地到目标的连接

# BBR 拥塞控制（强烈推荐）
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# 基础 TCP 优化
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=2
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_early_retrans=3

# 连接优化
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=16384
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_max_tw_buckets=400000

# 缓冲区配置（落地：256MB，平衡配置）
net.core.rmem_max=268435456
net.core.wmem_max=268435456
net.ipv4.tcp_rmem=8192 262144 268435456
net.ipv4.tcp_wmem=8192 262144 268435456
net.core.rmem_default=262144
net.core.wmem_default=262144

# UDP 优化
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384

# 其他优化
net.core.netdev_max_backlog=10000
net.ipv4.ip_local_port_range=1024 65535

# ===== 终点落地优化结束 =====
EOF

    apply_sysctl
    echo ""
    echo "[成功] 已应用【终点落地优化 v5】"
    echo "[配置] 详情:"
    echo "   - 缓冲区: 256MB"
    echo "   - 拥塞控制: BBR + FQ"
    echo "   - 适用场景: 纯落地，2-5Gbps"
    echo ""
}

apply_exit_equal_land() {  # 出口等于落地优化（新增）
    backup_configs
    echo "[应用] 正在应用【出口等于落地优化 v5】（出口机=落地机）..."
    
    # 清理旧配置
    sed -i '/^net.ipv4.tcp_/d; /^net.core.rmem/d; /^net.core.wmem/d; /^net.core.default_qdisc/d; /^net.core.somaxconn/d; /^net.core.netdev/d; /^net.ipv4.udp_/d; /^net.ipv4.ip_local/d' /etc/sysctl.conf
    
cat >> /etc/sysctl.conf <<'EOF'

# ===== 出口等于落地优化 v5（出口机=落地机，直连场景）=====
# 适用场景: 出口和落地是同一台服务器（如 Trojan/V2Ray 直连）
# 特点: 需要同时处理长RTT入口连接和短RTT目标连接
# 关键: 接收来自入口的跨国长延迟连接，需要大缓冲

# BBR 拥塞控制（强烈推荐）
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# 基础 TCP 优化
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=2
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_early_retrans=3

# 连接优化
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=16384
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_max_tw_buckets=400000

# 缓冲区配置（出口=落地：512MB，处理长RTT跨国连接）
# 这是核心：需要大缓冲来处理入口机的长RTT连接（150-300ms）
net.core.rmem_max=536870912
net.core.wmem_max=536870912
net.ipv4.tcp_rmem=8192 262144 536870912
net.ipv4.tcp_wmem=8192 262144 536870912
net.core.rmem_default=262144
net.core.wmem_default=262144

# 降低发送缓冲低水位（减少延迟）
net.ipv4.tcp_notsent_lowat=131072

# UDP 优化
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384

# 其他优化
net.core.netdev_max_backlog=10000
net.ipv4.ip_local_port_range=1024 65535

# ===== 出口等于落地优化结束 =====
EOF

    apply_sysctl
    echo ""
    echo "[成功] 已应用【出口等于落地优化 v5】"
    echo "[配置] 详情:"
    echo "   - 缓冲区: 512MB（针对长RTT优化）"
    echo "   - 拥塞控制: BBR + FQ"
    echo "   - 适用场景: Trojan/V2Ray 直连，出口=落地"
    echo "   - 为什么需要大缓冲: 处理跨国长RTT连接(150-300ms)"
    echo ""
    echo "[提示] 应用后建议重启服务（如 soga）:"
    echo "   systemctl restart soga"
    echo ""
}

apply_aggressive() {  # 激进优化
    backup_configs
    echo "[应用] 正在应用【激进优化 v5】（10Gbps+ 超高带宽场景）..."
    echo "[警告] 此配置占用大量内存，请确保服务器有足够资源！"
    read -rp "确认继续？[y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "已取消"; return; }
    
    # 清理旧配置
    sed -i '/^net.ipv4.tcp_/d; /^net.core.rmem/d; /^net.core.wmem/d; /^net.core.default_qdisc/d; /^net.core.somaxconn/d; /^net.core.netdev/d; /^net.ipv4.udp_/d; /^net.ipv4.ip_local/d' /etc/sysctl.conf
    
cat >> /etc/sysctl.conf <<'EOF'

# ===== 激进优化 v5（10Gbps+ 超高带宽场景）=====
# 适用场景: 10Gbps 以上带宽，服务器内存充足（16GB+）
# 特点: 巨型缓冲区，超高并发，适合数据中心骨干网

# BBR 拥塞控制
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# 基础 TCP 优化
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=2
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_early_retrans=3

# 连接优化（超高并发）
net.core.somaxconn=131072
net.ipv4.tcp_max_syn_backlog=32768
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_max_tw_buckets=2000000

# 巨型缓冲区配置（1GB）
net.core.rmem_max=1073741824
net.core.wmem_max=1073741824
net.ipv4.tcp_rmem=8192 524288 1073741824
net.ipv4.tcp_wmem=8192 524288 1073741824
net.core.rmem_default=1048576
net.core.wmem_default=1048576

# 降低发送缓冲低水位
net.ipv4.tcp_notsent_lowat=262144

# UDP 优化
net.ipv4.udp_rmem_min=32768
net.ipv4.udp_wmem_min=32768

# 高性能优化
net.core.netdev_max_backlog=50000
net.core.netdev_budget=600
net.core.netdev_budget_usecs=8000
net.ipv4.ip_local_port_range=1024 65535

# ===== 激进优化结束 =====
EOF

    apply_sysctl
    echo ""
    echo "[成功] 已应用【激进优化 v5】"
    echo "[配置] 详情:"
    echo "   - 缓冲区: 1GB"
    echo "   - 拥塞控制: BBR + FQ"
    echo "   - 适用场景: 10Gbps+，内存16GB+"
    echo ""
}

restore_backup() {
    echo "请输入备份目录路径（例如 /root/netopt_backup_HOST_日期）："
    read -rp "路径: " RESTORE_PATH
    if [ -f "$RESTORE_PATH/restore.sh" ]; then
        bash "$RESTORE_PATH/restore.sh"
    else
        echo "[错误] 未找到 restore.sh，请检查路径"
    fi
}

show_help() {
    cat <<'HELP'
========================================
Linux 网络优化管理器 v5 - 使用说明
========================================

[各优化模式说明]

1. 入口节点优化
   - 缓冲区: 128MB
   - 适用: 国内入口服务器
   - 场景: 处理用户连接，RTT 短(10-50ms)
   - 带宽: 1-2Gbps

2. 中转出口优化
   - 缓冲区: 256MB
   - 适用: 国外中转服务器
   - 场景: 双向转发，RTT 中等(50-150ms)
   - 带宽: 2-5Gbps

3. 终点落地优化
   - 缓冲区: 256MB
   - 适用: 纯落地服务器（前面有专门中转）
   - 场景: 落地到目标，RTT 较短
   - 带宽: 2-5Gbps

4. 出口等于落地优化 [推荐 Trojan/V2Ray]
   - 缓冲区: 512MB
   - 适用: 出口和落地同一台（直连场景）
   - 场景: 需要处理长RTT入口连接(150-300ms)
   - 带宽: 5-10Gbps
   - 典型: soga/Trojan/V2Ray 单机部署

5. 激进优化
   - 缓冲区: 1GB
   - 适用: 超高带宽场景
   - 场景: 数据中心，骨干网
   - 带宽: 10Gbps+
   - 要求: 内存 16GB+

[为什么缓冲区大小不同？]
   不是因为速率不同，而是因为 RTT 不同！
   BDP = 带宽 × RTT
   
   例如 1Gbps 带宽：
   - RTT 30ms → BDP 3.75MB → 128MB 够用
   - RTT 200ms → BDP 25MB → 需要 512MB

[优化后操作]
   1. 重启相关服务: systemctl restart soga
   2. 测试带宽: iperf3 -c <服务器> -t 30 -P 10
   3. 查看 BBR: ss -ti | grep bbr
   4. 监控重传: netstat -s | grep retrans

[注意事项]
   - 优化前会自动备份配置
   - 大缓冲区会占用更多内存
   - 建议在低峰期应用优化
   - 应用后需重启服务才能完全生效

[恢复配置]
   使用菜单选项 10，或直接运行备份目录中的 restore.sh

[问题排查]
   1. 检查内核支持: 选项 7
   2. 查看当前配置: 选项 6
   3. 测试工具建议: 选项 8

========================================
HELP
}

# ========== 主菜单 ==========
while true; do
    clear
    echo "========= Linux 网络优化管理 v5 ========="
    echo "主机名: $HOST"
    echo "日期: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================="
    echo ""
    echo "[优化模式选择]"
    echo "----------------------------------------"
    echo "1. 入口节点优化 (128MB, 国内入口)"
    echo "2. 中转出口优化 (256MB, 国外中转)"
    echo "3. 终点落地优化 (256MB, 纯落地)"
    echo "4. 出口=落地优化 (512MB, Trojan/V2Ray) [推荐]"
    echo "5. 激进优化 (1GB, 10Gbps+)"
    echo ""
    echo "[工具选项]"
    echo "----------------------------------------"
    echo "6. 查看当前网络配置"
    echo "7. 检查内核支持"
    echo "8. 测试工具建议"
    echo "9. 备份当前配置"
    echo "10. 从备份恢复"
    echo "11. 帮助文档"
    echo "0. 退出"
    echo "========================================="
    echo ""
    read -rp "请选择操作 [0-11]: " CHOICE
    
    case "$CHOICE" in
        1)
            apply_entry
            read -rp "按回车返回菜单..."
            ;;
        2)
            apply_exit
            read -rp "按回车返回菜单..."
            ;;
        3)
            apply_exit_land
            read -rp "按回车返回菜单..."
            ;;
        4)
            apply_exit_equal_land
            read -rp "按回车返回菜单..."
            ;;
        5)
            apply_aggressive
            read -rp "按回车返回菜单..."
            ;;
        6)
            show_current
            read -rp "按回车返回菜单..."
            ;;
        7)
            check_kernel
            read -rp "按回车返回菜单..."
            ;;
        8)
            test_network
            read -rp "按回车返回菜单..."
            ;;
        9)
            backup_configs
            read -rp "按回车返回菜单..."
            ;;
        10)
            restore_backup
            read -rp "按回车返回菜单..."
            ;;
        11)
            show_help
            read -rp "按回车返回菜单..."
            ;;
        0)
            echo ""
            echo "[退出] 感谢使用 Linux 网络优化管理器 v5"
            echo "[提示] 记得重启相关服务: systemctl restart <服务名>"
            echo ""
            exit 0
            ;;
        *)
            echo "[错误] 无效选项，请重新选择"
            sleep 1
            ;;
    esac
done
