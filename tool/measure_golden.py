"""Measure the golden rendered by test/frame_geometry_test.dart.

The poster area is pure red (255,0,0); the stroke is white. Any dark or
transparent run between them is a real layout gap.
"""

from PIL import Image

img = Image.open(
    r"D:\codex\Mova\test\goldens\frame_geometry.png"
).convert("RGB")
w, h = img.size
buf = [f"size {w} {h}"]

# Find the poster rows: scan the middle of the red area.
for y in (60, 100, 140):
    row = []
    prev = None
    for x in range(w):
        c = img.getpixel((x, y))
        if prev is None or abs(sum(c) - sum(prev)) > 20:
            row.append((x, c))
            prev = c
    buf.append(f"--- y={y} transitions ---")
    for x, c in row[:12]:
        buf.append(f"  x={x:3d} rgb={c}")

# Width of the white stroke band on the left edge at mid height.
y = 100
white = [x for x in range(w) if img.getpixel((x, y)) == (255, 255, 255)]
if white:
    buf.append(f"white pixels at y={y}: x {min(white)}..{max(white)} "
               f"count={len(white)}")
red = [x for x in range(w) if img.getpixel((x, y)) == (255, 0, 0)]
if red:
    buf.append(f"red pixels at y={y}: x {min(red)}..{max(red)} "
               f"count={len(red)}")
    buf.append(f"GAP between stroke inner edge and poster = "
               f"{min(red) - max(white) - 1}px")

with open(r"D:\codex\Mova\golden_report.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(buf))
