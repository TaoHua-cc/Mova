"""Probe: does the native player auto-hide its controls + cursor while playing?

Launches MovaNativePlayer.exe on a 60 s silent wav (playing, not paused),
then samples the controls window's layered alpha once per second for 10 s.
Alpha should decay to 0 after ~2.6 s idle. Temporary diagnostic tool.
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
alpha_out = wt.BYTE()
flags_out = wt.DWORD()
user32.GetLayeredWindowAttributes.argtypes = [
    wt.HWND, ctypes.POINTER(wt.COLORREF), ctypes.POINTER(wt.BYTE),
    ctypes.POINTER(wt.DWORD)]
user32.GetLayeredWindowAttributes.restype = wt.BOOL


def sample(hwnd, label):
    ok = user32.GetLayeredWindowAttributes(hwnd, None,
                                           ctypes.byref(alpha_out),
                                           ctypes.byref(flags_out))
    pt = wt.POINT()
    user32.GetCursorPos(ctypes.byref(pt))
    a = alpha_out.value if ok else 'n/a'
    print(f"{label} alpha={a} cursor=({pt.x},{pt.y})", flush=True)


def main():
    exe = sys.argv[1] if len(sys.argv) > 1 else r"D:\Mova\MovaNativePlayer.exe"
    out = tempfile.mkdtemp(prefix="mova_probe_")
    media = os.path.join(out, "long.wav")
    v.make_wav(media, seconds=60)
    argv = [
        exe, "--config=no", "--force-window=yes", "--keep-open=no",
        "--vo=gpu-next", "--gpu-api=d3d11", "--gpu-context=d3d11",
        "--osc=no", "--hwdec=no", media,
    ]
    proc = subprocess.Popen(argv, cwd=os.path.dirname(exe) or None,
                            env={**os.environ,
                                 "MOVA_TRACE_SHOW":
                                     os.path.join(out, "show.log")})
    try:
        main_hwnd = v.wait_class("MovaNativePlayerWindow")
        controls = v.wait_class("MovaNativePlayerControls")
        top_bar = v.wait_class("MovaNativePlayerTopBar")
        print(f"main={main_hwnd} controls={controls} top={top_bar}",
              flush=True)
        if not controls:
            print("controls window not found", flush=True)
            return 1
        for second in range(4):
            time.sleep(1)
            print(f"idle t={second + 1}s ", end="", flush=True)
            sample(controls, "controls")
        rect = wt.RECT()
        user32.GetWindowRect(controls, ctypes.byref(rect))
        main_rect = wt.RECT()
        user32.GetWindowRect(main_hwnd, ctypes.byref(main_rect))
        print(f"controls rect l={rect.left} t={rect.top} "
              f"r={rect.right} b={rect.bottom}", flush=True)
        # Phase 1: park on the controls bar (over the blank left margin) and
        # keep still - alpha must decay to 0.
        pt = wt.POINT(rect.left + 6, (rect.top + rect.bottom) // 2)
        user32.SetCursorPos(pt.x, pt.y)
        print(f"cursor parked on controls at {pt.x},{pt.y}", flush=True)
        for second in range(5):
            time.sleep(1)
            print(f"on-controls t={second + 1}s ", end="", flush=True)
            sample(controls, "controls")
        # Phase 2: nudge once (must restore 232), then park over the video
        # area and keep still - alpha must decay to 0 again.
        pt2 = wt.POINT((main_rect.left + main_rect.right) // 2,
                       main_rect.top + 200)
        user32.SetCursorPos(pt2.x, pt2.y)
        time.sleep(1)
        print(f"after nudge to video at {pt2.x},{pt2.y}", end="", flush=True)
        sample(controls, "controls")
        for second in range(5):
            time.sleep(1)
            print(f"on-video t={second + 1}s ", end="", flush=True)
            sample(controls, "controls")
        return 0
    finally:
        proc.kill()


if __name__ == "__main__":
    sys.exit(main())
