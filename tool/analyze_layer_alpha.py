"""层离屏面的 alpha 分布分析 —— 判「底板到底是透明还是块黑板」。

背景：`UpdateLayeredWindow` 的窗口（面板 / 控件条）内容只存在于它自己的 32bpp
预乘 ARGB DIB 里，抓屏和 PrintWindow 都拿不到。项目里用环境变量
`MOVA_TRACE_PANEL=<目录>` 把这块 DIB 导出成 `panel_NN.bmp` / `controls_NN.bmp`
（见 main.cpp 的 `TracePanelSurface`），本脚本读回来量化。

用法：
    python tool/analyze_layer_alpha.py <dir> [--prefix controls]

判据（控件条「只显示控件、不要底板」）：
    - `alpha == 0` 占比要显著（下缘淡出带 + 未绘制的边角），说明确实存在真透明区域；
    - 「实心内容」（alpha >= 200）只应出现在图标 / 进度条 / 时间码上，占比个位数 %；
    - 空白处（`region_max`）的 alpha 必须极小 —— 底板已经删掉了，只剩一层
      6/255 的不可见命中带；
    - **顶端不能是 0**：alpha=0 的像素点击穿透，进度条拖动命中靠顶部那条带，
      归零会让拖动失效。

⚠️ 本文件只做只读分析，不写任何东西。
"""

import argparse
import os
import struct
import sys


def read_bmp(path):
    """读 32bpp top-down BMP，返回 (width, height, bgra_bytes)。"""
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:2] != b"BM":
        raise ValueError(f"{path}: not a BMP")
    off_bits = struct.unpack_from("<I", data, 10)[0]
    width = struct.unpack_from("<i", data, 18)[0]
    height = struct.unpack_from("<i", data, 22)[0]
    bpp = struct.unpack_from("<H", data, 28)[0]
    if bpp != 32:
        raise ValueError(f"{path}: expected 32bpp, got {bpp}")
    pixels = data[off_bits:]
    return width, abs(height), pixels, height < 0


def analyze(path):
    width, height, pixels, top_down = read_bmp(path)
    total = width * height
    if len(pixels) < total * 4:
        raise ValueError(f"{path}: pixel data truncated")

    zero = 0
    opaque = 0
    alpha_sum = 0
    rows = [0] * height
    for y in range(height):
        base = y * width * 4
        if not top_down:  # bottom-up BMP：行序翻转
            base = (height - 1 - y) * width * 4
        row_sum = 0
        for x in range(width):
            a = pixels[base + x * 4 + 3]
            if a == 0:
                zero += 1
            elif a >= 200:
                opaque += 1
            row_sum += a
        rows[y] = row_sum / float(width)
        alpha_sum += row_sum

    return {
        "path": os.path.basename(path),
        "size": (width, height),
        "zero_pct": 100.0 * zero / total,
        "opaque_pct": 100.0 * opaque / total,
        "mean_alpha": alpha_sum / float(total),
        "row_alpha": rows,
    }


def band(rows, lo, hi):
    picked = rows[int(len(rows) * lo):max(int(len(rows) * hi), 1)]
    return sum(picked) / float(len(picked)) if picked else 0.0


def region_max(frame, x0, x1, y0, y1):
    """一块**相对**区域（0~1 的比例）里的最大 alpha。

    控件条现在没有任何底板，只剩一层 6/255 的「命中带」（逐像素 alpha 下
    alpha=0 的像素点击穿透，而进度条拖动 / 悬停预览靠这个窗口收鼠标）。所以判
    「有没有可见底板」不能看整块面的均值 —— 要看**空白处**的最大值有多小。
    """
    width, height, pixels, top_down = frame
    xa = max(0, min(width, int(width * x0)))
    xb = max(xa + 1, min(width, int(width * x1)))
    ya = max(0, min(height, int(height * y0)))
    yb = max(ya + 1, min(height, int(height * y1)))
    peak = 0
    for y in range(ya, yb):
        row_base = y * width * 4
        if not top_down:
            row_base = (height - 1 - y) * width * 4
        for x in range(xa, xb):
            alpha = pixels[row_base + x * 4 + 3]
            if alpha > peak:
                peak = alpha
    return peak


def region_mean(frame, x0, x1, y0, y1):
    """一块**相对**区域（0~1 的比例）里的平均 alpha。

    与 `region_max` 配成一对：max 用来判「空白处有没有可见底板」，mean 用来判
    「一片玻璃到底有多厚」。面板 / 提示这类大面积玻璃的底色浓度由「外观 → 模糊
    程度」映射而来（默认给 frost 的 128 上下），所以均值落在 80~200 才算玻璃；
    逼近 247 就是又变回那块「黑塑料」了。
    """
    width, height, pixels, top_down = frame
    xa = max(0, min(width, int(width * x0)))
    xb = max(xa + 1, min(width, int(width * x1)))
    ya = max(0, min(height, int(height * y0)))
    yb = max(ya + 1, min(height, int(height * y1)))
    total = 0
    count = 0
    for y in range(ya, yb):
        row_base = y * width * 4
        if not top_down:
            row_base = (height - 1 - y) * width * 4
        for x in range(xa, xb):
            total += pixels[row_base + x * 4 + 3]
            count += 1
    return total / float(count) if count else 0.0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory")
    parser.add_argument("--prefix", default="controls")
    parser.add_argument("--top", type=int, default=8,
                        help="最多分析几张（按文件名顺序取前 N 张非空的）")
    options = parser.parse_args()

    names = sorted(
        name for name in os.listdir(options.directory)
        if name.startswith(options.prefix + "_") and name.endswith(".bmp")
    )
    if not names:
        print(f"no {options.prefix}_*.bmp under {options.directory}")
        return 2

    # 控件条一帧里绝大多数重绘内容一样，取 alpha 总量最大的那几张（内容最全）。
    reports = []
    for name in names:
        try:
            reports.append(analyze(os.path.join(options.directory, name)))
        except ValueError as error:
            print(f"skip {name}: {error}")

    reports.sort(key=lambda item: item["mean_alpha"], reverse=True)
    printed = 0
    for report in reports[:options.top]:
        rows = report["row_alpha"]
        print(f"--- {report['path']}  {report['size'][0]}x{report['size'][1]} ---")
        print(f"    transparent(alpha=0) = {report['zero_pct']:.1f}%")
        print(f"    solid(alpha>=200)    = {report['opaque_pct']:.1f}%")
        print(f"    mean alpha           = {report['mean_alpha']:.1f}")
        print(f"    row alpha  top={band(rows, 0.0, 0.1):.1f} "
              f"upper={band(rows, 0.1, 0.3):.1f} "
              f"mid={band(rows, 0.4, 0.6):.1f} "
              f"bottom={band(rows, 0.85, 1.0):.1f}")
        printed += 1
    return 0 if printed else 1


if __name__ == "__main__":
    sys.exit(main())
