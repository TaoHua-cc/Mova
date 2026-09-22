#!/usr/bin/env python3
"""跑一次「发现页平滑滚动」帧耗时采集，产出可直接喂给 analyze_frame_trace.py 的日志。

它做的事：确认没有已运行的 Mova（单实例锁会让新进程直接退出）→ 带诊断环境变量
启动 profile 版 → 等驱动滚完 → 关掉进程。

用法：

    python tool/run_frame_trace.py --out trace_blur30.log
    python tool/run_frame_trace.py --out trace_blur0.log --blur 0
    python tool/run_frame_trace.py --out trace_idle.log --no-drive --wait 16

⚠️ 采集期间**不要让机器跑别的重活**（构建、测试、下载）。实测过：搭在一次
`flutter build` 之后采到的数据，光栅耗时会被污染到 2 倍以上。
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

DEFAULT_APP = Path("build/windows/x64/runner/Profile/mova.exe")
DELAY_MS = 6000


def _drain(process: subprocess.Popen, path: Path) -> None:
    """把应用输出落到文件。

    **不能丢进 DEVNULL**：诊断代码里的未捕获异常（曾经是 IOSink 的
    `Bad state: StreamSink is bound to a stream`）会让整段窗口记录消失，
    而只从数据上看像「应用没渲染」，根本查不到原因。
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        assert process.stdout is not None
        for chunk in iter(lambda: process.stdout.readline(), b""):
            handle.write(chunk)
            handle.flush()


def running_instances() -> list[str]:
    """列出正在运行的 mova.exe 进程号（不依赖 psutil）。

    `tasklist` 在本机用 ANSI 代码页（简体中文是 GBK）输出，直接用 `text=True`
    会抛 UnicodeDecodeError，所以按字节收、宽松解码 —— 进程名是纯 ASCII，
    解错编码也能认出来。
    """
    try:
        raw = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq mova.exe", "/NH"],
            capture_output=True, timeout=20,
        ).stdout or b""
    except (OSError, subprocess.SubprocessError):
        return []
    pids = []
    for line in raw.decode("utf-8", errors="replace").splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0].lower() == "mova.exe":
            pids.append(parts[1])
    return pids


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True, help="输出日志路径")
    parser.add_argument("--app", default=str(DEFAULT_APP), help="要启动的 exe")
    parser.add_argument("--blur", type=float, default=None,
                       help="诊断用玻璃模糊覆盖值（0~40）；不给就用偏好里的值")
    parser.add_argument("--no-drive", action="store_true",
                       help="不合成滚轮事件，只记录手滚或静止时的帧耗时")
    parser.add_argument("--wait", type=float, default=None,
                       help="进程存活秒数；默认按滚动时长 + 8 秒推算")
    parser.add_argument("--speed", type=float, default=1400, help="滚动速度（像素/秒）")
    parser.add_argument("--duration", type=int, default=8000, help="滚动时长（毫秒）")
    parser.add_argument("--round-trip", action="store_true",
                       help="前半程向下、后半程向上，用于复现海报往返抖动")
    parser.add_argument("--glass-skip", default=None,
                       help="归因用：整条跳过某处离屏模糊通道，取值 shell,clear,"
                            "frost,glass,circle,rect（逗号分隔）或 all。不设置就全开")
    options = parser.parse_args()

    app = Path(options.app)
    if not app.exists():
        print(f"BAD  找不到可执行文件 {app}；先跑 flutter build windows --profile")
        return 1

    existing = running_instances()
    if existing:
        print(f"BAD  已有 Mova 在运行（PID {', '.join(existing)}）：单实例锁会让本次启动"
              f"直接退出。先关掉它。")
        return 1

    out = Path(options.out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()
    err_path = out.with_suffix(out.suffix + ".stderr.log")

    env = dict(os.environ)
    env["MOVA_TRACE_FRAMES"] = str(out).replace("\\", "/")
    if options.blur is not None:
        env["MOVA_TRACE_BLUR"] = str(options.blur)
    if options.glass_skip:
        env["MOVA_TRACE_GLASS_SKIP"] = options.glass_skip
    if options.no_drive:
        env.pop("MOVA_TRACE_SCROLL", None)
    else:
        mode = ":roundtrip" if options.round_trip else ""
        env["MOVA_TRACE_SCROLL"] = (
            f"{DELAY_MS}:{options.duration}:{options.speed}{mode}"
        )

    wait = options.wait
    if wait is None:
        wait = 8 + (0 if options.no_drive else (DELAY_MS + options.duration) / 1000)
    print(f"启动 {app.name}：blur={options.blur if options.blur is not None else 'pref'}"
          f" glass_skip={options.glass_skip or '-'}"
          f" drive={'off' if options.no_drive else options.duration / 1000} "
          f"wait={wait:.0f}s → {out.name}")

    process = subprocess.Popen(
        [str(app)], cwd=str(app.parent), env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    watchdog = threading.Thread(
        target=_drain, args=(process, err_path), daemon=True,
    )
    watchdog.start()
    try:
        time.sleep(wait)
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()

    if not out.exists():
        print("BAD  没有生成日志：确认应用真的起来了（窗口是否被单实例挡掉）")
        return 1
    lines = out.read_text(encoding="utf-8", errors="replace").splitlines()
    frames = sum(1 for line in lines if line.startswith("FRAMES "))
    print(f"完成：{len(lines)} 行日志，其中 FRAMES {frames} 行；stderr → {err_path.name}")

    err = err_path.read_text(encoding="utf-8", errors="replace") if err_path.exists() else ""
    if "Unhandled Exception" in err:
        # 诊断自己抛异常会静默吞掉整段窗口记录（曾经如此），必须显式报出来。
        first = [ln for ln in err.splitlines() if "Unhandled Exception" in ln]
        print(f"BAD  应用里抛了未捕获异常：{first[0] if first else ''}")
        return 1
    if frames == 0:
        print("BAD  一个 FRAMES 窗口都没有：应用没渲染够 1 秒就被关了，或窗口没显示")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
