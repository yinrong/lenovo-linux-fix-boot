#!/bin/bash
# ============================================================
# fix-nvidia-boot.sh
# 修复联想笔记本（NVIDIA Optimus）断电后无法启动桌面的问题
#
# 故障现象：
#   关闭笔记本盖子（suspend），电池耗尽断电，重新充电开机后：
#   - 可以到达 gdm 登录界面
#   - 输入密码后黑屏，无法进入桌面
#
# 根本原因（已通过日志分析确认）：
#   1. 合盖触发 suspend，nvidia-suspend.service 将显存状态保存到 /var，
#      同时切换至 VT63（chvt 63）
#   2. 电池耗尽直接断电，nvidia-resume.service 从未运行
#   3. 重新开机后，nvidia-modeset (NVKMS) 内部状态仍残留 suspend 上下文
#   4. gdm greeter Xorg 在用户登录后执行 VT 切换（VT1→VT2）时，
#      调用 DRM master drop，触发 nv_drm_revoke_modeset_permission
#   5. 新 Xorg 尝试获取 DRM master 时，nvKms->grabOwnership() 因 NVKMS
#      状态异常而失败
#   6. Xorg 报 "Setting a mode on head N failed: Insufficient permissions"
#   7. gdm greeter Xorg 崩溃 → gdm 杀死用户 session → 黑屏返回登录界面
#
#   次要问题：/tmp 挂载在真实文件系统（非 tmpfs），断电后 /tmp/.X*-lock
#   残留，导致 "server already running" 警告（Xorg 会忽略并继续，非致命）
#
# 修复方案：
#   A. 在 suspend 时创建 flag 文件，resume 时删除；开机检测到 flag 则
#      重载 nvidia_drm + nvidia_modeset 模块，清除 NVKMS 坏状态
#   B. 清理 /tmp 下残留的 X lock 文件
#   C. UPower 电池耗尽策略改为 PowerOff（防止无 swap 时 HybridSleep 损坏）
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

logger -t "$LOG_TAG" "Suspend flag found: will reload nvidia_drm + nvidia_modeset"

# 等待 nvidia 基础模块加载完成（最多 5 秒）
for i in $(seq 1 10); do
    [ -f /proc/driver/nvidia/version ] && break
    sleep 0.5
done

if [ ! -f /proc/driver/nvidia/version ]; then
    logger -t "$LOG_TAG" "ERROR: nvidia module not loaded, skipping reload"
    rm -f "$SUSPEND_FLAG"
    exit 0
fi

# 卸载 nvidia_drm（nvidia-persistenced 只用基础 nvidia 模块，不受影响）
if lsmod | grep -q "^nvidia_drm "; then
    if ! rmmod nvidia_drm 2>/dev/null; then
        logger -t "$LOG_TAG" "WARNING: Cannot unload nvidia_drm (in use), skipping"
        rm -f "$SUSPEND_FLAG"
        exit 0
    fi
    logger -t "$LOG_TAG" "Unloaded nvidia_drm"
fi

# 卸载 nvidia_modeset
if lsmod | grep -q "^nvidia_modeset "; then
    if ! rmmod nvidia_modeset 2>/dev/null; then
        logger -t "$LOG_TAG" "WARNING: Cannot unload nvidia_modeset, re-loading nvidia_drm"
        modprobe nvidia_drm modeset=1 2>/dev/null || true
        rm -f "$SUSPEND_FLAG"
        exit 0
    fi
    logger -t "$LOG_TAG" "Unloaded nvidia_modeset"
fi

# 重新加载（清除 NVKMS 坏状态）
modprobe nvidia_modeset 2>/dev/null && logger -t "$LOG_TAG" "Loaded nvidia_modeset" \
    || logger -t "$LOG_TAG" "ERROR: Failed to load nvidia_modeset"
modprobe nvidia_drm modeset=1 2>/dev/null && logger -t "$LOG_TAG" "Loaded nvidia_drm modeset=1" \
    || logger -t "$LOG_TAG" "ERROR: Failed to load nvidia_drm"

rm -f "$SUSPEND_FLAG"
logger -t "$LOG_TAG" "Done: module reload complete"
EOF
chmod +x /usr/local/sbin/nvidia-boot-cleanup.sh

echo "[2/5] 安装 systemd 服务..."
cat > /etc/systemd/system/nvidia-boot-cleanup.service << 'EOF'
[Unit]
Description=Reset NVIDIA NVKMS state after unclean suspend exit (power loss)
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

# 立即执行一次修复（无论是否检测到 flag）
# 原因：脚本首次安装时，历史上的断电发生在 drop-in 安装之前，flag 不存在
# 直接重载模块是最可靠的方式，在 recovery mode 和正常 session 下均有效
echo ""
echo "    立即执行 nvidia_drm + nvidia_modeset 模块重载..."
if [ -f /proc/driver/nvidia/version ]; then
    _reload_ok=1
    if lsmod | grep -q "^nvidia_drm "; then
        if rmmod nvidia_drm 2>/dev/null; then
            echo "    卸载 nvidia_drm: OK"
        else
            echo "    WARNING: nvidia_drm 正在被使用，跳过重载（请在 recovery mode 下运行本脚本）"
            _reload_ok=0
        fi
    fi
    if [ "$_reload_ok" = "1" ] && lsmod | grep -q "^nvidia_modeset "; then
        if rmmod nvidia_modeset 2>/dev/null; then
            echo "    卸载 nvidia_modeset: OK"
        else
            echo "    WARNING: nvidia_modeset 卸载失败，尝试重新加载 nvidia_drm..."
            modprobe nvidia_drm modeset=1 2>/dev/null || true
            _reload_ok=0
        fi
    fi
    if [ "$_reload_ok" = "1" ]; then
        modprobe nvidia_modeset 2>/dev/null && echo "    加载 nvidia_modeset: OK"
        modprobe nvidia_drm modeset=1 2>/dev/null && echo "    加载 nvidia_drm modeset=1: OK"
        echo "    模块重载完成，NVKMS 状态已清除"
    fi
else
    echo "    nvidia 模块未加载（可能是旧内核），跳过模块重载"
    echo "    下次用新内核启动时，若 flag 文件存在则自动执行"
fi

# 同时创建 flag，确保下次启动也执行（以防本次重载不够）
touch /var/lib/nvidia-boot-cleanup/suspend-pending

echo ""
echo "✓ 安装完成。"
echo ""
echo "工作原理："
echo "  合盖 suspend → 创建 /var/lib/nvidia-boot-cleanup/suspend-pending"
echo "  正常唤醒     → 删除该文件"
echo "  断电后开机   → flag 存在 → 重载 nvidia_drm + nvidia_modeset → 删除 flag"
echo ""
echo "验证："
echo "  sudo journalctl -b -t nvidia-boot-cleanup"
echo ""
echo "模拟下次断电恢复（可选，重启后生效）："
echo "  sudo touch /var/lib/nvidia-boot-cleanup/suspend-pending"
