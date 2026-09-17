"""Visual proof for the auto-hide fix: two screenshots of the same player.

Shot A is taken right after start (controls visible, alpha 232); then the
cursor is parked over the video area and kept still; shot B is taken after
the controls have faded (alpha 0). Both land in %TEMP%\\mova_verify\\.
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


def main():
    exe = sys.argv[1] if len(sys.argv) > 1 else r"D:\Mova\MovaNativePlayer.exe"
    out_dir = os.path.join(tempfile.gettempdir(), "mova_verify")
    os.makedirs(out_dir, exist_ok=True)
    media = os.path.join(out_dir, "autohide.wav")
    v.make_wav(media, seconds=120)
    argv = [
        exe, "--config=no", "--force-window=yes", "--keep-open=no",
        "--vo=gpu-next", "--gpu-api=d3d11", "--gpu-context=d3d11",
        "--osc=no", "--hwdec=no", media,
    ]
    proc = subprocess.Popen(argv)
    try:
        main_hwnd = v.wait_class("MovaNativePlayerWindow")
        controls = v.wait_class("MovaNativePlayerControls")
        if not main_hwnd or not controls:
            print("windows not found")
            return 1
        time.sleep(1.2)
        rect, _client = v.geometry(main_hwnd)
        shot_a = os.path.join(out_dir, "20_autohide_visible.png")
        w, h, buf = v.grab_screen(rect)
        v.write_png(shot_a, w, h, buf)
        print(f"shot A (controls visible): {shot_a}", flush=True)
        # Park the cursor over the video and keep it perfectly still.
        pt = wt.POINT((rect.left + rect.right) // 2, rect.top + 200)
        user32 = v.user32
        user32.SetCursorPos(pt.x, pt.y)
        alpha = wt.BYTE()
        flags = wt.DWORD()
        user32.GetLayeredWindowAttributes.argtypes = [
            wt.HWND, ctypes.POINTER(wt.COLORREF), ctypes.POINTER(wt.BYTE),
            ctypes.POINTER(wt.DWORD)]
        deadline = time.time() + 8
        while time.time() < deadline:
            time.sleep(0.4)
            user32.GetLayeredWindowAttributes(controls, None,
                                              ctypes.byref(alpha),
                                              ctypes.byref(flags))
            if alpha.value == 0:
                break
        print(f"alpha after idle: {alpha.value}", flush=True)
        time.sleep(0.6)
        shot_b = os.path.join(out_dir, "21_autohide_hidden.png")
        w, h, buf = v.grab_screen(rect)
        v.write_png(shot_b, w, h, buf)
        print(f"shot B (controls hidden, cursor parked): {shot_b}",
              flush=True)
        return 0 if alpha.value == 0 else 2
    finally:
        proc.kill()


if __name__ == "__main__":
    sys.exit(main())
