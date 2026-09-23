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
import os
import subprocess
import sys
import time
from pathlib import Path

try:
    from PIL import Image, ImageGrab
except ImportError:  # pragma: no cover
    print("Pillow is required: pip install pillow")
    sys.exit(2)

# ⚠️ 默认抓的是 **Profile** 产物，而 `scripts/dev-verify.ps1 -Deploy` 构建/部署的是
# **Release**。两者的 `data/app.so` 是各自独立的编译输出：只跑 Release 构建时，
# Profile 目录里那份还是**上一次 `--profile` 构建的旧 Dart**。
#
# 后果很难看：验证「默认分支」的外观改动时，拍到的永远是旧行为，而且
# `--edge const` 之类**旧代码里已存在的开关照样生效**，于是看起来「开关是通的、
# 就是默认值没生效」—— 会一路往渲染后端 / shader 上怀疑，实际只是抓错了目录。
#
# 验证外观改动（尤其是「默认值」变了）时，务必显式指向已部署的 Release：
#     --app "D:\Mova\mova.exe"
# 判据：先 `grep -c -a cosine <app.so 所在目录>data/app.so` 对不上新代码的常量，
# 就说明抓的是旧产物。
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


def child_env(options) -> dict[str, str]:
    """应用子进程的环境变量：继承当前环境，再叠加诊断开关。"""
    env = dict(os.environ)
    if options.edge:
        env["MOVA_TRACE_EDGE"] = options.edge
    return env


def grab_by_print_window(hwnd: int):
    """用 `PrintWindow(PW_RENDERFULLCONTENT)` 向窗口索取它自己的绘制结果。

    为什么要单开这条路：`ImageGrab` 抓的是**屏幕像素**，桌面上只要有别的东西
    压在窗口上面，抓到的就是它 —— 实测踩过，四张截图整整齐齐全被别的程序盖住，
    而且每张盖的东西还不一样，逐像素比对时表现为「全图都在变」。`PrintWindow`
    向窗口要合成结果，不受遮挡影响。

    Flutter 走 GPU 直出，所以 `PW_RENDERFULLCONTENT`（0x2）不能省 —— 不带的话
    走的是老的 WM_PRINT 路径，拿回来是空白。
    """
    user32 = ctypes.windll.user32
    gdi32 = ctypes.windll.gdi32
    rect = wt.RECT()
    if not user32.GetWindowRect(hwnd, ctypes.byref(rect)):
        return None
    width = rect.right - rect.left
    height = rect.bottom - rect.top
    if width <= 0 or height <= 0:
        return None

    window_dc = user32.GetWindowDC(hwnd)
    mem_dc = gdi32.CreateCompatibleDC(window_dc)
    bitmap = gdi32.CreateCompatibleBitmap(window_dc, width, height)
    gdi32.SelectObject(mem_dc, bitmap)
    pw_render_full_content = 0x00000002
    ok = user32.PrintWindow(hwnd, mem_dc, pw_render_full_content)

    class BITMAPINFOHEADER(ctypes.Structure):
        _fields_ = [
            ("biSize", wt.DWORD),
            ("biWidth", ctypes.c_long),
            ("biHeight", ctypes.c_long),
            ("biPlanes", wt.WORD),
            ("biBitCount", wt.WORD),
            ("biCompression", wt.DWORD),
            ("biSizeImage", wt.DWORD),
            ("biXPelsPerMeter", ctypes.c_long),
            ("biYPelsPerMeter", ctypes.c_long),
            ("biClrUsed", wt.DWORD),
            ("biClrImportant", wt.DWORD),
        ]

    info = BITMAPINFOHEADER()
    info.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    info.biWidth = width
    info.biHeight = -height  # 负值 = 自上而下，免得再翻转
    info.biPlanes = 1
    info.biBitCount = 32
    info.biCompression = 0  # BI_RGB
    buf = ctypes.create_string_buffer(width * height * 4)
    gdi32.GetDIBits(mem_dc, bitmap, 0, height, buf, ctypes.byref(info), 0)

    gdi32.DeleteObject(bitmap)
    gdi32.DeleteDC(mem_dc)
    user32.ReleaseDC(hwnd, window_dc)
    if not ok:
        return None
    return Image.frombuffer("RGB", (width, height), buf, "raw", "BGRX", 0, 1)


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
    parser.add_argument("--edge", default=None,
                        help="透传 MOVA_TRACE_EDGE，比对圆形玻璃描边环的候选画法"
                             "（const / cosine / none；其他值等同现状）")
    parser.add_argument("--print-window", action="store_true",
                        help="走 PrintWindow 取窗口自身绘制结果，不用屏幕像素 —— "
                             "桌面上有别的窗口盖着时唯一的可靠办法")
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
            [str(app)], cwd=str(app.parent), env=child_env(options),
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

    # PrintWindow 只向窗口要它自己的绘制结果，与屏幕上谁压着谁无关，因此**不需要**
    # 抢前台 —— 少一次把用户正在用的窗口压下去、也少一次置顶闪烁。
    box = None if options.print_window else _foreground_window()
    if box is None and not options.print_window:
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
        if not options.print_window:
            box = _foreground_window() or box
    if options.print_window:
        hwnd = ctypes.windll.user32.FindWindowW(None, WINDOW_TITLE)
        image = grab_by_print_window(hwnd) if hwnd else None
        if image is None:
            print("BAD  PrintWindow 没拿到像素（窗口不存在，或渲染后端不给重定向表面）")
            if process is not None:
                process.terminate()
            return 1
        image.save(out)
        print(f"OK   {out.name}  {image.size[0]}x{image.size[1]}  PrintWindow 直取")
    else:
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
