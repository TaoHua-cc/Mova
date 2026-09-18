"""Measure a danmaku layer bitmap: are the lanes separated, and is there a real
gap between two danmaku sharing one lane?

The C++ side already reports ``overlap=`` / ``depth=`` per frame.  This script
reads the *rendered pixels* instead, which answers a different question: after
all the arithmetic, what does the layer actually look like?  It measures two
things:

* **lane bands** -- alpha coverage per scanline, grouped into bands.  If the
  lane pitch were smaller than the glyph box, neighbouring lanes would bleed
  into each other and the bands would merge.  Bands must stay separate.
* **gap inside a band** -- the x runs of ink separated by real background.
  The renderer reserves ``kDanmakuLaneGapPx`` (32px) between two consecutive
  danmaku in the same lane, so the runs inside a band should be at least that
  far apart.  A smaller gap means the lane packer let them crowd.

**Limitation, and why both measurements are needed**: two texts that actually
overlap produce continuous ink and therefore merge into ONE run -- this script
cannot see that.  It proves *separation*; the trace's ``depth`` proves the
*absence of overlap*.  Run both.

    python tool\\analyze_danmaku_bitmap.py <danmaku_01.bmp> [--expect-gap 32]
"""

import argparse
import struct
import sys


def load_bmp_alpha(path):
    """Return (width, height, alpha) for a 32-bit BGRA BMP."""
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:2] != b"BM":
        raise ValueError("not a BMP")
    pixel_offset = struct.unpack_from("<I", data, 10)[0]
    header_size = struct.unpack_from("<I", data, 14)[0]
    width = struct.unpack_from("<i", data, 18)[0]
    raw_height = struct.unpack_from("<i", data, 22)[0]
    bit_count = struct.unpack_from("<H", data, 28)[0]
    compression = struct.unpack_from("<I", data, 30)[0]
    if header_size < 40 or bit_count != 32 or compression != 0:
        raise ValueError(f"expect 32-bit uncompressed BMP, got {bit_count}bpp"
                         f" comp={compression}")
    height = abs(raw_height)
    top_down = raw_height < 0
    stride = width * 4
    rows = []
    for y in range(height):
        source = y if top_down else height - 1 - y
        base = pixel_offset + source * stride
        # Alpha is the 4th byte of each BGRA pixel.
        rows.append(bytes(data[base + 3:base + stride:4]))
    return width, height, rows


def bands(rows, threshold):
    """Group consecutive scanlines that carry any ink into bands."""
    flags = [any(byte > threshold for byte in row) for row in rows]
    out = []
    start = None
    for y, has_ink in enumerate(flags):
        if has_ink and start is None:
            start = y
        elif not has_ink and start is not None:
            out.append((start, y - 1))
            start = None
    if start is not None:
        out.append((start, len(flags) - 1))
    return out


def runs(rows, top, bottom, threshold):
    """x runs of ink inside one band (a column carries ink if any row does)."""
    width = len(rows[0])
    columns = []
    for x in range(width):
        hit = False
        for y in range(top, bottom + 1):
            if rows[y][x] > threshold:
                hit = True
                break
        columns.append(hit)
    out = []
    start = None
    for x, has_ink in enumerate(columns):
        if has_ink and start is None:
            start = x
        elif not has_ink and start is not None:
            out.append((start, x - 1))
            start = None
    if start is not None:
        out.append((start, len(columns) - 1))
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("bitmap")
    parser.add_argument("--threshold", type=int, default=24,
                        help="alpha above this counts as ink")
    parser.add_argument("--max-gap", type=int, default=24,
                        help="runs closer than this belong to the same block")
    parser.add_argument("--expect-gap", type=int, default=32,
                        help="minimum gap the lane packer must leave between "
                             "two danmaku in one lane (kDanmakuLaneGapPx)")
    options = parser.parse_args()

    width, height, rows = load_bmp_alpha(options.bitmap)
    found = bands(rows, options.threshold)
    print(f"{options.bitmap}  {width}x{height}  bands={len(found)}")
    merged = 0
    tight = 0
    for top, bottom in found:
        pieces = runs(rows, top, bottom, options.threshold)
        # Runs closer than max_gap are the same text (glyph spacing); anything
        # further apart is a different block in the same band.
        blocks = []
        for piece in pieces:
            if blocks and piece[0] - blocks[-1][1] - 1 <= options.max_gap:
                blocks[-1] = (blocks[-1][0], piece[1])
            else:
                blocks.append(piece)
        tall = bottom - top + 1
        gaps = [blocks[i + 1][0] - blocks[i][1] - 1
                for i in range(len(blocks) - 1)]
        crowding = [gap for gap in gaps if gap < options.expect_gap]
        merged += len([gap for gap in gaps if gap <= 0])
        tight += len(crowding)
        print(f"  y={top:4d}..{bottom:4d} h={tall:3d} blocks={len(blocks):2d}"
              f" min_gap={min(gaps) if gaps else '-'}"
              f" under_{options.expect_gap}px={len(crowding)}")
    verdict = "OK" if tight == 0 else "BAD"
    print(f"\nbands={len(found)} merged_pairs={merged}"
          f" gaps_under_{options.expect_gap}px={tight}")
    print(f"VERDICT {verdict}"
          + ("" if tight == 0 else
             "  danmaku share a lane without the reserved gap"))
    print("NOTE    overlapping texts merge into one run and are invisible here;"
          " the trace's depth= is what rules overlap out")
    return 0 if tight == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
