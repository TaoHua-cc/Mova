r"""Judge「这块玻璃是黑的还是透的」from a real screen grab.

The offline surfaces (MOVA_TRACE_PANEL) only tell you the panel's *own* alpha.
They cannot answer the user's actual complaint — 「菜单还是黑塑料」 — because
what the eye sees is the panel **composited over the video**. So this probe
takes a screenshot the user (or the harness) captured and compares:

  * the video right beside the panel (the backdrop we should be seeing through),
  * the panel body between rows (glass, no content),
  * the card interior (glass + the row's own tint).

From those it prints the **darkening ratio**: panel_lum / backdrop_lum. Real
frosted glass at the app's recipe (`YingjiGlass.hud` = .38 frost) should sit
around 0.55–0.75 on a mid-bright backdrop; anything under ~0.45 with the
backdrop bled to near zero is the black-plastic failure.

Usage:
  python tool/probe_glass_shot.py --shot PATH [--row 0.5]
  python tool/probe_glass_shot.py --shot PATH --bands 4
"""
import argparse
import sys

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    print("Pillow is required: pip install pillow")
    sys.exit(2)


def load(path):
    return Image.open(path).convert("RGB")


def average(image, x0, x1, y0, y1):
    box = image.crop((x0, y0, x1, y1))
    pixels = list(box.getdata())
    count = len(pixels) or 1
    return tuple(round(sum(p[c] for p in pixels) / count, 1) for c in range(3))


def luma(color):
    return round(0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2], 1)


def scan_row(image, y, step=4, window=4):
    width, _ = image.size
    values = []
    for x in range(0, width - window, step):
        values.append(luma(average(image, x, x + window, y, y + window)))
    return values


def find_panel_edges(values, step=4, window=4):
    """First / last column whose luma collapses toward the panel's dark sheet."""
    darkest = min(values)
    threshold = darkest + max(6.0, (max(values) - darkest) * 0.35)
    inside = [i for i, value in enumerate(values) if value <= threshold]
    if not inside:
        return None, None
    return inside[0] * step, inside[-1] * step + window


def report(image, row_fraction, bands):
    width, height = image.size
    y = int(height * row_fraction)
    values = scan_row(image, y)
    left, right = find_panel_edges(values)
    print(f"image        = {width}x{height}")
    print(f"scan row     = y={y} (fraction {row_fraction})")
    print(f"row luma     = " + " ".join(f"{v:.0f}" for v in values))
    if left is None:
        print("!! no dark band found on this row — pick another --row")
        return 1
    print(f"panel x-span = {left}..{right}  (width {right - left})")

    # 面板外的两翼：就是「背面本该透出来的画面」。
    wing = max(8, (left - 4) // 2)
    outside_left = average(image, max(0, left - wing - 4), max(1, left - 4),
                           y - 20, y + 20)
    outside_right = average(image, min(width - 1, right + 4),
                            min(width, right + 4 + wing), y - 20, y + 20)
    # 面板内的行间空白：纯玻璃，没有卡片自己的提亮。
    print()
    print("----- backdrop vs glass (luma) -----")
    for name, box in (
        ("video  left of panel", outside_left),
        ("video right of panel", outside_right),
    ):
        print(f"  {name:<24} rgb={box}  luma={luma(box)}")
    backdrop = max(1.0, (luma(outside_left) + luma(outside_right)) / 2.0)

    span = max(1, right - left)
    for index in range(bands):
        # 竖着切 `bands` 段，每段取中间那一小条，避开卡片文字与缩略图。
        band_top = int(height * 0.02)
        band_height = int((height * 0.96 - band_top) / bands)
        cx0 = left + int(span * 0.03)
        cx1 = left + int(span * 0.28)
        cy0 = band_top + band_height * index + int(band_height * 0.30)
        cy1 = band_top + band_height * index + int(band_height * 0.70)
        if cy1 <= cy0 or cx1 <= cx0:
            continue
        glass = average(image, cx0, cx1, cy0, cy1)
        print(f"  glass band {index} (x {cx0}..{cx1}, y {cy0}..{cy1})"
              f"  rgb={glass}  luma={luma(glass)}"
              f"  ratio={luma(glass) / backdrop:.2f}")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--shot", required=True, help="screenshot path")
    parser.add_argument("--row", type=float, default=0.5,
                        help="which image row to scan, 0..1")
    parser.add_argument("--bands", type=int, default=4,
                        help="how many vertical bands of glass to sample")
    options = parser.parse_args()
    return report(load(options.shot), options.row, options.bands)


if __name__ == "__main__":
    sys.exit(main())
