#!/usr/bin/env python3
"""给运行中的应用拍一张真实截图，供观感前后比对。

和 `probe_glass_shot.py` 的分工：那个负责**量化**一张已有截图里的玻璃浓度比，
这个负责**把截图拿到手**。原生播放器有自己的 `PrintWindow` 通道（见
`windows/native_player/main.cpp` 的 `UpdateGlassBackdrop`），但应用壳层是 GPU
直出的，最忠实的做法是抓屏幕上真正显示出来的像素。

用法：

    python tool/probe_window_shot.py --out shot.png            # 启动 → 等 → 抓 → 关
    python tool/probe_window_shot.py --out shot.png --wait 12
    python tool/probe_window_shot.py --out shot.png --attach   # 不启动，抓现有窗口
    python tool/probe_window_shot.py --out shot.png --window-only

⚠️ 抓图时别让机器跑重活，也别让别的窗口盖上来：这里抓的是屏幕像素，
不是离屏渲染结果。
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wt
import subprocess
import sys
import time
from pathlib import Path

try:
    from PIL import ImageGrab
except ImportError:  # pragma: no cover
    print("Pillow is required: pip install pillow")
    sys.exit(2)

DEFAULT_APP = Path("build/windows/x64/runner/Profile/mova.exe")
WINDOW_TITLE = "Mova"

HWND_TOPMOST = -1
HWND_NOTOPMOST = -2
SWP_NOMOVE = 0x0002
SWP_NOSIZE = 0x0001

def _set_topmost(hwnd: int, topmost: bool) -> None:
    ctypes.windll.user32.SetWindowPos(
        hwnd, HWND_TOPMOST if topmost else HWND_NOTOPMOST, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE,
    )


def _foreground_window() -> int | None:
    """把 Mova 主窗口调到最前并返回它的矩形（屏幕坐标）。

    ⚠️ 只调 `SetForegroundWindow` 是不够的：前台锁定（foreground lock）会让
    后台进程的这次调用静默失败，于是抓到的截图里窗口被别的程序盖住一半。
    实测踩过。临时置顶（`SetWindowPos(HWND_TOPMOST)`）绕得开，抓完再还原。
    """
    user32 = ctypes.windll.user32
    hwnd = user32.FindWindowW(None, WINDOW_TITLE)
    if not hwnd:
        return None
    user32.ShowWindow(hwnd, 9)  # SW_RESTORE
    _set_topmost(hwnd, True)
    user32.BringWindowToTop(hwnd)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.9)
    rect = wt.RECT()
    if not user32.GetWindowRect(hwnd, ctypes.byref(rect)):
        return None
    return (rect.left, rect.top, rect.right, rect.bottom)


def running_instances() -> list[str]:
    """列出正在运行的 mova.exe 进程号。

    `tasklist` 在本机用 ANSI 代码页输出，按字节收、宽松解码即可 —— 进程名是
    纯 ASCII，解错编码也能认出来。
    """
    try:
        raw = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq mova.exe", "/NH"],
            capture_output=True, timeout=20,
        ).stdout or b""
    except (OSError, subprocess.SubprocessError):
        return []
    pids = []
    for line in raw.decode("utf-8", errors="replace").splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0].lower() == "mova.exe":
            pids.append(parts[1])
    return pids


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True, help="PNG 输出路径")
    parser.add_argument("--app", default=str(DEFAULT_APP), help="要启动的 exe")
    parser.add_argument("--wait", type=float, default=9,
                        help="启动后等多少秒再抓（首屏要联网取图）")
    parser.add_argument("--attach", action="store_true",
                        help="不启动应用，直接抓当前已有的 Mova 窗口")
    parser.add_argument("--window-only", action="store_true",
                        help="只抓应用窗口矩形，而不是整屏")
    parser.add_argument("--place", default=None,
                        help="抓之前把窗口挪到 x,y,w,h（逗号分隔）。桌面上有别的前台"
                             "程序压着、置顶也抢不到时，把窗口挪到空白处最省事")
    parser.add_argument("--scroll", type=float, default=None,
                        help="抓图前先合成滚轮把页面滚到发现栏目（像素）")
    options = parser.parse_args()

    out = Path(options.out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)

    process = None
    if not options.attach:
        app = Path(options.app)
        if not app.exists():
            print(f"BAD  找不到可执行文件 {app}")
            return 1
        if running_instances():
            print("BAD  已有 Mova 在运行：单实例锁会让新进程直接退出，抓到的会是旧窗口。")
            return 1
        process = subprocess.Popen(
            [str(app)], cwd=str(app.parent),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        time.sleep(options.wait)

    if options.scroll:
        user32 = ctypes.windll.user32
        hwnd = user32.FindWindowW(None, WINDOW_TITLE)
        if not hwnd:
            print("BAD  找不到 Mova 窗口")
            if process is not None:
                process.terminate()
            return 1
        # 合成滚轮：WM_MOUSEWHEEL 的 lParam 高字是屏幕坐标，wParam 高字是 delta。
        rect = wt.RECT()
        user32.GetWindowRect(hwnd, ctypes.byref(rect))
        cx = (rect.left + rect.right) // 2
        cy = (rect.top + rect.bottom) // 2
        steps = max(1, int(abs(options.scroll) // 120))
        delta = 120 if options.scroll > 0 else -120
        for _ in range(steps):
            user32.PostMessageW(hwnd, 0x020A, (delta & 0xFFFF) << 16,
                                ((cy & 0xFFFF) << 16) | (cx & 0xFFFF))
            time.sleep(0.05)
        time.sleep(2.0)

    box = _foreground_window()
    if box is None:
        print("BAD  找不到 Mova 窗口；确认应用真的起来了")
        if process is not None:
            process.terminate()
        return 1
    if options.place:
        try:
            x, y, w, h = (int(v) for v in options.place.split(","))
        except ValueError:
            print("BAD  --place 需要 x,y,w,h 四个整数")
            if process is not None:
                process.terminate()
            return 1
        ctypes.windll.user32.MoveWindow(
            ctypes.windll.user32.FindWindowW(None, WINDOW_TITLE), x, y, w, h, True,
        )
        time.sleep(1.2)
        box = _foreground_window() or box
    if options.window_only:
        left, top, right, bottom = box
        bbox = (left, top, right, bottom)
    else:
        bbox = None

    image = ImageGrab.grab(bbox=bbox, all_screens=True)
    image.save(out)
    print(f"OK   {out.name}  {image.size[0]}x{image.size[1]}"
          f"  窗口矩形={box}  只抓窗口={options.window_only}")

    _set_topmost(ctypes.windll.user32.FindWindowW(None, WINDOW_TITLE), False)

    if process is not None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
    return 0


if __name__ == "__main__":
    sys.exit(main())
