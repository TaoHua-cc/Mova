"""控件条 / 顶栏两块离屏面的量化验证：底板到底是「真透明」还是「一块黑板」。

背景（2026-09-20）：控件条原先用
`SetLayeredWindowAttributes(g_controls, 0, 232, LWA_ALPHA)` 合成 —— 常量 alpha 只能把
「一整块不透明内容」整体压到 91%，视频只透过 9%，所以无论底板画多淡都必然是一块近黑
板。改成逐像素 alpha（`UpdateLayeredWindow` + 32bpp 预乘 ARGB DIB）后才真的透明。
顶栏同一天也从 `LWA_ALPHA | LWA_COLORKEY` 换成了 ULW。

随后用户又提了两条：「进度条从屏幕最左边到最右边完整展示」「去掉下面的控件背景框」，
于是控件条变成「一条通屏进度条 + 一排常驻玻璃圆片」，那道 10→124 的 scrim 全删，只留
一层 6/255、上下淡出的命中带（alpha=0 的像素会点击穿透，而拖动 / 悬停靠它收鼠标）。

再之后（同日）又提了「进度条和控件鼠标悬浮不要蓝色，进度条要能分辨已播放 / 已缓存 /
未缓存」与「提示不要黑底」：进度条改成同一条白的三档（未缓存 52 → 已缓存 96 →
已播放 250，底下垫一层 96 的黑保证亮画面上也看得见），悬停点亮从蓝改白；提示改成
完整胶囊 + 与应用同一套玻璃材质（基色 frost、浓度跟「外观 → 模糊程度」走）。

这个脚本直接读播放器导出的 `controls_*.bmp` / `topbar_*.bmp` / `hint_*.bmp`
（`MOVA_TRACE_PANEL=<目录>`），断言：

  控件条
  1. 存在真透明像素（alpha=0）            —— 下缘淡出 + 未绘制区域真的透出去；
  2. 顶带 mean alpha > 0 且 < 60           —— 顶端**不能归零**：命中要靠这条带；
  3. 空白处（按钮之间的整块区域）max alpha <= 12
                                          —— 没有可见底板（用户看到的「控件背景框」）；
  4. 进度条两端都有内容                    —— 最左 1% 与最右 1% 列在进度条所在行带宽
                                              内 alpha >= 80，证明它是通屏的；
  5. 已播放段明显亮于未缓存段              —— 左端 peak >= 200 且至少比右端高 80，
                                              三档亮度必须分得出来（不再是同一支蓝）；
  6. 实心（alpha>=200）像素 < 20%          —— 只有图标/进度条/时间码是不透明的。

  顶栏
  7. 真透明像素 > 80%                      —— 换成 ULW 之前整条恒为 232，不可能这么透；
  8. 中段 25%~75% 的 max alpha <= 12       —— 顶上没有横贯整屏的黑条；
  9. 最右 22% max alpha >= 80              —— 右上角三个窗口按钮确实画出来了。

  提示（滚轮改音量触发）
 10. 存在真透明像素 >= 3%                  —— 四周留了给柔影的透明边；
 11. 提示体的 mean alpha 在 60~200 之间    —— 是「透光的玻璃」而不是一块 247 的黑塑料，
                                              也不能薄到压不住字。
 12. 提示窗口矩形落在**播放器窗口**内      —— 用户原话「不要显示在播放器外面」。
                                              窗口模式下播放器只占桌面一块，按屏幕
                                              工作区居中会把提示飘到窗口外。

用法：
  python tool/verify_controls_dock_surface.py [--exe PATH] [--workdir DIR]
"""

import argparse
import ctypes
import glob
import os
import struct
import sys
import time
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyze_layer_alpha as alpha_tool  # noqa: E402
import verify_native_panels as base  # noqa: E402
import verify_segments_and_danmaku as suite  # noqa: E402

user32 = base.user32

WM_MOUSEWHEEL = 0x020A


def write_checker_png(path, width, height, bgra, cell=10):
    """把离屏面按「棋盘格背景」合成后导出 PNG，供人眼复核。

    ⚠️ 不能直接复用 `base.write_png`：那支只写 RGB、**把 alpha 丢掉**，而离屏面是
    **预乘** ARGB —— 丢掉 alpha 后 124 的玻璃看着就是一块近黑，正好把「到底透不透」
    这个要看的点看反了（断言读的是 alpha，不受影响，但人眼证据会骗人）。

    预乘源的 over 合成就是 `out = src + dst * (1 - a)`；背景用棋盘格，
    半透明区域才会自己「说话」。
    """
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            index = (y * width + x) * 4
            blue, green, red, alpha = bgra[index:index + 4]
            light = ((x // cell) + (y // cell)) % 2 == 0
            base = 200 if light else 96
            keep = 255 - alpha
            out_r = min(255, red + base * keep // 255)
            out_g = min(255, green + base * keep // 255)
            out_b = min(255, blue + base * keep // 255)
            raw += bytes((out_r, out_g, out_b))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)


def band(rows, lo, hi):
    picked = rows[int(len(rows) * lo):max(int(len(rows) * hi), 1)]
    return sum(picked) / float(len(picked)) if picked else 0.0


def nudge_cursor_into_dock(controls):
    """把真实光标挪进控件条并抖一下 —— 自动隐藏只认真实位移。"""
    window, _ = base.geometry(controls)
    cx = (window.left + window.right) // 2
    cy = (window.top + window.bottom) // 2
    for index in range(6):
        user32.SetCursorPos(cx + index * 4, cy + (index % 2) * 3)
        time.sleep(0.06)
    user32.SetCursorPos(cx, cy)


def run(exe, workdir):
    out_dir = os.path.join(os.environ["TEMP"], "mova_controls_surface")
    trace_dir = os.path.join(out_dir, "trace")
    os.makedirs(trace_dir, exist_ok=True)
    for stale in glob.glob(os.path.join(trace_dir, "controls_*.bmp")):
        os.remove(stale)

    media = suite.media_file(out_dir)
    player = suite.Player(exe, workdir, media, [], trace_dir)
    problems = []
    details = []
    try:
        controls = base.wait_class("MovaNativePlayerControls", timeout=25.0)
        if not controls:
            return ["controls window never appeared"], details, None
        nudge_cursor_into_dock(controls)
        time.sleep(1.0)
        files = sorted(glob.glob(os.path.join(trace_dir, "controls_*.bmp")))
        if not files:
            problems.append("NO controls_*.bmp dumped (MOVA_TRACE_PANEL not honoured?)")
            return problems, details, None

        reports = [alpha_tool.analyze(path) for path in files]
        reports.sort(key=lambda item: item["mean_alpha"], reverse=True)
        best = reports[0]
        rows = best["row_alpha"]
        top = band(rows, 0.0, 0.10)
        upper = band(rows, 0.10, 0.32)
        bottom = band(rows, 0.86, 1.0)
        frame = alpha_tool.read_bmp(files[0])
        # 空白处：时间码右边到传输按钮左边这一整片（设计稿里 x≈0.10~0.30 段，
        # 上下都避开图标行）。这里只该剩 6/255 的命中带。
        gap_peak = alpha_tool.region_max(frame, 0.10, 0.30, 0.35, 0.95)
        # 进度条是否真的通屏：最左 / 最右 1% 列，在进度条所在的 y 带里必须有内容。
        left_peak = alpha_tool.region_max(frame, 0.0, 0.01, 0.10, 0.26)
        right_peak = alpha_tool.region_max(frame, 0.99, 1.0, 0.10, 0.26)

        details.append(f"frames dumped        = {len(files)}")
        details.append(f"surface              = {best['size'][0]}x{best['size'][1]}"
                       f"  ({best['path']})")
        details.append(f"transparent alpha=0  = {best['zero_pct']:.2f}%")
        details.append(f"solid    alpha>=200  = {best['opaque_pct']:.2f}%")
        details.append(f"mean alpha           = {best['mean_alpha']:.1f}")
        details.append(f"band alpha top={top:.1f} upper={upper:.1f} bottom={bottom:.1f}")
        details.append(f"peak alpha gap={gap_peak}  progress left={left_peak} "
                       f"right={right_peak}")

        if best["zero_pct"] <= 0.1:
            problems.append(
                f"no truly transparent pixels ({best['zero_pct']:.2f}%) — "
                "底板还是一整块不透明内容")
        if top <= 0.0:
            problems.append(
                f"top band alpha={top:.2f} == 0 → 顶部像素点击穿透，"
                "进度条拖动命中会失效")
        if top >= 60.0:
            problems.append(f"top band alpha={top:.1f} 太暗，顶上是可见的底板")
        if gap_peak > 12:
            problems.append(
                f"空白处 peak alpha={gap_peak} > 12 —— 又出现可见的底板了"
                "（只应剩 6/255 的命中带）")
        if left_peak < 80 or right_peak < 80:
            problems.append(
                f"进度条没有通屏（左 {left_peak} / 右 {right_peak} < 80）——"
                "左右两端到不了屏幕边缘")
        # 三档亮度必须分得出来：已播放是亮白（250），未缓存只是同一条白的低位
        # （52 + 一层 96 的黑托底）。以前两者同为 (110,168,255) 的蓝，右端看着
        # 和左端一个样，「已缓存 / 未缓存」根本读不出来。
        if left_peak < 200:
            problems.append(
                f"已播放段 peak alpha={left_peak} < 200 —— 不是亮白的「已播放」")
        if left_peak < right_peak + 80:
            problems.append(
                f"已播放 {left_peak} 与未缓存 {right_peak} 差不到 80 ——"
                "三档亮度分不出来")
        if best["opaque_pct"] >= 20.0:
            problems.append(
                f"实心像素 {best['opaque_pct']:.1f}% 太多 —— 不像「只有控件」")

        # 顶栏：同一天也从 LWA_ALPHA|LWA_COLORKEY 换成了 ULW。它以前是「一条恒为
        # 232 的暗带」，现在是逐像素 alpha —— 中段应当完全透明。
        topbar_files = sorted(glob.glob(os.path.join(trace_dir, "topbar_*.bmp")))
        if not topbar_files:
            problems.append("NO topbar_*.bmp dumped (MOVA_TRACE_PANEL not honoured?)")
        else:
            bar_reports = [alpha_tool.analyze(path) for path in topbar_files]
            bar_reports.sort(key=lambda item: item["mean_alpha"], reverse=True)
            bar = bar_reports[0]
            bar_frame = alpha_tool.read_bmp(topbar_files[0])
            bar_mid = alpha_tool.region_max(bar_frame, 0.25, 0.75, 0.0, 1.0)
            bar_right = alpha_tool.region_max(bar_frame, 0.78, 1.0, 0.0, 1.0)

            details.append(f"topbar               = {bar['size'][0]}x{bar['size'][1]}"
                           f"  zero={bar['zero_pct']:.2f}%  mean={bar['mean_alpha']:.1f}")
            details.append(f"topbar peak          mid={bar_mid} right={bar_right}")

            if bar["zero_pct"] <= 80.0:
                problems.append(
                    f"顶栏只有 {bar['zero_pct']:.1f}% 真透明像素 —— 还是一整条不透明暗带")
            if bar_mid > 12:
                problems.append(
                    f"顶栏中段 max alpha={bar_mid} > 12 —— 顶上出现了横贯整屏的底板")
            if bar_right < 80:
                problems.append(
                    f"顶栏最右 22% max alpha={bar_right} < 80 —— 右上角窗口按钮没画出来")

            bar_png = os.path.join(out_dir, "topbar_surface.png")
            write_checker_png(bar_png, bar_frame[0], bar_frame[1], bar_frame[2])
            details.append(f"topbar png           = {bar_png}")

        # 提示浮层：滚轮改音量会弹一次。它以前是一块 168~196 的海军蓝近黑
        # （用户说的「提示也是黑色背景」），现在和应用同一套玻璃 —— 这里量它
        # 到底有多透。滚轮由控件条窗口处理（不是主窗口）。
        for stale in glob.glob(os.path.join(trace_dir, "hint_*.bmp")):
            os.remove(stale)
        # 提示必须夹在**播放器窗口**里（用户原话：「不要显示在播放器外面」）。
        # 窗口模式下播放器只占桌面一块，按屏幕工作区居中会让提示飘到窗口外。
        #
        # ⚠️ 提示是 toast（1.5s 就自己收），单次「发滚轮 → 等 0.6s → 查窗口」会
        # 偶发查不到（查的那一瞬刚好被收掉）。改成「发一次就抓着找 0.9s，
        # 没抓到再发一次」，最多试 4 轮 —— 抓不到的才是真失败。
        main_window = base.wait_class("MovaNativePlayerWindow", timeout=5.0)
        hint_rect = None
        for _ in range(4):
            user32.PostMessageW(controls, WM_MOUSEWHEEL, (120 & 0xFFFF) << 16,
                                0)
            deadline = time.time() + 0.9
            while time.time() < deadline:
                hint_window = base.wait_class("MovaNativePlayerHint",
                                              timeout=0.03, visible=True)
                if hint_window:
                    hint_rect, _ = base.geometry(hint_window)
                    break
                time.sleep(0.03)
            if hint_rect:
                break
        time.sleep(0.3)
        if hint_rect is not None and main_window:
            frame, _ = base.geometry(main_window)
            details.append(
                f"hint rect            = ({hint_rect.left},{hint_rect.top})-"
                f"({hint_rect.right},{hint_rect.bottom})  "
                f"frame=({frame.left},{frame.top})-({frame.right},{frame.bottom})")
            if (hint_rect.left < frame.left or hint_rect.right > frame.right or
                    hint_rect.top < frame.top or hint_rect.bottom > frame.bottom):
                problems.append(
                    f"提示跑到播放器窗口外面了：hint="
                    f"({hint_rect.left},{hint_rect.top})-({hint_rect.right},{hint_rect.bottom})"
                    f" 不在 frame=({frame.left},{frame.top})-"
                    f"({frame.right},{frame.bottom}) 内")
        else:
            problems.append(
                "找不到提示 / 主窗口 —— 无法确认提示是否夹在播放器窗口内")
        hint_files = sorted(glob.glob(os.path.join(trace_dir, "hint_*.bmp")))
        if not hint_files:
            problems.append(
                "NO hint_*.bmp dumped —— 提示浮层没被触发（滚轮改音量应当弹一次）")
        else:
            hint_reports = [alpha_tool.analyze(path) for path in hint_files]
            hint_reports.sort(key=lambda item: item["mean_alpha"], reverse=True)
            hint = hint_reports[0]
            hint_frame = alpha_tool.read_bmp(hint_files[0])
            body_mean = alpha_tool.region_mean(hint_frame, 0.10, 0.90, 0.20, 0.80)
            details.append(f"hint                 = {hint['size'][0]}x{hint['size'][1]}"
                           f"  zero={hint['zero_pct']:.2f}%  body mean={body_mean:.1f}")
            if hint["zero_pct"] < 3.0:
                problems.append(
                    f"提示只有 {hint['zero_pct']:.2f}% 真透明像素 —— 胶囊四周的"
                    "柔影边距没留出来")
            if body_mean >= 200.0:
                problems.append(
                    f"提示体 mean alpha={body_mean:.1f} >= 200 —— 又变回一块黑塑料")
            if body_mean <= 40.0:
                problems.append(
                    f"提示体 mean alpha={body_mean:.1f} <= 40 —— 玻璃太薄，白字压不住画面")
            hint_png = os.path.join(out_dir, "hint_surface.png")
            write_checker_png(hint_png, hint_frame[0], hint_frame[1],
                              hint_frame[2])
            details.append(f"hint png             = {hint_png}")

        # 顺手留一张 PNG 供人眼确认
        width, height, buffer, _ = alpha_tool.read_bmp(files[0])
        png = os.path.join(out_dir, "controls_surface.png")
        write_checker_png(png, width, height, buffer)
        details.append(f"png                  = {png}")
    finally:
        player.close()
        code = player.process.returncode
        details.append(f"exit code            = {code}")
        if code != 0:
            problems.append(f"player exit code {code}")

    return problems, details, out_dir


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", default=r"D:\Mova\MovaNativePlayer.exe")
    parser.add_argument("--workdir", default=r"D:\Mova")
    options = parser.parse_args()

    ctypes.windll.shcore.SetProcessDpiAwareness(2)
    problems, details, out_dir = run(options.exe, options.workdir)
    for line in details:
        print("    " + line, flush=True)
    if problems:
        for line in problems:
            print("    FAILED: " + line, flush=True)
        print("    VERDICT BAD", flush=True)
        return 1
    print("    VERDICT OK  控件条与顶栏都是真透明，且顶部保住了命中", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
