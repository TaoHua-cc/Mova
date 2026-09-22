r"""把播放器启动时的帧节拍诊断原样打出来（MOVA_FRAME_PACING）。

为什么单独有个工具：探针（probe_danmaku_layout.py）只汇总
`MOVA_DANMAKU_DRAW`，而「这一版到底认了哪块屏、哪块屏自己报多少 Hz」只在
`MOVA_FRAME_PACING` 那一行里，探针不会转述它。查「节拍是不是按错了面板」
时必须能看到这一行。

`QueryRefreshPeriodMs` 问的是**主**显示器（DwmGetCompositionTimingInfo(NULL)
与 EnumDisplaySettings(NULL) 都只看主屏），所以一旦窗口被拖到副屏上，分频就会
按另一块面板算 —— 这里的 `monitor=` / `hz=` / `primary=` 就是用来排除这一条的。
本机实测：`monitor=\\.\DISPLAY1 hz=170 primary=yes`，与 refresh=5.882ms 一致。

跑：python tool/probe_frame_pacing_env.py [--seconds 12]
"""

import argparse
import os
import subprocess
import sys
import threading
import time

EXE = r"D:\Mova\MovaNativePlayer.exe"
WORKDIR = r"D:\Mova"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", default=EXE)
    parser.add_argument("--workdir", default=WORKDIR)
    parser.add_argument("--seconds", type=float, default=12.0)
    parser.add_argument("--media", default="av://lavfi:testsrc2=size=1920x1080"
                                        ":rate=25:duration=600")
    options = parser.parse_args()

    trace = os.path.join(os.environ["TEMP"], "mova_frame_pacing_env")
    os.makedirs(trace, exist_ok=True)

    argv = [
        options.exe,
        "--config=no", "--force-window=yes", "--keep-open=no",
        "--vo=gpu-next", "--gpu-api=d3d11", "--gpu-context=d3d11",
        "--osc=no", "--terminal=yes", "--force-media-title=pacing env",
        "--hwdec=auto-safe",
        options.media,
    ]
    environment = dict(os.environ)
    environment["MOVA_TRACE_DANMAKU"] = "1"
    environment["MOVA_TRACE_PANEL"] = trace

    process = subprocess.Popen(
        argv, cwd=options.workdir, env=environment, stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=1,
        text=True, encoding="utf-8", errors="replace")
    lines = []

    def pump():
        for line in process.stdout:
            lines.append(line.rstrip("\r\n"))

    threading.Thread(target=pump, daemon=True).start()
    time.sleep(options.seconds)
    process.kill()
    process.wait(timeout=10)

    pacing = [line for line in lines if line.startswith("MOVA_FRAME_PACING")]
    if not pacing:
        print("FAILED: no MOVA_FRAME_PACING line -- 播放器没起来？")
        return 1
    for line in pacing:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
