#!/usr/bin/env python3
"""
window-memory — 切换显示器时自动保留窗口尺寸和位置

行为：
  2K → 4K  : 保持窗口逻辑像素尺寸不变（阻止 GNOME 按 DPI 比例放大）
  4K → 2K  : 保持尺寸，超出屏幕边界时自动收缩并移入屏幕
  记忆功能  : 为每种显示器配置单独记忆各应用窗口的尺寸和位置
              再次切换回来时精确恢复（含标题模糊匹配）

技术要点：
  - 监听 org.gnome.Mutter.DisplayConfig MonitorsChanged dbus 信号
    → 完全事件驱动，空闲时 CPU 占用为零（不再轮询）
  - os.nice(19) 将进程优先级设为最低，不影响前台工作
  - 周期保存（60s）用后台线程实现，不阻塞主循环

用法（通过 wm 脚本调用，见 README）：
  python3 window-memory.py daemon   # 启动守护进程
  python3 window-memory.py save     # 立即保存当前窗口状态
  python3 window-memory.py restore  # 恢复当前 profile 的记忆
  python3 window-memory.py list     # 列出所有已保存的 profile

依赖：wmctrl, xprop（X11 工具）, python3-dbus
"""

import os
import subprocess
import json
import time
import hashlib
import logging
import re
import sys
import threading
from pathlib import Path
from typing import Optional

# ── 配置 ────────────────────────────────────────────────────────────────────
SAVE_DIR      = Path.home() / ".config" / "window-memory"
PROFILES_FILE = SAVE_DIR / "profiles.json"
LOG_FILE      = SAVE_DIR / "window-memory.log"

SAVE_INTERVAL  = 60.0  # 周期性保存间隔（秒）
SETTLE_DELAY   = 3.0   # 检测到切换后，等待 GNOME 稳定的时间（秒）

MIN_W, MIN_H   = 100, 50   # 窗口最小尺寸
MARGIN         = 5         # 离屏幕边缘的最小距离（像素）

# 忽略这些 WM_CLASS（桌面/面板/系统覆盖层等不需要管理）
SKIP_CLASSES = {
    "gnome-shell.gnome-shell",
    "gnome-panel.gnome-panel",
    "desktop_window.Nautilus",
    "gjs.Gjs",            # GNOME Shell 扩展覆盖层
    "unknown.unknown",    # xprop 无法识别的系统窗口
}

# ── 日志 ────────────────────────────────────────────────────────────────────
def setup_logging(verbose: bool = False):
    SAVE_DIR.mkdir(parents=True, exist_ok=True)
    level = logging.DEBUG if verbose else logging.INFO
    fmt = "%(asctime)s %(levelname)s %(message)s"
    handlers: list = [logging.FileHandler(LOG_FILE)]
    # 只有在交互终端时才输出到 stdout（避免 nohup 导致日志重复）
    if sys.stdout.isatty():
        handlers.append(logging.StreamHandler(sys.stdout))
    logging.basicConfig(level=level, format=fmt, handlers=handlers)


# ── 系统调用助手 ─────────────────────────────────────────────────────────────
def _run(cmd: list) -> str:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return r.stdout
    except Exception:
        return ""


# ── 显示器 profile ───────────────────────────────────────────────────────────
def get_display_profile() -> tuple[Optional[str], str]:
    """
    返回 (profile_id, description)。
    profile_id 是活动显示器列表（connector:WxH，已排序）的 MD5 前缀。
    无活动显示器时返回 (None, "")。
    """
    out = _run(["xrandr", "--query"])
    active = []
    for line in out.splitlines():
        if " connected " in line:
            m = re.search(r"(\d+x\d+)\+\d+\+\d+", line)
            if m:
                name = line.split()[0]
                active.append(f"{name}:{m.group(1)}")
    if not active:
        return None, ""
    desc = ",".join(sorted(active))
    pid = hashlib.md5(desc.encode()).hexdigest()[:12]
    return pid, desc


def get_screen_bounds() -> tuple[int, int]:
    """返回当前 X11 逻辑屏幕总尺寸 (width, height)。"""
    out = _run(["xrandr", "--query"])
    m = re.search(r"current\s+(\d+)\s+x\s+(\d+)", out)
    return (int(m.group(1)), int(m.group(2))) if m else (3840, 2160)


# ── 窗口信息获取 ─────────────────────────────────────────────────────────────
def _get_wm_class(wid: str) -> str:
    out = _run(["xprop", "-id", wid, "WM_CLASS"])
    parts = re.findall(r'"([^"]+)"', out)
    if len(parts) >= 2:
        return f"{parts[0]}.{parts[1]}"
    return parts[0] if parts else "unknown"


def _get_net_wm_state(wid: str) -> set:
    out = _run(["xprop", "-id", wid, "_NET_WM_STATE"])
    return set(re.findall(r"_NET_WM_STATE_\w+", out))


def get_windows() -> list[dict]:
    """
    返回所有普通窗口列表，每项含：
      id, cls, title, x, y, w, h, maximized
    """
    out = _run(["wmctrl", "-l", "-G"])
    windows = []
    for line in out.splitlines():
        parts = line.split(None, 8)
        if len(parts) < 8:
            continue
        try:
            wid = parts[0]
            x, y = int(parts[2]), int(parts[3])
            w, h = int(parts[4]), int(parts[5])
            title = parts[7] if len(parts) > 7 else ""
            wm_class = _get_wm_class(wid)
            if wm_class in SKIP_CLASSES:
                continue
            state = _get_net_wm_state(wid)
            maximized = bool(
                {"_NET_WM_STATE_MAXIMIZED_VERT", "_NET_WM_STATE_MAXIMIZED_HORZ"} & state
            )
            windows.append(
                dict(id=wid, cls=wm_class, title=title,
                     x=x, y=y, w=w, h=h, maximized=maximized)
            )
        except (ValueError, IndexError):
            continue
    return windows


# ── 窗口几何操作 ─────────────────────────────────────────────────────────────
def _set_maximized(wid: str, maximized: bool):
    action = "add" if maximized else "remove"
    subprocess.run(
        ["wmctrl", "-i", "-r", wid, "-b",
         f"{action},maximized_vert,maximized_horz"],
        capture_output=True,
    )


def set_geometry(wid: str, x: int, y: int, w: int, h: int):
    """先取消最大化，再设置精确几何。"""
    _set_maximized(wid, False)
    time.sleep(0.08)
    subprocess.run(
        ["wmctrl", "-i", "-r", wid, "-e", f"0,{x},{y},{w},{h}"],
        capture_output=True,
    )


def clamp_to_screen(x: int, y: int, w: int, h: int,
                    sw: int, sh: int) -> tuple[int, int, int, int]:
    """将窗口几何限制在 (sw, sh) 屏幕内，超出时先收缩再移位。"""
    w = max(MIN_W, min(w, sw - MARGIN * 2))
    h = max(MIN_H, min(h, sh - MARGIN * 2))
    x = max(MARGIN, min(x, sw - w - MARGIN))
    y = max(MARGIN, min(y, sh - h - MARGIN))
    return x, y, w, h


# ── profile 持久化 ───────────────────────────────────────────────────────────
def load_profiles() -> dict:
    if PROFILES_FILE.exists():
        try:
            return json.loads(PROFILES_FILE.read_text())
        except Exception:
            pass
    return {"profiles": {}}


def _save_profiles(data: dict):
    # 原子写入：先写临时文件再 rename，防止写到一半时崩溃
    tmp = PROFILES_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    tmp.replace(PROFILES_FILE)


def save_windows_to_profile(pid: str, desc: str):
    """将当前所有窗口状态写入 pid 对应的 profile。"""
    windows = get_windows()
    if not windows:
        return
    sw, sh = get_screen_bounds()

    win_map: dict[str, list] = {}
    for w in windows:
        entry = {k: w[k] for k in ("x", "y", "w", "h", "title", "maximized")}
        win_map.setdefault(w["cls"], []).append(entry)

    data = load_profiles()
    data["profiles"][pid] = {
        "description": desc,
        "screen_w": sw,
        "screen_h": sh,
        "windows": win_map,
    }
    _save_profiles(data)
    logging.debug(f"已保存 profile [{desc}]（{len(windows)} 个窗口）")


# ── 恢复窗口 ─────────────────────────────────────────────────────────────────
def restore_windows(new_pid: str, new_desc: str, old_pid: Optional[str]):
    """
    恢复策略（优先级从高到低）：
      1. 新 profile 有记忆 → 直接恢复（含标题模糊匹配）
      2. 旧 profile 有记忆 → 沿用旧尺寸，clamp 到新屏幕（保持窗口大小不变）
      3. 否则跳过
    """
    data = load_profiles()
    sw, sh = get_screen_bounds()

    if new_pid in data["profiles"]:
        source = data["profiles"][new_pid]
        logging.info(f"恢复 profile 记忆 → [{new_desc}]")
    elif old_pid and old_pid in data["profiles"]:
        source = data["profiles"][old_pid]
        logging.info(
            f"新 profile 无记忆，沿用旧配置并 clamp 到 [{new_desc}] ({sw}×{sh})"
        )
    else:
        logging.info("无可用记忆，跳过恢复")
        return

    win_map = source.get("windows", {})
    current = get_windows()
    used: dict[str, set] = {}

    for win in current:
        cls = win["cls"]
        if cls not in win_map:
            continue
        saved_list = win_map[cls]
        used.setdefault(cls, set())

        # 1. 精确标题匹配
        matched_idx = None
        for i, s in enumerate(saved_list):
            if i in used[cls] or s.get("title", "") != win["title"]:
                continue
            matched_idx = i
            break

        # 2. 标题包含匹配
        if matched_idx is None:
            for i, s in enumerate(saved_list):
                if i in used[cls]:
                    continue
                saved_title = s.get("title", "")
                if saved_title and (saved_title in win["title"] or
                                    win["title"] in saved_title):
                    matched_idx = i
                    break

        # 3. 取第一个未使用的
        if matched_idx is None:
            for i in range(len(saved_list)):
                if i not in used[cls]:
                    matched_idx = i
                    break

        if matched_idx is None:
            matched_idx = 0

        used[cls].add(matched_idx)
        saved = saved_list[matched_idx]

        if saved.get("maximized"):
            logging.info(f"  ↔ 最大化  {cls!r}")
            _set_maximized(win["id"], True)
            continue

        x, y, w, h = clamp_to_screen(
            saved["x"], saved["y"], saved["w"], saved["h"], sw, sh
        )
        changed = (x, y, w, h) != (saved["x"], saved["y"], saved["w"], saved["h"])
        flag = " [clamped]" if changed else ""
        logging.info(
            f"  ↔ {cls!r}  \"{win['title'][:40]}\"\n"
            f"     保存: ({saved['x']},{saved['y']} {saved['w']}×{saved['h']})"
            f" → 应用: ({x},{y} {w}×{h}){flag}"
        )
        set_geometry(win["id"], x, y, w, h)


# ── 命令行子命令 ─────────────────────────────────────────────────────────────
def cmd_save():
    setup_logging()
    pid, desc = get_display_profile()
    if not pid:
        print("错误：无活动显示器")
        return
    save_windows_to_profile(pid, desc)
    print(f"已保存 profile [{desc}]")


def cmd_restore():
    setup_logging()
    pid, desc = get_display_profile()
    if not pid:
        print("错误：无活动显示器")
        return
    restore_windows(pid, desc, None)


def cmd_list():
    data = load_profiles()
    profiles = data.get("profiles", {})
    if not profiles:
        print("无保存的 profile")
        return
    for pid, info in profiles.items():
        desc = info.get("description", pid)
        sw, sh = info.get("screen_w", "?"), info.get("screen_h", "?")
        wins = info.get("windows", {})
        n = sum(len(v) for v in wins.values())
        print(f"  [{pid}] {desc}  屏幕:{sw}×{sh}  窗口:{n}")
        for cls, entries in wins.items():
            for e in entries:
                title = e.get("title", "")[:50]
                geo = f"{e['w']}×{e['h']}+{e['x']}+{e['y']}"
                maxed = " [最大化]" if e.get("maximized") else ""
                print(f"    {cls!r}  \"{title}\"  {geo}{maxed}")


# ── 周期保存线程 ─────────────────────────────────────────────────────────────
class PeriodicSaver(threading.Thread):
    """后台线程，每 SAVE_INTERVAL 秒保存一次当前 profile。"""

    def __init__(self):
        super().__init__(daemon=True, name="PeriodicSaver")
        self._stop = threading.Event()
        self._pid: Optional[str] = None
        self._desc: str = ""
        self._lock = threading.Lock()

    def update_profile(self, pid: Optional[str], desc: str):
        with self._lock:
            self._pid, self._desc = pid, desc

    def stop(self):
        self._stop.set()

    def run(self):
        while not self._stop.wait(SAVE_INTERVAL):
            with self._lock:
                pid, desc = self._pid, self._desc
            if pid:
                try:
                    save_windows_to_profile(pid, desc)
                except Exception:
                    logging.exception("PeriodicSaver 保存失败")


# ── dbus 事件驱动主循环 ───────────────────────────────────────────────────────
def daemon():
    # ① 设为最低 CPU 优先级，不影响前台应用
    try:
        os.nice(19)
        logging.debug("已设置 nice=19（最低 CPU 优先级）")
    except OSError:
        pass

    setup_logging()
    logging.info("=" * 60)
    logging.info("window-memory 守护进程启动（dbus 事件驱动模式）")
    logging.info(f"  保存间隔: {SAVE_INTERVAL}s | 稳定等待: {SETTLE_DELAY}s | nice=19")
    logging.info(f"  profiles: {PROFILES_FILE}")

    cur_pid, cur_desc = get_display_profile()
    logging.info(f"初始 profile: {cur_desc or '(无活动显示器)'}  id={cur_pid}")

    # ② 启动周期保存线程
    saver = PeriodicSaver()
    saver.update_profile(cur_pid, cur_desc)
    saver.start()

    # ③ 监听 Mutter MonitorsChanged dbus 信号
    try:
        import dbus
        import dbus.mainloop.glib
        from gi.repository import GLib
    except ImportError:
        logging.warning(
            "python3-dbus 或 python3-gi 未安装，回退到轮询模式（2s 间隔）"
        )
        _daemon_polling(cur_pid, cur_desc, saver)
        return

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()

    def on_monitors_changed(*args):
        nonlocal cur_pid, cur_desc
        logging.info("-" * 40)
        logging.info("dbus: MonitorsChanged 信号收到")

        # 等待 GNOME 完成重排
        logging.info(f"等待 {SETTLE_DELAY}s 让 GNOME 完成窗口重排…")
        time.sleep(SETTLE_DELAY)

        new_pid, new_desc = get_display_profile()
        if new_pid == cur_pid:
            logging.info("profile 未变化，跳过")
            return

        logging.info(f"  旧: {cur_desc or '(无)'}")
        logging.info(f"  新: {new_desc or '(无活动显示器)'}")

        # 保存旧状态
        if cur_pid:
            save_windows_to_profile(cur_pid, cur_desc)

        old_pid = cur_pid
        cur_pid, cur_desc = new_pid, new_desc
        saver.update_profile(cur_pid, cur_desc)

        if not new_pid:
            logging.warning("新 profile 无活动显示器，跳过恢复")
            return

        restore_windows(new_pid, new_desc, old_pid)
        save_windows_to_profile(new_pid, new_desc)

    bus.add_signal_receiver(
        on_monitors_changed,
        signal_name="MonitorsChanged",
        dbus_interface="org.gnome.Mutter.DisplayConfig",
        bus_name="org.gnome.Mutter.DisplayConfig",
        path="/org/gnome/Mutter/DisplayConfig",
    )

    logging.info("已订阅 MonitorsChanged 信号，进入事件循环（空闲时 CPU=0）")

    loop = GLib.MainLoop()
    try:
        loop.run()
    except KeyboardInterrupt:
        logging.info("收到 KeyboardInterrupt，保存并退出")
        if cur_pid:
            save_windows_to_profile(cur_pid, cur_desc)
        saver.stop()


# ── 回退：轮询模式（无 dbus 时使用）────────────────────────────────────────
def _daemon_polling(cur_pid, cur_desc, saver):
    POLL_INTERVAL = 2.0
    logging.info(f"轮询模式启动，间隔 {POLL_INTERVAL}s")
    while True:
        try:
            time.sleep(POLL_INTERVAL)
            new_pid, new_desc = get_display_profile()
            if new_pid == cur_pid:
                continue

            logging.info("-" * 40)
            logging.info(f"检测到显示器切换: {cur_desc} → {new_desc}")

            if cur_pid:
                save_windows_to_profile(cur_pid, cur_desc)

            old_pid = cur_pid
            cur_pid, cur_desc = new_pid, new_desc
            saver.update_profile(cur_pid, cur_desc)

            if not new_pid:
                continue

            logging.info(f"等待 {SETTLE_DELAY}s 让 GNOME 稳定…")
            time.sleep(SETTLE_DELAY)

            restore_windows(new_pid, new_desc, old_pid)
            save_windows_to_profile(new_pid, new_desc)

        except KeyboardInterrupt:
            logging.info("收到 KeyboardInterrupt，保存并退出")
            if cur_pid:
                save_windows_to_profile(cur_pid, cur_desc)
            saver.stop()
            break
        except Exception:
            logging.exception("轮询主循环异常（自动恢复）")
            time.sleep(POLL_INTERVAL)


# ── 入口 ─────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "daemon"
    if cmd in ("daemon", "run"):
        daemon()
    elif cmd == "save":
        cmd_save()
    elif cmd == "restore":
        cmd_restore()
    elif cmd == "list":
        cmd_list()
    else:
        print(__doc__)
        sys.exit(1)
