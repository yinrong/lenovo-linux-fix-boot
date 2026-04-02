#!/bin/bash
# ============================================================
# fix-nvidia-boot.sh
# 修复联想笔记本（NVIDIA Optimus）断电后无法启动桌面的问题
#
# 故障现象：
#   电池耗尽断电后重启，6.14.0-34 内核下 gdm 无法启动
#   Xorg 日志报：
#     (EE) open /dev/fb0: Permission denied
#     (WW) NVIDIA: Failed to bind sideband socket '/var/run/nvidia-xdriver-XXXX': Permission denied
#     (WW) NVIDIA(G0): Setting a mode on head N failed: Insufficient permissions
#
# 根本原因：
#   1. NVIDIA 驱动配置了 NVreg_PreserveVideoMemoryAllocations=1
#   2. 正常 suspend 后电池耗尽直接断电（而非正常恢复）
#   3. /proc/driver/nvidia/suspend 状态未被重置
#   4. 导致下次启动时 NVIDIA 驱动拒绝 gdm(uid=120) 的显示权限请求
#
# 修复方案：
#   A. systemd 服务：每次启动时清理 NVIDIA 残留状态（治本）
#   B. UPower 配置：电池耗尽时 PowerOff 代替 HybridSleep（无 swap 时 HybridSleep 有害）
#
# 使用方法：sudo bash fix-nvidia-boot.sh
# ============================================================

set -e

if [ "$EUID" -ne 0 ]; then
    echo "请以 root 运行: sudo bash $0"
    exit 1
fi

# Recovery mode 下根文件系统通常是只读的，自动重挂载为读写
if ! touch /tmp/.rw_test 2>/dev/null; then
    echo "[0/4] 根文件系统只读，正在重挂载为读写..."
    mount -o remount,rw /
    echo "    已重挂载 / 为读写"
else
    rm -f /tmp/.rw_test
fi

echo "[1/4] 安装 NVIDIA 启动清理脚本..."
cat > /usr/local/sbin/nvidia-boot-cleanup.sh << 'EOF'
#!/bin/bash
# 清理 NVIDIA 断电后的残留状态

# 清理 nvidia-xdriver socket 残留
find /var/run /run -maxdepth 2 -name "nvidia-xdriver-*" -type s -delete 2>/dev/null
find /var/run /run -maxdepth 2 -name "nvidia-xdriver-*" -delete 2>/dev/null

# 重置 NVIDIA suspend 状态
if [ -w /proc/driver/nvidia/suspend ]; then
    CURRENT=$(cat /proc/driver/nvidia/suspend 2>/dev/null)
    if [ "$CURRENT" = "suspended" ] || [ "$CURRENT" = "hibernated" ]; then
        echo "resume" > /proc/driver/nvidia/suspend 2>/dev/null || true
    fi
fi

# 清理 nvidia-sleep 临时文件
rm -f /var/run/nvidia-sleep/Xorg.vt_number 2>/dev/null

exit 0
EOF
chmod +x /usr/local/sbin/nvidia-boot-cleanup.sh

echo "[2/4] 安装 systemd 服务..."
cat > /etc/systemd/system/nvidia-boot-cleanup.service << 'EOF'
[Unit]
Description=Clean up stale NVIDIA xdriver sockets and reset suspend state after power loss
After=local-fs.target
Before=display-manager.service
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nvidia-boot-cleanup.sh
RemainAfterExit=yes
StandardOutput=journal

[Install]
WantedBy=display-manager.service
EOF

systemctl daemon-reload
systemctl enable nvidia-boot-cleanup.service
echo "    已启用 nvidia-boot-cleanup.service"

echo "[3/4] 修改 UPower 电池耗尽策略 (HybridSleep -> PowerOff)..."
if grep -q "CriticalPowerAction=HybridSleep" /etc/UPower/UPower.conf; then
    sed -i 's/CriticalPowerAction=HybridSleep/CriticalPowerAction=PowerOff/' /etc/UPower/UPower.conf
    echo "    已修改 CriticalPowerAction=PowerOff"
else
    echo "    已是 PowerOff 或不需要修改: $(grep CriticalPowerAction /etc/UPower/UPower.conf)"
fi

echo "[4/4] 验证..."
systemctl start nvidia-boot-cleanup.service
STATUS=$(systemctl is-active nvidia-boot-cleanup.service)
echo "    nvidia-boot-cleanup.service 状态: $STATUS"

echo ""
echo "✓ 修复完成。下次使用新内核启动时将自动生效。"
echo "  如要验证：sudo systemctl status nvidia-boot-cleanup.service"
