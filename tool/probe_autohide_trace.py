"""Probe the auto-hide decision from inside the player (temporary).

The player writes one line per 50 ms timer tick when MOVA_TRACE_AUTOHIDE is
set. Reading layered alpha from outside is useless here: the physical mouse
keeps moving during the test, so we need to see *why* ShowControls() fires
(or does not) rather than just the resulting alpha.
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


controls_hwnd = [0]


def alpha_of():
    if not controls_hwnd[0]:
        return -1
    alpha = wt.BYTE()
    flags = wt.DWORD()
    v.user32.GetLayeredWindowAttributes.argtypes = [
        wt.HWND, ctypes.POINTER(wt.COLORREF), ctypes.POINTER(wt.BYTE),
        ctypes.POINTER(wt.DWORD)]
    v.user32.GetLayeredWindowAttributes.restype = wt.BOOL
    if not v.user32.GetLayeredWindowAttributes(controls_hwnd[0], None,
                                               ctypes.byref(alpha),
                                               ctypes.byref(flags)):
        return -1
    return alpha.value


class CURSORINFO(ctypes.Structure):
    _fields_ = [("cbSize", wt.DWORD), ("flags", wt.DWORD),
                ("hCursor", wt.HANDLE), ("ptScreenPos", wt.POINT)]


def cursor_shown():
    info = CURSORINFO()
    info.cbSize = ctypes.sizeof(info)
    if not v.user32.GetCursorInfo(ctypes.byref(info)):
        return None
    return bool(info.flags & 0x00000001)  # CURSOR_SHOWING


def main():
    exe = sys.argv[1] if len(sys.argv) > 1 else r"D:\Mova\MovaNativePlayer.exe"
    out = tempfile.mkdtemp(prefix="mova_trace_")
    media = os.path.join(out, "long.wav")
    v.make_wav(media, seconds=120)
    log = os.path.join(out, "autohide.log")
    argv = [
        exe, "--config=no", "--force-window=yes", "--keep-open=no",
        "--vo=gpu-next", "--gpu-api=d3d11", "--gpu-context=d3d11",
        "--osc=no", "--hwdec=no", media,
    ]
    proc = subprocess.Popen(argv, cwd=os.path.dirname(exe) or None,
                            env={**os.environ, "MOVA_TRACE_AUTOHIDE": log})
    try:
        main_hwnd = v.wait_class("MovaNativePlayerWindow")
        controls_hwnd[0] = v.wait_class("MovaNativePlayerControls")
        print(f"main={main_hwnd} log={log}", flush=True)
        rect, _ = v.geometry(main_hwnd)
        v.user32.SetCursorPos((rect.left + rect.right) // 2,
                              rect.top + (rect.bottom - rect.top) // 3)
        print("cursor parked over video area, staying still for 8 s",
              flush=True)
        time.sleep(8)
        hidden_alpha = alpha_of()
        hidden_cursor = cursor_shown()
        print(f"after idle: alpha={hidden_alpha} cursor_shown={hidden_cursor}",
              flush=True)

        # Wave the cursor inside the window: controls must come back.
        rect2, _ = v.geometry(main_hwnd)
        for step in range(12):
            v.user32.SetCursorPos(rect2.left + 120 + step * 30,
                                  rect2.bottom - 60)
            time.sleep(0.12)
        time.sleep(1.0)
        shown_alpha = alpha_of()
        shown_cursor = cursor_shown()
        print(f"after move: alpha={shown_alpha} cursor_shown={shown_cursor}",
              flush=True)
        ok = hidden_alpha == 0 and not hidden_cursor and shown_alpha == 232 \
            and shown_cursor
        print("RESULT " + ("PASS" if ok else "FAIL"), flush=True)
        return 0 if ok else 1
    finally:
        proc.kill()
        time.sleep(0.3)
        if not os.path.exists(log):
            print("no trace file produced")
            return 0
        lines = open(log, encoding="utf-8", errors="replace").read().splitlines()
        print(f"=== {len(lines)} trace lines, log kept at {log} ===")
        for line in lines[:4]:
            print(line)
        print("...")
        # Every place where the idle timer was reset (idle dropped) - print
        # the surrounding lines so we can see who called ShowControls().
        drops = []
        for i in range(1, len(lines)):
            if " idle=" not in lines[i] or " idle=" not in lines[i - 1]:
                continue
            now = int(lines[i].split(" idle=")[1].split(" ")[0])
            prev = int(lines[i - 1].split(" idle=")[1].split(" ")[0])
            if now + 100 < prev:
                drops.append(i)
        print(f"--- {len(drops)} idle drops; showing the last 3 ---")
        for i in drops[-3:]:
            for line in lines[max(0, i - 4):i + 2]:
                print("   " + line)
            print("   ---")
        for line in lines[-6:]:
            print(line)
        moved = sum(1 for l in lines if " moved=1 " in l)
        inwin = sum(1 for l in lines if " inwin=1 " in l)
        hide = sum(1 for l in lines if " hide=1 " in l)
        print(f"moved={moved} inwin={inwin} should_hide={hide}")


if __name__ == "__main__":
    sys.exit(main())
