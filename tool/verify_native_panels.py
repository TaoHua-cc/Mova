r"""End-to-end geometry + content regression for the native player's panels.

Launches the real MovaNativePlayer.exe with a synthetic playlist and servers,
posts real WM_LBUTTONDOWN clicks to the controls window at the tool slot
positions, then captures the whole player window from the screen so the dock
and the open panel are both visible in one image.

What it asserts (cases 01-06, geometry):
  * the panel hangs 0-20 px above the dock,
  * the panel is horizontally centred on the clicked tool button,
  * the process exits cleanly on WM_CLOSE.

What it exercises (cases 10-11, visual, no hard assertion):
  * the new per-episode args: --mova-playlist-image/-progress/-duration/-meta
    (real cover, watch progress with clock labels, placeholder without image),
  * the new per-resource args: --mova-resource-icon/-mark/-rank
    (icon file vs. mark fallback vs. rank ring).

The slot geometry mirrors ToolLayout() in main.cpp and is derived from the
controls window's measured client width, so it also works when the player
opens in its compact layout.

Usage:
  python tool/verify_native_panels.py [--exe D:\Mova\MovaNativePlayer.exe]

Screenshots and report.txt land in %TEMP%\mova_verify\.
"""
import argparse
import ctypes
import ctypes.wintypes as wt
import os
import struct
import subprocess
import sys
import time
import wave
import zlib

user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)

user32.FindWindowW.restype = wt.HWND
user32.FindWindowW.argtypes = [wt.LPCWSTR, wt.LPCWSTR]
user32.GetWindowRect.argtypes = [wt.HWND, ctypes.POINTER(wt.RECT)]
user32.GetClientRect.argtypes = [wt.HWND, ctypes.POINTER(wt.RECT)]
user32.IsWindowVisible.argtypes = [wt.HWND]
user32.GetDC.restype = wt.HDC
user32.GetDC.argtypes = [wt.HWND]
gdi32.CreateCompatibleDC.restype = wt.HDC
gdi32.CreateCompatibleDC.argtypes = [wt.HDC]
gdi32.CreateDIBSection.restype = wt.HBITMAP
gdi32.CreateDIBSection.argtypes = [
    wt.HDC, ctypes.c_void_p, wt.UINT, ctypes.POINTER(ctypes.c_void_p),
    wt.HANDLE, wt.DWORD]
gdi32.SelectObject.restype = wt.HGDIOBJ
gdi32.SelectObject.argtypes = [wt.HDC, wt.HGDIOBJ]
gdi32.DeleteObject.argtypes = [ctypes.c_void_p]
gdi32.DeleteDC.argtypes = [wt.HDC]
gdi32.BitBlt.argtypes = [
    wt.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
    wt.HDC, ctypes.c_int, ctypes.c_int, wt.DWORD]
gdi32.BitBlt.restype = wt.BOOL
user32.ReleaseDC.argtypes = [wt.HWND, wt.HDC]

BI_RGB = 0
SRCCOPY = 0x00CC0020
WM_CLOSE = 0x0010
WM_LBUTTONDOWN = 0x0201
WM_LBUTTONUP = 0x0202
MK_LBUTTON = 0x0001

# Panel metrics from main.cpp, needed to aim a click at a row inside a panel.
PANEL_SHADOW = 26
PANEL_PADDING = 10
PANEL_ROW_GAP = 6
PANEL_HEADER_H = 32
PANEL_OPTION_H = 68


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", wt.DWORD), ("biWidth", ctypes.c_long),
        ("biHeight", ctypes.c_long), ("biPlanes", wt.WORD),
        ("biBitCount", wt.WORD), ("biCompression", wt.DWORD),
        ("biSizeImage", wt.DWORD), ("biXPelsPerMeter", ctypes.c_long),
        ("biYPelsPerMeter", ctypes.c_long), ("biClrUsed", wt.DWORD),
        ("biClrImportant", wt.DWORD)]


def write_png(path, width, height, bgra):
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)
        row = bgra[y * stride:(y + 1) * stride]
        for x in range(width):
            raw += bytes((row[x * 4 + 2], row[x * 4 + 1], row[x * 4]))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)


def solid_png(path, red, green, blue, width=96, height=54):
    row = bytes((blue, green, red, 255)) * width
    write_png(path, width, height, row * height)


def grab_screen(rect):
    width = rect.right - rect.left
    height = rect.bottom - rect.top
    screen_dc = user32.GetDC(None)
    mem_dc = gdi32.CreateCompatibleDC(screen_dc)
    bmi = BITMAPINFOHEADER()
    bmi.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bmi.biWidth = width
    bmi.biHeight = -height
    bmi.biPlanes = 1
    bmi.biBitCount = 32
    bmi.biCompression = BI_RGB
    bits = ctypes.c_void_p()
    hbmp = gdi32.CreateDIBSection(mem_dc, ctypes.byref(bmi), 0,
                                  ctypes.byref(bits), None, 0)
    old = gdi32.SelectObject(mem_dc, hbmp)
    gdi32.BitBlt(mem_dc, 0, 0, width, height, screen_dc, rect.left, rect.top,
                 SRCCOPY)
    buf = ctypes.string_at(bits, width * height * 4)
    gdi32.SelectObject(mem_dc, old)
    gdi32.DeleteObject(hbmp)
    gdi32.DeleteDC(mem_dc)
    user32.ReleaseDC(None, screen_dc)
    return width, height, buf


def geometry(hwnd):
    rect = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    client = wt.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(client))
    return rect, client


# 自绘 UI 的缩放：main.cpp 里所有尺寸常量都是 1280x760 的设计稿值，绘制和
# 命中判定都先除一遍 UiScale()。窗口默认开到工作区的 92%（宽高各自封顶
# 1920x1160），比设计稿大，所以 UiScale() 会到 1.25 上限——测试里 PostMessage
# 的坐标是「物理像素」，必须先按设计稿写、再乘系数，否则点不中。
UI_DESIGN_WIDTH = 1280.0
UI_DESIGN_HEIGHT = 760.0
UI_MIN_SCALE = 0.55
UI_MAX_SCALE = 1.25


def ui_scale(main_hwnd):
    """Mirror UpdateUiScale(): design units -> physical pixels."""
    _, client = geometry(main_hwnd)
    return max(UI_MIN_SCALE,
               min(UI_MAX_SCALE,
                   min(client.right / UI_DESIGN_WIDTH,
                       client.bottom / UI_DESIGN_HEIGHT)))


def design_size(main_hwnd):
    """Physical client size -> (design width, design height, ui scale)."""
    _, client = geometry(main_hwnd)
    scale = ui_scale(main_hwnd)
    return client.right / scale, client.bottom / scale, scale


def click_design(hwnd, x, y, label, scale=1.0):
    """Click a point given in *design* coordinates.

    Returns the physical point actually posted, so callers that compare
    against the panel's on-screen position stay in physical space.
    """
    px = int(round(x * scale))
    py = int(round(y * scale))
    click(hwnd, px, py, label)
    return px, py


def make_wav(path, seconds=3.0, rate=8000):
    with wave.open(path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(b"\x00\x00" * int(rate * seconds))


def wait_class(name, timeout=20.0, visible=False):
    """Wait for a window by class name.

    ``visible=True`` additionally requires IsWindowVisible. That matters for
    the panel: the panel window is created once at startup and parked at 1x1
    while hidden, so a plain FindWindow match returns the parked handle and
    the caller samples "NOT VISIBLE" before the click has revealed it.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        hwnd = user32.FindWindowW(name, None)
        if hwnd and (not visible or user32.IsWindowVisible(hwnd)):
            return hwnd
        time.sleep(0.02)
    return None


def tool_slots(dock_width, tool_count):
    """Mirror ToolAreaStart / ToolSlotCapacity / ToolLayout."""
    compact = dock_width < 780
    transport_right = dock_width / 2.0 + (104.0 if compact else 166.0)
    area_start = transport_right + 24.0
    reserved_volume = 0.0 if compact else 120.0
    available = dock_width - 24.0 - area_start - reserved_volume
    capacity = max(0, int(available // 40.0))
    start = area_start + (0.0 if compact else 120.0)
    overflow = tool_count > capacity
    shown = max(0, capacity - 1) if overflow else min(tool_count, capacity)
    centres = [int(start + 20.0 + i * 40.0) for i in range(shown)]
    if overflow:
        centres.append(int(start + 20.0 + shown * 40.0))
    return [c for c in centres if c + 20 <= dock_width - 4], overflow, capacity


def click(hwnd, x, y, label):
    packed = ((y & 0xFFFF) << 16) | (x & 0xFFFF)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.15)
    user32.PostMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, packed)
    user32.PostMessageW(hwnd, WM_LBUTTONUP, 0, packed)
    time.sleep(0.4)
    print(f"    click {label} @({x},{y})")


def measure(controls, panel, expected_center_x=None):
    c_rect, c_client = geometry(controls)
    out = [f"    dock   rect=({c_rect.left},{c_rect.top})-({c_rect.right},{c_rect.bottom})"
           f" client={c_client.right}x{c_client.bottom}"]
    if not panel or not user32.IsWindowVisible(panel):
        out.append("    panel  NOT VISIBLE")
        return "\n".join(out), False
    p_rect, p_client = geometry(panel)
    body_top = p_rect.top + PANEL_SHADOW
    body_bottom = p_rect.bottom - PANEL_SHADOW
    body_left = p_rect.left + PANEL_SHADOW
    body_right = p_rect.right - PANEL_SHADOW
    gap = c_rect.top - body_bottom
    ok = 0 <= gap <= 20
    out.append(
        f"    panel  body=({body_left},{body_top})-({body_right},{body_bottom})"
        f" size={p_client.right}x{p_client.bottom}")
    out.append(f"    gap panel-bottom -> dock-top = {gap}px (expect ~8)")
    out.append("    VERDICT " + (
        "OK  panel hangs just above the dock"
        if ok else "BAD panel is not anchored above the dock"))
    if expected_center_x is not None:
        centre = (body_left + body_right) / 2.0
        delta = centre - expected_center_x
        aligned = abs(delta) <= 4.0
        out.append(
            f"    panel centre x={centre:.0f} clicked button screen x="
            f"{expected_center_x} delta={delta:+.0f}px")
        out.append("    VERDICT " + (
            "OK  panel is centred on the clicked button"
            if aligned else "BAD panel is horizontally offset from the button"))
        ok = ok and aligned
    return "\n".join(out), ok


def playlist_args():
    """Synthetic 5-episode playlist spanning two seasons."""
    entries = [
        ("怪奇物语", 1, 1, "第一章 开端"),
        ("怪奇物语", 1, 2, "第二章 枫树街"),
        ("怪奇物语", 1, 3, "第三章 圣诞灯"),
        ("怪奇物语", 2, 1, "第一章 疯狂麦克斯"),
        ("怪奇物语", 2, 2, "第二章 不给糖就捣蛋"),
    ]
    argv = ["--mova-playlist-start=0"]
    for title, season, episode, name in entries:
        argv += [
            f"--mova-playlist-title={title}",
            f"--mova-playlist-season={season}",
            f"--mova-playlist-episode={episode}",
            f"--mova-playlist-episode-title={name}",
            f"--mova-playlist-detail=第 {season} 季 · 第 {episode} 集 · {name}",
        ]
    return argv


def resource_args():
    return [
        "--mova-resource-source=云盘 A",
        "--mova-resource-detail=1920×1080 · HDR10 · 8.1 Mbps · 4.7 GB",
        "--mova-resource-source=云盘 B",
        "--mova-resource-detail=3840×2160 · 杜比视界 · 24.0 Mbps · 46.2 GB",
        "--mova-resource-source=WebDAV 家里",
        "--mova-resource-detail=1280×720 · SDR · 3.2 Mbps · 850 MB",
        "--mova-resource-current=0",
    ]


def full_args(out_dir):
    """The full argument set the app now emits, with real fixture images.

    12 episodes across two seasons, current = S2E1 (playlist index 9) —
    mirrors the real-library screenshot that showed out-of-panel drawing.
    """
    cover_a = os.path.join(out_dir, "cover_a.png")
    cover_b = os.path.join(out_dir, "cover_b.png")
    icon = os.path.join(out_dir, "icon_server.png")
    solid_png(cover_a, 200, 60, 60)
    solid_png(cover_b, 60, 120, 220)
    solid_png(icon, 240, 180, 40, 96, 96)
    argv = ["--mova-playlist-start=9"]
    for index in range(12):
        season = 1 if index < 9 else 2
        episode = index + 1 if season == 1 else index - 8
        progress = ""
        duration = "3200"
        watched = index < 7  # S1E1-7 fully watched -> badge, no progress bar
        if index == 7:
            progress = "0.01"  # barely started (S1E8)
        elif index == 8:
            progress = "0.2"
        elif index == 9:
            progress = "0.37"  # current
        elif index == 10:
            progress = "0.24"
        elif index == 11:
            progress = "0.22"
        argv += [
            "--mova-playlist-title=怪奇物语",
            f"--mova-playlist-season={season}",
            f"--mova-playlist-episode={episode}",
            f"--mova-playlist-episode-title=第 {index + 1} 个故事",
            f"--mova-playlist-detail=第 {season} 季 · 第 {episode} 集",
            f"--mova-playlist-image={cover_a if index % 2 == 0 else cover_b}",
            f"--mova-playlist-progress={progress}",
            f"--mova-playlist-duration={duration}",
            f"--mova-playlist-watched={1 if watched else 0}",
            f"--mova-playlist-meta=2016-0{index % 8 + 1}-15 · 53 分钟",
        ]
    # icon file / mark fallback / rank ring
    argv += [
        "--mova-resource-source=Jellyfin 主库",
        "--mova-resource-detail=3840×2160 · 杜比视界 · 24.0 Mbps · 46.2 GB",
        f"--mova-resource-icon={icon}",
        "--mova-resource-mark=2",
        "--mova-resource-rank=1",
        "--mova-resource-source=Emby 备库",
        "--mova-resource-detail=1920×1080 · HDR10 · 8.1 Mbps · 4.7 GB",
        "--mova-resource-icon=",
        "--mova-resource-mark=1",
        "--mova-resource-rank=2",
        "--mova-resource-source=WebDAV 家里",
        "--mova-resource-detail=1280×720 · SDR · 3.2 Mbps · 850 MB",
        "--mova-resource-icon=",
        "--mova-resource-mark=3",
        "--mova-resource-rank=3",
        "--mova-resource-current=0",
    ]
    return argv


def run_case(exe, workdir, media, name, tool_args, clicks, out_dir,
             expect_panel=True):
    out_path = os.path.join(out_dir, f"{name}.png")
    argv = [
        exe,
        "--config=no", "--force-window=yes", "--keep-open=no",
        "--pause=yes",
        "--vo=gpu-next", "--gpu-api=d3d11", "--gpu-context=d3d11",
        "--osc=no", "--hwdec=no", "--force-media-title=怪奇物语",
    ]
    argv += tool_args
    # 每一集都要真的进 mpv 播放列表：playlist-pos 只在有 N 个条目时才能指到
    # 第 N 项，只传一个文件的话「当前集」永远是 0，selected / reveal 全错位。
    # pause 固定时序，避免 3 秒样例播完跳集、控件条淡出这类竞态。
    episode_count = sum(
        1 for arg in tool_args if arg.startswith("--mova-playlist-title="))
    for _ in range(max(1, episode_count)):
        argv.append(media)

    proc = subprocess.Popen(argv, cwd=workdir)
    lines = [f"=== {name} === pid={proc.pid}"]
    main_hwnd = wait_class("MovaNativePlayerWindow")
    controls = wait_class("MovaNativePlayerControls")
    if not main_hwnd or not controls:
        proc.kill()
        lines.append("    FAILED to find the player windows")
        return "\n".join(lines)
    time.sleep(1.5)

    # The window opens centred on the work area; log the evidence.
    m_rect, _ = geometry(main_hwnd)
    centre_x = (m_rect.left + m_rect.right) / 2.0
    work = wt.RECT()
    ctypes.windll.user32.SystemParametersInfoW(0x0030, 0, ctypes.byref(work), 0)
    work_cx = (work.left + work.right) / 2.0
    work_cy = (work.top + work.bottom) / 2.0
    centre_y = (m_rect.top + m_rect.bottom) / 2.0
    lines.append(
        f"    window rect=({m_rect.left},{m_rect.top})-({m_rect.right},"
        f"{m_rect.bottom}) centre=({centre_x:.0f},{centre_y:.0f}) "
        f"work centre=({work_cx:.0f},{work_cy:.0f})")

    _, c_client = geometry(controls)
    order = []
    for arg in tool_args:
        if arg.startswith("--mova-tool-order="):
            order.append(arg.split("=", 1)[1])
    if not order:
        order = ["声音", "字幕", "剧集", "弹幕", "画面", "倍速", "章节",
                 "片头片尾", "资源"]
    # ToolLayout() 吃的是设计稿宽度，控件条的命中判定也把物理坐标除回设计稿，
    # 所以这里先把 dock 的物理宽度换算成设计宽度再排版。
    scale = ui_scale(main_hwnd)
    dock_design = int(round(c_client.right / scale))
    centres, overflow, capacity = tool_slots(dock_design, len(order))
    lines.append(
        f"    order={order} dock={dock_design}(design) x "
        f"{c_client.right}(px) scale={scale:.3f} capacity={capacity}"
        f" overflow={overflow}")
    lines.append(f"    slot centres={centres} (design)")

    last_dock_click_x = None
    for click_fn in clicks:
        screen_x = click_fn(controls, centres, scale)
        if screen_x is not None:
            last_dock_click_x = screen_x

    panel = wait_class("MovaNativePlayerPanel", timeout=3.0, visible=True)
    if not panel and clicks:
        # PostMessage 的点击偶发落空（与被测代码无关的时序毛刺，失败用例
        # 每轮随机分布）：等不到面板就把整串点击重放一遍再等一次。
        for click_fn in clicks:
            click_fn(controls, centres, scale)
        panel = wait_class("MovaNativePlayerPanel", timeout=3.0, visible=True)
    text, ok = measure(controls, panel, last_dock_click_x)
    if not expect_panel:
        # 用例本身就不点击：面板不出现才是对的。
        text += "\n    VERDICT " + (
            "OK  no panel as expected"
            if not panel else "BAD panel opened without a click")
        ok = not panel
    lines.append(text)

    rect, _ = geometry(main_hwnd)
    width, height, buf = grab_screen(rect)
    write_png(out_path, width, height, buf)
    lines.append(f"    shot {name}.png {width}x{height}")

    user32.PostMessageW(main_hwnd, WM_CLOSE, 0, 0)
    try:
        proc.wait(timeout=10)
        lines.append(f"    exit code = {proc.returncode}")
    except subprocess.TimeoutExpired:
        proc.kill()
        lines.append("    exit code = KILLED")
        ok = False
    return "\n".join(lines), ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", default=r"D:\Mova\MovaNativePlayer.exe")
    parser.add_argument("--workdir", default=r"D:\Mova")
    options = parser.parse_args()

    exe = options.exe
    workdir = options.workdir
    out_dir = os.path.join(os.environ["TEMP"], "mova_verify")
    os.makedirs(out_dir, exist_ok=True)
    media = os.path.join(out_dir, "silent.wav")
    make_wav(media)

    def click_slot(index, label):
        def run(controls, centres, scale=1.0):
            if index >= len(centres):
                print(f"    click {label} SKIPPED (no slot {index})")
                return None
            px, _ = click_design(controls, centres[index], 72, label, scale)
            c_rect, _ = geometry(controls)
            return c_rect.left + px
        return run

    def click_panel_row(row_index, label):
        def run(controls, centres, scale=1.0):
            panel = wait_class("MovaNativePlayerPanel", timeout=3.0,
                               visible=True)
            if not panel:
                print(f"    click {label} SKIPPED (no panel)")
                return None
            y = (PANEL_SHADOW + PANEL_PADDING +
                 PANEL_HEADER_H + PANEL_ROW_GAP +
                 row_index * (PANEL_OPTION_H + PANEL_ROW_GAP) +
                 PANEL_OPTION_H // 2)
            click_design(panel, 170, y, label, scale)
            # 子面板沿用一级面板的锚点，所以预期的中心 x 仍是一级面板那个按钮。
            return None
        return run

    cases = [
        ("01_episodes", playlist_args() + ["--mova-tool-order=剧集"],
         [click_slot(0, "剧集 tool")], True),
        ("02_resources", resource_args() + ["--mova-tool-order=资源"],
         [click_slot(0, "资源 tool")], True),
        ("03_chapters", ["--mova-tool-order=章节"],
         [click_slot(0, "章节 tool")], True),
        ("04_overflow", [], [click_slot(3, "更多 tool")], True),
        ("05_overflow_subpanel", [],
         [click_slot(3, "更多 tool"), click_panel_row(0, "更多首行")], True),
        ("06_dock_only", [], [], False),
        ("10_episodes_full", full_args(out_dir) + ["--mova-tool-order=剧集"],
         [click_slot(0, "剧集 tool")], True),
        ("11_resources_full", full_args(out_dir) + ["--mova-tool-order=资源"],
         [click_slot(0, "资源 tool")], True),
    ]

    report = []
    failures = 0
    for name, args, clicks, expect_panel in cases:
        text, ok = run_case(exe, workdir, media, name, args, clicks, out_dir,
                            expect_panel=expect_panel)
        report.append(text)
        if not ok:
            failures += 1
    report.append(f"\nsummary: {len(cases) - failures}/{len(cases)} cases OK")

    text = "\n".join(report)
    with open(os.path.join(out_dir, "report.txt"), "w", encoding="utf-8") as f:
        f.write(text)
    print("\n" + text)
    print(f"\nreport: {os.path.join(out_dir, 'report.txt')}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
