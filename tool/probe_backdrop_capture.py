r"""背板模糊的端到端验证：那块玻璃里到底有没有「背后糊过的画面」？

原生播放器没有 `BackdropFilter`。一个分层窗口只能「透」，不能「糊」—— 想做出应用里
那种毛玻璃，就得自己抓一帧背后的画面、糊掉、再垫在 frost 底下（`DrawGlassBackdrop`）。
这条管线有好几个环节会静默失败，所以这里一路端到端断言：

  * 抓屏能不能看到**活**视频（D3D11 flip 交换链可能被提升到硬件覆盖平面，`BitBlt`
    抓回来是黑的）；
  * 提示 / 面板的离屏面在玻璃体上是不是**不透明**（alpha 255）——只有背板铺上去了
    才这样；拿不到背板走的是「真透明」老路，玻璃体只有 ~100；
  * 背板自己是不是「有画面 + 糊透了」（有起伏 = 有内容，相邻像素几乎相等 = 糊过）；
  * 一次重抓要多久（整窗 `PrintWindow` + 降采样 + 模糊），摊到刷新间隔上占多少核；
  * 暂停之后是不是**不再**重抓（画面静止，再抓一帧一模一样的纯属白烧 CPU）。

用法：
  # 用播放器自己的缓存块当片源（.bin.part 是 MKV 的话从头就能播）
  python tool/probe_backdrop_capture.py --workdir D:\Mova
  python tool/probe_backdrop_capture.py --media D:\clip.mkv --workdir D:\Mova

产物落在 %TEMP%\mova_glass_probe\：`panel_surface.png` / `hint_surface.png` /
`backdrop_surface.png`（合成到棋盘格上，半透明处一眼可见），以及 `trace\` 里的原始
离屏面与 `backdrop.log`（每次采集的各步耗时）。
"""
import argparse
import ctypes
import ctypes.wintypes as wt
import glob
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_native_panels as base
import verify_segments_and_danmaku as suite

user32 = base.user32
gdi32 = base.gdi32

user32.PrintWindow.argtypes = [wt.HWND, wt.HDC, wt.UINT]
user32.PrintWindow.restype = wt.BOOL

PW_RENDERFULLCONTENT = 0x00000002
WM_MOUSEWHEEL = 0x020A
WM_KEYDOWN = 0x0100
VK_SPACE = 0x20
# main.cpp 里 kGlassBackdropRefreshMs 的镜像（背板重抓的间隔）。改了那边要改这里，
# 否则「这块玻璃占多少核」会算错。
REFRESH_MS = 260

CACHE = os.path.join(os.environ["APPDATA"], "Mova", "Mova", "mova-video-cache")


def local_media(out_dir, chunk_bytes=48 * 1024 * 1024):
    """Cut the head off one of the player's own MKV cache chunks.

    The `.bin.part` files are the proxy's byte cache of a real episode. The
    Matroska ones (`1a 45 df a3`) stream from the first byte, so a truncated
    copy is a perfectly good 40-second test clip — and it needs no network.
    """
    os.makedirs(out_dir, exist_ok=True)
    target = os.path.join(out_dir, f"clip_{chunk_bytes // 1048576}mb.mkv")
    if os.path.exists(target) and os.path.getsize(target) >= chunk_bytes:
        return target
    candidates = []
    for path in glob.glob(os.path.join(CACHE, "*.bin.part")):
        with open(path, "rb") as handle:
            if handle.read(4) == b"\x1a\x45\xdf\xa3":
                candidates.append((os.path.getsize(path), path))
    if not candidates:
        return None
    candidates.sort(reverse=True)
    source = candidates[0][1]
    with open(source, "rb") as src, open(target, "wb") as dst:
        dst.write(src.read(chunk_bytes))
    print(f"media        = {os.path.basename(source)} head -> {target}")
    return target


def stats(width, height, buffer):
    """Mean / spread of the BGRA buffer, ignoring nothing."""
    count = width * height
    total = 0
    total_sq = 0
    for index in range(0, count * 4, 4):
        value = (buffer[index] + buffer[index + 1] + buffer[index + 2]) // 3
        total += value
        total_sq += value * value
    mean = total / count
    variance = max(0.0, total_sq / count - mean * mean)
    return mean, variance ** 0.5


def delta(first, second):
    """Fraction of sampled pixels that moved by more than 8 levels."""
    moved = 0
    total = 0
    for index in range(0, min(len(first), len(second)), 16):
        value = abs(first[index] - second[index])
        if value > 8:
            moved += 1
        total += 1
    return moved / max(1, total)


def print_window(hwnd, rect):
    width = rect.right - rect.left
    height = rect.bottom - rect.top
    screen_dc = user32.GetDC(None)
    mem_dc = gdi32.CreateCompatibleDC(screen_dc)
    bmi = base.BITMAPINFOHEADER()
    bmi.biSize = ctypes.sizeof(base.BITMAPINFOHEADER)
    bmi.biWidth = width
    bmi.biHeight = -height
    bmi.biPlanes = 1
    bmi.biBitCount = 32
    bmi.biCompression = 0
    bits = ctypes.c_void_p()
    hbmp = gdi32.CreateDIBSection(mem_dc, ctypes.byref(bmi), 0,
                                  ctypes.byref(bits), None, 0)
    old = gdi32.SelectObject(mem_dc, hbmp)
    ok = user32.PrintWindow(hwnd, mem_dc, PW_RENDERFULLCONTENT)
    buffer = ctypes.string_at(bits, width * height * 4)
    gdi32.SelectObject(mem_dc, old)
    gdi32.DeleteObject(hbmp)
    gdi32.DeleteDC(mem_dc)
    user32.ReleaseDC(None, screen_dc)
    return width, height, buffer, bool(ok)


def newest(trace_dir, pattern):
    files = sorted(glob.glob(os.path.join(trace_dir, pattern)))
    return files[-1] if files else None


def backdrop_refresh_cost(trace_dir):
    """背板每次重抓的实测耗时，从程序自己写的 backdrop.log 里读。

    比在外部比进程 CPU 靠谱得多：解码开销会随画面内容漂（同一次运行里就能从 55%
    涨到 80%），「扣基线」扣不准；而「抓一帧要多少毫秒」是确定的，跟解码无关。
    返回 (中位数 ms, 样本数)；没有任何成功记录时返回 None。
    """
    path = os.path.join(trace_dir, "backdrop.log")
    if not os.path.exists(path):
        return None
    totals = []
    with open(path, encoding="utf-8-sig", errors="replace") as handle:
        for line in handle:
            match = re.search(r"total ([\d.]+)ms", line)
            if match:
                totals.append(float(match.group(1)))
    if not totals:
        return None
    totals.sort()
    return totals[len(totals) // 2], len(totals)


def glass_mean(width, height, buffer):
    """Mean alpha over the middle band — the glass body, not the surrounding shadow."""
    total = 0
    count = 0
    for y in range(int(height * 0.45), int(height * 0.60)):
        row = y * width * 4
        for x in range(int(width * 0.20), int(width * 0.80)):
            total += buffer[row + x * 4 + 3]
            count += 1
    return total / max(1, count)


def export_best_surface(files, out_path, dock):
    """Write the *most opaque* frame of `files` as a checkerboard-composited PNG.

    ⚠️ Not `files[-1]`: a run also covers a paused stretch and possibly a black
    one, where the glass **correctly** falls back to plain translucency. Asking
    for the last frame can hand a human reviewer the fallback and read as "the
    glass is still broken". Composite over a checkerboard because these surfaces
    are premultiplied ARGB — a ~100-alpha glass looks near-black otherwise,
    which is exactly the thing being judged.
    """
    best = None
    for path in files:
        width, height, buffer = suite.read_bmp(path)
        mean = glass_mean(width, height, buffer)
        if best is None or mean > best[0]:
            best = (mean, path, width, height, buffer)
    if best is None:
        return
    mean, path, width, height, buffer = best
    dock.write_checker_png(out_path, width, height, buffer)
    print(f"    exported {os.path.basename(out_path):24s} {width}x{height}"
          f"  glass alpha={mean:.1f}  <- {os.path.basename(path)}"
          f" of {len(files)} frames")


def log_lines(trace_dir):
    path = os.path.join(trace_dir, "backdrop.log")
    if not os.path.exists(path):
        return 0
    with open(path, encoding="utf-8-sig", errors="replace") as handle:
        return sum(1 for _ in handle)


def window_picture_mean(hwnd, rect):
    """PrintWindow 拍到的画面平均亮度 —— 判断「此刻窗口里到底有没有画面」。

    ⚠️ 不能用屏幕 BitBlt 判：D3D 的 flip 交换链会被提升到硬件覆盖平面，BitBlt 抓到的
    视频区是黑的，只剩窗口边框/黑边那点亮，均值 20 也可能「其实没画面」。PrintWindow
    走的是 DWM 合成结果，和背板采集同一条路 —— 同一条路才有同一种答案。
    """
    width, height, buffer, _ = print_window(hwnd, rect)
    return stats(width, height, buffer)[0]


def wait_for_picture(hwnd, timeout=10.0):
    """等到窗口里真的有画面为止，返回最后测到的均值。

    背板在「没画面」时会正确地退回真透明玻璃（免得糊一块黑塑料）—— 所以想验证
    「玻璃里有没有那块糊过的画面」，必须先确认此刻确实有画面可糊，否则测到的是
    一次合法降级，而不是一个缺陷。播放器刚起播、跳转、缓冲、走到截断片尾都会黑一阵。
    """
    deadline = time.time() + timeout
    mean = 0.0
    while time.time() < deadline:
        mean = window_picture_mean(hwnd, base.geometry(hwnd)[0])
        if mean >= 6.0:
            return mean
        time.sleep(0.3)
    return mean


def surface_alpha(width, height, buffer, x0, x1, y0, y1):
    """Fraction of opaque pixels and the mean alpha over a relative box."""
    total = 0
    opaque = 0
    count = 0
    for y in range(int(height * y0), int(height * y1)):
        row = y * width * 4
        for x in range(int(width * x0), int(width * x1)):
            alpha = buffer[row + x * 4 + 3]
            total += alpha
            if alpha >= 240:
                opaque += 1
            count += 1
    return (opaque / max(1, count), total / max(1, count))


def picture_stats(width, height, buffer):
    """Mean luma, luma spread and horizontal neighbour difference.

    A *blurred* picture is the signature we want: real content (spread > 1) but
    neighbouring pixels nearly equal (neighbour difference small). A sharp video
    frame would show a much bigger neighbour difference; flat frost would show a
    spread of ~0.
    """
    luma = []
    for y in range(0, height, 2):
        row = y * width * 4
        for x in range(0, width, 2):
            offset = row + x * 4
            luma.append((buffer[offset] + buffer[offset + 1] +
                         buffer[offset + 2]) / 3.0)
    mean = sum(luma) / max(1, len(luma))
    spread = (sum((value - mean) ** 2 for value in luma) /
              max(1, len(luma))) ** 0.5
    diffs = []
    for y in range(0, height, 2):
        row = y * width * 4
        for x in range(0, width - 2, 2):
            offset = row + x * 4
            here = (buffer[offset] + buffer[offset + 1] + buffer[offset + 2]) / 3.0
            offset += 4
            there = (buffer[offset] + buffer[offset + 1] + buffer[offset + 2]) / 3.0
            diffs.append(abs(here - there))
    return mean, spread, sum(diffs) / max(1, len(diffs))


def cpu_seconds(pid):
    """Total CPU time of a process, via PowerShell (no psutil in this env)."""
    out = subprocess.check_output(
        ["powershell", "-NoProfile", "-Command",
         f"(Get-Process -Id {pid}).TotalProcessorTime.TotalSeconds"],
        text=True)
    return float(out.strip())


def check_glass(player, main_window, trace_dir, out_dir):
    """开着真视频，看玻璃里到底有没有那块「背后糊过的画面」。

    判据选得很明确，不做任何「看起来差不多」的判断：

      * 提示 / 面板的离屏面在玻璃体上必须**不透明**（alpha 255）。只有背板那一层被
        画上去才会这样 —— 拿不到背板时走的是「真透明」的老路，玻璃体只有 ~100。
      * 背板自己（`backdrop_*.bmp`，1/4 尺寸、提亮提饱和之后的那张）必须有画面
        （亮度有起伏）而且是**糊的**（相邻像素几乎相等）。有起伏但没有模糊，或者
        糊了却是纯色，都说明管线不对。
    """
    problems = []
    controls = base.wait_class("MovaNativePlayerControls", timeout=10.0)
    if not controls:
        return ["找不到控件条 —— 无法触发提示 / 打开面板"]

    # 控件条要真的亮着才能收点击与滚轮（自动隐藏会把它退场）。
    dock = __import__("verify_controls_dock_surface")
    dock.nudge_cursor_into_dock(controls)
    time.sleep(0.6)

    # 先量一条基线：这一段里没有任何玻璃浮层在刷。mpv 本身（软件解码）就吃掉大半个
    # 核，不扣掉基线的话，测出来的数全是解码的账。
    #
    # 基线和「开菜单」各测一次、取两次的平均：解码开销跟着画面内容走，同一段源在
    # 不同时刻能差 20pp（实测 41.8% vs 65.4%），只测一次会把漂移算进玻璃头上。
    def cpu_window(seconds):
        before = cpu_seconds(player.process.pid)
        started = time.perf_counter()
        time.sleep(seconds)
        return (cpu_seconds(player.process.pid) - before) / (
            time.perf_counter() - started)

    baseline_a = cpu_window(2.0)
    print(f"  baseline (no glass)  {baseline_a * 100:.1f}% of one core")

    # ---- 提示（滚轮改音量）：纯玻璃，没有缩略图这类内容来混淆 ----
    #
    # ⚠️ 不能只看 newest()。提示是 1.5s 的 toast，一次运行里可能弹好几条 —— 后面那条
    # 如果正好撞上视频没出画面的瞬间（跳转/缓冲/黑场），它会**正确地**退回「真透明」，
    # 于是断言把一次合法的降级判成失败（这个坑踩过：读到 hint_06 的 131，而 hint_00~05
    # 全是 255）。所以按「这次滚轮新产生的那些帧」来判：只要其中有一帧铺上了背板，
    # 就证明提示这条路径通了；退回了几帧、当时画面亮不亮，一并报出来供人核对。
    picture = wait_for_picture(main_window)
    print(f"  window picture before hint = {picture:.1f}")
    before_hint = set(glob.glob(os.path.join(trace_dir, "hint_*.bmp")))
    user32.PostMessageW(controls, WM_MOUSEWHEEL, (120 & 0xFFFF) << 16, 0)
    time.sleep(0.9)
    fresh = sorted(set(glob.glob(os.path.join(trace_dir, "hint_*.bmp"))) -
                   before_hint)
    if not fresh:
        problems.append("提示没被触发 —— 滚轮之后没有新的 hint_*.bmp")
    else:
        opaque_frames = 0
        for path in fresh:
            width, height, buffer = suite.read_bmp(path)
            opaque, mean = surface_alpha(width, height, buffer, 0.20, 0.80,
                                         0.45, 0.60)
            if mean >= 180:
                opaque_frames += 1
        width, height, buffer = suite.read_bmp(fresh[-1])
        _, last_mean = surface_alpha(width, height, buffer, 0.20, 0.80, 0.45,
                                     0.60)
        print(f"  hint surface    {width}x{height}  frames={len(fresh)}"
              f"  with-backdrop={opaque_frames}  last glass mean alpha="
              f"{last_mean:.1f}")
        if opaque_frames == 0:
            if picture >= 6.0:
                problems.append(
                    f"提示一帧都没铺上背板（{len(fresh)} 帧全是 alpha≈100 的退路），"
                    f"但触发前窗口里明明有画面（PrintWindow 均值 {picture:.1f}）"
                    f"—— 提示这条绘制路径的「设计稿矩形 → 背板像素」映射八成算错了")
            else:
                print(f"    (跳过断言：触发前窗口里没有画面，均值 {picture:.1f}，"
                      f"退回真透明是正确行为)")
        export_best_surface(fresh, os.path.join(out_dir, "hint_surface.png"),
                            dock)

    # ---- 面板（点「剧集」）：大块玻璃，另外验证设计稿矩形→背板像素的映射 ----
    picture = wait_for_picture(main_window)
    centres, scale, info = suite.tool_slot(controls, main_window, 1)
    before_panel = set(glob.glob(os.path.join(trace_dir, "panel_*.bmp")))
    base.click_design(controls, centres[0], 72, "剧集 tool", scale)
    panel = base.wait_class("MovaNativePlayerPanel", timeout=3.0, visible=True)
    if not panel:
        problems.append("点了「剧集」但面板没出来 —— 无法验证面板背板")
    else:
        time.sleep(0.8)
        busy = cpu_window(3.0)
        print(f"  panel open total     {busy * 100:.1f}% of one core (含软件解码)")
        fresh = sorted(set(glob.glob(os.path.join(trace_dir, "panel_*.bmp"))) -
                       before_panel)
        if not fresh:
            problems.append("面板没有导出离屏面")
        else:
            opaque_frames = 0
            for path in fresh:
                width, height, buffer = suite.read_bmp(path)
                opaque, mean = surface_alpha(width, height, buffer, 0.15, 0.85,
                                             0.20, 0.80)
                if mean >= 180:
                    opaque_frames += 1
            width, height, buffer = suite.read_bmp(fresh[-1])
            _, last_mean = surface_alpha(width, height, buffer, 0.15, 0.85,
                                         0.20, 0.80)
            print(f"  panel surface   {width}x{height}  frames={len(fresh)}"
                  f"  with-backdrop={opaque_frames}  last glass mean alpha="
                  f"{last_mean:.1f}")
            if opaque_frames == 0:
                if picture >= 6.0:
                    problems.append(
                        f"面板一帧都没铺上背板（{len(fresh)} 帧全是退路），但打开前"
                        f"窗口里明明有画面（PrintWindow 均值 {picture:.1f}）—— 很可能是"
                        f"「设计稿矩形 → 屏幕 → 背板像素」的映射算错了（越界就静默退回）")
                else:
                    print(f"    (跳过断言：打开前窗口里没有画面，均值 {picture:.1f}，"
                          f"退回真透明是正确行为)")
            export_best_surface(fresh, os.path.join(out_dir, "panel_surface.png"),
                                dock)

    # ---- 背板自己：有画面 + 是糊的 ----
    backdrop_path = newest(trace_dir, "backdrop_*.bmp")
    if not backdrop_path:
        problems.append("没有 backdrop_*.bmp —— 背板一次都没抓成")
    else:
        width, height, buffer = suite.read_bmp(backdrop_path)
        mean, spread, neighbour = picture_stats(width, height, buffer)
        print(f"  backdrop        {width}x{height}  luma mean={mean:.1f}"
              f"  spread={spread:.2f}  neighbour diff={neighbour:.2f}")
        if mean < 6.0:
            problems.append(f"背板几乎全黑（mean={mean:.1f}）")
        if spread < 1.0:
            problems.append(f"背板是一块纯色（spread={spread:.2f}）—— 没抓到画面")
        if neighbour > 8.0:
            problems.append(
                f"背板没被模糊（相邻像素差 {neighbour:.2f}）—— 模糊那一趟没生效")
        export_best_surface(sorted(glob.glob(os.path.join(trace_dir,
                                                          "backdrop_*.bmp"))),
                            os.path.join(out_dir, "backdrop_surface.png"), dock)

    # ---- 玻璃开着时的净开销：读程序自己记的「一帧抓了多久」 ----
    cost = backdrop_refresh_cost(trace_dir)
    if cost is None:
        problems.append("backdrop.log 里没有一条成功的采集记录 —— 背板一次都没成")
    else:
        median_ms, count = cost
        # REFRESH_MS 是 main.cpp 里 kGlassBackdropRefreshMs 的镜像；改了那边要改这里。
        share = median_ms / REFRESH_MS * 100.0
        print(f"  backdrop refresh     {median_ms:.1f} ms median over {count}"
              f" captures  ->  {share:.1f}% of one core while glass is up")
        # 一次抓帧 + 降采样 + 模糊就是这块玻璃的全部周期性开销。超过 15% 就该回头
        # 砍了（整窗 PrintWindow 是大头，降采样和模糊各 ~4ms 已经很小）。
        if share > 15.0:
            problems.append(
                f"背板刷新太贵：{median_ms:.1f}ms / {REFRESH_MS}ms = {share:.1f}% "
                f"of one core（暂停时应当归零，见 UpdateGlassBackdrop）")
    # ---- 暂停时玻璃不该再刷 ----
    #
    # 画面静止 → 每 260ms 再抓一帧和手上完全相同的图纯属白烧 CPU（整窗 PrintWindow
    # 就要 15ms）。判据很直接：暂停之后 backdrop.log 的行数不再增长。
    if panel is None:
        return problems
    before_pause = log_lines(trace_dir)
    user32.PostMessageW(main_window, WM_KEYDOWN, VK_SPACE, 0)
    time.sleep(1.0)
    paused_from = log_lines(trace_dir)
    time.sleep(2.2)
    paused_to = log_lines(trace_dir)
    print(f"  while paused         log lines {paused_from} -> {paused_to}"
          f"  (+{paused_to - paused_from} over 2.2s = {2.2 / (REFRESH_MS / 1000.0):.0f}"
          f" refresh slots)")
    if paused_to != paused_from:
        problems.append(
            f"暂停后背板还在刷（{paused_to - paused_from} 次 / 2.2s）—— 画面静止时"
            f"重抓一帧一模一样的图是白烧 CPU，UpdateGlassBackdrop 的暂停短路没生效")
    user32.PostMessageW(main_window, WM_KEYDOWN, VK_SPACE, 0)
    time.sleep(0.8)
    print(f"  after resume         log lines {before_pause} -> {log_lines(trace_dir)}")
    return problems


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--media", default="")
    parser.add_argument("--workdir", default=r"D:\Mova")
    parser.add_argument("--exe", default=r"D:\Mova\MovaNativePlayer.exe")
    options = parser.parse_args()

    out_dir = os.path.join(os.environ["TEMP"], "mova_glass_probe")
    os.makedirs(out_dir, exist_ok=True)
    media = options.media or local_media(out_dir)
    if not media or not os.path.exists(media):
        print("no media to play")
        return 2
    print(f"playing      = {media}")

    trace_dir = os.path.join(out_dir, "trace")
    os.makedirs(trace_dir, exist_ok=True)
    for stale in glob.glob(os.path.join(trace_dir, "*.bmp")):
        os.remove(stale)
    # 合成一份播放列表：剧集面板要有条目才打得开。空格要绑成播放/暂停 —— 快捷键表
    # 本来由应用下发，探针自己起播放器就得自己给，否则按空格没人接（RunShortcut 找不到
    # 这个键就直接返回 false），「暂停时不再刷背板」那条断言会假通过。
    extra = base.playlist_args() + ["--mova-tool-order=剧集",
                                    "--mova-shortcut=playPause|SPACE"]
    player = suite.Player(options.exe, options.workdir, media, extra, trace_dir)
    problems = []
    try:
        main_window = base.wait_class("MovaNativePlayerWindow", timeout=30.0)
        if not main_window:
            print("main window never appeared")
            return 1
        # 等 mpv 真正出画：有窗口不等于有帧。
        time.sleep(4.0)
        frame, _ = base.geometry(main_window)
        print(f"window rect  = ({frame.left},{frame.top})-"
              f"({frame.right},{frame.bottom})")

        first = base.grab_screen(frame)
        first_mean, first_spread = stats(*first)
        time.sleep(0.5)
        second = base.grab_screen(frame)
        second_mean, second_spread = stats(*second)
        moved = delta(first[2], second[2])

        width, height, buffer, ok = print_window(main_window, frame)
        pw_mean, pw_spread = stats(width, height, buffer)

        print()
        print("----- capture paths -----")
        print(f"  screen BitBlt   mean={first_mean:6.1f} spread={first_spread:6.1f}")
        print(f"  screen (0.5s)   mean={second_mean:6.1f} spread={second_spread:6.1f}"
              f"  moving pixels={moved * 100:.1f}%")
        print(f"  PrintWindow     mean={pw_mean:6.1f} spread={pw_spread:6.1f}"
              f"  returned={ok}")

        # 两条路的像素级对照：PrintWindow 若和屏幕抓屏几乎一致，说明它既含画面
        # 也和 GetWindowRect 对齐（面板/提示是按窗口矩形定位的，差几像素会错位）。
        same = delta(first[2], buffer)
        print(f"  screen vs print different pixels = {same * 100:.1f}%")

        # 代价：背板想「活着」（面板开着时定期重抓）就必须够快。
        for label, action in (
            ("screen BitBlt", lambda: base.grab_screen(frame)),
            ("PrintWindow  ", lambda: print_window(main_window, frame)),
        ):
            timings = []
            for _ in range(5):
                start = time.perf_counter()
                action()
                timings.append((time.perf_counter() - start) * 1000.0)
            timings.sort()
            print(f"  {label} cost = {timings[2]:6.1f} ms "
                  f"(min {timings[0]:.1f}, max {timings[-1]:.1f})")

        for name, data in (("screen", first), ("printwindow", (width, height,
                                                               buffer))):
            png = os.path.join(out_dir, f"{name}.png")
            base.write_png(png, data[0], data[1], data[2])
            print(f"  png             = {png}")

        print()
        # ⚠️ 判「有没有画面」只认 PrintWindow，不认屏幕 BitBlt。视频可能被提升到硬件
        # 覆盖平面，那时 BitBlt 抓到的视频区是纯黑 —— 屏幕上那几个数（上面已打印）只是
        # 背景参考，拿它断言会在别的机器上假失败。背板走的是 PrintWindow，同一条路
        # 才有同一种答案。
        if pw_mean < 4.0:
            problems.append(
                f"PrintWindow 拍不到画面（mean={pw_mean:.1f}）—— 背板拿不到东西可糊")

        problems += check_glass(player, main_window, trace_dir, out_dir)

        print()
        if problems:
            print("VERDICT FAILED")
            for item in problems:
                print("  - " + item)
            return 1
        print("VERDICT OK  背板模糊真的生效：抓屏能看到活画面，提示/面板玻璃体不透明，"
              "背板有内容且糊过，暂停时不再重抓")
        return 0
    finally:
        try:
            player.process.stdin.write("quit\n")
            player.process.stdin.flush()
        except Exception:
            pass
        try:
            player.process.wait(timeout=8)
        except Exception:
            player.process.kill()


if __name__ == "__main__":
    sys.exit(main())
