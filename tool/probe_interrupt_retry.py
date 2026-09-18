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

    def __init__(self, fault_start=None, status=500):
        self.socket = socket.socket()
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind(("127.0.0.1", 0))
        self.socket.listen(8)
        self.port = self.socket.getsockname()[1]
        self.fault_start = fault_start
        self.status = status
        self.faulted = False
        self.requests = []
        self.running = True
        threading.Thread(target=self._serve, daemon=True).start()

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
        start, end = 0, TOTAL_BYTES - 1
        match = re.search(r"Range:\s*bytes=(\d+)-(\d*)", request, re.I)
        if match:
            start = int(match.group(1))
            if match.group(2):
                end = int(match.group(2))
        end = min(end, TOTAL_BYTES - 1)
        self.requests.append(start)
        fault = (self.fault_start is not None and not self.faulted
                 and start > self.fault_start)
        if fault:
            self.faulted = True
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
            f"Content-Range: bytes {start}-{end}/{TOTAL_BYTES}\r\n"
            f"Content-Length: {length}\r\n"
            "Connection: close\r\n\r\n".encode())
        header = wav_header(DATA_BYTES)
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", default=r"D:\Mova\MovaNativePlayer.exe")
    parser.add_argument("--workdir", default=r"D:\Mova")
    parser.add_argument("--only", default="")
    options = parser.parse_args()
    cases = [("01_seek_interrupt_retry", run_case)]
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
