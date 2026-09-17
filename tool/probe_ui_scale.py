"""Probe: does the native player UI scale down with a small window?

Shrinks the main window to 720x430 (expected ui scale 0.5625), clicks the
"剧集" tool slot at its scaled position, then reports the panel's physical
size (expected ≈ 480*0.5625 + 2*26*0.5625 ≈ 299 px wide) and takes a shot.
"""
import ctypes
import ctypes.wintypes as wt
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_native_panels as v  # noqa: E402

user32 = v.user32
WM_LBUTTONDOWN = 0x0201
WM_LBUTTONUP = 0x0202
MK_LBUTTON = 0x0001


def click(hwnd, x, y, label):
    packed = ((y & 0xFFFF) << 16) | (x & 0xFFFF)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.15)
    user32.PostMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, packed)
    user32.PostMessageW(hwnd, WM_LBUTTONUP, 0, packed)
    time.sleep(0.5)
    print(f"click {label} @({x},{y})", flush=True)


def main():
    exe = sys.argv[1] if len(sys.argv) > 1 else r"D:\Mova\MovaNativePlayer.exe"
    out = tempfile.mkdtemp(prefix="mova_scale_")
    media = os.path.join(out, "sample.wav")
    v.make_wav(media)
    argv = [
        exe, "--config=no", "--force-window=yes", "--keep-open=no",
        "--pause=yes", "--vo=gpu-next", "--gpu-api=d3d11",
        "--gpu-context=d3d11", "--osc=no", "--hwdec=no",
        "--mova-tool-order=剧集", media,
    ]
    proc = subprocess.Popen(argv, cwd=os.path.dirname(exe) or None)
    try:
        main_hwnd = v.wait_class("MovaNativePlayerWindow")
        controls = v.wait_class("MovaNativePlayerControls")
        panel = v.wait_class("MovaNativePlayerPanel")
        print(f"windows {main_hwnd}/{controls}/{panel}", flush=True)
        time.sleep(1.0)

        # Shrink to 720x430: expected ui scale = min(720/1280, 430/760) = 0.5625.
        user32.SetWindowPos(main_hwnd, None, 100, 100, 720, 430,
                            0x0004 | 0x0010)  # NOZORDER | NOACTIVATE
        time.sleep(0.8)
        rect, client = v.geometry(main_hwnd)
        scale = min(client.right / 1280.0, client.bottom / 760.0)
        print(f"shrunk window client={client.right}x{client.bottom} "
              f"expected scale={scale:.4f}", flush=True)

        c_rect, c_client = v.geometry(controls)
        print(f"controls client={c_client.right}x{c_client.bottom} "
              f"(expected ~{int(1040 * scale)}x{int(112 * scale)})", flush=True)

        # "剧集" slot at design (ToolAreaStart(1040)+120+20, 72) = (850, 72)
        # for a single-tool order (slot index 0).
        design_x, design_y = 850.0, 72.0
        click(controls, int(design_x * scale), int(design_y * scale),
              "剧集 tool (scaled)")
        panel = v.wait_class("MovaNativePlayerPanel", timeout=3.0,
                             visible=True)
        if not panel:
            click(controls, int(design_x * scale), int(design_y * scale),
                  "剧集 retry")
            panel = v.wait_class("MovaNativePlayerPanel", timeout=3.0,
                                 visible=True)
        ok = True
        if panel:
            p_rect, p_client = v.geometry(panel)
            expected_w = (480 + 2 * 26) * scale
            print(f"panel client={p_client.right}x{p_client.bottom} "
                  f"(expected ~{expected_w:.0f} x ~"
                  f"{(34+2*10+72+6) * scale:.0f}+)", flush=True)
            inside = (p_rect.left >= rect.left and p_rect.right <= rect.right
                      and p_rect.top >= rect.top
                      and p_rect.bottom <= rect.bottom)
            print(f"panel inside window: {inside}", flush=True)
            ok = ok and inside
        else:
            print("panel NOT visible", flush=True)
            ok = False
        user32.SetForegroundWindow(main_hwnd)
        time.sleep(0.4)
        rect2, _ = v.geometry(main_hwnd)
        width, height, buf = v.grab_screen(rect2)
        shot = os.path.join(out_dir := os.environ["TEMP"], "ui_scale_small.png")
        v.write_png(shot, width, height, buf)
        print(f"shot {shot}", flush=True)
        print("RESULT " + ("PASS" if ok else "FAIL"), flush=True)
        return 0 if ok else 1
    finally:
        proc.kill()


if __name__ == "__main__":
    sys.exit(main())
