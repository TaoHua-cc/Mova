"""MOVA_DANMAKU_DRAW 诊断行的解析回归。

为什么单独给这行做个测试：这行是**可选字段一路嵌套**的长正则，每加一个字段都要
同时改正则与取值下标，改漏了不会报错、只会静静返回 `[]`。本轮就踩过一次 ——
`compose=` 插在 `flush=` 与 `dwell=` 之间没进正则，探针于是把**所有**帧节拍样本
都丢掉了，报告里只剩「没有 pacing 样本」，看起来像「环境拿不到刷新率」，实际是
解析器坏了。所以把历史各代真实行长都钉在这里。

跑：python tool/test_danmaku_trace_parser.py
"""

import sys

sys.path.insert(0, r"D:\codex\Mova\tool")

from verify_segments_and_danmaku import Player  # noqa: E402

# 各代真实行长共有的前缀（字段顺序按 main.cpp 里 PaintDanmaku 的打印顺序）。
PRE = ("MOVA_DANMAKU_DRAW=live=12 drawn=12 size=2560x1440 pos=42.10 "
       "draw=1.20 post=2.00 gap=14.00 frames=61 "
       "overlap=0 mixed=1 lanes=20 dropped=0 drop=0 "
       "depth=0.0 olane=-1 orect=0,0,0,0 "
       "avg=13.90 late20=0 late33=0 ")

# label -> (整行, 该行长应当解析出的关键字段)
CASES = [
    ("加节拍诊断之前", PRE.rstrip() + "|",
     {"refresh": 0.0, "div": 0, "dwell": [], "compose": 0.0}),
    # 注意：中途有一版短暂加过 `flush=../n` 与 `fhist=..`（用来定位 DwmFlush 的
    # 1/2 拍双峰）。那套字段随「改用固定周期节拍时钟」一起删掉了，解析器也不再
    # 认它 —— 它只存在于本轮的中间构建里，没有发布过，不值得为正则留复杂度。
    ("只有 refresh/div（没有 compose）",
     PRE + "refresh=5.882 div=2 dwell=0,55,5,0|",
     {"refresh": 5.882, "div": 2, "compose": 0.0, "dwell": [0, 55, 5, 0]}),
    ("当前节拍时钟版",
     PRE + "refresh=5.882 div=2 compose=5.88 dwell=2,57,1,0 tick=11.80/57|",
     {"refresh": 5.882, "div": 2, "compose": 5.88, "dwell": [2, 57, 1, 0],
      "tick": 11.80, "ticks": 57}),
    # 节拍诊断版：同一行末尾再挂 tickdwell / tkmax / ptph / ptjit / mw。
    # 这几个字段是为了分「定时器调度歪了」与「绘制被推迟了」两类根因才加的，
    # 少解析掉任何一个，两边的分布就对不上，会直接导向错误的修法。
    ("加了节拍分布与绘制相位",
     PRE + "refresh=5.882 div=2 compose=5.88 dwell=23,14,23,0 tick=11.76/60"
     " tickdwell=0,60,0,0 tkmax=12.31 ptph=0.42 ptjit=0.31 mw=0|",
     {"tickdwell": [0, 60, 0, 0], "tickmax": 12.31, "ptphase": 0.42,
      "ptjit": 0.31, "msgwakes": 0, "dwell": [23, 14, 23, 0]}),
]


def main():
    trace = Player.__new__(Player)
    trace.lines = [line for _, line, _ in CASES]
    samples = trace.draws()
    if len(samples) != len(CASES):
        print(f"FAIL parsed {len(samples)} of {len(CASES)} lines -- "
              f"某个字段没进正则，样本被整行丢掉了")
        return 1
    failures = 0
    for (label, _, expected), sample in zip(CASES, samples):
        wrong = {k: (sample[k], v) for k, v in expected.items()
                 if sample[k] != v}
        if wrong:
            failures += 1
            print(f"FAIL {label}: " + ", ".join(
                f"{k} 解析成 {got!r} 应为 {want!r}"
                for k, (got, want) in wrong.items()))
        else:
            print(f"ok   {label}")
    print("PASS" if not failures else f"{failures} case(s) failed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
