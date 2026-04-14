# rem-win-size — 切换显示器时自动保留窗口尺寸

在多显示器（尤其是 2K 笔记本屏 + 4K 外接屏）之间切换时，GNOME 会按 DPI 比例重排所有窗口，导致窗口尺寸和位置发生变化。本工具通过监听 GNOME 的显示器切换事件，自动恢复每个应用在各显示器配置下的窗口几何。

## 功能特性

| 场景 | 行为 |
|------|------|
| **2K → 4K**（有记忆） | 恢复上次在 4K 下的精确位置和尺寸 |
| **2K → 4K**（首次） | 保持 2K 下的尺寸不变（阻止 GNOME 放大） |
| **4K → 2K** | 恢复 2K 记忆；超出屏幕时自动收缩并移入 |
| **周期保存** | 每 60 秒静默保存当前所有窗口状态 |
| **CPU 占用** | 事件驱动（dbus），空闲时 CPU = 0；进程 nice=19 |

## 文件说明

```
rem-win-size/
├── window-memory.py   # 守护进程主体（事件驱动 + 周期保存）
├── wm                 # 生命周期管理工具（两阶段激活）
└── README.md          # 本文件
```

运行后会在系统中创建：

```
~/.local/bin/window-memory.py      # 安装的守护进程
~/.local/bin/window-memory-try-once.sh  # 试运行包装（try_start 时创建）
~/.config/autostart/window-memory.desktop       # 永久自启（confirm_start 后）
~/.config/autostart/window-memory-try.desktop   # 试运行自启（try_start 时）
~/.config/window-memory/profiles.json           # 窗口记忆数据
~/.config/window-memory/window-memory.log       # 运行日志
~/.config/window-memory/activation.json         # 激活状态记录
```

---

## 在新计算机上设置

### 第 0 步：安装依赖

```bash
./wm install-deps
```

这会安装 `wmctrl`（X11 窗口管理工具）、`python3-dbus`、`python3-gi`。

> 如果系统有 apt 依赖冲突（常见于预装了特殊软件的机器），脚本会自动绕过，手动提取 wmctrl 二进制。

### 第 1 步：试运行（`try_start`）

```bash
chmod +x wm
./wm try_start
```

**发生了什么：**
- 将 `window-memory.py` 复制到 `~/.local/bin/`
- 写入一个**重启后自动失效**的 autostart 条目
- 立即在后台启动守护进程

**此时可以测试：**
- 插拔外接显示器，观察窗口是否保持尺寸
- 查看日志：`./wm log`

**重启后的行为：**
- 试运行 autostart 会执行一次守护进程，然后**自动删除自身**
- 再次重启后，守护进程将不再自启
- 即：如果出现任何问题，**硬重启两次即可完全清除**，无需手动操作

### 第 2 步：确认永久生效（`confirm_start`）

在测试满意、重启后确认功能正常后，执行：

```bash
./wm confirm_start
```

**发生了什么：**
- 写入永久 autostart 条目（每次登录后自动启动）
- 清理试运行的临时文件
- 激活状态记录为 `permanent`

### 停止

```bash
./wm stop
```

停止守护进程，删除所有 autostart 条目。窗口记忆数据（`profiles.json`）会保留，方便以后重新启用。

---

## 日常命令

```bash
./wm status          # 查看运行状态和激活模式
./wm log             # 查看最近 40 行日志
./wm log 100         # 查看最近 100 行日志
./wm save            # 立即保存当前所有窗口状态
./wm restore         # 立即恢复当前显示器配置的记忆
./wm list            # 列出所有已记忆的显示器配置
```

---

## 工作原理

### 事件驱动（零 CPU 占用）

本工具监听 GNOME Mutter 的 `org.gnome.Mutter.DisplayConfig MonitorsChanged` dbus 信号，仅在显示器配置发生变化时才被唤醒。空闲时 CPU 占用为零。

如果系统缺少 `python3-dbus`，会自动回退到 2 秒轮询模式（有少量 CPU 占用）。

### 进程优先级

守护进程以 `nice=19` 运行（Linux 最低 CPU 优先级），确保不会与前台应用争抢 CPU 资源。

### 两阶段激活

```
try_start
  └─ 写入「一次性」autostart（执行后自删除）
  └─ 立即启动守护进程
  └─ 状态: "try"

     重启 → autostart 执行一次 → 自删除
     再重启 → 守护进程不再自启（完全清除）

confirm_start（在 try_start 后重启并确认正常后执行）
  └─ 写入永久 autostart
  └─ 清理试运行临时文件
  └─ 状态: "permanent"

stop
  └─ 停止守护进程
  └─ 删除所有 autostart 条目
  └─ 状态: "stopped"
```

### 窗口记忆与匹配

每个显示器配置（由活动输出的 connector + 分辨率组合的 MD5 标识）独立保存一份 profile。

恢复时按以下优先级匹配窗口：
1. 精确标题匹配
2. 标题包含关系匹配（适应文档名变化）
3. 同类应用按顺序分配

### profile 数据格式

`~/.config/window-memory/profiles.json` 可手动编辑：

```json
{
  "profiles": {
    "6e7e067fd760": {
      "description": "HDMI-1-0:3840x2160",
      "screen_w": 3840,
      "screen_h": 2160,
      "windows": {
        "code.Code": [
          {"x": 100, "y": 50, "w": 1920, "h": 1080, "title": "my-project", "maximized": false}
        ]
      }
    }
  }
}
```

---

## 依赖

| 依赖 | 用途 | 安装 |
|------|------|------|
| `wmctrl` | 获取/设置窗口几何 | `sudo apt install wmctrl` |
| `xprop` | 读取窗口属性 | `sudo apt install x11-utils`（通常已预装） |
| `python3-dbus` | 监听 dbus 信号（事件驱动） | `sudo apt install python3-dbus` |
| `python3-gi` | GLib 主循环 | `sudo apt install python3-gi` |

> 所有依赖均可通过 `./wm install-deps` 一键安装。

---

## 故障排查

**切换显示器后窗口没有恢复？**
- 检查守护进程是否在运行：`./wm status`
- 查看日志：`./wm log`
- 确认是否在 X11 会话下运行（不支持纯 Wayland）

**窗口恢复位置不对？**
- 手动调整到满意位置后执行 `./wm save`，覆盖旧记忆

**想为特定应用固定尺寸？**
- 将应用调整到期望尺寸，执行 `./wm save` 即可
