#!/usr/bin/env python3
"""汇总 `MOVA_TRACE_FRAMES` 诊断文件，判定滚动卡顿落在哪一侧。

用法：

    python tool/analyze_frame_trace.py <trace.log> [--expect-fps 165]

日志由 `lib/src/diagnostics/frame_trace.dart` 写出（需先设 `MOVA_TRACE_FRAMES`
环境变量）。本脚本只读文件，不会启动应用。

判定原则（面板 170Hz 时 budget≈5.88ms）：

- `fps` 远低于刷新率 → 面板帧槽没用满（每帧都在做事却没做出帧）；
- `build_*` 超预算 → UI 线程（build/layout/paint 录制）是瓶颈；
- `raster_*` 超预算 → 光栅线程（模糊、投影、大图解码上传、离屏图层）是瓶颈；
- `span_*` 是两者之和加 vsync 等待，用来对齐「用户实际感受到的卡」。
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field

FRAMES_RE = re.compile(
    r"FRAMES window=(?P<window>\d+) wall=(?P<wall>\d+) n=(?P<n>\d+) "
    r"fps=(?P<fps>[0-9.]+) budget=(?P<budget>[0-9.]+) "
    r"build_avg=(?P<build_avg>[0-9.]+) build_p50=(?P<build_p50>[0-9.]+) "
    r"build_p95=(?P<build_p95>[0-9.]+) build_max=(?P<build_max>[0-9.]+) "
    r"raster_avg=(?P<raster_avg>[0-9.]+) raster_p50=(?P<raster_p50>[0-9.]+) "
    r"raster_p95=(?P<raster_p95>[0-9.]+) raster_max=(?P<raster_max>[0-9.]+) "
    r"span_p95=(?P<span_p95>[0-9.]+) span_max=(?P<span_max>[0-9.]+) "
    r"slow_build=(?P<slow_build>\d+) slow_raster=(?P<slow_raster>\d+) "
    r"depth=(?P<depth>[0-9.]+)"
    r"(?: pos=(?P<pos>[0-9.]+) max=(?P<max>[0-9.]+))?"
)

START_RE = re.compile(
    r"FRAMETRACE start view=(?P<view>\S+) dpr=(?P<dpr>[0-9.]+) "
    r"refresh=(?P<refresh>\S+) blur=(?P<blur>\S+)"
)

DRIVE_RE = re.compile(
    r"SCROLLDRIVE state=(?P<state>\w+)(?P<rest>.*)"
)


@dataclass
class Window:
    window: int
    wall: int
    n: int
    fps: float
    budget: float
    build_avg: float
    build_p95: float
    build_max: float
    raster_avg: float
    raster_p95: float
    raster_max: float
    span_p95: float
    span_max: float
    slow_build: int
    slow_raster: int
    depth: float
    pos: float | None = None
    max: float | None = None

    @property
    def slow_total(self) -> int:
        """同时超预算的帧数取大者：任一阶段超预算这一帧就会迟到。"""
        return max(self.slow_build, self.slow_raster)

    @property
    def slow_share(self) -> float:
        return self.slow_total / self.n if self.n else 0.0

    @property
    def budget_use(self) -> float:
        """帧槽使用率：实际出帧 fps / 面板刷新率。"""
        return self.fps * self.budget / 1000 if self.budget else 0.0


@dataclass
class Trace:
    header: dict[str, str] = field(default_factory=dict)
    windows: list[Window] = field(default_factory=list)
    drive: list[str] = field(default_factory=list)


def parse(path: str) -> Trace:
    trace = Trace()
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            match = START_RE.search(line)
            if match:
                trace.header = match.groupdict()
                continue
            match = DRIVE_RE.search(line)
            if match:
                trace.drive.append(line)
                continue
            match = FRAMES_RE.search(line)
            if match:
                values = match.groupdict()
                trace.windows.append(
                    Window(
                        window=int(values["window"]),
                        wall=int(values["wall"]),
                        n=int(values["n"]),
                        fps=float(values["fps"]),
                        budget=float(values["budget"]),
                        build_avg=float(values["build_avg"]),
                        build_p95=float(values["build_p95"]),
                        build_max=float(values["build_max"]),
                        raster_avg=float(values["raster_avg"]),
                        raster_p95=float(values["raster_p95"]),
                        raster_max=float(values["raster_max"]),
                        span_p95=float(values["span_p95"]),
                        span_max=float(values["span_max"]),
                        slow_build=int(values["slow_build"]),
                        slow_raster=int(values["slow_raster"]),
                        depth=float(values["depth"]),
                        pos=float(values["pos"]) if values["pos"] else None,
                        max=float(values["max"]) if values["max"] else None,
                    )
                )
    return trace


def label(window: Window, previous: Window | None) -> str:
    """三种状态：真的在滚 / 没滚但仍在出帧 / 几乎不出帧。

    「没滚却一直在出帧」是独立问题：说明有东西在持续把区域标脏（动画、定时重绘、
    图片陆续到位），它会和滚动抢同一个光栅线程。
    """
    moved = False
    if previous is not None:
        if window.pos is not None and previous.pos is not None:
            moved = abs(window.pos - previous.pos) > 1
        else:
            moved = abs(window.depth - previous.depth) > 1e-9
    if moved:
        return "scroll"
    return "repaint" if window.fps >= 15 else "quiet"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", help="MOVA_TRACE_FRAMES 写出的日志")
    parser.add_argument("--expect-fps", type=float, default=0.0,
                       help="期望 fps（一般填面板刷新率的 90%~97%）；给了才判定达成率")
    options = parser.parse_args()

    trace = parse(options.trace)
    if not trace.windows:
        print("BAD  日志里没有任何 FRAMES 行：确认 MOVA_TRACE_FRAMES 生效且应用跑够 1 秒")
        return 1

    header = trace.header
    print("=== 运行环境 ===")
    print(f"  view={header.get('view', '?')} dpr={header.get('dpr', '?')} "
          f"refresh={header.get('refresh', '?')}Hz blur={header.get('blur', '?')}")
    for line in trace.drive:
        print(" ", line)

    print()
    print("=== 按秒窗口 ===")
    print("  win  wall   n    fps    build_p95 raster_p95 span_p95  slow   "
          "pos     阶段")
    previous: Window | None = None
    rollup: dict[str, list[Window]] = {"scroll": [], "repaint": [], "quiet": []}
    for window in trace.windows:
        phase = label(window, previous)
        rollup[phase].append(window)
        pos = "—" if window.pos is None else f"{window.pos:.0f}"
        print(
            f"  {window.window:>3} {window.wall:>5} {window.n:>4} "
            f"{window.fps:>6.1f}  {window.build_p95:>8.2f} "
            f"{window.raster_p95:>9.2f} {window.span_p95:>8.2f} "
            f"{window.slow_total:>4}/{window.n:<4} {pos:>7}  {phase}"
        )
        previous = window

    print()
    print("=== 汇总 ===")
    for phase in ("scroll", "repaint", "quiet"):
        group = rollup[phase]
        if not group:
            continue
        frames = sum(w.n for w in group)
        seconds = sum((w.n / w.fps) if w.fps else 0.0 for w in group)
        fps = frames / seconds if seconds else 0.0
        slow = sum(w.slow_total for w in group)
        build_p95 = max(w.build_p95 for w in group)
        raster_p95 = max(w.raster_p95 for w in group)
        span_p95 = max(w.span_p95 for w in group)
        print(f"  {phase:>7}: {seconds:.0f}s / {frames} 帧  fps={fps:.1f}"
              f"  慢帧={slow} ({100.0 * slow / frames if frames else 0:.1f}%)"
              f"  build_p95≤{build_p95:.2f}ms"
              f"  raster_p95≤{raster_p95:.2f}ms"
              f"  span_p95≤{span_p95:.2f}ms")

    scroll_windows = rollup["scroll"]
    if not scroll_windows:
        print("\nBAD  没有识别到滚动窗口：驱动没生效或应用窗口未渲染")
        return 1

    frames = sum(w.n for w in scroll_windows)
    seconds = sum(w.n / w.fps for w in scroll_windows if w.fps)
    fps = frames / seconds if seconds else 0.0
    slow = sum(w.slow_total for w in scroll_windows)
    build_p95 = max(w.build_p95 for w in scroll_windows)
    raster_p95 = max(w.raster_p95 for w in scroll_windows)
    budget = scroll_windows[0].budget

    print()
    print("=== 判定 ===")
    print(f"  面板周期 budget={budget:.3f}ms → 理论上限 {1000 / budget:.0f}fps")
    print(f"  滚动期间实测 {fps:.1f}fps（帧槽使用率 {100 * fps * budget / 1000:.1f}%），"
          f"慢帧 {100.0 * slow / frames:.1f}%")
    verdict = 0
    if build_p95 > budget and build_p95 >= raster_p95:
        print(f"  瓶颈：UI 线程（build_p95={build_p95:.2f}ms > {budget:.2f}ms）"
              f" → 每帧在重建/布局/录制太多内容")
    elif raster_p95 > budget:
        print(f"  瓶颈：光栅线程（raster_p95={raster_p95:.2f}ms > {budget:.2f}ms）"
              f" → 模糊/投影/离屏图层/纹理上传")
    else:
        print("  两阶段都没超预算：卡顿来自帧槽没用满（vsync 等待或调度）")
    if rollup["repaint"]:
        repaint_frames = sum(w.n for w in rollup["repaint"])
        repaint_p95 = max(w.raster_p95 for w in rollup["repaint"])
        print(f"  另一处开销：静止却持续出帧的窗口 {len(rollup['repaint'])} 个 / "
              f"{repaint_frames} 帧，raster_p95≤{repaint_p95:.2f}ms"
              f" —— 非滚动状态的每帧成本本身就超预算")
    if options.expect_fps > 0 and fps < options.expect_fps:
        print(f"  BAD  滚动 fps {fps:.1f} < 期望 {options.expect_fps:.1f}")
        verdict = 1
    print("  VERDICT " + ("BAD" if verdict else "OK"))
    return verdict


if __name__ == "__main__":
    sys.exit(main())
