"""Probe: which end-file reason does 自动跳过 produce?

用户报「自动跳过会存在播放失败的情况」——播放器底栏出现
`播放失败 · 请更换资源`。那一行只有一条来路：`g_playback_error` 被置位，而它
只由 `kPlaybackInterrupted` 置位，后者只来自两种 end-file：

  * `reason == ERROR(4)`                    —— 源站/缓冲出错
  * `reason == EOF(0)` 但位置离片尾太远     —— 断流被 ffmpeg 报成 EOF

自动跳过自己有两条完全不同的跳法（见 `SkipSegment`）：

  * 片头 / 前情 / 预告 → `seek <end> absolute`（原地跳）
  * 片尾               → 有下一集就 `loadfile replace`，没有就 `seek duration`

所以这里分三个场景，把播放器的 stdout 原样收下来，看每一次跳转之后 mpv 到底
报了哪种 end-file：

  01_intro_seek     原地 seek，不该有任何 end-file
  02_credits_next   片尾 + 有下一集 → loadfile replace，看被替换掉的那一集报什么
  03_credits_last   片尾 + 最后一集 → seek 到片尾，看会不会被「假 EOF」判成中断

用法：
  python tool/probe_autoskip_endfile.py [--exe PATH] [--workdir DIR]
"""
import argparse
import os
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_native_panels as base  # noqa: E402

END_FILE_REASON = {
    0: "EOF",
    2: "STOP",
    3: "QUIT",
    4: "ERROR",
    5: "REDIRECT",
}

CREDITS = "MOVA_SEGMENT=credits|100|118|probe"
INTRO = "MOVA_SEGMENT=intro|10|40|probe"
# 来源数据很脏：片段的结束点跑到总时长之外。公共库给出的片头时间点偶尔会大于
# 实际时长（拿错版本、时长字段按另一版算），照跳就会 seek 到文件之外。
INTRO_PAST_END = "MOVA_SEGMENT=intro|10|300|probe"
# 两个来源各报了一条片头，覆盖同一段时间：跳过一条之后另一条仍然命中。
TWO_INTROS = "MOVA_SEGMENT=intro|10|40|probe"
TWO_INTROS_B = "MOVA_SEGMENT=intro|10|40|other"


class Probe:
    """One player run; collects everything it prints, with timestamps.

    Both stdout (our own MOVA_* protocol lines) and stderr (mpv's terminal,
    where `--term-status-msg` lands) are captured: to tell "the origin really
    broke" apart from "our own seek/loadfile interrupted the file" you need the
    mpv-side error text as well as the position).
    """

    def __init__(self, exe, workdir, media_paths, args, status=False):
        argv = [
            exe,
            "--config=no", "--force-window=yes", "--keep-open=no",
            "--vo=gpu-next", "--gpu-api=d3d11", "--gpu-context=d3d11",
            "--osc=no", "--hwdec=no", "--terminal=yes", "--msg-level=all=warn,statusline=status",
            "--force-media-title=自动跳过探针",
        ]
        if status:
            argv.append("--term-status-msg=[POS]${time-pos}|${duration}"
                        "|${playlist-pos}")
        # 每个 mpv 条目对应一个真实的输入文件：播放列表索引只有在对得上条目时
        # 才有意义（换集走的是 loadfile，索引由原生侧自己维护）。
        argv += args + list(media_paths)
        self.lines = []
        self.start = time.time()
        self.process = subprocess.Popen(
            argv, cwd=workdir, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, bufsize=1, text=True, encoding="utf-8",
            errors="replace")
        self.argv = argv
        for stream in (self.process.stdout, self.process.stderr):
            threading.Thread(target=self._pump, args=(stream,), daemon=True).start()

    def _pump(self, stream):
        for line in stream:
            self.lines.append((time.time() - self.start, line.rstrip("\r\n")))

    def send(self, line):
        try:
            self.process.stdin.write(line + "\n")
            self.process.stdin.flush()
        except (BrokenPipeError, ValueError):
            pass

    def text_lines(self):
        return [line for _, line in self.lines]

    def end_files(self):
        """Every end-file mpv reported, in order, as (reason, index, detail)."""
        found = []
        for line in self.text_lines():
            if line.startswith("MOVA_ENDFILE="):
                payload = line.split("=", 1)[1]
                head, _, detail = payload.partition("|")
                reason, _, index = head.partition("|")
                try:
                    code = int(reason)
                except ValueError:
                    continue
                found.append((code, END_FILE_REASON.get(code, "?"),
                              index.strip(), detail.strip()))
        return found

    def positions(self):
        found = []
        for line in self.text_lines():
            if line.startswith("[POS]"):
                found.append(line[5:])
        return found

    def tail(self, count=24, keep=lambda line: True):
        """The last `count` lines that pass `keep`, with timestamps."""
        picked = [(stamp, line) for stamp, line in self.lines if keep(line)]
        return [f"      +{stamp:6.2f}s  {line}" for stamp, line in picked[-count:]]

    def timeline(self, around=6):
        """The last `around` lines before and after each end-file, timestamped."""
        interesting = []
        indexes = [i for i, (_, line) in enumerate(self.lines)
                   if line.startswith("MOVA_ENDFILE=")]
        for index in indexes:
            low = max(0, index - around)
            high = min(len(self.lines), index + around + 1)
            for stamp, line in self.lines[low:high]:
                interesting.append(f"      +{stamp:6.2f}s  {line}")
            interesting.append("      ----")
        return interesting

    def close(self):
        try:
            base.user32.PostMessageW(
                base.wait_class("MovaNativePlayerWindow", timeout=2.0)
                or 0, base.WM_CLOSE, 0, 0)
        except Exception:  # noqa: BLE001
            pass
        try:
            return self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            return "KILLED"


def scene_segments(player, segments):
    time.sleep(1.5)
    for segment in segments:
        player.send(segment)
    player.send("MOVA_SEGMENTS_DONE=1")


def run_case(exe, workdir, media_paths, name, args, segments, wait,
             expect_no_error, status=True):
    out = [f"=== {name} ==="]
    player = Probe(exe, workdir, media_paths, args, status=status)
    ok = True
    try:
        scene_segments(player, segments)
        time.sleep(wait)
        out.append(f"    watched {wait:.0f}s after the segments arrived")
        ends = player.end_files()
        if ends:
            for code, label, index, detail in ends:
                out.append(f"    MOVA_ENDFILE reason={code} ({label}) "
                           f"index={index} {detail}")
        else:
            out.append("    MOVA_ENDFILE: none")
        for line in player.text_lines():
            if line.startswith("MOVA_SUSPECT_EOF"):
                out.append(f"    {line}   <- 假 EOF 判成播放中断")
            elif line.startswith("MOVA_COMPLETED"):
                out.append(f"    {line}")
        tail = player.positions()[-4:]
        out.append(f"    status tail: {tail}")
        out.append("    timeline around each end-file:")
        out += player.timeline(around=4)
        # 一行 end-file 都没有的时候（换集之后 mpv 甚至可能什么都不报）光看
        # timeline 全是空的，所以再留一段原始尾部：MOVA_* 与状态行都带出来。
        out.append("    raw tail (MOVA_* + status):")
        out += player.tail(20, keep=lambda line: line.startswith("MOVA_")
                           or "POS]" in line)
        errors = [item for item in ends if item[0] == 4]
        suspect = any(line.startswith("MOVA_SUSPECT_EOF")
                      for line in player.text_lines())
        bad = bool(errors) or suspect
        if expect_no_error:
            out.append("    VERDICT " + (
                "OK  no end-file error from the skip"
                if not bad else
                "BAD auto-skip produced a playback failure"))
            ok = not bad
        else:
            out.append("    VERDICT " + (
                "OK  reproduced: the skip reports" +
                (" reason=ERROR" if errors else " a suspect EOF")
                if bad else "BAD expected an error, none seen"))
            ok = bad
    finally:
        out.append(f"    exit code = {player.close()}")
    return "\n".join(out), ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", default=r"D:\Mova\MovaNativePlayer.exe")
    parser.add_argument("--workdir", default=r"D:\Mova")
    parser.add_argument("--only", default="")
    options = parser.parse_args()

    out_dir = os.path.join(os.environ["TEMP"], "mova_autoskip_probe")
    os.makedirs(out_dir, exist_ok=True)
    media = os.path.join(out_dir, "silence120.wav")
    if not os.path.exists(media):
        base.make_wav(media, seconds=120.0)

    shared = ["--mova-auto-skip-segments=yes", "--mova-skip-delay-seconds=1"]
    episode_titles = ["--mova-playlist-title=第1集"]
    cases = [
        # 片头：原地 seek 到片段结束点。这里不该有任何 end-file。
        ("01_intro_seek",
         shared + episode_titles + ["--start=12"],
         [INTRO], 4.0, True, True),
        # 片尾 + 有下一集：loadfile replace 换集，被替换掉的那一集要报什么原因？
        ("02_credits_next",
         shared + episode_titles + ["--mova-playlist-title=第2集",
                                    "--start=101"],
         [CREDITS], 8.0, True, True),
        # 片尾 + 最后一集：没有下一集，代码会 seek 到总时长，让「播完」按 EOF 处理。
        # 如果位置校验把这次主动 seek 当成断流，就会误报「播放失败」。
        ("03_credits_last",
         shared + episode_titles + ["--start=101"],
         [CREDITS], 8.0, True, True),
        # 片头片段的结束点超出总时长：seek 到文件之外，mpv 会立刻报 EOF。
        ("04_intro_past_end",
         shared + episode_titles + ["--start=12"],
         [INTRO_PAST_END], 6.0, True, True),
        # 两个来源报了同一段片头：跳过一条后另一条仍命中，会在 1 秒内跳第二次。
        ("05_two_intros",
         shared + episode_titles + ["--start=12"],
         [TWO_INTROS, TWO_INTROS_B], 6.0, True, True),
    ]
    if options.only:
        wanted = [part.strip() for part in options.only.split(",") if part.strip()]
        cases = [case for case in cases
                 if any(part in case[0] for part in wanted)]

    blocks = []
    results = []
    for name, args, segments, wait, expect_no_error, status in cases:
        # 几集就给几个真实文件：mpv 的条目数要与下发的集数一致。
        # 注意用 startswith 而不是 list.count()：标题是 "=第1集" 这种带后缀的，
        # count 要求完全相等，会数成 0，于是换集路径永远走不到（踩过一次）。
        episodes = max(1, sum(1 for arg in args
                              if arg.startswith("--mova-playlist-title=")))
        text, ok = run_case(options.exe, options.workdir, [media] * episodes,
                            name, args, segments, wait, expect_no_error, status)
        blocks.append(text)
        results.append((name, ok))
        print(text, flush=True)

    summary = ["", "=== summary ==="]
    summary += [f"    {'OK ' if ok else 'BAD'} {name}" for name, ok in results]
    print("\n".join(summary), flush=True)
    return 0 if all(ok for _, ok in results) else 1


if __name__ == "__main__":
    sys.exit(main())
