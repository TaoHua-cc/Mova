"""Measure the white stroke / gap / poster bands in the user's screenshot."""

import sys

from PIL import Image

buf = []

img = Image.open(
    r"C:\Users\gctyk\.workbuddy\clipboard-images"
    r"\clipboard-2026-09-17T19-51-20-357Z-d18fb111.png"
).convert("RGB")
w, h = img.size
buf.append(f"size {w} {h}")

# Scan a few horizontal rows through the poster area and report the
# runs of "bright" (stroke) vs dark vs image pixels.


def runs(y):
    row = [img.getpixel((x, y)) for x in range(w)]
    out = []
    cur_color = row[0]
    start = 0

    def close(a, b, tol=40):
        return abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2]) <= tol

    for x in range(1, w):
        if not close(row[x], cur_color):
            out.append((start, x - 1, cur_color))
            cur_color = row[x]
            start = x
    out.append((start, w - 1, cur_color))
    # merge tiny runs for readability
    buf.append(f"--- row y={y} ---")
    for s, e, c in out:
        if e - s >= 1:
            buf.append(f"  x {s:3d}-{e:3d} ({e-s+1:3d}px) rgb={c}")


for y in (60, 90, 120):
    runs(y)

open(r"D://codex//Mova//seam_report.txt", "w", encoding="utf-8").write("\n".join(buf))
