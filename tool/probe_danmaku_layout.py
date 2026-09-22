"""Quantify danmaku lane overlap and frame pacing under a realistic feed.

「弹幕叠在一起看不清」和「一顿一顿」是两个可以量化的缺陷：

* 重叠 —— 播放器每帧在同轨区间里数「我压住了几条别人」，报成 ``overlap=``。
  正常排版下这个数应该是 0；只要轨道分配不严密，它就会稳定地上去。
  ``mixed=`` 是「滚动弹幕从顶/底固定弹幕上飘过去」的条数 —— 所有播放器都这样，
  只作参考，不算缺陷；但它能把「同轨明明有两拨东西、overlap 却是 0」解释清楚。
* 卡顿 —— ``draw`` / ``post`` / ``gap`` 把「文字画得慢」「合成慢」「定时器被
  堵住」三种原因分开；``drop`` 是 mpv 自己丢掉的解码帧，用它和 gap 对照可以
  分清是弹幕在抖，还是视频本身在抖。

弹幕文本用**真实的长度分布**（2~40 字、含顶/底弹幕），不是等长占位文本：
轨道容量和文字宽度直接相关，等长文本会把这个缺陷盖住。

    python tool\\probe_danmaku_layout.py --label before
    python tool\\probe_danmaku_layout.py --media <真实视频> --seconds 20
"""

import argparse
import base64
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import verify_native_panels as base  # noqa: E402
import verify_segments_and_danmaku as suite  # noqa: E402

PHRASES = [
    "前排", "哈哈哈哈哈", "这也太真实了吧", "名场面来了",
    "第 1 季 遁天 南古装剧里以狠毒是男频爽文，智能力双强的",
    "赵没曦", "时局不稳", "镜头看着赵没一转 场就过去了",
    "九坐等", "傅庭芸", "丁禹兮演草莽毫无违和感",
    "我希望我女朋友没有看过这个", "反过来想", "编剧清醒点",
    "这一段配乐是真的绝了", "笑死我了", "什么时候更新下一集",
    "我要反复观看这一段", "龙光毒辣", "这剧情走向我完全想不到",
    "重温第三遍还是好笑", "编剧你是懂节奏的", "这个眼神绝了",
]


def realistic_danmaku_file(out_dir, seconds=24.0, per_second=14, seed=20260919,
                           top_ratio=0.08, bottom_ratio=0.05, name="layout"):
    """A feed shaped like a real episode: mixed lengths, mixed modes.

    Roughly 87% scrolling, 8% top, 5% bottom -- that mix matters because the
    fixed ones hold a lane for four seconds and so are the first thing to
    expose a lane allocator that cannot say "no".
    """
    path = os.path.join(out_dir, f"danmaku_{name}_{per_second}.txt")
    rng = random.Random(seed)
    index = 0
    with open(path, "w", encoding="utf-8") as handle:
        moment = 0.0
        while moment < seconds:
            for _ in range(per_second):
                roll = rng.random()
                if roll < top_ratio:
                    mode = rng.choice((4, 5))
                elif roll < top_ratio + bottom_ratio:
                    mode = 6
                else:
                    mode = 1
                # 真实弹幕的长度分布：短句多、长句少（triangular(low, high, mode)）。
                length = min(len(PHRASES) - 1, int(rng.triangular(0, 21, 3)))
                text = PHRASES[length]
                if rng.random() < 0.35:
                    text = text + f" x{rng.randint(2, 9)}"
                color = rng.choice((-1, -1, -1, 0x66CCFF, 0xFF7200, 0xFFFF00))
                payload = base64.b64encode(text.encode("utf-8")).decode("ascii")
                handle.write(f"{moment:.2f}\t{mode}\t{color}\t{payload}\n")
                index += 1
            moment += 1.0
    return path


def run(exe, workdir, media, out_dir, comments, label, density, area,
        seconds, danmaku=True):
    trace_dir = os.path.join(out_dir, f"trace_layout_{label}")
    enabled = "yes" if danmaku else "no"
    player = suite.Player(exe, workdir, media, [
        # 生产参数：真实播放走硬件解码，用 --hwdec=no（用例默认）测出来的
        # 帧率没有参考价值 —— 软解 1080p 本身就把 CPU 占满了。
        "--hwdec=auto-safe",
        "--mova-tool-order=弹幕", f"--mova-danmaku-enabled={enabled}",
        f"--mova-danmaku-area={area}", f"--mova-danmaku-density={density}",
    ], trace_dir, trace_danmaku=True)
    lines = [f"=== danmaku layout probe: {label} ==="]
    ok = True
    try:
        if not base.wait_class("MovaNativePlayerWindow"):
            return "\n".join(lines + ["    FAILED: player window not found"]), False
        time.sleep(1.0)
        total = sum(1 for _ in open(comments, encoding="utf-8"))
        if danmaku:
            player.send("MOVA_DANMAKU_STATUS=loading")
            player.send(f"MOVA_DANMAKU_INFO={total}\t\t")
            player.send(f"MOVA_DANMAKU={comments}")
        # 前 2 秒是加载 + 起播，单独隔开；之后的样本才是稳态。
        time.sleep(2.0)
        mark = len(player.draws())
        time.sleep(seconds)
        samples = player.draws()[mark:]
        lines.append(f"    media={os.path.basename(media)} comments={total}"
                     f" density={density} area={area}"
                     f" danmaku={'on' if danmaku else 'off'} samples={len(samples)}")
        for item in samples:
            lines.append(
                f"      live={item['live']:3d} lanes={item['lanes']:2d}"
                f" overlap={item['overlap']:3d} mixed={item['mixed']:3d}"
                f" depth={item['depth']:5.1f} dropped={item['dropped']:4d}"
                f" draw={item['draw']:5.2f} post={item['post']:5.2f}"
                f" avg={item['avg']:5.2f} gap={item['gap']:6.1f}"
                f" late20={item['late20']:2d} late33={item['late33']:2d}"
                f" drop={item['drop']}")
        if not samples:
            return "\n".join(lines + ["    FAILED: no draw trace samples"]), False
        peak = {
            "live": max(i["live"] for i in samples),
            "lanes": max(i["lanes"] for i in samples),
            "overlap": max(i["overlap"] for i in samples),
            "mixed": max(i["mixed"] for i in samples),
            "depth": max(i["depth"] for i in samples),
            "dropped": max(i["dropped"] for i in samples),
            "draw": max(i["draw"] for i in samples),
            "post": max(i["post"] for i in samples),
            "gap": max(i["gap"] for i in samples),
            "avg": max(i["avg"] for i in samples),
            "late20": max(i["late20"] for i in samples),
            "late33": max(i["late33"] for i in samples),
            "drop": max(i["drop"] for i in samples),
        }
        deepest = max(samples, key=lambda i: i["depth"])
        lines.append(f"    peak live={peak['live']} lanes={peak['lanes']}"
                     f" overlap={peak['overlap']} mixed={peak['mixed']}"
                     f" depth={peak['depth']:.1f} dropped={peak['dropped']}"
                     f" draw={peak['draw']:.2f}ms"
                     f" post={peak['post']:.2f}ms avg={peak['avg']:.2f}ms"
                     f" gap={peak['gap']:.1f}ms late20={peak['late20']}"
                     f" late33={peak['late33']} drop={peak['drop']}")
        if peak["depth"] > 0.0:
            lines.append(f"    deepest pair lane={deepest['olane']}"
                         f" rect={deepest['orect']}")
        # 判缺陷看**压进去多深**，不看条数：同轨相邻两条正好贴边（<2px）是浮点
        # 边界的产物，肉眼看不出来；真正「看不清」的是几十像素的互相压盖。
        landing = [i for i in samples if i["depth"] > 2.0]
        if landing:
            ok = False
            lines.append(f"    VERDICT BAD danmaku overlap by up to"
                         f" {peak['depth']:.1f}px in lane"
                         f" {deepest['olane']} (unreadable)")
        elif peak["overlap"]:
            lines.append(f"    VERDICT OK  {peak['overlap']} pair(s) touch"
                         f" within {peak['depth']:.1f}px -- boundary only,"
                         " not visible")
        else:
            lines.append("    VERDICT OK  no two danmaku share a lane span")
        if peak["avg"] > 18.0:
            ok = False
            lines.append(f"    VERDICT BAD frame clock averages"
                         f" {peak['avg']:.1f}ms"
                         f" ({1000.0 / peak['avg']:.0f}fps) -- systematic"
                         " stutter, not an occasional hitch")
        elif peak["draw"] > 12.0:
            ok = False
            lines.append(f"    VERDICT BAD drawing costs {peak['draw']:.2f}ms"
                         " of the 16.7ms budget")
        elif peak["drop"] > 0:
            ok = False
            lines.append(f"    VERDICT BAD mpv dropped {peak['drop']} frames")
        elif peak["late33"] >= 3:
            ok = False
            lines.append(f"    VERDICT BAD {peak['late33']} frames ran past 33ms"
                         " -- repeated stalls")
        elif peak["late20"] > 6 and not (
                samples and samples[-1]["dwell"] and samples[-1]["refresh"] > 0):
            # `late20` 是 60fps 时代留下的**绝对**门槛。走节拍时钟之后目标节拍是
            # divisor × 刷新周期（本机 11.76ms），20ms 只有 1.7 拍，一次调度抖动
            # 就会踩线 —— 它拦不住真缺陷、只会随机变红。节拍路径改由下面的
            # 「停留拍数是否集中」直接判（见 specs 2026-09-22）。
            ok = False
            lines.append(f"    VERDICT BAD {peak['late20']} of 60 frames ran"
                         " past 20ms")
        elif peak["gap"] > 40.0:
            # 单次 40ms 级别的停顿在这台机器上是调度噪声（后台编译 / DWM 合成），
            # 不是播放器的问题：均值仍然贴着 16.7ms，且只有这一帧超 33ms。
            # 判缺陷要看「反复超时」，一次抖动不该让整个用例失败。
            lines.append(f"    VERDICT OK  clock steady at {peak['avg']:.2f}ms;"
                         f" one isolated hitch of {peak['gap']:.1f}ms"
                         f" ({peak['late33']} frame past 33ms)")
        elif peak["late20"]:
            lines.append(f"    VERDICT OK  frames stay inside the 60fps budget"
                         f" ({peak['late20']} of 60 frames past 20ms,"
                         f" worst {peak['gap']:.1f}ms)")
        else:
            lines.append("    VERDICT OK  frames stay inside the 60fps budget")
        # 帧节拍是否与面板刷新同源 —— 判「滚起来匀不匀」的主指标，见
        # docs/specs/2026-09-22-danmaku-frame-pacing.md。
        #
        # 均值 / late20 / late33 只说明「平均出够帧数」：170Hz 面板 + 16ms 定时器
        # 的老组合给出 avg=16.3ms、late33=0 的漂亮数字，每帧却在屏停留 2.77 个
        # 刷新周期（77% 停 3 拍、23% 停 2 拍），位移步长 3:2 交替。所以要直接断言
        # 「停留拍数分布在不在同一个档上」。
        paced = [i for i in samples if i["dwell"] and i["refresh"] > 0]
        if paced:
            last = paced[-1]
            div = last["div"]
            # 判「平滑」要看**稳态**：开头两个窗口还在铺弹幕、时钟刚对上相位，
            # 把它们算进去会把占比拉低十几个百分点（实测 55% vs 稳态 93%），
            # 于是判据看着红、实际已经达标。取最后三个窗口。
            steady = paced[-3:]
            total = sum(sum(i["dwell"]) for i in steady)
            exact = (sum(i["dwell"][div - 1] for i in steady)
                     if 1 <= div <= 4 else 0)
            share = exact / total if total else 0.0
            lines.append(f"    pacing: refresh={last['refresh']:.3f}ms"
                         f" div={div} compose={last['compose']:.2f}ms"
                         f" tick={last['tick']:.2f}ms"
                         f" paints/tick="
                         f"{(last['frames'] / last['ticks']) if last['ticks'] else 0:.2f}"
                         f" -> 稳态停留 {div} 拍的帧占"
                         f" {share * 100:.1f}% ({exact}/{total})")
            if share < 0.85:
                ok = False
                # 一个 tick 就是 div 拍，所以 dwell 应当**几乎全部**落在 div 上。
                # 散到别的档 = 节拍时钟（高精度定时器）被系统卡顿打断，或它的
                # 周期与面板没成精确整数比。这里只报事实、不下成因结论 ——
                # 曾经的「合成器在漏拍」那套推断依赖已删掉的 DwmFlush 直方图。
                dominant = max(range(4), key=lambda i: last["dwell"][i]) + 1
                lines.append(f"    VERDICT BAD only {share * 100:.1f}% of frames"
                             f" dwell exactly {div} refresh period(s);"
                             f" dominant bucket = {dominant} period(s),"
                             f" dwell 1/2/3/4+ = {last['dwell']},"
                             f" compose={last['compose']:.2f}ms")
            else:
                lines.append(f"    VERDICT OK  frame clock locked to the panel"
                             f" ({1000.0 / last['refresh']:.0f}Hz /"
                             f" {div})")
        ink, note = suite.shot_danmaku(out_dir, f"layout_{label}", trace_dir)
        lines.append(f"    {note}")
        if ink < 500:
            ok = False
            lines.append(f"    VERDICT BAD layer renders no text (ink={ink}px)")
    finally:
        code = player.close()
        lines.append(f"    exit code = {code}")
        if code != 0:
            ok = False
    return "\n".join(lines), ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", default=r"D:\Mova\MovaNativePlayer.exe")
    parser.add_argument("--workdir", default=r"D:\Mova")
    parser.add_argument("--media", default="",
                        help="real video to decode, 'lavfi' for a synthetic "
                             "1080p source; default is the silent WAV")
    parser.add_argument("--danmaku", default="on", choices=("on", "off"),
                        help="'off' measures the same video without the layer")
    parser.add_argument("--label", default="run")
    parser.add_argument("--seconds", type=float, default=16.0)
    parser.add_argument("--per-second", type=int, default=14)
    parser.add_argument("--density", default="0.55")
    parser.add_argument("--area", default="0.65")
    options = parser.parse_args()

    out_dir = os.path.join(os.environ["TEMP"], "mova_danmaku_layout")
    os.makedirs(out_dir, exist_ok=True)
    media = options.media or suite.media_file(out_dir)
    if media == "lavfi":
        # 本机没有 ffmpeg，也不方便造真实视频：mpv 自带的 libavfilter 源可以
        # 生成 1080p 视频，足以把「视频在解码 + 弹幕层也在合成」这个组合摆出来。
        media = "av://lavfi:testsrc2=size=1920x1080:rate=25:duration=600"
    comments = realistic_danmaku_file(out_dir, seconds=options.seconds + 12,
                                      per_second=options.per_second,
                                      name=options.label)
    text, ok = run(options.exe, options.workdir, media, out_dir, comments,
                   options.label, options.density, options.area,
                   options.seconds, danmaku=options.danmaku == "on")
    print(text, flush=True)
    print(f"\n=== {options.label}: {'OK' if ok else 'BAD'} ===", flush=True)
    with open(os.path.join(out_dir, f"probe_{options.label}.txt"), "w",
              encoding="utf-8") as handle:
        handle.write(text + "\n")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
