"""Probe: does a跳转之后的源站抖动 still end in 「播放失败 · 请更换资源」?

用户报「自动跳过会存在播放失败的情况」。先把自动跳过自己的机制排掉
（`tool/probe_autoskip_endfile.py`：三种跳法 + 两种脏数据，mpv 都只报干净的
EOF，没有 ERROR），所以那行提示只能来自「mpv 在跳转那一刻把文件结束了」——
自动跳片头/片尾会让播放器去要一段**新的字节区间**（新建连接），撞上源站抖动的
概率比顺放时高得多。

这里把那一次抖动造出来：本机起一个假的源站，第一次遇到「起点不为 0 的 Range
请求」（=自动跳过触发的那次跳转）就回 500。然后看播放器怎么办：

  * 修复前：mpv 收到错误码 → end-file → 播放器举手投降 → 底栏「播放失败」
  * 修复后：同一集补一次 + 退回中断前的位置 → 播放继续，只有一次轻微卡顿

断言：出现 `MOVA_RETRY`，且之后播放位置继续往前爬、不再有第二次错误 end-file。

用法：
  python tool/probe_interrupt_retry.py [--exe PATH] [--workdir DIR]
"""
import argparse
import ctypes
import os
import re
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_autoskip_endfile as autoskip  # noqa: E402

# 用「现算的静音 WAV」当源：一小时的 8kHz 单声道等于 57MB，够大，mpv 不可能
# 一次读完整份，所以跳转一定会真的再发一次 HTTP 请求。静音也让生成成本为零。
#
# `FakeOrigin(seconds=...)` 可以给单个实例换时长 —— 「换集」那类用例需要一集
# 短到能自己播完（自动连播下一集），另一集长到能读出起播位置。默认仍是 3600s，
# 既有用例的字节偏移（fault_start=400_000）不受影响。
SAMPLE_RATE = 8000
SECONDS = 3600.0
DATA_BYTES = int(SAMPLE_RATE * SECONDS) * 2
TOTAL_BYTES = 44 + DATA_BYTES


def wav_header(total_data):
    byte_rate = SAMPLE_RATE * 2
    return (
        b"RIFF" + (36 + total_data).to_bytes(4, "little") + b"WAVE"
        + b"fmt " + (16).to_bytes(4, "little")
        + (1).to_bytes(2, "little")      # PCM
        + (1).to_bytes(2, "little")      # mono
        + SAMPLE_RATE.to_bytes(4, "little")
        + byte_rate.to_bytes(4, "little")
        + (2).to_bytes(2, "little")      # block align
        + (16).to_bytes(2, "little")     # bits per sample
        + b"data" + total_data.to_bytes(4, "little")
    )


class FakeOrigin:
    """Ranges over a virtual silent WAV, with one injected 500.

    `fault_start`: 第一个「起点超过这个字节偏移」的请求会被打回 500（只打一次）。
    默认值落在片头结束点之后，也就是自动跳过刚跳过去的那一刻。
    """

    def __init__(self, fault_start=None, status=500, fault_count=1,
                 seconds=SECONDS):
        self.socket = socket.socket()
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind(("127.0.0.1", 0))
        self.socket.listen(8)
        self.port = self.socket.getsockname()[1]
        # 每实例时长：换集类用例要一集短（自己播完触发连播）、一集长。
        self.seconds = seconds
        self.data_bytes = int(SAMPLE_RATE * seconds) * 2
        self.total_bytes = 44 + self.data_bytes
        self.fault_start = fault_start
        self.status = status
        # 注入几次故障。默认一次 = 自动重试那一次；给 2 次就能把自动重试也吃掉，
        # 逼出「播放失败」状态 —— 02 用例要复现的正是那个现场。
        #
        # 为什么两次都落在 start > fault_start 上：第二次请求来自「自动重试之后
        # 补回位置的那次 seek」，不是重开文件本身的那次（那次是 start=0）。
        self.fault_count = fault_count
        self.faults = 0
        self.requests = []
        self.running = True
        threading.Thread(target=self._serve, daemon=True).start()

    @property
    def faulted(self):
        return self.faults > 0

    @property
    def url(self):
        return f"http://127.0.0.1:{self.port}/media.wav"

    def _serve(self):
        while self.running:
            try:
                connection, _ = self.socket.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(connection,),
                             daemon=True).start()

    def _handle(self, connection):
        try:
            request = connection.recv(4096).decode("latin-1")
        except OSError:
            connection.close()
            return
        start, end = 0, self.total_bytes - 1
        match = re.search(r"Range:\s*bytes=(\d+)-(\d*)", request, re.I)
        if match:
            start = int(match.group(1))
            if match.group(2):
                end = int(match.group(2))
        end = min(end, self.total_bytes - 1)
        self.requests.append(start)
        fault = (self.fault_start is not None
                 and self.faults < self.fault_count
                 and start > self.fault_start)
        if fault:
            self.faults += 1
            body = f"injected failure #{len(self.requests)}".encode()
            connection.sendall(
                f"HTTP/1.1 {self.status} Injected\r\n"
                f"Content-Length: {len(body)}\r\n"
                "Connection: close\r\n\r\n".encode() + body)
            connection.close()
            return
        length = end - start + 1
        connection.sendall(
            f"HTTP/1.1 206 Partial Content\r\n"
            f"Content-Type: audio/wav\r\n"
            f"Accept-Ranges: bytes\r\n"
            f"Content-Range: bytes {start}-{end}/{self.total_bytes}\r\n"
            f"Content-Length: {length}\r\n"
            "Connection: close\r\n\r\n".encode())
        header = wav_header(self.data_bytes)
        sent = 0
        try:
            while sent < length:
                chunk = min(512 * 1024, length - sent)
                offset = start + sent
                if offset < len(header):
                    chunk = min(chunk, len(header) - offset)
                    connection.sendall(header[offset:offset + chunk])
                else:
                    connection.sendall(bytes(chunk))
                sent += chunk
        except OSError:
            pass
        connection.close()

    def close(self):
        self.running = False
        try:
            self.socket.close()
        except OSError:
            pass


def run_case(exe, workdir, name, fault=True, wait=14.0):
    out = [f"=== {name} ==="]
    # 片头 [10,40]：自动跳过会 seek 到 40s，也就是 640000 字节附近。
    origin = FakeOrigin(fault_start=400_000 if fault else None)
    player = autoskip.Probe(
        exe, workdir, [origin.url],
        ["--mova-auto-skip-segments=yes", "--mova-skip-delay-seconds=1",
         "--mova-playlist-title=第1集", "--start=12",
         # 逼着 mpv 每次跳转都重新发 HTTP 请求：不然整份文件都被读进 demuxer
         # 缓存里，注入的故障永远触发不到。
         "--cache=no", "--demuxer-readahead-secs=1",
         "--demuxer-max-bytes=2MiB"],
        status=True)
    ok = True
    try:
        time.sleep(1.5)
        player.send(autoskip.INTRO)
        player.send("MOVA_SEGMENTS_DONE=1")
        time.sleep(wait)
        text = player.text_lines()
        injected = origin.faulted
        out.append(f"    injected a {origin.status} on a seek past "
                   f"{400_000} bytes: {injected}")
        out.append(f"    range requests seen: {origin.requests[:8]}"
                   f"{' …' if len(origin.requests) > 8 else ''}")
        ends = player.end_files()
        for code, label, index, detail in ends:
            out.append(f"    MOVA_ENDFILE reason={code} ({label}) {detail}")
        for line in text:
            if line.startswith("MOVA_RETRY"):
                out.append(f"    {line}")
            elif line.startswith("MOVA_SUSPECT_EOF"):
                out.append(f"    {line}")
        # 位置用播放器自己的 MOVA_POSITION（它每秒吐好几次），不要指望 mpv 的
        # --term-status-msg：原生侧把它排除在 SetOption 之外，那条状态行根本不会
        # 存在（第一版探针就盯错了标记，断言永远是 False）。
        streams = [(stamp, line) for stamp, line in player.lines
                   if line.startswith("MOVA_POSITION=")]
        positions = [line.split("=", 1)[1] for _, line in streams]
        out.append("    timeline:")
        out += [f"      +{stamp:6.2f}s  pos={line.split('=', 1)[1]}"
                for stamp, line in streams[-14:]]
        if not injected:
            ok = False
            out.append("    VERDICT BAD the fault was never injected — "
                       "mpv never asked for a new range")
        else:
            retried = any(line.startswith("MOVA_RETRY") for line in text)
            errors = [item for item in ends if item[0] == 4]
            # 跳转之后位置必须继续往前走（说明播放还在继续）。
            tail_values = []
            for line in positions[-6:]:
                try:
                    tail_values.append(float(line.split("|")[0]))
                except (IndexError, ValueError):
                    continue
            moved = bool(tail_values) and tail_values[-1] > 42.0
            out.append(f"    retried={retried} error_end_files={len(errors)}"
                       f" position_moved={moved}")
            if retried and moved and not errors:
                out.append("    VERDICT OK  抖动被一次重试吃掉，播放继续")
            else:
                ok = False
                out.append("    VERDICT BAD 抖动之后播放没有恢复"
                           "（正是「播放失败 · 请更换资源」那条路径）")
        if not positions:
            out.append("    (no status lines: --term-status-msg not honoured)")
    finally:
        out.append(f"    exit code = {player.close()}")
        origin.close()
    return "\n".join(out), ok


# ---- 02：自动重试也用尽之后，用户按下播放键能不能把这一集救回来 ---------------
#
# 与 01 只差一处：故障注入**两次**。第一次被自动重试吃掉，第二次把自动重试也吃掉，
# 播放器于是进入 g_playback_error —— 控件条左下出现红字「播放失败」。从前到了这
# 一步就只剩换集或者退出播放页重进：mpv 已经是 idle，播放键发的 `cycle pause`
# 是空操作（这就是用户报的「播放失败就无法恢复」）。修好之后播放键 / 空格 / 左下
# 那颗「重新播放」胶囊都应该能把同一集重开，并从最后一次有效位置接上。
WM_KEYDOWN = 0x0100
WM_LBUTTONDOWN = 0x0201
MK_LBUTTON = 0x0001
VK_SPACE = 0x20
# 控件条设计稿高 140；拿真实客户区高反推 DPI 缩放，免得 150% 缩放下点空。
CONTROLS_DESIGN_HEIGHT = 140.0
PLAY_KEY_Y = 72.0


def _client_scale(controls):
    rect = autoskip.base.wt.RECT()
    if not autoskip.base.user32.GetClientRect(controls, ctypes.byref(rect)):
        return 1.0
    if rect.bottom <= 0:
        return 1.0
    return max(1.0, rect.bottom / CONTROLS_DESIGN_HEIGHT)


def _click_play_key():
    """点控件条中央的播放键（最贴近用户实际动作的恢复入口）。"""
    controls = autoskip.base.wait_class(
        "MovaNativePlayerControls", timeout=3.0)
    if not controls:
        return False
    rect = autoskip.base.wt.RECT()
    if not autoskip.base.user32.GetClientRect(controls, ctypes.byref(rect)):
        return False
    scale = _client_scale(controls)
    x = int(rect.right / 2)
    y = int(PLAY_KEY_Y * scale)
    autoskip.base.user32.PostMessageW(
        controls, WM_LBUTTONDOWN, MK_LBUTTON, (y << 16) | (x & 0xFFFF))
    return True


def _click_replay_capsule():
    """点左下那颗「重新播放」胶囊（命中区 x∈[20,152]，胶囊中心 115×67）。"""
    controls = autoskip.base.wait_class(
        "MovaNativePlayerControls", timeout=3.0)
    if not controls:
        return False
    rect = autoskip.base.wt.RECT()
    if not autoskip.base.user32.GetClientRect(controls, ctypes.byref(rect)):
        return False
    scale = _client_scale(controls)
    x = int(115.0 * scale)
    y = int(67.0 * scale)
    autoskip.base.user32.PostMessageW(
        controls, WM_LBUTTONDOWN, MK_LBUTTON, (y << 16) | (x & 0xFFFF))
    return True


def _press_space():
    main = autoskip.base.wait_class("MovaNativePlayerWindow", timeout=3.0)
    if not main:
        return False
    autoskip.base.user32.PostMessageW(main, WM_KEYDOWN, VK_SPACE, 0)
    return True


def _positions(player):
    values = []
    for _, line in player.lines:
        if line.startswith("MOVA_POSITION="):
            try:
                values.append(float(line.split("=", 1)[1].split("|")[0]))
            except ValueError:
                continue
    return values


def run_replay_case(exe, workdir, name, entry="play_key", wait=15.0):
    out = [f"=== {name} ==="]
    origin = FakeOrigin(fault_start=400_000, fault_count=2)
    player = autoskip.Probe(
        exe, workdir, [origin.url],
        ["--mova-auto-skip-segments=yes", "--mova-skip-delay-seconds=1",
         "--mova-playlist-title=第1集", "--start=12",
         "--cache=no", "--demuxer-readahead-secs=1",
         "--demuxer-max-bytes=2MiB"],
        status=True)
    ok = True
    try:
        time.sleep(1.5)
        player.send(autoskip.INTRO)
        player.send("MOVA_SEGMENTS_DONE=1")
        time.sleep(wait)
        ends = player.end_files()
        text = player.text_lines()
        retries = [line for line in text if line.startswith("MOVA_RETRY=")]
        failed = [line for line in text if line.startswith("MOVA_FAILED=")]
        out.append(f"    injected failures: {origin.faults}"
                   f" (asked for {origin.fault_count})")
        out.append(f"    range requests seen: {origin.requests[:8]}")
        for code, label, index, detail in ends:
            out.append(f"    MOVA_ENDFILE reason={code} ({label}) {detail}")
        out.append(f"    MOVA_RETRY x{len(retries)}   MOVA_FAILED x{len(failed)}")
        if not failed:
            ok = False
            out.append("    VERDICT BAD 没进入失败态 —— 本用例的前提是"
                       "「自动重试也用尽」，检查注入次数与 mpv 的请求时序")
        else:
            clicked = (_click_replay_capsule() if entry == "capsule"
                       else _click_play_key())
            time.sleep(5.0)
            replayed = [line for line in player.text_lines()
                        if line.startswith("MOVA_REPLAY=")]
            path = ("click_replay_capsule" if entry == "capsule"
                    else "click_play_key")
            if not replayed and clicked:
                _press_space()
                time.sleep(5.0)
                replayed = [line for line in player.text_lines()
                            if line.startswith("MOVA_REPLAY=")]
                path += " → space (点击未命中，退回快捷键)"
            values = _positions(player)
            last = values[-1] if values else None
            moved = bool(values) and values[-1] > 42.0
            out.append(f"    recovery via {path}: MOVA_REPLAY x{len(replayed)}"
                       f"  position_moved={moved}  last_pos={last}")
            if replayed and moved:
                out.append(f"    VERDICT OK  失败态的恢复入口可用（{path}）")
            else:
                ok = False
                out.append("    VERDICT BAD 失败态没有被恢复"
                           "（正是用户报的「播放失败之后无法恢复」）")
        out.append("    tail:")
        out += player.tail(10, keep=lambda line: line.startswith("MOVA_"))
    finally:
        out.append(f"    exit code = {player.close()}")
        origin.close()
    return "\n".join(out), ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", default=r"D:\Mova\MovaNativePlayer.exe")
    parser.add_argument("--workdir", default=r"D:\Mova")
    parser.add_argument("--only", default="")
    options = parser.parse_args()
    cases = [
        ("01_seek_interrupt_retry", run_case),
        ("02_replay_via_play_key", run_replay_case),
        ("03_replay_via_capsule",
         lambda exe, workdir, name: run_replay_case(
             exe, workdir, name, entry="capsule")),
    ]
    if options.only:
        cases = [case for case in cases if options.only in case[0]]
    blocks, results = [], []
    for name, runner in cases:
        text, ok = runner(options.exe, options.workdir, name)
        blocks.append(text)
        results.append((name, ok))
        print(text, flush=True)
    summary = ["", "=== summary ==="]
    summary += [f"    {'OK ' if ok else 'BAD'} {name}" for name, ok in results]
    print("\n".join(summary), flush=True)
    return 0 if all(ok for _, ok in results) else 1


if __name__ == "__main__":
    sys.exit(main())
