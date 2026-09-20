"""提示浮层（hint）排版探针：把离屏面的**墨迹区间**列出来，看有没有被裁掉。

背景（2026-09-20）：提示标题被 GDI+ 的省略号修剪吞掉，只剩一个字。`hint_*.bmp`
是 `MOVA_TRACE_PANEL` 导出的 32bpp 预乘 ARGB 离屏面 —— layered 窗口抓屏拿不到，
只能离线读它。肉眼很难判断「音量」是不是真的只有「音」，把每个墨迹块的行带与
水平区间打出来就一目了然：

  * 一行标题 + 行内值（音量）：期望 4 个墨迹块 —— 图标 / 标题 2 字 / 值 3 字符
    （`42%` 里的 `%` 可能与数字相连，按实际输出为准）；
  * 标题两个字在物理像素上应当各占 ≈ 字号 × UiScale 的宽度。若某个块宽只有一个
    字的量级，就是又被修剪丢字了。

用法：
  python tool/probe_hint_layout.py [--dir TRACE_DIR] [--file hint_XX.bmp]
                                   [--thresh 180]
"""

import argparse
import glob
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyze_layer_alpha as alpha_tool  # noqa: E402


def ink_bands(width, height, buffer, thresh):
    rows = []
    for y in range(height):
        row = buffer[y * width * 4:(y + 1) * width * 4]
        rows.append(sum(1 for x in range(width) if row[x * 4 + 3] >= thresh))
    bands = []
    start = None
    for y, count in enumerate(rows):
        if count > 0 and start is None:
            start = y
        elif count == 0 and start is not None:
            bands.append((start, y - 1))
            start = None
    if start is not None:
        bands.append((start, height - 1))
    return bands


def ink_runs(width, buffer, y0, y1, thresh):
    runs = []
    start = None
    for x in range(width):
        hit = any(buffer[y * width * 4 + x * 4 + 3] >= thresh
                  for y in range(y0, y1 + 1))
        if hit and start is None:
            start = x
        elif not hit and start is not None:
            runs.append((start, x - 1))
            start = None
    if start is not None:
        runs.append((start, width - 1))
    return runs


def ascii_dump(width, height, buffer, thresh, band):
    """把某个行带打成字符画：`#` 是实墨、`-` 是较亮的一档。

    墨迹区间只能告诉你「有几块」，看不出那是几个字；字符画可以直接读字。
    ⚠️ 提示体的玻璃本身就有 120~170 的 alpha，阈值取低了整块都是「墨」——
    要用 `--thresh 240` 这种只留下字形（alpha 255）的值。
    """
    y0, y1 = band
    for y in range(y0, y1 + 1):
        line = []
        for x in range(width):
            value = buffer[y * width * 4 + x * 4 + 3]
            line.append('#' if value >= thresh
                        else ('-' if value >= 200 else '.'))
        print("  " + "".join(line))


def probe(path, thresh, ascii_mode):
    width, height, buffer, _ = alpha_tool.read_bmp(path)
    print(f"file   = {path}")
    print(f"size   = {width}x{height}")
    bands = ink_bands(width, height, buffer, thresh)
    print(f"bands  = {bands}")
    for y0, y1 in bands:
        runs = ink_runs(width, buffer, y0, y1, thresh)
        widths = "+".join(str(b - a + 1) for a, b in runs)
        print(f"  y {y0:>3}..{y1:<3} n={len(runs)} runs={runs}")
        print(f"             widths={widths}")
        if ascii_mode:
            ascii_dump(width, height, buffer, thresh, (y0, y1))
    return bands


def main():
    parser = argparse.ArgumentParser()
    default_dir = os.path.join(os.environ.get("TEMP", "."),
                               "mova_controls_surface", "trace")
    parser.add_argument("--dir", default=default_dir)
    parser.add_argument("--file", default="")
    parser.add_argument("--thresh", type=int, default=180)
    parser.add_argument("--ascii", action="store_true",
                        help="把每个墨迹行带打成字符画，直接读字")
    options = parser.parse_args()

    if options.file:
        files = [options.file]
    else:
        files = sorted(glob.glob(os.path.join(options.dir, "hint_*.bmp")))
    if not files:
        print(f"no hint_*.bmp under {options.dir}")
        return 1
    # 只探最后一张：滚轮改音量弹的那次就是最终状态。
    probe(files[-1], options.thresh, options.ascii)
    return 0


if __name__ == "__main__":
    sys.exit(main())
