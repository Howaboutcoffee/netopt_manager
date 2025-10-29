#!/usr/bin/env bash
# ==========================================
# Linux 网络优化管理器 v8（Debian 13 修复版）
# ------------------------------------------
# 改进：BBR+FQ 已集成到每个 TCP 优化方案中
# 修复：备份函数改用 cp 而非 cp -a（Debian 13兼容）
# 修复：确保文件存在才执行 sed 操作
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
    
    # 改用 cp 而非 cp -a，避免 Debian 13 的潜在问题
    [ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.bak" 2>/dev/null || touch "$BACKUP_DIR/sysctl.conf.bak"
    [ -f /etc/security/limits.conf ] && cp /etc/security/limits.conf "$BACKUP_DIR/limits.conf.bak" 2>/dev/null || true
    [ -f /etc/systemd/system.conf ] && cp /etc/systemd/system.conf "$BACKUP_DIR/system.conf.bak" 2>/dev/null || true
    command -v iptables-save >/dev/null 2>&1 && iptables-save > "$BACKUP_DIR/iptables.bak" 2>/dev/null || true

    cat > "$BACKUP_DIR/restore.sh" <<'EOF'
#!/usr/bin/env bash
set -e
[ "$(id -u)" -eq 0 ] || { echo "请以 root 运行此脚本"; exit 1; }
BASEDIR="$(dirname "$0")"
[ -f "$BASEDIR/sysctl.conf.bak" ] && cp "$BASEDIR/sysctl.conf.bak" /etc/sysctl.conf 2>/dev/null || true
[ -f "$BASEDIR/limits.conf.bak" ] && cp "$BASEDIR/limits.conf.bak" /etc/security/limits.conf 2>/dev/null || true
[ -f "$BASEDIR/system.conf.bak" ] && cp "$BASEDIR/system.conf.bak" /etc/systemd/system.conf 2>/dev/null || true
[ -f "$BASEDIR/iptables.bak" ] && command -v iptables-restore >/dev/null 2>&1 && iptables-restore < "$BASEDIR/iptables.bak" || true
# 清理网卡队列
for iface in $(ip link show | grep "state UP" | awk -F: '{print $2}' | xargs); do
    tc qdisc del dev $iface root 2>/dev/null || true
done
sysctl --system >/dev/null 2>&1 || true
systemctl daemon-reexec 2>/dev/null || true
echo "[成功] 已恢复至备份配置"
EOF
    chmod +x "$BACKUP_DIR/restore.sh"
    echo "[完成] 备份完成，可用 $BACKUP_DIR/restore.sh 恢复"
}

# 确保 sysctl.conf 存在
ensure_sysctl_conf() {
    if [ ! -f /etc/sysctl.conf ]; then
        echo "[警告] /etc/sysctl.conf 不存在，正在创建..."
        touch /etc/sysctl.conf
        chmod 644 /etc/sysctl.conf
    fi
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
    
    # 检查 FQ 支持
    echo ""
    echo "[队列调度支持检查]"
    modprobe sch_fq 2>/dev/null && echo "  ✓ FQ (将被使用)" || echo "  ✗ FQ (需要 3.18+)"
    
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

configure_network_queues() {
    echo "[配置] 正在配置网卡队列为 FQ..."
    for IFACE in $(ip link show | grep "state UP" | awk -F: '{print $2}' | xargs); do
        echo "  → 配置网卡: $IFACE"
        tc qdisc del dev $IFACE root 2>/dev/null || true
        if tc qdisc add dev $IFACE root fq 2>/dev/null; then
            echo "    ✓ FQ 队列已启用"
        else
            echo "    ✗ FQ 失败，使用默认队列"
        fi
    done
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

# ========== TCP 优化模式（已集成 BBR+FQ）==========

apply_entry() {  # 入口节点优化
    backup_configs
    ensure_sysctl_conf
    echo "[应用] 正在应用【入口节点 TCP 优化】（国内入口机）..."
    
    # 清理旧配置
    sed -i '/^net.ipv4.tcp_no_metrics/d; /^net.ipv4.tcp_ecn/d; /^net.ipv4.tcp_frto/d; /^net.ipv4.tcp_mtu_probing/d; /^net.ipv4.tcp_rfc1337/d; /^net.ipv4.tcp_sack/d; /^net.ipv4.tcp_fack/d; /^net.ipv4.tcp_window_scaling/d; /^net.ipv4.tcp_moderate_rcvbuf/d; /^net.ipv4.tcp_fastopen/d; /^net.ipv4.tcp_slow_start_after_idle/d; /^net.ipv4.tcp_early_retrans/d; /^net.core.rmem/d; /^net.core.wmem/d; /^net.core.somaxconn/d; /^net.core.netdev/d; /^net.ipv4.udp_/d; /^net.ipv4.ip_local/d; /^net.ipv4.tcp_tw_reuse/d; /^net.ipv4.tcp_fin_timeout/d; /^net.ipv4.tcp_keepalive/d; /^net.ipv4.tcp_max/d; /^net.ipv4.tcp_limit_output_bytes/d; /^net.ipv4.tcp_notsent_lowat/d; /^net.core.default_qdisc/d; /^net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    
cat >> /etc/sysctl.conf <<'EOF'

# ===== 入口节点 TCP 优化 v8（国内入口机）=====
# 适用场景: 国内入口服务器，处理用户到入口的连接
# 特点: RTT较短(10-50ms)，连接数多，单连接带宽适中
# 拥塞控制: BBR + FQ（已集成）

# 拥塞控制算法
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# 基础 TCP 优化
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=1
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

# 连接优化（高并发，接收所有用户连接）
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=16384
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_max_tw_buckets=200000

# 缓冲区配置（入口：256MB，连接数多需要更大缓冲）
net.core.rmem_max=268435456
net.core.wmem_max=268435456
net.ipv4.tcp_rmem=8192 131072 268435456
net.ipv4.tcp_wmem=8192 131072 268435456
net.core.rmem_default=262144
net.core.wmem_default=262144

# UDP 优化
net.ipv4.udp_rmem_min=65536
net.ipv4.udp_wmem_min=65536

# 其他优化
net.core.netdev_max_backlog=10000
net.ipv4.ip_local_port_range=1024 65535

# ===== 入口节点 TCP 优化结束 =====
EOF

    apply_sysctl
    configure_network_queues
    
    echo ""
    echo "[成功] 已应用【入口节点 TCP 优化】+ BBR+FQ"
    echo "[配置] 详情:"
    echo "   - 拥塞控制: BBR + FQ"
    echo "   - 缓冲区: 256MB（连接数多需要更大缓冲）"
    echo "   - 适用场景: 国内入口，1-2Gbps，短RTT"
    echo ""
}

apply_exit() {  # 中转出口优化
    backup_configs
    ensure_sysctl_conf
    echo "[应用] 正在应用【中转出口 TCP 优化】（国外出口机）..."
    
    sed -i '/^net.ipv4.tcp_no_metrics/d; /^net.ipv4.tcp_ecn/d; /^net.ipv4.tcp_frto/d; /^net.ipv4.tcp_mtu_probing/d; /^net.ipv4.tcp_rfc1337/d; /^net.ipv4.tcp_sack/d; /^net.ipv4.tcp_fack/d; /^net.ipv4.tcp_window_scaling/d; /^net.ipv4.tcp_moderate_rcvbuf/d; /^net.ipv4.tcp_fastopen/d; /^net.ipv4.tcp_slow_start_after_idle/d; /^net.ipv4.tcp_early_retrans/d; /^net.core.rmem/d; /^net.core.wmem/d; /^net.core.somaxconn/d; /^net.core.netdev/d; /^net.ipv4.udp_/d; /^net.ipv4.ip_local/d; /^net.ipv4.tcp_tw_reuse/d; /^net.ipv4.tcp_fin_timeout/d; /^net.ipv4.tcp_keepalive/d; /^net.ipv4.tcp_max/d; /^net.ipv4.tcp_limit_output_bytes/d; /^net.ipv4.tcp_notsent_lowat/d; /^net.core.default_qdisc/d; /^net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    
cat >> /etc/sysctl.conf <<'EOF'

# ===== 中转出口 TCP 优化 v8（国外出口机）=====
# 适用场景: 国外中转服务器，处理双向转发
# 特点: RTT中等(50-150ms)，转发为主，需要平衡上下行
# 拥塞控制: BBR + FQ（已集成）

# 拥塞控制算法
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# 基础 TCP 优化
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=1
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

# 连接优化（保持大量到入口的长连接）
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=16384
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=20
net.ipv4.tcp_keepalive_time=300
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
net.ipv4.udp_rmem_min=65536
net.ipv4.udp_wmem_min=65536

# 其他优化
net.core.netdev_max_backlog=10000
net.ipv4.ip_local_port_range=1024 65535

# ===== 中转出口 TCP 优化结束 =====
EOF

    apply_sysctl
    configure_network_queues
    
    echo ""
    echo "[成功] 已应用【中转出口 TCP 优化】+ BBR+FQ"
    echo "[配置] 详情:"
    echo "   - 拥塞控制: BBR + FQ"
    echo "   - 缓冲区: 256MB"
    echo "   - 适用场景: 国外中转，2-5Gbps，中等RTT"
    echo ""
}

apply_exit_land() {  # 终点落地优化
    backup_configs
    ensure_sysctl_conf
    echo "[应用] 正在应用【终点落地 TCP 优化】（纯落地机）..."
    
    sed -i '/^net.ipv4.tcp_no_metrics/d; /^net.ipv4.tcp_ecn/d; /^net.ipv4.tcp_frto/d; /^net.ipv4.tcp_mtu_probing/d; /^net.ipv4.tcp_rfc1337/d; /^net.ipv4.tcp_sack/d; /^net.ipv4.tcp_fack/d; /^net.ipv4.tcp_window_scaling/d; /^net.ipv4.tcp_moderate_rcvbuf/d; /^net.ipv4.tcp_fastopen/d; /^net.ipv4.tcp_slow_start_after_idle/d; /^net.ipv4.tcp_early_retrans/d; /^net.core.rmem/d; /^net.core.wmem/d; /^net.core.somaxconn/d; /^net.core.netdev/d; /^net.ipv4.udp_/d; /^net.ipv4.ip_local/d; /^net.ipv4.tcp_tw_reuse/d; /^net.ipv4.tcp_fin_timeout/d; /^net.ipv4.tcp_keepalive/d; /^net.ipv4.tcp_max/d; /^net.ipv4.tcp_limit_output_bytes/d; /^net.ipv4.tcp_notsent_lowat/d; /^net.core.default_qdisc/d; /^net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    
cat >> /etc/sysctl.conf <<'EOF'

# ===== 终点落地 TCP 优化 v8（纯落地机）⭐ =====
# 适用场景: 纯落地服务器（前面有专门中转）[最常见场景]
# 特点: 落地到目标，RTT较短，带宽需求高，数量最多（50-60台）
# 拥塞控制: BBR + FQ（已集成）

# 拥塞控制算法
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# 基础 TCP 优化
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=1
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

# 缓冲区配置（落地：256MB，适合2-5Gbps）
net.core.rmem_max=268435456
net.core.wmem_max=268435456
net.ipv4.tcp_rmem=8192 131072 268435456
net.ipv4.tcp_wmem=8192 131072 268435456
net.core.rmem_default=262144
net.core.wmem_default=262144

# UDP 优化
net.ipv4.udp_rmem_min=65536
net.ipv4.udp_wmem_min=65536

# 其他优化
net.core.netdev_max_backlog=10000
net.ipv4.ip_local_port_range=1024 65535

# ===== 终点落地 TCP 优化结束 =====
EOF

    apply_sysctl
    configure_network_queues
    
    echo ""
    echo "[成功] 已应用【终点落地 TCP 优化】+ BBR+FQ ⭐"
    echo "[配置] 详情:"
    echo "   - 拥塞控制: BBR + FQ"
    echo "   - 缓冲区: 256MB"
    echo "   - 适用场景: 纯落地，2-5Gbps [最常见，数量最多]"
    echo ""
}

apply_exit_equal_land() {  # 出口等于落地优化
    backup_configs
    ensure_sysctl_conf
    echo "[应用] 正在应用【出口=落地 TCP 优化】（直连场景）..."
    
    sed -i '/^net.ipv4.tcp_no_metrics/d; /^net.ipv4.tcp_ecn/d; /^net.ipv4.tcp_frto/d; /^net.ipv4.tcp_mtu_probing/d; /^net.ipv4.tcp_rfc1337/d; /^net.ipv4.tcp_sack/d; /^net.ipv4.tcp_fack/d; /^net.ipv4.tcp_window_scaling/d; /^net.ipv4.tcp_moderate_rcvbuf/d; /^net.ipv4.tcp_fastopen/d; /^net.ipv4.tcp_slow_start_after_idle/d; /^net.ipv4.tcp_early_retrans/d; /^net.core.rmem/d; /^net.core.wmem/d; /^net.core.somaxconn/d; /^net.core.netdev/d; /^net.ipv4.udp_/d; /^net.ipv4.ip_local/d; /^net.ipv4.tcp_tw_reuse/d; /^net.ipv4.tcp_fin_timeout/d; /^net.ipv4.tcp_keepalive/d; /^net.ipv4.tcp_max/d; /^net.ipv4.tcp_limit_output_bytes/d; /^net.ipv4.tcp_notsent_lowat/d; /^net.core.default_qdisc/d; /^net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    
cat >> /etc/sysctl.conf <<'EOF'

# ===== 出口=落地 TCP 优化 v8（合并部署场景）=====
# 适用场景: 出口和落地在同一台机器（合并部署/省钱方案）
# 特点: 高并发，长短RTT混合，需要防止单连接占用过多带宽
# 拥塞控制: BBR + FQ（已集成）

# 拥塞控制算法
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# 基础 TCP 优化
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=1
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

# 连接优化（高并发）
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=16384
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=20
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_max_tw_buckets=400000

# 缓冲区配置（256MB）
net.core.rmem_max=268435456
net.core.wmem_max=268435456
net.ipv4.tcp_rmem=8192 131072 268435456
net.ipv4.tcp_wmem=8192 131072 268435456
net.core.rmem_default=262144
net.core.wmem_default=262144

# UDP 优化（加大缓冲区支持QUIC/Hysteria等协议）
net.ipv4.udp_rmem_min=65536
net.ipv4.udp_wmem_min=65536

# 其他优化
net.core.netdev_max_backlog=10000
net.ipv4.ip_local_port_range=1024 65535

# ===== 出口=落地 TCP 优化结束 =====
EOF

    apply_sysctl
    configure_network_queues
    
    echo ""
    echo "[成功] 已应用【出口=落地 TCP 优化】+ BBR+FQ"
    echo "[配置] 详情:"
    echo "   - 拥塞控制: BBR + FQ"
    echo "   - 缓冲区: 256MB"
    echo "   - 适用场景: 出口+落地合并，5-10Gbps"
    echo ""
}

apply_aggressive() {  # 激进优化
    backup_configs
    ensure_sysctl_conf
    echo "[应用] 正在应用【激进 TCP 优化】（超高带宽）..."
    
    sed -i '/^net.ipv4.tcp_no_metrics/d; /^net.ipv4.tcp_ecn/d; /^net.ipv4.tcp_frto/d; /^net.ipv4.tcp_mtu_probing/d; /^net.ipv4.tcp_rfc1337/d; /^net.ipv4.tcp_sack/d; /^net.ipv4.tcp_fack/d; /^net.ipv4.tcp_window_scaling/d; /^net.ipv4.tcp_moderate_rcvbuf/d; /^net.ipv4.tcp_fastopen/d; /^net.ipv4.tcp_slow_start_after_idle/d; /^net.ipv4.tcp_early_retrans/d; /^net.core.rmem/d; /^net.core.wmem/d; /^net.core.somaxconn/d; /^net.core.netdev/d; /^net.ipv4.udp_/d; /^net.ipv4.ip_local/d; /^net.ipv4.tcp_tw_reuse/d; /^net.ipv4.tcp_fin_timeout/d; /^net.ipv4.tcp_keepalive/d; /^net.ipv4.tcp_max/d; /^net.ipv4.tcp_limit_output_bytes/d; /^net.ipv4.tcp_notsent_lowat/d; /^net.core.default_qdisc/d; /^net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    
cat >> /etc/sysctl.conf <<'EOF'

# ===== 激进 TCP 优化 v8（超高带宽场景）=====
# 适用场景: 超高带宽，数据中心，骨干网
# 特点: 10Gbps+，需要大量内存
# 拥塞控制: BBR + FQ（已集成）

# 拥塞控制算法
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# 基础 TCP 优化
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=1
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
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_max_tw_buckets=500000

# 缓冲区配置（激进：512MB，适合10Gbps+）
net.core.rmem_max=536870912
net.core.wmem_max=536870912
net.ipv4.tcp_rmem=16384 262144 536870912
net.ipv4.tcp_wmem=16384 262144 536870912
net.core.rmem_default=1048576
net.core.wmem_default=1048576

# UDP 优化（超高带宽需要更大UDP缓冲）
net.ipv4.udp_rmem_min=65536
net.ipv4.udp_wmem_min=65536

# 其他优化
net.core.netdev_max_backlog=30000
net.ipv4.ip_local_port_range=1024 65535

# ===== 激进 TCP 优化结束 =====
EOF

    apply_sysctl
    configure_network_queues
    
    echo ""
    echo "[成功] 已应用【激进 TCP 优化】+ BBR+FQ"
    echo "[配置] 详情:"
    echo "   - 拥塞控制: BBR + FQ"
    echo "   - 缓冲区: 512MB"
    echo "   - 适用场景: 10Gbps+，数据中心"
    echo "   - 要求: 内存 16GB+"
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
Linux 网络优化管理器 v8 - 使用说明
========================================

[版本说明]
v8 是最终版本，已将 BBR+FQ 统一集成到每个 TCP 优化方案中。
不再需要单独选择拥塞控制算法，一键应用即可。

[Debian 13 特别说明]
此版本已针对 Debian 13 (trixie) 进行优化，解决了文件系统兼容性问题。

[TCP 优化模式]

1. 入口节点优化
   - 拥塞控制: BBR + FQ（已集成）
   - 缓冲区: 256MB（连接数多需要更大缓冲）
   - 适用: 国内入口服务器
   - 场景: 处理用户连接，RTT 短(10-50ms)
   - 带宽: 1-2Gbps

2. 中转出口优化
   - 拥塞控制: BBR + FQ（已集成）
   - 缓冲区: 256MB
   - 适用: 国外中转服务器
   - 场景: 双向转发，RTT 中等(50-150ms)
   - 带宽: 2-5Gbps

3. 终点落地优化 ⭐ [最常见，数量最多]
   - 拥塞控制: BBR + FQ（已集成）
   - 缓冲区: 256MB
   - 适用: 纯落地服务器（前面有专门中转）
   - 场景: 落地到目标，RTT 较短
   - 带宽: 2-5Gbps
   - 典型: 大量不同地区/线路的落地节点（50-60台）

4. 出口等于落地优化
   - 拥塞控制: BBR + FQ（已集成）
   - 缓冲区: 256MB
   - 适用: 出口和落地同一台（合并部署）
   - 场景: 高并发，长短RTT混合
   - 带宽: 5-10Gbps

5. 激进优化
   - 拥塞控制: BBR + FQ（已集成）
   - 缓冲区: 512MB
   - 适用: 超高带宽场景
   - 场景: 数据中心，骨干网
   - 带宽: 10Gbps+
   - 要求: 内存 16GB+

[使用场景推荐]

场景1: 国内入口，1-2台
→ 选项1 (入口节点优化)

场景2: 香港/日本出口（纯中转），6台左右
→ 选项2 (中转出口优化)

场景3: 纯落地机器，50-60台 ⭐⭐⭐⭐⭐ [最常见]
→ 选项3 (终点落地优化)
   这是数量最多、最常用的场景！

场景4: 出口+落地合并
→ 选项4 (出口=落地优化)

场景5: 数据中心，10Gbps+
→ 选项5 (激进优化)

[使用流程]

步骤1: 选择对应的 TCP 优化模式（1-5）
步骤2: 等待应用完成（会自动配置 BBR+FQ）
步骤3: 重启相关服务
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
   - BBR+FQ 已集成，无需单独配置
   - 建议在低峰期应用优化
   - 应用后需重启服务才能完全生效
   - 需要内核 4.9+ 支持 BBR
   - Debian 13 已完全支持

[恢复配置]
   使用菜单选项 10，或直接运行备份目录中的 restore.sh

========================================
HELP
}

# ========== 主菜单 ==========
while true; do
    clear
    echo "========= Linux 网络优化管理 v8 (Debian 13) ========="
    echo "主机名: $HOST"
    echo "日期: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================="
    echo ""
    echo "[TCP 优化方案（已集成 BBR+FQ）]"
    echo "----------------------------------------"
    echo "1. 入口节点优化 (256MB, 国内入口)"
    echo "2. 中转出口优化 (256MB, 国外中转)"
    echo "3. 终点落地优化 (256MB, 纯落地) ⭐ [最常见]"
    echo "4. 出口=落地优化 (256MB, 合并部署)"
    echo "5. 激进优化 (512MB, 10Gbps+)"
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
            echo "[退出] 感谢使用 Linux 网络优化管理器 v8"
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
