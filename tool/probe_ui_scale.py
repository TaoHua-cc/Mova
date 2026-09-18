"""Probe: the native player's design→physical coordinate mapping.

Two things are checked, because both ends have bitten this project:

1. **Default (big) window** — prints the window / dock sizes in both physical
   and design units plus the resulting ``UiScale()``. Anything that posts
   clicks into these windows has to work in design units, so this is the line
   to look at when a click "lands nowhere".
2. **Shrunk window** — resizes the main window to 720x430 (expected ui scale
   0.5625), clicks the "剧集" tool slot at its scaled position, then reports
   the panel's physical size (expected ≈ 480*0.5625 + 2*26*0.5625 ≈ 299 px
   wide) and takes a shot.

Coordinates here are always written in design units and pushed through
``v.click_design()`` — never hand-roll ``int(x * scale)``.
"""
import ctypes
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_native_panels as v  # noqa: E402

user32 = v.user32


def report_geometry(main_hwnd, controls, label):
    """Print window/dock size in physical + design units, and the scale."""
    m_rect, m_client = v.geometry(main_hwnd)
    c_rect, c_client = v.geometry(controls)
    scale = v.ui_scale(main_hwnd)
    d_w, d_h, _ = v.design_size(main_hwnd)
    centres = v.tool_slots(int(round(c_client.right / scale)), 1)[0]
    print(f"[{label}] screen={ctypes.windll.user32.GetSystemMetrics(0)}x"
          f"{ctypes.windll.user32.GetSystemMetrics(1)} "
          f"main={m_rect.right-m_rect.left}x{m_rect.bottom-m_rect.top}"
          f" (client {m_client.right}x{m_client.bottom} -> design "
          f"{d_w:.0f}x{d_h:.0f}) "
          f"dock={c_client.right}(px) -> {int(round(c_client.right/scale))}"
          f"(design) scale={scale:.4f} slot0={centres}", flush=True)
    return scale, m_rect


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

        # 1) 默认（放大后的）窗口：这里就是「按 1.0 算坐标会点空」的来源。
        report_geometry(main_hwnd, controls, "default")

        # Shrink to 720x430: expected ui scale = min(720/1280, 430/760) = 0.5625.
        user32.SetWindowPos(main_hwnd, None, 100, 100, 720, 430,
                            0x0004 | 0x0010)  # NOZORDER | NOACTIVATE
        time.sleep(0.8)
        rect, client = v.geometry(main_hwnd)
        scale = v.ui_scale(main_hwnd)
        print(f"shrunk window client={client.right}x{client.bottom} "
              f"expected scale={scale:.4f}", flush=True)

        c_rect, c_client = v.geometry(controls)
        print(f"controls client={c_client.right}x{c_client.bottom} "
              f"(expected ~{int(1040 * scale)}x{int(112 * scale)})", flush=True)

        # "剧集" slot at design (ToolAreaStart(1040)+120+20, 72) = (850, 72)
        # for a single-tool order (slot index 0). Design units → click_design().
        design_x, design_y = 850.0, 72.0
        v.click_design(controls, design_x, design_y, "剧集 tool (scaled)", scale)
        panel = v.wait_class("MovaNativePlayerPanel", timeout=3.0,
                             visible=True)
        if not panel:
            v.click_design(controls, design_x, design_y, "剧集 retry", scale)
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
