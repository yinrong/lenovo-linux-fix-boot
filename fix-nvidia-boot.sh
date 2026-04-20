#!/bin/bash
# ============================================================
# fix-nvidia-boot.sh
# 修复联想笔记本（NVIDIA Optimus）断电后桌面无法显示的问题
#
# 故障现象：
#   关闭笔记本盖子（suspend），电池耗尽断电，重新充电开机后：
#   - 可以到达 GDM 登录界面
#   - 输入密码后桌面无法显示（黑屏或显示器无信号）
#
# 根本原因（已确认）：
#   1. /tmp 不是 tmpfs，断电后 /tmp/.X*-lock 和 /tmp/.X11-unix/X* 残留，
#      可能导致新 Xorg 实例初始化异常
#
#   2. /run/nvidia-xdriver-* socket 在某些情况下可能残留
#
#   3. nvidia-suspend.service 在 suspend 时执行 chvt 63（切换到 VT63），
#      若 nvidia-resume.service 从未运行（断电），GDM 重新启动时
#      需要自行处理 VT 分配
#
#   注意：NVreg_PreserveVideoMemoryAllocations=1 + NVreg_TemporaryFilePath=/var
#   配置下，NVIDIA 驱动使用 O_TMPFILE 匿名文件保存显存，断电后自动消失，
#   无文件残留，无需清理
#
# 修复方案：
#   A. 开机时清理 /tmp 下残留的 X lock 和 socket 文件
#   B. 开机时清理 /run/nvidia-xdriver-* 残留 socket
#   C. 创建 suspend/resume flag 机制，检测断电发生
#   D. UPower 电池耗尽策略改为 PowerOff（防止 HybridSleep 写入大文件）
#
# 重要提示：
#   若开机后桌面不显示，先检查：
#   1. 外接显示器电源是否打开
#   2. 显示器输入源是否正确（切换到 HDMI 接口）
#   3. 尝试 Ctrl+Alt+F2 切换到 VT2（用户 X 会话所在 VT）
#   4. 如以上均正常，查看日志: sudo journalctl -b -t nvidia-boot-cleanup
#
# 使用方法：sudo bash fix-nvidia-boot.sh
# ============================================================

set -e

if [ "$EUID" -ne 0 ]; then
    echo "请以 root 运行: sudo bash $0"
    exit 1
fi

if ! touch /tmp/.rw_test 2>/dev/null; then
    echo "[0/5] 根文件系统只读，正在重挂载为读写..."
    mount -o remount,rw /
    echo "    已重挂载 / 为读写"
else
    rm -f /tmp/.rw_test
fi

mkdir -p /var/lib/nvidia-boot-cleanup

echo "[1/5] 安装 NVIDIA 启动清理脚本..."
cat > /usr/local/sbin/nvidia-boot-cleanup.sh << 'EOF'
#!/bin/bash
SUSPEND_FLAG="/var/lib/nvidia-boot-cleanup/suspend-pending"
LOG_TAG="nvidia-boot-cleanup"

logger -t "$LOG_TAG" "Starting"

# 清理 /tmp 下残留的 X lock 文件（/tmp 不是 tmpfs，断电后残留）
for lockfile in /tmp/.X[0-9]*-lock; do
    [ -f "$lockfile" ] || continue
    pid=$(tr -d ' \n' < "$lockfile" 2>/dev/null)
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
        display=$(echo "$lockfile" | grep -oE 'X[0-9]+' | head -1)
        rm -f "$lockfile" "/tmp/.X11-unix/${display}" 2>/dev/null || true
        logger -t "$LOG_TAG" "Removed stale X lock: $lockfile (dead pid $pid)"
    fi
done

# 清理 nvidia-xdriver socket 残留
find /var/run /run -maxdepth 2 -name "nvidia-xdriver-*" -delete 2>/dev/null || true

if [ ! -f "$SUSPEND_FLAG" ]; then
    logger -t "$LOG_TAG" "No suspend flag, done"
    exit 0
fi

logger -t "$LOG_TAG" "Suspend flag found (unclean shutdown during suspend); GDM will handle VT assignment"

rm -f "$SUSPEND_FLAG"
logger -t "$LOG_TAG" "Done"
EOF
chmod +x /usr/local/sbin/nvidia-boot-cleanup.sh

echo "[2/5] 安装 systemd 服务..."
cat > /etc/systemd/system/nvidia-boot-cleanup.service << 'EOF'
[Unit]
Description=Clean up stale X locks and NVIDIA sockets after unclean suspend exit
After=local-fs.target systemd-udevd.service
Before=display-manager.service
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nvidia-boot-cleanup.sh
RemainAfterExit=yes
StandardOutput=journal
TimeoutStartSec=30

[Install]
WantedBy=display-manager.service
EOF

echo "[3/5] 安装 suspend/resume flag drop-in..."

mkdir -p /etc/systemd/system/nvidia-suspend.service.d
cat > /etc/systemd/system/nvidia-suspend.service.d/set-flag.conf << 'EOF'
[Service]
ExecStartPost=/bin/sh -c 'mkdir -p /var/lib/nvidia-boot-cleanup && touch /var/lib/nvidia-boot-cleanup/suspend-pending'
EOF

mkdir -p /etc/systemd/system/nvidia-hibernate.service.d
cat > /etc/systemd/system/nvidia-hibernate.service.d/set-flag.conf << 'EOF'
[Service]
ExecStartPost=/bin/sh -c 'mkdir -p /var/lib/nvidia-boot-cleanup && touch /var/lib/nvidia-boot-cleanup/suspend-pending'
EOF

mkdir -p /etc/systemd/system/nvidia-resume.service.d
cat > /etc/systemd/system/nvidia-resume.service.d/clear-flag.conf << 'EOF'
[Service]
ExecStartPost=/bin/rm -f /var/lib/nvidia-boot-cleanup/suspend-pending
EOF

echo "[4/5] 修改 UPower 电池耗尽策略 (HybridSleep -> PowerOff)..."
if grep -q "CriticalPowerAction=HybridSleep" /etc/UPower/UPower.conf 2>/dev/null; then
    sed -i 's/CriticalPowerAction=HybridSleep/CriticalPowerAction=PowerOff/' /etc/UPower/UPower.conf
    echo "    已修改 CriticalPowerAction=PowerOff"
else
    echo "    当前配置: $(grep CriticalPowerAction /etc/UPower/UPower.conf 2>/dev/null || echo '未找到')"
fi

echo "[5/5] 重载 systemd 并启用服务..."
systemctl daemon-reload
systemctl enable nvidia-boot-cleanup.service

echo ""
echo "✓ 安装完成。"
echo ""
echo "工作原理："
echo "  合盖 suspend → 创建 /var/lib/nvidia-boot-cleanup/suspend-pending"
echo "  正常唤醒     → 删除该文件"
echo "  断电后开机   → flag 存在 → 清理残留 X lock / socket → 删除 flag"
echo ""
echo "若开机后桌面不显示，请依次检查："
echo "  1. 外接显示器电源是否已打开"
echo "  2. 显示器输入源是否切换到正确的 HDMI 接口"
echo "  3. 按 Ctrl+Alt+F2 切换到 VT2（X 会话所在 VT）"
echo "  4. 查看日志: sudo journalctl -b -t nvidia-boot-cleanup"
echo ""
echo "验证安装："
echo "  sudo journalctl -b -t nvidia-boot-cleanup"
echo ""
echo "模拟下次断电恢复（可选，重启后生效）："
echo "  sudo touch /var/lib/nvidia-boot-cleanup/suspend-pending"
