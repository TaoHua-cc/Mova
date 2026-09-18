"""End-to-end check for the native player's segment and danmaku panels.

What it verifies (all against the real MovaNativePlayer.exe):

  01_segment_panel   the segment data pushed over stdin (MOVA_SEGMENT / …DONE)
                     shows up in the 「片头片尾」panel, and clicking a segment
                     row seeks the player to that segment's end.
  02_danmaku_panel   the 「弹幕」panel carries the display settings that mirror
                     「设置 → 弹幕显示」; clicking one emits MOVA_SETTING back to
                     the app and refreshes the panel in place.
  03_auto_skip       with auto-skip on and a 2s delay, entering the intro range
                     moves playback to the end of the range on its own.
  08_interrupt_retry a 500 injected into the range request the auto-skip seek
                     triggers (a stand-in for a flaky source) must be absorbed by
                     one same-episode retry — not turned into 「播放失败」.
  04_danmaku_settings_playing
                     changing the danmaku settings while playing must not stop
                     the comments — checked through the draw trace and a screen
                     grab, both for a value row (显示区域) and for the 滚动弹幕
                     switch turned off and back on.
  05_live_settings   settings changed in the app *while playing* reach the
                     running player over stdin (MOVA_APPLY=…) and are applied on
                     the spot: danmaku values, the auto-skip switch and delay,
                     the danmaku master switch, and the option whitelist.
  06_danmaku_frame_pacing
                     with a dense comment burst (18/s, like an OP) the layer
                     must keep drawing inside the 60fps budget and never stall
                     between frames; the layer bitmap is dumped as well so the
                     cached-texture path is verified to still draw text.
                     Also asserts the two readability numbers: no two danmaku
                     may overlap by more than 2px in the same lane (depth),
                     and the frame clock's *average* interval must stay near
                     16.7ms — a max-only check cannot tell an occasional hitch
                     from a clock that systematically runs slow.

Screenshots and report.txt land in %TEMP%/mova_verify_segments/.

Usage:
  python tool/verify_segments_and_danmaku.py [--exe PATH] [--workdir DIR]
"""
import argparse
import base64
import ctypes
import ctypes.wintypes as wt
import glob
import os
import re
import struct
import subprocess
import sys
import threading
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_native_panels as base  # noqa: E402  (path set above)

user32 = base.user32
PANEL_NOTE_H = 34
WM_CLOSE = base.WM_CLOSE


def media_file(out_dir, seconds=120.0):
    path = os.path.join(out_dir, "silence120.wav")
    if not os.path.exists(path):
        base.make_wav(path, seconds=seconds)
    return path


def shot_danmaku(out_dir, name, trace_dir):
    """Export the danmaku layer's own bitmap and count how much text it holds.

    A screen grab cannot be trusted for the danmaku layer: it is a layered
    window, so anything stacked above it wins the BitBlt. The player can dump
    the layer's own DIB instead (MOVA_TRACE_PANEL), which is what we check here
    — the text now comes from cached bitmaps, so this is also the regression
    that the cached path still draws.
    """
    files = sorted(glob.glob(os.path.join(trace_dir, "danmaku_*.bmp")))
    if not files:
        return 0, "NO DANMAKU BITMAP (MOVA_TRACE_PANEL not honoured?)"
    width, height, buffer = read_bmp(files[-1])
    base.write_png(os.path.join(out_dir, f"{name}.png"), width, height, buffer)
    ink = sum(1 for value in buffer[3::4] if value > 32)
    return ink, (f"{name}.png {width}x{height} ink={ink}px "
                 f"(from {os.path.basename(files[-1])})")


def panel_row_y(rows):
    """Design-space y of a panel row's centre.

    ``rows`` is the list of row kinds above (and including) the wanted row,
    using the same vocabulary as the panel: ``header`` / ``note`` / ``option``.
    Mirrors PanelRowHeight() + the row gap in main.cpp.
    """
    y = base.PANEL_SHADOW + base.PANEL_PADDING
    for kind in rows[:-1]:
        y += {"header": base.PANEL_HEADER_H, "note": PANEL_NOTE_H,
              "option": base.PANEL_OPTION_H}[kind] + base.PANEL_ROW_GAP
    last = rows[-1]
    y += {"header": base.PANEL_HEADER_H, "note": PANEL_NOTE_H,
          "option": base.PANEL_OPTION_H}[last] // 2
    return y


def tool_slot(controls, main_hwnd, tool_count=1):
    """Locate the dock's tool buttons in design coordinates.

    ToolLayout() is fed the *design* dock width, and both the dock and the panel
    divide the incoming physical point by UiScale() before hit-testing. So the
    slot centres come out in design units and every click has to go through
    base.click_design().
    """
    scale = base.ui_scale(main_hwnd)
    _, client = base.geometry(controls)
    dock_design = int(round(client.right / scale))
    centres, overflow, capacity = base.tool_slots(dock_design, tool_count)
    return centres, scale, (f"dock={dock_design}(design) x {client.right}(px)"
                            f" scale={scale:.3f} capacity={capacity}"
                            f" overflow={overflow} centres={centres}")


class Player:
    """A running native player with its stdout line feed and stdin pipe."""

    def __init__(self, exe, workdir, media, extra, trace_dir,
                 trace_danmaku=False):
        self.trace_dir = trace_dir
        os.makedirs(trace_dir, exist_ok=True)
        for stale in glob.glob(os.path.join(trace_dir, "panel_*.bmp")):
            os.remove(stale)
        argv = [
            exe,
            "--config=no", "--force-window=yes", "--keep-open=no",
            "--vo=gpu-next", "--gpu-api=d3d11", "--gpu-context=d3d11",
            "--osc=no", "--hwdec=no", "--terminal=yes",
            "--force-media-title=片头片尾验证",
        ] + extra + [media]
        environment = dict(os.environ)
        # 面板是 layered 窗口，内容只存在于它自己的 DIB 里（抓屏会被别的窗口
        # 挡住、PrintWindow 也拿不到），所以让播放器把同一块位图导出成 BMP。
        environment["MOVA_TRACE_PANEL"] = trace_dir
        if trace_danmaku:
            # 弹幕层同样是 layered 窗口。打开这个开关后播放器每秒回报一次
            # 「屏上几条 / 画了几条 / 弹幕层尺寸 / 播放位置」，用来判断改完
            # 设置之后到底是数据侧不再激活，还是窗口侧没渲染。
            environment["MOVA_TRACE_DANMAKU"] = "1"
        self.process = subprocess.Popen(
            argv, cwd=workdir, env=environment, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=1,
            text=True, encoding="utf-8", errors="replace")
        self.lines = []
        self.reader = threading.Thread(target=self._pump, daemon=True)
        self.reader.start()
        self.argv = argv

    def _pump(self):
        for line in self.process.stdout:
            self.lines.append(line.rstrip("\r\n"))

    def send(self, line):
        self.process.stdin.write(line + "\n")
        self.process.stdin.flush()

    def positions(self):
        """All time-pos values reported so far (MOVA_POSITION=<pos>|<dur>|…)."""
        found = []
        for line in list(self.lines):
            match = re.search(r"MOVA_POSITION=([0-9.]+)\|", line)
            if match:
                found.append(float(match.group(1)))
        return found

    def draws(self):
        """MOVA_DANMAKU_DRAW=live=N drawn=M size=WxH pos=P [draw=.. post=..
        gap=.. frames=.. [overlap=.. [mixed=..] lanes=.. dropped=.. drop=..
        [depth=.. olane=.. orect=a0,a1,b0,b1 [avg=.. late20=.. late33=..]]]]|
        samples."""
        found = []
        for line in list(self.lines):
            match = re.search(
                r"MOVA_DANMAKU_DRAW=live=(\d+) drawn=(\d+) size=(\d+)x(\d+)"
                r" pos=([0-9.]+)(?: draw=([0-9.]+) post=([0-9.]+)"
                r" gap=([0-9.]+) frames=(\d+))?"
                r"(?: overlap=(\d+)(?: mixed=(\d+))? lanes=(\d+)"
                r" dropped=(\d+) drop=(\d+)"
                r"(?: depth=([0-9.]+) olane=(-?\d+) orect=([0-9.,-]+)"
                r"(?: avg=([0-9.]+) late20=(\d+) late33=(\d+))?)?)?\|",
                line)
            if match:
                found.append({
                    "live": int(match.group(1)),
                    "drawn": int(match.group(2)),
                    "width": int(match.group(3)),
                    "height": int(match.group(4)),
                    "pos": float(match.group(5)),
                    "draw": float(match.group(6) or 0),
                    "post": float(match.group(7) or 0),
                    "gap": float(match.group(8) or 0),
                    "frames": int(match.group(9) or 0),
                    "overlap": int(match.group(10) or 0),
                    "mixed": int(match.group(11) or 0),
                    "lanes": int(match.group(12) or 0),
                    "dropped": int(match.group(13) or 0),
                    "drop": int(match.group(14) or 0),
                    "depth": float(match.group(15) or 0),
                    "olane": int(match.group(16) or -1),
                    "orect": match.group(17) or "",
                    "avg": float(match.group(18) or 0),
                    "late20": int(match.group(19) or 0),
                    "late33": int(match.group(20) or 0),
                })
        return found

    def draws_since(self, mark):
        """Drawn samples recorded after ``mark`` (an index into draws())."""
        return self.draws()[mark:]

    def settings(self):
        return [line for line in list(self.lines) if "MOVA_SETTING=" in line]

    def wait_position(self, predicate, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            for value in self.positions():
                if predicate(value):
                    return value
            time.sleep(0.1)
        return None

    def close(self):
        try:
            win = user32.FindWindowW("MovaNativePlayerWindow", None)
            if win:
                user32.PostMessageW(win, WM_CLOSE, 0, 0)
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
        finally:
            try:
                self.process.stdin.close()
            except Exception:
                pass
        return self.process.returncode


def read_bmp(path):
    """Read the 32bpp top-down BMP that PanelSurface::SaveBmp writes."""
    with open(path, "rb") as handle:
        data = handle.read()
    offset = struct.unpack_from("<I", data, 10)[0]
    width = struct.unpack_from("<i", data, 18)[0]
    height = abs(struct.unpack_from("<i", data, 22)[0])
    depth = struct.unpack_from("<H", data, 28)[0]
    if depth != 32:
        raise ValueError(f"unexpected BMP depth {depth}")
    return width, height, data[offset:offset + width * height * 4]


def shot_panel(out_dir, name, trace_dir):
    """Export the newest panel bitmap the player rendered."""
    deadline = time.time() + 4.0
    files = []
    while time.time() < deadline:
        files = sorted(glob.glob(os.path.join(trace_dir, "panel_*.bmp")))
        if files:
            break
        time.sleep(0.1)
    files = sorted(glob.glob(os.path.join(trace_dir, "panel_*.bmp")))
    if not files:
        return f"{name}: NO PANEL BITMAP (MOVA_TRACE_PANEL not honoured?)"
    width, height, buffer = read_bmp(files[-1])
    base.write_png(os.path.join(out_dir, f"{name}.png"), width, height, buffer)
    return f"{name}.png {width}x{height} (from {os.path.basename(files[-1])})"


def shot_screen(out_dir, name, main_hwnd):
    """Grab the player window as the user sees it.

    The danmaku layer is a layered child of the player window, so a screen grab
    is the only way to prove the comments are actually visible (its pixels also
    live in a DIB, but exported panel bitmaps would not show occlusion).
    """
    user32.SetWindowPos(main_hwnd, 0, 0, 0, 0, 0,
                        0x0001 | 0x0002 | 0x0010)  # TOP, no size/move/activate
    user32.SetForegroundWindow(main_hwnd)
    time.sleep(0.4)
    rect, _ = base.geometry(main_hwnd)
    width, height, buffer = base.grab_screen(rect)
    base.write_png(os.path.join(out_dir, f"{name}.png"), width, height, buffer)
    return f"{name}.png {width}x{height}"


SEGMENT_FEED = [
    "MOVA_SEGMENT_STATUS=loading",
    "MOVA_SEGMENT=intro|30|41|IntroDB",
    "MOVA_SEGMENT=credits|90|110|TheIntroDB",
    "MOVA_SEGMENTS_DONE=2",
]


def case_segment_panel(exe, workdir, media, out_dir):
    """Panel content + manual jump from a segment row."""
    out = ["=== 01_segment_panel ==="]
    trace_dir = os.path.join(out_dir, "trace_segments")
    player = Player(exe, workdir, media, [
        "--pause=yes", "--mova-tool-order=片头片尾",
        "--mova-auto-skip-segments=yes", "--mova-skip-delay-seconds=5",
    ], trace_dir)
    ok = True
    try:
        controls = base.wait_class("MovaNativePlayerControls")
        main_hwnd = base.wait_class("MovaNativePlayerWindow")
        if not controls or not main_hwnd:
            return "\n".join(out + ["    FAILED: player windows not found"]), False
        time.sleep(1.2)
        for line in SEGMENT_FEED:
            player.send(line)
        time.sleep(0.6)

        centres, scale, layout = tool_slot(controls, main_hwnd, 1)
        out.append("    " + layout)
        base.click_design(controls, centres[0], 72, "片头片尾 tool", scale)
        panel = base.wait_class("MovaNativePlayerPanel", timeout=3.0, visible=True)
        if not panel:
            return "\n".join(out + ["    FAILED: segment panel did not open"]), False
        out.append("    panel visible")
        out.append("    " + shot_panel(out_dir, "01_segment_panel", trace_dir))

        # Row layout: header, option(自动跳过), option(片头), option(片尾).
        base.click_design(panel, 170, panel_row_y(["header", "option", "option"]),
                          "片头 row", scale)
        time.sleep(0.8)
        jumped = player.wait_position(lambda value: value >= 40.5, 6.0)
        out.append(f"    click「片头」行 -> time-pos >= 40.5 ? {jumped}")
        if jumped is None:
            ok = False
            out.append("    VERDICT BAD clicking the intro row did not seek")
        else:
            out.append("    VERDICT OK  clicking the intro row jumps to its end")
        out.append(f"    positions seen: {player.positions()[-6:]}")

        # 再打开一次：处理过的段落应当置灰（enabled=false），这就是「跳过过了」
        # 的可见凭据。
        base.click_design(controls, centres[0], 72, "片头片尾 tool", scale)
        base.wait_class("MovaNativePlayerPanel", timeout=3.0, visible=True)
        time.sleep(0.4)
        out.append("    " + shot_panel(out_dir, "01b_after_click", trace_dir))
    finally:
        code = player.close()
        out.append(f"    exit code = {code}")
        if code != 0:
            ok = False
    return "\n".join(out), ok


def case_danmaku_panel(exe, workdir, media, out_dir):
    """Danmaku display settings live in the control panel and write back."""
    out = ["=== 02_danmaku_panel ==="]
    trace_dir = os.path.join(out_dir, "trace_danmaku")
    player = Player(exe, workdir, media, [
        "--pause=yes", "--mova-tool-order=弹幕",
        "--mova-danmaku-enabled=yes", "--mova-danmaku-area=0.65",
        "--mova-danmaku-density=0.55",
    ], trace_dir)
    # 面板里没配置 API 时应用侧会推 error 状态；这里直接给一个「获取失败」面板。
    player.send("MOVA_DANMAKU_STATUS=error:未配置弹幕 API")
    ok = True
    try:
        controls = base.wait_class("MovaNativePlayerControls")
        main_hwnd = base.wait_class("MovaNativePlayerWindow")
        if not controls or not main_hwnd:
            return "\n".join(out + ["    FAILED: player windows not found"]), False
        time.sleep(1.2)
        centres, scale, layout = tool_slot(controls, main_hwnd, 1)
        out.append("    " + layout)
        base.click_design(controls, centres[0], 72, "弹幕 tool", scale)
        panel = base.wait_class("MovaNativePlayerPanel", timeout=3.0, visible=True)
        if not panel:
            return "\n".join(out + ["    FAILED: danmaku panel did not open"]), False
        out.append("    panel visible")
        out.append("    " + shot_panel(out_dir, "02_danmaku_panel", trace_dir))

        # Rows: header(弹幕), note(获取失败), note(检查 API), header(显示设置),
        #       option(显示区域), …
        base.click_design(
            panel, 170,
            panel_row_y(["header", "note", "note", "header", "option"]),
            "显示区域 row", scale)
        time.sleep(0.6)
        written = player.settings()
        out.append(f"    MOVA_SETTING lines = {written}")
        out.append("    " + shot_panel(out_dir, "02b_after_change", trace_dir))
        if any("yingji.danmaku.area|0.75" in line for line in written):
            out.append("    VERDICT OK  显示区域 前进一档并回写应用偏好")
        else:
            ok = False
            out.append("    VERDICT BAD 未收到预期回写（期望 yingji.danmaku.area|0.75）")

        # 面板应该原地刷新、仍然可见（改设置不该把面板关掉）。
        if user32.IsWindowVisible(panel):
            out.append("    VERDICT OK  panel stays open after a setting change")
        else:
            ok = False
            out.append("    VERDICT BAD  panel closed after a setting change")

        # 再点一次「不透明度」：证明可以连续调。
        base.click_design(
            panel, 170,
            panel_row_y(["header", "note", "note", "header", "option",
                         "option"]),
            "不透明度 row", scale)
        time.sleep(0.5)
        out.append(f"    MOVA_SETTING lines = {player.settings()}")

        # 面板比一屏高，滚到下半部分确认三个开关行也渲染正常。
        for _ in range(4):
            user32.PostMessageW(panel, 0x020A, 0xFF88 << 16, 0)
            time.sleep(0.2)
        time.sleep(0.4)
        out.append("    " + shot_panel(out_dir, "02c_scrolled", trace_dir))
    finally:
        code = player.close()
        out.append(f"    exit code = {code}")
        if code != 0:
            ok = False
    return "\n".join(out), ok


def case_auto_skip(exe, workdir, media, out_dir):
    """Entering the intro range skips it automatically after the delay."""
    out = ["=== 03_auto_skip ==="]
    trace_dir = os.path.join(out_dir, "trace_skip")
    player = Player(exe, workdir, media, [
        "--start=38", "--mova-auto-skip-segments=yes",
        "--mova-skip-delay-seconds=2", "--mova-tool-order=片头片尾",
    ], trace_dir)
    ok = True
    try:
        if not base.wait_class("MovaNativePlayerWindow"):
            return "\n".join(out + ["    FAILED: player window not found"]), False
        # Intro range 30-41s with position starting at 38s: playing for the
        # delay plus a moment must land past 41s.
        player.send("MOVA_SEGMENT_STATUS=loading")
        player.send("MOVA_SEGMENT=intro|30|41|IntroDB")
        player.send("MOVA_SEGMENTS_DONE=1")
        jumped = player.wait_position(lambda value: value >= 40.5, 20.0)
        out.append(f"    auto skip reached time-pos >= 40.5 ? {jumped}")
        out.append(f"    positions seen: {player.positions()[-8:]}")
        if jumped is None:
            ok = False
            out.append("    VERDICT BAD auto skip did not fire")
        else:
            out.append("    VERDICT OK  intro was skipped automatically")
    finally:
        code = player.close()
        out.append(f"    exit code = {code}")
        if code != 0:
            ok = False
    return "\n".join(out), ok


def danmaku_file(out_dir, seconds=120.0):
    """One scrolling comment per second — dense enough that the layer is never
    empty while playing, and only mode 1 so the 滚动弹幕 switch isolates it."""
    path = os.path.join(out_dir, "danmaku_scroll.txt")
    with open(path, "w", encoding="utf-8") as handle:
        index = 0
        moment = 0.0
        while moment < seconds:
            text = base64.b64encode(
                f"测试弹幕 {index}".encode("utf-8")).decode("ascii")
            handle.write(f"{moment:.1f}\t1\t-1\t{text}\n")
            index += 1
            moment += 1.0
    return path


PANEL_NOTE_H = 34
PANEL_MAX_CONTENT_H = 470


def panel_rows_y(rows, at_bottom=False):
    """Design-space y of every row's centre, optionally scrolled to the end.

    Mirrors LayoutPanelRows() + PanelMaxScroll(): the panel content is clamped
    to PANEL_MAX_CONTENT_H and scrolled by the overflow, exactly like the
    player does, so a row can be located without hard-coding pixel offsets.
    """
    heights = {"header": base.PANEL_HEADER_H, "note": PANEL_NOTE_H,
               "option": base.PANEL_OPTION_H}
    content = (base.PANEL_PADDING * 2 + sum(heights[row] for row in rows) +
               base.PANEL_ROW_GAP * (len(rows) - 1))
    viewport = min(PANEL_MAX_CONTENT_H, content) - base.PANEL_PADDING * 2
    scroll = max(0, content - viewport) if at_bottom else 0
    result = []
    y = base.PANEL_PADDING
    for row in rows:
        result.append(base.PANEL_SHADOW + base.PANEL_PADDING +
                      (y - scroll) + heights[row] / 2)
        y += heights[row] + base.PANEL_ROW_GAP
    return result


# 弹幕面板「有数据」状态下的行序：标题 + 已加载 + 显示区域说明 + 显示设置标题，
# 后面八行是可调项（显示区域 … 底部弹幕）。
DANMAKU_ROWS = (["header", "note", "note", "header"] + ["option"] * 8)
DANMAKU_SCROLL_ROW = DANMAKU_ROWS.index("option") + 5  # 滚动弹幕
DANMAKU_AREA_ROW = DANMAKU_ROWS.index("option")       # 显示区域
DANMAKU_FONT_ROW = DANMAKU_ROWS.index("option") + 2   # 字号


def scroll_panel_to_bottom(panel, times=6):
    for _ in range(times):
        user32.PostMessageW(panel, 0x020A, 0xFF88 << 16, 0)
        time.sleep(0.2)
    time.sleep(0.3)


def case_interrupt_retry(exe, workdir, media, out_dir):
    """跳转之后的源站抖动要被一次重试吃掉，而不是判成「播放失败」。

    用户报「自动跳过会存在播放失败的情况」。自动跳片头/片尾会让播放器去要一段
    **新的字节区间**（新建连接），撞上源站抖动的概率比顺放时高得多：mpv 拿到
    错误码之后把这一集报成结束，位置校验发现「离片尾还远」，于是播放器举手投降
    —— 底栏就是那行「播放失败 · 请更换资源」。

    这里用一个假源站把那次抖动造出来（第一次起点不为 0 的 Range 请求回 500，
    也就是自动跳过触发的那次跳转），然后断言播放器自己补了一次、并且接着往下播。
    """
    out = ["=== 08_interrupt_retry ==="]
    import probe_interrupt_retry  # 同目录：假源站在那边（诊断脚本共用一份）

    trace_dir = os.path.join(out_dir, "trace_retry")
    origin = probe_interrupt_retry.FakeOrigin(fault_start=400_000)
    player = Player(exe, workdir, origin.url, [
        "--mova-auto-skip-segments=yes", "--mova-skip-delay-seconds=1",
        "--mova-playlist-title=第1集", "--start=12",
        # 逼着 mpv 每次跳转都重新发请求：整份文件若被读进 demuxer 缓存，
        # 注入的故障就永远触发不到（顺放也不需要网络，就是靠这份缓存）。
        "--cache=no", "--demuxer-readahead-secs=1", "--demuxer-max-bytes=2MiB",
    ], trace_dir)
    ok = True
    try:
        time.sleep(1.5)
        player.send("MOVA_SEGMENT=intro|10|40|测试")
        player.send("MOVA_SEGMENTS_DONE=1")
        time.sleep(14.0)
        out.append(f"    injected a 500 on the first non-zero range request: "
                   f"{origin.faulted} (requests={origin.requests[:6]})")
        retried = [line for line in player.lines if "MOVA_RETRY=" in line]
        for line in retried:
            out.append(f"    {line}")
        ends = [line for line in player.lines if line.startswith("MOVA_ENDFILE=")]
        for line in ends:
            out.append(f"    {line}")
        positions = player.positions()
        tail = [round(value, 2) for value in positions[-5:]]
        out.append(f"    position tail: {tail}")
        if not origin.faulted:
            ok = False
            out.append("    VERDICT BAD 故障没注入：播放器没有为跳转重新发请求")
        elif not retried:
            ok = False
            out.append("    VERDICT BAD 抖动之后没有重试 -> 用户看到「播放失败」")
        elif not positions or positions[-1] <= 42.0:
            ok = False
            out.append("    VERDICT BAD 重试了但播放没有继续（位置没有越过片头结束点）")
        else:
            out.append("    VERDICT OK  抖动被一次重试吃掉，播放从片头结束点继续")
        # 截图留一份人眼证据：这时的底栏不该出现「播放失败 · 请更换资源」。
        main_hwnd = base.wait_class("MovaNativePlayerWindow")
        if main_hwnd:
            out.append("    " + shot_screen(out_dir, "08_after_retry", main_hwnd))
    finally:
        code = player.close()
        out.append(f"    exit code = {code}")
        origin.close()
        if code != 0:
            ok = False
    return "\n".join(out), ok


def case_danmaku_settings_playing(exe, workdir, media, out_dir):
    """Changing danmaku settings mid-playback must not stop the danmaku.

    This is the regression for "改完弹幕设置弹幕就没了": the switch rows used to
    mark *every* comment in the episode as played, so turning 滚动弹幕 off and
    back on killed the rest of the episode. The draw trace tells us whether the
    overlay still has anything on screen (drawn > 0) after each change.
    """
    out = ["=== 04_danmaku_settings_playing ==="]
    trace_dir = os.path.join(out_dir, "trace_danmaku_play")
    comments = danmaku_file(out_dir)
    player = Player(exe, workdir, media, [
        "--mova-tool-order=弹幕", "--mova-danmaku-enabled=yes",
        "--mova-danmaku-area=0.65", "--mova-danmaku-density=0.55",
    ], trace_dir, trace_danmaku=True)
    ok = True
    try:
        controls = base.wait_class("MovaNativePlayerControls")
        main_hwnd = base.wait_class("MovaNativePlayerWindow")
        if not controls or not main_hwnd:
            return "\n".join(out + ["    FAILED: player windows not found"]), False
        time.sleep(1.0)
        total = sum(1 for _ in open(comments, encoding="utf-8"))
        player.send("MOVA_DANMAKU_STATUS=loading")
        player.send(f"MOVA_DANMAKU_INFO={total}\t\t")
        player.send(f"MOVA_DANMAKU={comments}")
        time.sleep(3.0)

        def drawn_after(mark, label):
            samples = player.draws_since(mark)
            peak = max((item["drawn"] for item in samples), default=-1)
            live = max((item["live"] for item in samples), default=-1)
            tail = samples[-3:]
            out.append(f"    {label}: {len(samples)} samples peak drawn={peak}"
                       f" live={live} tail={[i['drawn'] for i in tail]}")
            return peak, len(samples)

        peak, _ = drawn_after(0, "baseline (playing, no settings touched)")
        out.append("    " + shot_screen(out_dir, "04a_baseline", main_hwnd))
        if peak <= 0:
            ok = False
            out.append("    VERDICT BAD baseline has no danmaku on screen")

        centres, scale, layout = tool_slot(controls, main_hwnd, 1)
        out.append("    " + layout)
        base.click_design(controls, centres[0], 72, "弹幕 tool", scale)
        panel = base.wait_class("MovaNativePlayerPanel", timeout=3.0, visible=True)
        if not panel:
            return "\n".join(out + ["    FAILED: danmaku panel did not open"]), False

        # 1) A value row (显示区域): the overlay must keep rendering.
        mark = len(player.draws())
        base.click_design(panel, 170,
                          panel_rows_y(DANMAKU_ROWS)[DANMAKU_AREA_ROW],
                          "显示区域 row", scale)
        time.sleep(3.0)
        peak, _ = drawn_after(mark, "after 显示区域 change")
        if peak <= 0:
            ok = False
            out.append("    VERDICT BAD danmaku stopped after a value change")
        else:
            out.append("    VERDICT OK  danmaku keeps rendering after 显示区域")

        # 2) A font-size change: this rebuilds the cached font and re-measures
        #    every comment, a different code path from the area switch.
        mark = len(player.draws())
        base.click_design(panel, 170,
                          panel_rows_y(DANMAKU_ROWS)[DANMAKU_FONT_ROW],
                          "字号 row", scale)
        time.sleep(3.0)
        peak, _ = drawn_after(mark, "after 字号 change")
        if peak <= 0:
            ok = False
            out.append("    VERDICT BAD danmaku stopped after a font change")
        else:
            out.append("    VERDICT OK  danmaku keeps rendering after 字号")

        # 3) Turn 滚动弹幕 off: the overlay should empty out.
        scroll_panel_to_bottom(panel)
        y = panel_rows_y(DANMAKU_ROWS, at_bottom=True)[DANMAKU_SCROLL_ROW]
        mark = len(player.draws())
        base.click_design(panel, 170, y, "滚动弹幕 off", scale)
        time.sleep(2.5)
        peak_off, _ = drawn_after(mark, "after 滚动弹幕 off")
        out.append("    " + shot_screen(out_dir, "04b_scroll_off", main_hwnd))

        # 4) Turn it back on: comments that have not reached their time yet must
        #    still show up. Before the fix everything was already marked played,
        #    so the rest of the episode stayed empty.
        scroll_panel_to_bottom(panel)
        mark = len(player.draws())
        base.click_design(panel, 170, y, "滚动弹幕 on", scale)
        time.sleep(5.0)
        peak_on, _ = drawn_after(mark, "after 滚动弹幕 on again")
        out.append("    " + shot_screen(out_dir, "04c_scroll_on", main_hwnd))
        if peak_on <= 0:
            ok = False
            out.append("    VERDICT BAD danmaku never came back after re-enabling"
                       " 滚动弹幕 (episode-wide played标记)")
        else:
            out.append("    VERDICT OK  danmaku resumed after re-enabling 滚动弹幕")
        out.append(f"    switches written: {player.settings()[-4:]}")
    finally:
        code = player.close()
        out.append(f"    exit code = {code}")
        if code != 0:
            ok = False
    return "\n".join(out), ok


def case_live_settings(exe, workdir, media, out_dir):
    """Settings changed in the app while playing must reach the running player.

    05_live_settings  The app pushes every changed option over stdin
    (``MOVA_APPLY=<name>|<value>``), the player applies it in place and echoes
    ``MOVA_LIVE=`` back; danmaku values are written to the app prefs as usual.
    These values used to be handed over only once, on the command line at
    start-up, so editing the settings page during playback did nothing until
    the video was restarted -- the settings page and the player then showed
    different values.
    """
    out = ["=== 05_live_settings ==="]
    trace_dir = os.path.join(out_dir, "trace_live")
    comments = danmaku_file(out_dir)
    player = Player(exe, workdir, media, [
        "--pause=yes", "--mova-danmaku-enabled=yes",
        "--mova-danmaku-area=0.65", "--mova-tool-order=弹幕",
    ], trace_dir)
    ok = True
    try:
        main_hwnd = base.wait_class("MovaNativePlayerWindow")
        if not main_hwnd:
            return "\n".join(out + ["    FAILED: player window not found"]), False
        time.sleep(1.0)
        player.send(f"MOVA_DANMAKU={comments}")
        time.sleep(2.0)

        overlay = user32.FindWindowW("MovaNativePlayerDanmaku", None)
        visible = bool(overlay) and bool(user32.IsWindowVisible(overlay))
        out.append(f"    danmaku overlay hwnd={overlay} visible={visible}")
        if not visible:
            ok = False
            out.append("    VERDICT BAD overlay missing before the changes")

        def applied(name):
            prefix = f"MOVA_LIVE={name}|"
            return any(prefix in line for line in list(player.lines))

        def written(key, value):
            wanted = f"MOVA_SETTING={key}|{value}"
            return any(wanted in line for line in list(player.lines))

        # Each row: option name, value pushed from the settings page, and the
        # pref key/value the player must write back (None = no write-back).
        checks = [
            ("mova-danmaku-area", "0.85", "yingji.danmaku.area", "0.85"),
            ("mova-danmaku-font-size", "22", "yingji.danmaku.font-size", "22"),
            ("mova-danmaku-scroll", "no", "yingji.danmaku.scroll", "false"),
            ("mova-danmaku-scroll", "yes", "yingji.danmaku.scroll", "true"),
            ("mova-auto-skip-segments", "no", None, None),
            ("mova-skip-delay-seconds", "8", None, None),
            ("mova-seek-seconds", "30", None, None),
            ("mova-volume-step", "2", None, None),
        ]
        for name, value, key, echoed in checks:
            player.send(f"MOVA_APPLY={name}|{value}")
            time.sleep(0.5)
            landed = applied(name)
            out.append(f"    apply {name}={value} -> applied={landed}")
            if not landed:
                ok = False
                out.append(f"    VERDICT BAD {name} was not applied")
            elif key and not written(key, echoed):
                ok = False
                out.append(f"    VERDICT BAD no write-back {key}={echoed}")
            elif key:
                out.append(f"      write-back ok: {key}={echoed}")

        # Only the danmaku / segment options may travel this way: the channel
        # must not become a way to poke arbitrary player options.
        player.send("MOVA_APPLY=mova-keep-open|yes")
        player.send("MOVA_APPLY=mova-tool-order|声音")
        time.sleep(0.5)
        if applied("mova-keep-open") or applied("mova-tool-order"):
            ok = False
            out.append("    VERDICT BAD a non-settings option slipped through")
        else:
            out.append("    VERDICT OK  only danmaku / segment options accepted")

        # The danmaku master switch has to take effect right away: off hides
        # the overlay, on brings it back (the app side re-pushes the data).
        player.send("MOVA_APPLY=mova-danmaku-enabled|no")
        time.sleep(1.0)
        hidden = not bool(user32.IsWindowVisible(overlay))
        player.send("MOVA_APPLY=mova-danmaku-enabled|yes")
        time.sleep(1.5)
        restored = bool(user32.IsWindowVisible(overlay))
        out.append(f"    master switch: hidden after no={hidden},"
                   f" visible after yes={restored}")
        if not hidden or not restored:
            ok = False
            out.append("    VERDICT BAD the master switch did not hide / restore"
                       " the overlay")
        else:
            out.append("    VERDICT OK  master switch hides and restores on the spot")
        out.append("    " + shot_screen(out_dir, "05_live_settings", main_hwnd))
    finally:
        code = player.close()
        out.append(f"    exit code = {code}")
        if code != 0:
            ok = False
    return "\n".join(out), ok


def dense_danmaku_file(out_dir, seconds=20.0, per_second=18, seed_text="弹"):
    """A comment burst — the shape of an OP: tens of comments per second.

    Smoothness problems only show up under load, so the pacing case needs a much
    denser feed than the one-comment-per-second file the panel cases use.
    """
    path = os.path.join(out_dir, f"danmaku_dense_{per_second}.txt")
    index = 0
    with open(path, "w", encoding="utf-8") as handle:
        moment = 0.0
        while moment < seconds:
            for _ in range(per_second):
                text = base64.b64encode(
                    f"密集弹幕第{index}条带一点长度".encode("utf-8")).decode("ascii")
                handle.write(f"{moment:.2f}\t1\t-1\t{text}\n")
                index += 1
            moment += 1.0
    return path


def case_danmaku_frame_pacing(exe, workdir, media, out_dir):
    """每帧的绘制耗时与帧间隔必须留在 60fps 的预算里。

    「一顿一顿」是绘制超预算（一帧画了 20ms 以上，掉帧）或定时器被堵住
    （gap 远大于 16.7ms）的表现，所以这个用例直接断言这两个数字，而不是靠
    肉眼看截图。旧实现每帧对每条弹幕做两次 GDI+ DrawString，同屏几十条就会
    超预算；现在把文字栅格化一次缓存成位图，每帧只做 AlphaBlend。
    """
    out = ["=== 06_danmaku_frame_pacing ==="]
    trace_dir = os.path.join(out_dir, "trace_danmaku_pacing")
    comments = dense_danmaku_file(out_dir)
    player = Player(exe, workdir, media, [
        "--mova-tool-order=弹幕", "--mova-danmaku-enabled=yes",
        "--mova-danmaku-area=0.65", "--mova-danmaku-density=0.85",
    ], trace_dir, trace_danmaku=True)
    ok = True
    try:
        if not base.wait_class("MovaNativePlayerWindow"):
            return "\n".join(out + ["    FAILED: player window not found"]), False
        time.sleep(1.0)
        total = sum(1 for _ in open(comments, encoding="utf-8"))
        player.send("MOVA_DANMAKU_STATUS=loading")
        player.send(f"MOVA_DANMAKU_INFO={total}\t\t")
        player.send(f"MOVA_DANMAKU={comments}")
        # 第一秒是加载 + 起播，单独看一段；之后才是稳定播放的稳态。
        time.sleep(1.5)
        first = player.draws()
        time.sleep(8.0)
        samples = player.draws()[len(first):]
        out.append(f"    comments={total} samples={len(samples)}")
        for item in samples:
            out.append(f"      live={item['live']:3d} drawn={item['drawn']:3d}"
                       f" overlap={item['overlap']:3d}"
                       f" depth={item['depth']:5.1f}"
                       f" draw={item['draw']:6.2f}ms post={item['post']:5.2f}ms"
                       f" avg={item['avg']:5.2f}ms gap={item['gap']:6.1f}ms"
                       f" late20={item['late20']:2d} frames={item['frames']}")
        if not samples:
            return "\n".join(out + ["    FAILED: no draw trace samples"]), False
        peak_draw = max(item["draw"] for item in samples)
        peak_post = max(item["post"] for item in samples)
        peak_gap = max(item["gap"] for item in samples)
        peak_avg = max(item["avg"] for item in samples)
        peak_late20 = max(item["late20"] for item in samples)
        peak_late33 = max(item["late33"] for item in samples)
        peak_live = max(item["live"] for item in samples)
        peak_drawn = max(item["drawn"] for item in samples)
        peak_overlap = max(item["overlap"] for item in samples)
        peak_depth = max(item["depth"] for item in samples)
        worst = max(samples, key=lambda i: i["depth"])
        out.append(f"    peak live={peak_live} drawn={peak_drawn}"
                   f" overlap={peak_overlap} depth={peak_depth:.1f}"
                   f" draw={peak_draw:.2f}ms post={peak_post:.2f}ms"
                   f" avg={peak_avg:.2f}ms gap={peak_gap:.1f}ms"
                   f" late20={peak_late20} late33={peak_late33}")
        # 「看不清」和「一顿一顿」是两类缺陷，分别断言：
        #   depth —— 同轨两条弹幕互相压进去多少像素。只数条数会把「正好贴边」
        #     也算上（浮点误差），所以按深度判：>2px 才是真的糊在一起。
        #   avg  —— 这一个诊断窗口的平均帧间隔。只看 gap 最大值分不清「偶尔抖
        #     一下」和「整段掉到 50fps」，均值贴 16.7ms 才算节拍正常。
        if peak_depth > 2.0:
            ok = False
            out.append(f"    VERDICT BAD danmaku overlap by up to"
                       f" {peak_depth:.1f}px in lane {worst['olane']}"
                       f" ({worst['orect']}) -- unreadable")
        elif peak_overlap:
            out.append(f"    VERDICT OK  {peak_overlap} pair(s) only touch"
                       f" within {peak_depth:.1f}px (boundary, not visible)")
        else:
            out.append("    VERDICT OK  every danmaku keeps its own lane span")
        # 两帧间隔的上限比平均帧率更能说明「一顿一顿」：帧率可以是 60fps，
        # 但每隔几帧卡一次同样看得见。反过来，孤立的单次停顿（后台编译、DWM
        # 合成）不该让用例失败 —— 判缺陷要判「反复超时」。
        if peak_drawn <= 0:
            ok = False
            out.append("    VERDICT BAD nothing was drawn at all")
        elif peak_avg > 18.0:
            ok = False
            out.append(f"    VERDICT BAD frame clock averages {peak_avg:.1f}ms"
                       f" ({1000.0 / peak_avg:.0f}fps) -- systematic stutter")
        elif peak_draw > 12.0:
            ok = False
            out.append(f"    VERDICT BAD drawing costs too much "
                       f"({peak_draw:.2f}ms of the 16.7ms budget)")
        elif peak_late33 >= 3:
            ok = False
            out.append(f"    VERDICT BAD {peak_late33} frames ran past 33ms"
                       " -- repeated stalls")
        elif peak_late20 > 6:
            ok = False
            out.append(f"    VERDICT BAD {peak_late20} of 60 frames ran past 20ms")
        elif peak_gap > 40.0:
            out.append(f"    VERDICT OK  clock steady at {peak_avg:.2f}ms;"
                       f" one isolated hitch of {peak_gap:.1f}ms")
        else:
            out.append("    VERDICT OK  frames stay inside the 60fps budget")
        ink, note = shot_danmaku(out_dir, "06_danmaku_layer", trace_dir)
        out.append("    " + note)
        if ink < 500:
            ok = False
            out.append(f"    VERDICT BAD the danmaku layer renders no text "
                       f"(ink={ink}px)")
        else:
            out.append("    VERDICT OK  the cached-bitmap path still draws text")
        out.append("    " + shot_screen(out_dir, "06_danmaku_pacing",
                                        base.wait_class("MovaNativePlayerWindow")))
    finally:
        code = player.close()
        out.append(f"    exit code = {code}")
        if code != 0:
            ok = False
    return "\n".join(out), ok


def case_player_preferences(exe, workdir, media, out_dir):
    """控件菜单里改的播放器偏好要回写应用偏好（下次起播才沿用）。

    以前倍速 / 亮度 / 画面比例 / 音量只在本次播放里生效，起播又回到设置页里的
    旧值。现在原生把这些改动回写成 yingji.player.* 交给应用侧，这里断言每一
    项都真的发出来了；音量是连续量，另外断言它按「手停下来再发」的节奏走。
    """
    out = ["=== 07_player_preferences ==="]
    trace_dir = os.path.join(out_dir, "trace_player_prefs")
    player = Player(exe, workdir, media, [
        "--pause=yes", "--mova-tool-order=倍速", "--mova-tool-order=画面",
    ], trace_dir)
    ok = True
    try:
        controls = base.wait_class("MovaNativePlayerControls")
        main_hwnd = base.wait_class("MovaNativePlayerWindow")
        if not controls or not main_hwnd:
            return "\n".join(out + ["    FAILED: player windows not found"]), False
        time.sleep(1.2)
        centres, scale, layout = tool_slot(controls, main_hwnd, 2)
        if len(centres) < 2:
            return "\n".join(out + ["    FAILED: two tool slots expected"]), False
        out.append("    " + layout)

        def click_row(panel, rows, label):
            # panel_rows_y() 给的是每一行中心的列表；这里点的是最后一行的中心。
            base.click_design(panel, 170, panel_rows_y(rows)[-1], label, scale)
            time.sleep(0.4)

        # 1) 倍速面板：1.5× 是第 5 个档位。
        base.click_design(controls, centres[0], 72, "倍速 tool", scale)
        panel = base.wait_class("MovaNativePlayerPanel", timeout=3.0, visible=True)
        if not panel:
            return "\n".join(out + ["    FAILED: speed panel did not open"]), False
        click_row(panel, ["header"] + ["option"] * 5, "1.5× row")
        written = player.settings()
        expected = "MOVA_SETTING=yingji.player.speed|1.5"
        out.append(f"    speed   -> {[line for line in written if 'speed' in line]}")
        if not any(expected in line for line in written):
            ok = False
            out.append(f"    VERDICT BAD expected {expected}")
        else:
            out.append("    VERDICT OK  倍速回写 yingji.player.speed")

        # 2) 画面面板：16:9（第 2 行）与亮度「更暗」（第 6 行）。
        base.click_design(controls, centres[1], 72, "画面 tool", scale)
        panel = base.wait_class("MovaNativePlayerPanel", timeout=3.0, visible=True)
        if not panel:
            return "\n".join(out + ["    FAILED: picture panel did not open"]), False
        click_row(panel, ["header", "option", "option"], "16:9 row")
        written = player.settings()
        out.append(f"    aspect  -> {[line for line in written if 'aspect' in line]}")
        if not any("yingji.player.aspect|16:9" in line for line in written):
            ok = False
            out.append("    VERDICT BAD expected yingji.player.aspect|16:9")
        else:
            out.append("    VERDICT OK  画面比例回写标签而不是比例数值")
        click_row(panel, ["header"] + ["option"] * 4 + ["header", "option"],
                  "更暗 row")
        written = player.settings()
        out.append(f"    bright  -> "
                   f"{[line for line in written if 'brightness' in line]}")
        if not any("yingji.player.brightness|-30" in line for line in written):
            ok = False
            out.append("    VERDICT BAD expected yingji.player.brightness|-30")
        else:
            out.append("    VERDICT OK  亮度回写 yingji.player.brightness")
        out.append("    " + shot_panel(out_dir, "07_picture_panel", trace_dir))

        # 3) 音量：拖一次音量条会连出几十个值，回写要等手停下来（400ms）。
        player.send("MOVA_APPLY=volume|40")
        time.sleep(0.3)
        early = [line for line in player.settings() if 'player.volume' in line]
        time.sleep(1.0)
        late = [line for line in player.settings() if 'player.volume' in line]
        out.append(f"    音量 0.3s 后={len(early)} 条，1.3s 后={len(late)} 条")
        if not any("yingji.player.volume|40" in line for line in late):
            ok = False
            out.append("    VERDICT BAD 音量没有回写（期望 yingji.player.volume|40）")
        else:
            out.append("    VERDICT OK  音量回写 yingji.player.volume（防抖后一次）")
    finally:
        code = player.close()
        out.append(f"    exit code = {code}")
        if code != 0:
            ok = False
    return "\n".join(out), ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", default=r"D:\Mova\MovaNativePlayer.exe")
    parser.add_argument("--workdir", default=r"D:\Mova")
    parser.add_argument("--only", default="",
                        help="comma-separated case name fragments to run")
    options = parser.parse_args()
    out_dir = os.path.join(os.environ["TEMP"], "mova_verify_segments")
    os.makedirs(out_dir, exist_ok=True)
    media = media_file(out_dir)

    cases = [case_segment_panel, case_danmaku_panel, case_auto_skip,
             case_interrupt_retry, case_danmaku_settings_playing,
             case_live_settings, case_danmaku_frame_pacing,
             case_player_preferences]
    if options.only:
        wanted = [part.strip() for part in options.only.split(",") if part.strip()]
        cases = [case for case in cases
                 if any(part in case.__name__ for part in wanted)]

    blocks = []
    results = []
    for case in cases:
        try:
            text, ok = case(options.exe, options.workdir, media, out_dir)
        except Exception:  # noqa: BLE001
            # 用例里抛异常（通常是 harness 自己的坐标/断言写错）不该把整轮结果
            # 一起带走：落成一条 BAD，继续跑后面的用例。
            text = (f"=== {case.__name__} ===\n"
                    + traceback.format_exc())
            ok = False
        blocks.append(text)
        results.append((case.__name__, ok))
        # 边跑边打印：套件中途被打断时，前面用例的结论仍然留在输出里。
        print(text, flush=True)

    summary = ["", "=== summary ==="]
    summary += [f"    {'OK ' if ok else 'BAD'} {name}" for name, ok in results]
    print("\n".join(summary), flush=True)
    report = "\n".join(blocks + summary)
    with open(os.path.join(out_dir, "report.txt"), "w", encoding="utf-8") as fh:
        fh.write(report)
    print(f"    report: {os.path.join(out_dir, 'report.txt')}")
    return 0 if all(ok for _, ok in results) else 1


if __name__ == "__main__":
    sys.exit(main())
