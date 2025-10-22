#!/usr/bin/env bash
# ==========================================
# Linux 网络优化管理器 v6（模块化版本）
# ------------------------------------------
# 改进：拥塞控制和队列调度独立配置
# 1-5: TCP 参数和缓冲区优化（不含拥塞控制）
# 12-15: 独立的拥塞控制和队列算法选择
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
# 清理网卡队列
for iface in $(ip link show | grep "state UP" | awk -F: '{print $2}' | xargs); do
    tc qdisc del dev $iface root 2>/dev/null || true
done
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
    if grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        echo "[OK] 内核支持 BBR"
    else
        echo "[警告] 内核不支持 BBR（需要 4.9+）"
    fi
    
    # 检查队列调度支持
    echo ""
    echo "[队列调度支持检查]"
    modprobe sch_fq 2>/dev/null && echo "  ✓ FQ" || echo "  ✗ FQ"
    modprobe sch_fq_codel 2>/dev/null && echo "  ✓ FQ_CODEL" || echo "  ✗ FQ_CODEL"
    modprobe sch_fq_pie 2>/dev/null && echo "  ✓ FQ_PIE" || echo "  ✗ FQ_PIE (需要4.20+)"
    modprobe sch_cake 2>/dev/null && echo "  ✓ CAKE" || echo "  ✗ CAKE (需要4.19+)"
    
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
    echo "[网卡队列]"
    for iface in $(ip link show | grep "state UP" | awk -F: '{print $2}' | xargs); do
        echo "  $iface:"
        tc qdisc show dev $iface | head -1 | sed 's/^/    /'
    done
    
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
    echo "[测试5] 查看队列统计："
    echo "   tc -s qdisc show"
    echo ""
    echo "[提示] 优化后建议重启相关服务（如 soga/nginx）"
    echo "   systemctl restart soga"
    echo "======================================"
}

# ========== TCP 优化模式（不含拥塞控制）==========

apply_entry() {  # 入口节点优化
    backup_configs
    echo "[应用] 正在应用【入口节点 TCP 优化】（国内入口机）..."
    
    # 只清理TCP参数，不清理拥塞控制
    sed -i '/^net.ipv4.tcp_no_metrics/d; /^net.ipv4.tcp_ecn/d; /^net.ipv4.tcp_frto/d; /^net.ipv4.tcp_mtu_probing/d; /^net.ipv4.tcp_rfc1337/d; /^net.ipv4.tcp_sack/d; /^net.ipv4.tcp_fack/d; /^net.ipv4.tcp_window_scaling/d; /^net.ipv4.tcp_moderate_rcvbuf/d; /^net.ipv4.tcp_fastopen/d; /^net.ipv4.tcp_slow_start_after_idle/d; /^net.ipv4.tcp_early_retrans/d; /^net.core.rmem/d; /^net.core.wmem/d; /^net.core.somaxconn/d; /^net.core.netdev/d; /^net.ipv4.udp_/d; /^net.ipv4.ip_local/d; /^net.ipv4.tcp_tw_reuse/d; /^net.ipv4.tcp_fin_timeout/d; /^net.ipv4.tcp_keepalive/d; /^net.ipv4.tcp_max/d; /^net.ipv4.tcp_limit_output_bytes/d; /^net.ipv4.tcp_notsent_lowat/d' /etc/sysctl.conf
    
cat >> /etc/sysctl.conf <<'EOF'

# ===== 入口节点 TCP 优化 v6（国内入口机）=====
# 适用场景: 国内入口服务器，处理用户到入口的连接
# 特点: RTT较短(10-50ms)，连接数多，单连接带宽适中
# 注意: 拥塞控制和队列调度需要单独配置（选项12-15）

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

# ===== 入口节点 TCP 优化结束 =====
EOF

    apply_sysctl
    echo ""
    echo "[成功] 已应用【入口节点 TCP 优化】"
    echo "[配置] 详情:"
    echo "   - 缓冲区: 128MB"
    echo "   - 适用场景: 国内入口，1-2Gbps，短RTT"
    echo ""
    echo "[提示] 请继续选择拥塞控制算法（选项12-15）"
    echo "   推荐: 选项12 (BBR + FQ_CODEL)"
    echo ""
}

apply_exit() {  # 中转出口优化
    backup_configs
    echo "[应用] 正在应用【中转出口 TCP 优化】（国外出口机）..."
    
    sed -i '/^net.ipv4.tcp_no_metrics/d; /^net.ipv4.tcp_ecn/d; /^net.ipv4.tcp_frto/d; /^net.ipv4.tcp_mtu_probing/d; /^net.ipv4.tcp_rfc1337/d; /^net.ipv4.tcp_sack/d; /^net.ipv4.tcp_fack/d; /^net.ipv4.tcp_window_scaling/d; /^net.ipv4.tcp_moderate_rcvbuf/d; /^net.ipv4.tcp_fastopen/d; /^net.ipv4.tcp_slow_start_after_idle/d; /^net.ipv4.tcp_early_retrans/d; /^net.core.rmem/d; /^net.core.wmem/d; /^net.core.somaxconn/d; /^net.core.netdev/d; /^net.ipv4.udp_/d; /^net.ipv4.ip_local/d; /^net.ipv4.tcp_tw_reuse/d; /^net.ipv4.tcp_fin_timeout/d; /^net.ipv4.tcp_keepalive/d; /^net.ipv4.tcp_max/d; /^net.ipv4.tcp_limit_output_bytes/d; /^net.ipv4.tcp_notsent_lowat/d' /etc/sysctl.conf
    
cat >> /etc/sysctl.conf <<'EOF'

# ===== 中转出口 TCP 优化 v6（国外出口机）=====
# 适用场景: 国外中转服务器，处理双向转发
# 特点: RTT中等(50-150ms)，转发为主，需要平衡上下行

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

# ===== 中转出口 TCP 优化结束 =====
EOF

    apply_sysctl
    echo ""
    echo "[成功] 已应用【中转出口 TCP 优化】"
    echo "[配置] 详情:"
    echo "   - 缓冲区: 256MB"
    echo "   - 适用场景: 国外中转，2-5Gbps，中等RTT"
    echo ""
    echo "[提示] 请继续选择拥塞控制算法（选项12-15）"
    echo "   推荐: 选项12 (BBR + FQ_CODEL)"
    echo ""
}

apply_exit_land() {  # 终点落地优化
    backup_configs
    echo "[应用] 正在应用【终点落地 TCP 优化】（落地机或纯落地）..."
    
    sed -i '/^net.ipv4.tcp_no_metrics/d; /^net.ipv4.tcp_ecn/d; /^net.ipv4.tcp_frto/d; /^net.ipv4.tcp_mtu_probing/d; /^net.ipv4.tcp_rfc1337/d; /^net.ipv4.tcp_sack/d; /^net.ipv4.tcp_fack/d; /^net.ipv4.tcp_window_scaling/d; /^net.ipv4.tcp_moderate_rcvbuf/d; /^net.ipv4.tcp_fastopen/d; /^net.ipv4.tcp_slow_start_after_idle/d; /^net.ipv4.tcp_early_retrans/d; /^net.core.rmem/d; /^net.core.wmem/d; /^net.core.somaxconn/d; /^net.core.netdev/d; /^net.ipv4.udp_/d; /^net.ipv4.ip_local/d; /^net.ipv4.tcp_tw_reuse/d; /^net.ipv4.tcp_fin_timeout/d; /^net.ipv4.tcp_keepalive/d; /^net.ipv4.tcp_max/d; /^net.ipv4.tcp_limit_output_bytes/d; /^net.ipv4.tcp_notsent_lowat/d' /etc/sysctl.conf
    
cat >> /etc/sysctl.conf <<'EOF'

# ===== 终点落地 TCP 优化 v6（落地机或纯落地）=====
# 适用场景: 纯落地服务器，前面有专门的中转
# 特点: RTT较短，主要处理落地到目标的连接

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

# 缓冲区配置（落地：256MB）
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

# ===== 终点落地 TCP 优化结束 =====
EOF

    apply_sysctl
    echo ""
    echo "[成功] 已应用【终点落地 TCP 优化】"
    echo "[配置] 详情:"
    echo "   - 缓冲区: 256MB"
    echo "   - 适用场景: 纯落地，前面有专门中转"
    echo ""
    echo "[提示] 请继续选择拥塞控制算法（选项12-15）"
    echo "   推荐: 选项12 (BBR + FQ_CODEL)"
    echo ""
}

apply_exit_equal_land() {  # 出口等于落地优化
    backup_configs
    echo "[应用] 正在应用【出口等于落地 TCP 优化】（出口+落地并存）..."
    
    sed -i '/^net.ipv4.tcp_no_metrics/d; /^net.ipv4.tcp_ecn/d; /^net.ipv4.tcp_frto/d; /^net.ipv4.tcp_mtu_probing/d; /^net.ipv4.tcp_rfc1337/d; /^net.ipv4.tcp_sack/d; /^net.ipv4.tcp_fack/d; /^net.ipv4.tcp_window_scaling/d; /^net.ipv4.tcp_moderate_rcvbuf/d; /^net.ipv4.tcp_fastopen/d; /^net.ipv4.tcp_slow_start_after_idle/d; /^net.ipv4.tcp_early_retrans/d; /^net.core.rmem/d; /^net.core.wmem/d; /^net.core.somaxconn/d; /^net.core.netdev/d; /^net.ipv4.udp_/d; /^net.ipv4.ip_local/d; /^net.ipv4.tcp_tw_reuse/d; /^net.ipv4.tcp_fin_timeout/d; /^net.ipv4.tcp_keepalive/d; /^net.ipv4.tcp_max/d; /^net.ipv4.tcp_limit_output_bytes/d; /^net.ipv4.tcp_notsent_lowat/d' /etc/sysctl.conf
    
cat >> /etc/sysctl.conf <<'EOF'

# ===== 出口等于落地 TCP 优化 v6（出口+落地并存）=====
# 适用场景: 出口和落地在同一台机器
# 特点: 需要处理双向连接，长短RTT混合

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
net.ipv4.tcp_early_retrans=4

# 连接优化
net.core.somaxconn=131072
net.ipv4.tcp_max_syn_backlog=32768
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_max_tw_buckets=2000000

# 缓冲区配置（出口=落地：256MB，配合队列管理）
# 注意：使用 FQ_CODEL 时不需要太大缓冲区
net.core.rmem_max=268435456
net.core.wmem_max=268435456
net.ipv4.tcp_rmem=4096 87380 268435456
net.ipv4.tcp_wmem=4096 87380 268435456
net.core.rmem_default=262144
net.core.wmem_default=262144

# 关键：限制单连接占用（防止Bufferbloat）
net.ipv4.tcp_limit_output_bytes=131072
net.ipv4.tcp_notsent_lowat=16384

# UDP 优化
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384

# 其他优化
net.core.netdev_max_backlog=50000
net.core.netdev_budget=600
net.core.netdev_budget_usecs=8000
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_max_orphans=262144

# ===== 出口等于落地 TCP 优化结束 =====
EOF

    apply_sysctl
    echo ""
    echo "[成功] 已应用【出口等于落地 TCP 优化】"
    echo "[配置] 详情:"
    echo "   - 缓冲区: 256MB（配合队列管理）"
    echo "   - 单连接限制: 128KB"
    echo "   - 适用场景: 出口+落地并存，高并发"
    echo ""
    echo "[提示] 请继续选择拥塞控制算法（选项12-15）"
    echo "   强烈推荐: 选项12 (BBR + FQ_CODEL) ⭐⭐⭐⭐⭐"
    echo ""
}

apply_aggressive() {  # 激进优化
    backup_configs
    echo "[应用] 正在应用【激进 TCP 优化】（10Gbps+ 超高带宽场景）..."
    echo "[警告] 此配置占用大量内存，请确保服务器有足够资源！"
    read -rp "确认继续？[y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "已取消"; return; }
    
    sed -i '/^net.ipv4.tcp_no_metrics/d; /^net.ipv4.tcp_ecn/d; /^net.ipv4.tcp_frto/d; /^net.ipv4.tcp_mtu_probing/d; /^net.ipv4.tcp_rfc1337/d; /^net.ipv4.tcp_sack/d; /^net.ipv4.tcp_fack/d; /^net.ipv4.tcp_window_scaling/d; /^net.ipv4.tcp_moderate_rcvbuf/d; /^net.ipv4.tcp_fastopen/d; /^net.ipv4.tcp_slow_start_after_idle/d; /^net.ipv4.tcp_early_retrans/d; /^net.core.rmem/d; /^net.core.wmem/d; /^net.core.somaxconn/d; /^net.core.netdev/d; /^net.ipv4.udp_/d; /^net.ipv4.ip_local/d; /^net.ipv4.tcp_tw_reuse/d; /^net.ipv4.tcp_fin_timeout/d; /^net.ipv4.tcp_keepalive/d; /^net.ipv4.tcp_max/d; /^net.ipv4.tcp_limit_output_bytes/d; /^net.ipv4.tcp_notsent_lowat/d' /etc/sysctl.conf
    
cat >> /etc/sysctl.conf <<'EOF'

# ===== 激进 TCP 优化 v6（10Gbps+ 超高带宽场景）=====
# 适用场景: 10Gbps 以上带宽，服务器内存充足（16GB+）
# 特点: 超大缓冲区，超高并发

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
net.ipv4.tcp_early_retrans=4

# 连接优化（超高并发）
net.core.somaxconn=131072
net.ipv4.tcp_max_syn_backlog=32768
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_max_tw_buckets=2000000

# 超大缓冲区配置（512MB）
net.core.rmem_max=536870912
net.core.wmem_max=536870912
net.ipv4.tcp_rmem=8192 524288 536870912
net.ipv4.tcp_wmem=8192 524288 536870912
net.core.rmem_default=1048576
net.core.wmem_default=1048576

# 限制单连接
net.ipv4.tcp_limit_output_bytes=262144
net.ipv4.tcp_notsent_lowat=131072

# UDP 优化
net.ipv4.udp_rmem_min=32768
net.ipv4.udp_wmem_min=32768

# 高性能优化
net.core.netdev_max_backlog=50000
net.core.netdev_budget=600
net.core.netdev_budget_usecs=8000
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_max_orphans=262144

# ===== 激进 TCP 优化结束 =====
EOF

    apply_sysctl
    echo ""
    echo "[成功] 已应用【激进 TCP 优化】"
    echo "[配置] 详情:"
    echo "   - 缓冲区: 512MB"
    echo "   - 适用场景: 10Gbps+，内存16GB+"
    echo ""
    echo "[提示] 请继续选择拥塞控制算法（选项12-15）"
    echo "   推荐: 选项12 (BBR + FQ_CODEL)"
    echo ""
}

# ========== 拥塞控制和队列调度配置 ==========

apply_bbr_fq() {
    echo "[应用] 正在配置【BBR + FQ】..."
    
    # 只修改拥塞控制相关配置
    sed -i '/^net.core.default_qdisc/d; /^net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    
    cat >> /etc/sysctl.conf <<'EOF'

# ===== 拥塞控制: BBR + FQ =====
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    
    echo "[完成] BBR + FQ 已启用"
    echo "[提示] FQ 适合低并发场景（<200人）"
}

apply_bbr_fq_codel() {
    echo "[应用] 正在配置【BBR + FQ_CODEL】（推荐）..."
    
    sed -i '/^net.core.default_qdisc/d; /^net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    
    cat >> /etc/sysctl.conf <<'EOF'

# ===== 拥塞控制: BBR + FQ_CODEL（推荐）=====
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_ecn=1
EOF

    sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_ecn=1 >/dev/null 2>&1
    
    # 配置网卡队列
    echo "[配置] 正在配置网卡 FQ_CODEL 队列..."
    for IFACE in $(ip link show | grep "state UP" | awk -F: '{print $2}' | xargs); do
        echo "  → 配置网卡: $IFACE"
        tc qdisc del dev $IFACE root 2>/dev/null || true
        if tc qdisc add dev $IFACE root fq_codel \
            limit 10240 flows 1024 quantum 1514 \
            target 5ms interval 100ms ecn 2>/dev/null; then
            echo "    ✓ 成功"
        else
            tc qdisc add dev $IFACE root fq_codel \
                limit 10240 flows 1024 target 5ms interval 100ms noecn 2>/dev/null \
                && echo "    ✓ 成功（无ECN）" || echo "    ✗ 失败"
        fi
    done
    
    # 创建开机自启动
    cat > /etc/systemd/system/fq-codel-setup.service <<'SVCEOF'
[Unit]
Description=FQ_CODEL Queue Setup
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for iface in $(ip link show | grep "state UP" | awk -F: "{print \\$2}" | xargs); do tc qdisc del dev $iface root 2>/dev/null || true; tc qdisc add dev $iface root fq_codel limit 10240 flows 1024 target 5ms interval 100ms ecn 2>/dev/null || tc qdisc add dev $iface root fq_codel limit 10240 flows 1024 target 5ms interval 100ms noecn; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
    
    systemctl daemon-reload
    systemctl enable fq-codel-setup.service >/dev/null 2>&1
    
    echo "[完成] BBR + FQ_CODEL 已启用"
    echo "[优势] 自动防止 Bufferbloat，适合高并发（200+人）"
}

apply_bbr_cake() {
    echo "[应用] 正在配置【BBR + CAKE】（进阶）..."
    
    # 检查 CAKE 支持
    if ! modprobe sch_cake 2>/dev/null; then
        echo "[错误] 内核不支持 CAKE（需要 4.19+）"
        echo "[建议] 使用 FQ_CODEL 替代（选项12）"
        return 1
    fi
    
    sed -i '/^net.core.default_qdisc/d; /^net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    
    cat >> /etc/sysctl.conf <<'EOF'

# ===== 拥塞控制: BBR + CAKE（进阶）=====
# CAKE 自己管理队列，不需要 default_qdisc
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_ecn=1
EOF

    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_ecn=1 >/dev/null 2>&1
    
    # 配置网卡 CAKE
    echo "[配置] 正在配置网卡 CAKE 队列..."
    for IFACE in $(ip link show | grep "state UP" | awk -F: '{print $2}' | xargs); do
        echo "  → 配置网卡: $IFACE"
        
        SPEED=$(ethtool $IFACE 2>/dev/null | grep "Speed:" | awk '{print $2}' | sed 's/Mb\/s//')
        if [ -z "$SPEED" ] || [ "$SPEED" == "Unknown!" ]; then
            BANDWIDTH="1Gbit"
        else
            BANDWIDTH="${SPEED}Mbit"
        fi
        
        tc qdisc del dev $IFACE root 2>/dev/null || true
        if tc qdisc add dev $IFACE root cake \
            bandwidth $BANDWIDTH besteffort triple-isolate \
            nonat nowash no-ack-filter rtt 50ms 2>/dev/null; then
            echo "    ✓ 成功 (带宽: $BANDWIDTH)"
        else
            echo "    ✗ CAKE 失败，回退到 FQ_CODEL"
            tc qdisc add dev $IFACE root fq_codel limit 10240 flows 1024 ecn 2>/dev/null
        fi
    done
    
    echo "[完成] BBR + CAKE 已启用"
    echo "[优势] 功能最强大，延迟最稳定，但 CPU 占用高"
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
Linux 网络优化管理器 v6 - 使用说明
========================================

[重要改进]
v6 版本将 TCP 参数优化和拥塞控制算法分离：
1. 先选择 TCP 优化模式（选项1-5）
2. 再选择拥塞控制算法（选项12-14）

[TCP 优化模式（1-5）]

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

4. 出口等于落地优化 ⭐ [推荐]
   - 缓冲区: 256MB + 单连接限制
   - 适用: 出口和落地同一台（直连场景）
   - 场景: 高并发，长短RTT混合
   - 带宽: 5-10Gbps
   - 典型: soga/Trojan/V2Ray 单机部署

5. 激进优化
   - 缓冲区: 512MB
   - 适用: 超高带宽场景
   - 场景: 数据中心，骨干网
   - 带宽: 10Gbps+
   - 要求: 内存 16GB+

[拥塞控制算法（12-14）]

12. BBR + FQ_CODEL ⭐⭐⭐⭐⭐ [强烈推荐]
    - 最适合: 所有场景，特别是高并发（200+人）
    - 优点: 自动防止 Bufferbloat，延迟稳定
    - 缺点: 几乎没有
    - 适用: 入口/出口/落地/出口+落地

13. BBR + FQ ⭐⭐
    - 最适合: 低并发场景（<100人）
    - 优点: 简单，资源占用低
    - 缺点: 高并发时会掉速
    - 适用: 测试环境，低负载场景

14. BBR + CAKE ⭐⭐⭐⭐
    - 最适合: 追求极致性能的用户
    - 优点: 功能最强大，延迟最稳定
    - 缺点: 配置复杂，CPU 占用高，需要 4.19+ 内核
    - 适用: 高端场景，愿意折腾的用户

[推荐组合]

场景1: 国内入口，500人在线
→ 选项1 (入口节点) + 选项12 (BBR+FQ_CODEL)

场景2: 香港出口（纯中转），500人在线
→ 选项2 (中转出口) + 选项12 (BBR+FQ_CODEL)

场景3: 纯落地机器，500人在线
→ 选项3 (终点落地) + 选项12 (BBR+FQ_CODEL)

场景4: 出口+落地并存，500人在线 ⭐⭐⭐⭐⭐
→ 选项4 (出口=落地) + 选项12 (BBR+FQ_CODEL)
   这是最常见且最需要优化的场景！

场景5: 测试环境，<50人
→ 选项2 (中转出口) + 选项13 (BBR+FQ)

[使用流程]

步骤1: 先配置 TCP 参数
   选择选项 1-5 中的一个

步骤2: 再配置拥塞控制
   选择选项 12-14 中的一个（推荐12）

步骤3: 重启服务
   systemctl restart soga
   systemctl restart naiveproxy

步骤4: 验证效果
   tc qdisc show
   ss -ti | grep bbr
   tc -s qdisc show

[优化后操作]
   1. 重启相关服务: systemctl restart soga
   2. 测试带宽: iperf3 -c <服务器> -t 30 -P 10
   3. 查看 BBR: ss -ti | grep bbr
   4. 监控队列: tc -s qdisc show
   5. 监控重传: netstat -s | grep retrans

[注意事项]
   - 优化前会自动备份配置
   - 必须先配置 TCP 参数（1-5），再配置拥塞控制（12-14）
   - 建议在低峰期应用优化
   - 应用后需重启服务才能完全生效

[恢复配置]
   使用菜单选项 10，或直接运行备份目录中的 restore.sh

========================================
HELP
}

# ========== 主菜单 ==========
while true; do
    clear
    echo "========= Linux 网络优化管理 v6 ========="
    echo "主机名: $HOST"
    echo "日期: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================="
    echo ""
    echo "[第一步: TCP 参数优化]"
    echo "----------------------------------------"
    echo "1. 入口节点优化 (128MB, 国内入口)"
    echo "2. 中转出口优化 (256MB, 国外中转)"
    echo "3. 终点落地优化 (256MB, 纯落地)"
    echo "4. 出口=落地优化 (256MB, 出口+落地) ⭐ [推荐]"
    echo "5. 激进优化 (512MB, 10Gbps+)"
    echo ""
    echo "[第二步: 拥塞控制算法]"
    echo "----------------------------------------"
    echo "6. BBR + FQ_CODEL ⭐⭐⭐⭐⭐ [强烈推荐]"
    echo "7. BBR + FQ (低并发场景)"
    echo "8. BBR + CAKE (进阶，需要 4.19+)"
    echo ""
    echo "[工具选项]"
    echo "----------------------------------------"
    echo "9. 查看当前网络配置"
    echo "10. 检查内核支持"
    echo "11. 测试工具建议"
    echo "12. 备份当前配置"
    echo "13. 从备份恢复"
    echo "14. 帮助文档"
    echo "0. 退出"
    echo "========================================="
    echo ""
    read -rp "请选择操作 [0-14]: " CHOICE
    
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
            apply_bbr_fq_codel
            read -rp "按回车返回菜单..."
            ;;
        7)
            apply_bbr_fq
            read -rp "按回车返回菜单..."
            ;;
        8)
            apply_bbr_cake
            read -rp "按回车返回菜单..."
            ;;
        9)
            show_current
            read -rp "按回车返回菜单..."
            ;;
        10)
            check_kernel
            read -rp "按回车返回菜单..."
            ;;
        11)
            test_network
            read -rp "按回车返回菜单..."
            ;;
        12)
            backup_configs
            read -rp "按回车返回菜单..."
            ;;
        13)
            restore_backup
            read -rp "按回车返回菜单..."
            ;;
        14)
            show_help
            read -rp "按回车返回菜单..."
            ;;
        0)
            echo ""
            echo "[退出] 感谢使用 Linux 网络优化管理器 v6"
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
