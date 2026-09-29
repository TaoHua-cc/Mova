"""Probe: 换集之后，新的这一集从哪儿开始播？

用户报「切换上下集时，没有正确根据上下集进度播放，都是从上一集的进度播放」。

根因候选：应用侧起播时把本集续播点交给 mpv 的 `--start=<秒>`，而 `--start` 是
**普通命令行选项**，不是文件局部选项。mpv 手册 Per-File Options 一节写得很直
白：「any option given on the command line usually affects all files」、
「（运行时改过的选项）are not reset when a new file is played」。原生换集走
`loadfile <url> replace`，于是 mpv 把**第 1 集的续播点又对第 2 集应用了一遍**
—— 每一集都从上一集的位置开始，正是用户看到的现象。

用例：
  01_next_episode_does_not_inherit_resume
    两集都从本机的假源站拉，第 1 集只做 20 秒、以 `--start=10` 起播（模拟续播
    到第 10 秒），于是它 10 秒后自己播完 —— 走的是与「下一集」按钮**完全相同**
    的换集路径（`kPlaylistAdvance` → `LoadPlaylistEntry`）。第 2 集没看过，就该
    从头播：

      BUG   第 2 集的读数从 10s 起（继承了第 1 集的 --start）
      修好后 第 2 集的读数从 0 起

    两集的时长差得足够远（20s / 3600s），而且原生 `EmitProgress` 的位置读数里
    自带集索引，所以「这条读数属于哪一集」是直接读出来的，不必靠时间窗口猜。

用法：
  python tool/probe_episode_switch_resume.py [--exe PATH] [--workdir DIR] [--only 01]
"""
import argparse
import ctypes
import os
import sys
import time
from urllib.parse import quote

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_autoskip_endfile as autoskip  # noqa: E402
import probe_interrupt_retry as retry  # noqa: E402

WM_LBUTTONDOWN = 0x0201
MK_LBUTTON = 0x0001
# 原生控件条使用 `kControlsHeight = 112` 设计单位；按它反推 UI 缩放。
CONTROLS_DESIGN_HEIGHT = 112.0
EPISODE_SWITCH_OFFSET_X = 141.0  # 上/下一集命中区的中心偏移
CONTROL_Y = 72.0
# 第 1 集起播点（= 上一次看到哪儿）。它不该跟着换集跑到第 2 集上去。
RESUME_SECONDS = 10.0
FIRST_EPISODE_SECONDS = 20.0
# 第 2 集的时长拿来做「这条读数是哪一集」的判别门槛。
LONG_EPISODE_SECONDS = 60.0
INHERIT_TOLERANCE = 5.0


def _position_readings(player):
    """(相对时间, 位置, 时长, 集索引) —— 取原生 `EmitProgress` 那一路。

    位置读数有两路可能的来源，实测只有一路能用：

      * mpv 的 `--term-status-msg`（2 段）—— **在管道下根本不输出**（它不是终端），
        所以探针里传了也拿不到；
      * 原生自己的 `EmitProgress`（3 段：`pos|duration|index`）—— 上一次状态变化
        就落一条（约 16 条/秒），而且多带一个集索引。

    集索引正好可以直接回答「这条读数属于哪一集」，比拿时长去猜干净得多。
    """
    found = []
    for stamp, line in player.lines:
        if not line.startswith("MOVA_POSITION="):
            continue
        fields = line.split("=", 1)[1].split("|")
        if len(fields) != 3:
            continue
        try:
            found.append((stamp, float(fields[0]), float(fields[1]),
                          int(fields[2])))
        except ValueError:
            continue
    return found


def _click_episode(direction):
    """点控件条上的上一集 / 下一集。

    ⚠️ 控件条命中判定用的是**设计坐标**：物理坐标除以 `UiScale()` 之后，宽度
    不足 780 的窗口走 compact 布局 —— 那时「上一集 / 下一集」根本不画，点击也
    没有分支接。探针主用例走自动连播（同一个 `LoadPlaylistEntry`），这条点击
    路径留作人工核对用。
    """
    controls = autoskip.base.wait_class(
        "MovaNativePlayerControls", timeout=3.0)
    if not controls:
        return False, "控件条窗口不存在"
    rect = autoskip.base.wt.RECT()
    if not autoskip.base.user32.GetClientRect(controls, ctypes.byref(rect)):
        return False, "读不到控件条尺寸"
    scale = max(1.0, rect.bottom / CONTROLS_DESIGN_HEIGHT) if rect.bottom else 1.0
    width = rect.right / scale
    offset = EPISODE_SWITCH_OFFSET_X * (1 if direction == "next" else -1)
    x = int(rect.right / 2 + offset * scale)
    y = int(CONTROL_Y * scale)
    note = (f"控件条 {rect.right}x{rect.bottom} 物理 / "
            f"{width:.0f} 设计，点击 ({x}, {y})")
    if width < 780:
        return False, note + " —— 窄窗走 compact 布局，「下一集」被收进更多菜单"
    if x >= rect.right:
        return False, note + " —— 命中区落在窗口外"
    autoskip.base.user32.PostMessageW(
        controls, WM_LBUTTONDOWN, MK_LBUTTON, (y << 16) | (x & 0xFFFF))
    return True, note


def run_case(exe, workdir, name, wait=30.0):
    first = retry.FakeOrigin(seconds=FIRST_EPISODE_SECONDS)
    second = retry.FakeOrigin()
    args = [
        # 两个都传：同一份探针要能同时跑在修复前 / 修复后的 exe 上。
        #   `--start=`        修复前的接口（mpv 的普通选项，换集时不重置 → 复现 bug）
        #   `--mova-start=`   修复后的接口（原生解析，每次 loadfile 前显式 set）
        # 修复后的 exe 会把不认识的 `--start` 转发给 mpv 当选项设一下，但原生在
        # 每次 loadfile 之前都会自己 set 一次 start —— 后者必然覆盖它，于是这条
        # 用例顺带验证了「显式设置一定赢过命令行残留」。
        f"--start={RESUME_SECONDS}",
        f"--mova-start={RESUME_SECONDS}",
        "--mova-playlist-start=0",
        "--mova-playlist-title=探针第 1 集",
        "--mova-playlist-title=探针第 2 集",
    ]
    player = autoskip.Probe(exe, workdir, [first.url, second.url], args)
    out = [f"=== {name} ==="]
    ok = True
    try:
        time.sleep(wait)
        readings = _position_readings(player)
        if not readings:
            return "\n".join(out + ["    没有任何位置读数",
                                    "    （原生 EmitProgress 没输出？）"]), False
        # 集索引是原生自己带的，直接按它分集。
        first_side = [item for item in readings
                      if item[3] == 0 and item[2] > 0]
        premise_ok = False
        if first_side:
            premise_ok = abs(first_side[0][1] - RESUME_SECONDS) <= 2.0
            out.append(f"    第 1 集 {FIRST_EPISODE_SECONDS:.0f}s，以起播点 "
                       f"{RESUME_SECONDS:.0f}s 播放；读数 {len(first_side)} 条，"
                       f"首 {first_side[0][1]:.2f}s（+{first_side[0][0]:.1f}s）"
                       f" → 末 {first_side[-1][1]:.2f}s"
                       f"（+{first_side[-1][0]:.1f}s）"
                       + ("" if premise_ok else "  ← 起播点没生效，前提不成立"))
        else:
            out.append("    第 1 集一条读数都没有")
        completed = [stamp for stamp, line in player.lines
                     if line.startswith("MOVA_COMPLETED=")]
        out.append("    MOVA_COMPLETED: "
                   + ("第 1 集播完，已自动连播" if completed else "没等到"))
        out.append(f"    第 1 集源站请求数 = {len(first.requests)}，"
                   f"第 2 集源站请求数 = {len(second.requests)}")
        second_side = [item for item in readings
                       if item[3] == 1 and item[2] > LONG_EPISODE_SECONDS]
        if not premise_ok:
            ok = False
            out.append("    VERDICT BAD 第 1 集没有从指定的起播点开始 —— "
                       "「第 2 集不该继承」这个前提没有成立，本次结果不作数")
        elif not second_side:
            ok = False
            out.append("    VERDICT BAD 第 2 集没有出过任何读数")
        else:
            start_position = min(item[1] for item in second_side)
            out.append(f"    第 2 集读数 {len(second_side)} 条，"
                       f"首 {second_side[0][1]:.2f}s"
                       f"（+{second_side[0][0]:.1f}s）"
                       f" → 末 {second_side[-1][1]:.2f}s"
                       f"（+{second_side[-1][0]:.1f}s），最小 {start_position:.2f}s")
            if len(second.requests) == 0:
                ok = False
                out.append("    VERDICT BAD 第 2 集源站没收到请求，没真的换集")
            elif start_position >= RESUME_SECONDS - INHERIT_TOLERANCE:
                ok = False
                out.append(f"    VERDICT BAD 第 2 集从 {start_position:.2f}s 起"
                           f" —— 继承了第 1 集的续播点"
                           f"（--start 不是文件局部选项，换集时被 mpv 重新应用）")
            else:
                out.append(f"    VERDICT OK  第 2 集从 {start_position:.2f}s 起，"
                           f"没有继承第 1 集的续播点")
    finally:
        out.append(f"    exit code = {player.close()}")
        for item in (first, second):
            item.close()
    return "\n".join(out), ok


def run_own_resume_case(exe, workdir, name, wait=30.0):
    """第 2 集自己有观看记录时，换过去要落在**它自己**的位置上。"""
    first = retry.FakeOrigin(seconds=FIRST_EPISODE_SECONDS)
    second = retry.FakeOrigin()
    own_resume = 200.0
    args = [
        f"--start={RESUME_SECONDS}",
        f"--mova-start={RESUME_SECONDS}",
        "--mova-playlist-start=0",
        "--mova-playlist-title=探针第 1 集",
        "--mova-playlist-title=探针第 2 集",
        # 与 URL 同序：第 1 集没有记录（它由 --mova-start 给定），第 2 集有。
        "--mova-playlist-resume=",
        f"--mova-playlist-resume={own_resume:.3f}",
    ]
    player = autoskip.Probe(exe, workdir, [first.url, second.url], args)
    out = [f"=== {name} ==="]
    ok = True
    try:
        time.sleep(wait)
        readings = _position_readings(player)
        second_side = [item for item in readings
                       if item[3] == 1 and item[2] > LONG_EPISODE_SECONDS]
        out.append(f"    第 2 集自己的续播点 = {own_resume:.0f}s")
        if not second_side:
            return "\n".join(out + ["    VERDICT BAD 第 2 集没有出过任何读数"]), False
        start_position = min(item[1] for item in second_side)
        out.append(f"    第 2 集读数 {len(second_side)} 条，"
                   f"首 {second_side[0][1]:.2f}s（+{second_side[0][0]:.1f}s）"
                   f" → 末 {second_side[-1][1]:.2f}s，最小 {start_position:.2f}s")
        if len(second.requests) == 0:
            ok = False
            out.append("    VERDICT BAD 第 2 集源站没收到请求，没真的换集")
        elif abs(start_position - own_resume) > INHERIT_TOLERANCE:
            ok = False
            out.append(f"    VERDICT BAD 第 2 集从 {start_position:.2f}s 起，"
                       f"没有落在它自己的 {own_resume:.0f}s 上")
        else:
            out.append(f"    VERDICT OK  第 2 集从自己的 {start_position:.2f}s 起")
    finally:
        out.append(f"    exit code = {player.close()}")
        for item in (first, second):
            item.close()
    return "\n".join(out), ok


def run_unaggregated_switch_case(exe, workdir, name, direction):
    """未聚合的相邻集应回传季集坐标，而不是对空 URL 执行 loadfile。"""
    origin = retry.FakeOrigin(seconds=LONG_EPISODE_SECONDS)
    current_index = 0 if direction == "next" else 1
    target_episode = 2 if direction == "next" else 1
    urls = [origin.url, ""] if direction == "next" else ["", origin.url]
    args = [
        f"--mova-playlist-start={current_index}",
        "--mova-playlist-title=探针第 1 集",
        "--mova-playlist-title=待搜索第 2 集",
        "--mova-playlist-season=1",
        "--mova-playlist-season=1",
        "--mova-playlist-episode=1",
        "--mova-playlist-episode=2",
    ]
    # 相邻目标故意保留空 URL，模拟尚未按需聚合的剧集。
    player = autoskip.Probe(exe, workdir, urls, args)
    out = [f"=== {name} ==="]
    ok = True
    try:
        time.sleep(2.0)
        clicked, note = _click_episode(direction)
        out.append(f"    {note}")
        if not clicked:
            ok = False
            out.append("    VERDICT BAD 无法触发下一集控件")
        else:
            deadline = time.time() + 6.0
            while time.time() < deadline and player.process.poll() is None:
                if any(line.startswith(f"MOVA_EPISODE=1|{target_episode}|")
                       for _, line in player.lines):
                    break
                time.sleep(0.05)
            requests = [line for _, line in player.lines
                        if line.startswith("MOVA_EPISODE=")]
            out.append("    request = " + (requests[-1] if requests else "<none>"))
            bad_empty_load = any(
                line.startswith("MOVA_ENDFILE=4|") for _, line in player.lines)
            if requests and not bad_empty_load:
                out.append("    VERDICT OK  已将季集交回应用按需聚合")
            else:
                ok = False
                out.append("    VERDICT BAD 未回传季集，或空 URL 被当作媒体加载")
    finally:
        out.append(f"    exit code = {player.close()}")
        origin.close()
    return "\n".join(out), ok


def run_live_unaggregated_switch_case(exe, workdir, name, resolve=True):
    """Resolve a missing next episode over stdin without respawning the player."""
    current = retry.FakeOrigin(seconds=LONG_EPISODE_SECONDS)
    resolved = retry.FakeOrigin(seconds=LONG_EPISODE_SECONDS)
    args = [
        "--mova-live-episode-resolution=yes",
        "--mova-playlist-start=0",
        "--mova-playlist-title=探针第 1 集",
        "--mova-playlist-title=待搜索第 2 集",
        "--mova-playlist-season=1",
        "--mova-playlist-season=1",
        "--mova-playlist-episode=1",
        "--mova-playlist-episode=2",
    ]
    player = autoskip.Probe(exe, workdir, [current.url, ""], args)
    out = [f"=== {name} ==="]
    ok = True
    reason = None
    try:
        time.sleep(2.0)
        window_before = autoskip.base.wait_class(
            "MovaNativePlayerWindow", timeout=3.0)
        clicked, note = _click_episode("next")
        out.append(f"    {note}")
        if not clicked:
            reason = "无法触发下一集控件"
        else:
            deadline = time.time() + 6.0
            request = None
            while time.time() < deadline:
                request = next((line for _, line in player.lines
                                if line.startswith("MOVA_EPISODE_REQUEST=")), None)
                if request:
                    break
                time.sleep(0.05)
            if not request:
                reason = "未收到动态搜索请求"
            else:
                out.append(f"    request = {request}")
                out.append(f"    search wait: process={'alive' if player.process.poll() is None else 'exited'}")
                window_during_search = autoskip.base.wait_class(
                    "MovaNativePlayerWindow", timeout=2.0)
                if player.process.poll() is not None:
                    reason = "搜索期间播放器进程已退出"
                elif not window_before or window_during_search != window_before:
                    reason = "搜索期间播放器窗口被重建"
                elif resolve:
                    player.send(
                        "MOVA_EPISODE_RESOLVED=1|"
                        f"{quote(resolved.url, safe='')}||0"
                    )
                else:
                    player.send(
                        "MOVA_EPISODE_RESOLVE_FAILED=1|"
                        f"{quote('未找到该集可播放资源', safe='')}"
                    )
                if reason is None and resolve:
                    deadline = time.time() + 8.0
                    while time.time() < deadline:
                        loaded = any(
                            stamp > 1.0 and index == 1 and duration > 0
                            for stamp, position, duration, index in _position_readings(player)
                        )
                        if loaded and resolved.requests:
                            break
                        time.sleep(0.05)
                    still_same_window = autoskip.base.wait_class(
                        "MovaNativePlayerWindow", timeout=2.0)
                    loaded = (player.process.poll() is None and
                              still_same_window == window_before and
                              bool(resolved.requests) and
                              any(index == 1 and duration > 0
                                  for _, _, duration, index in _position_readings(player)))
                    if loaded:
                        time.sleep(2.0)
                        loaded = player.process.poll() is None
                    if loaded:
                        out.append("    VERDICT OK  同一窗口收到搜索结果并加载下一集")
                    else:
                        reason = "搜索结果未在原窗口加载"
                elif reason is None:
                    time.sleep(1.0)
                    still_same_window = autoskip.base.wait_class(
                        "MovaNativePlayerWindow", timeout=2.0)
                    ok = (player.process.poll() is None and
                          still_same_window == window_before)
                    if ok:
                        out.append("    VERDICT OK  搜索未命中后恢复当前集，窗口保持打开")
                    else:
                        reason = "搜索未命中后播放器未能恢复"
        if reason:
            ok = False
            out.append(f"    VERDICT BAD {reason}")
    finally:
        exit_code = player.close()
        out.append(f"    exit code = {exit_code}")
        if exit_code != 0:
            out += player.tail(24, keep=lambda line: not line.startswith("MOVA_POSITION="))
        current.close()
        resolved.close()
    return "\n".join(out), ok and exit_code == 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", default=r"D:\Mova\MovaNativePlayer.exe")
    parser.add_argument("--workdir", default=r"D:\Mova")
    parser.add_argument("--only", default=None)
    options = parser.parse_args()

    cases = [("01_next_episode_does_not_inherit_resume", run_case),
             ("02_next_episode_uses_its_own_resume", run_own_resume_case),
             ("03_next_unaggregated_episode_requests_search",
              lambda exe, workdir, name:
                  run_unaggregated_switch_case(exe, workdir, name, "next")),
             ("04_previous_unaggregated_episode_requests_search",
              lambda exe, workdir, name:
                  run_unaggregated_switch_case(exe, workdir, name, "previous")),
             ("05_live_unaggregated_episode_switch",
              run_live_unaggregated_switch_case),
             ("06_live_unaggregated_search_failure",
              lambda exe, workdir, name:
                  run_live_unaggregated_switch_case(
                      exe, workdir, name, resolve=False))]
    selected_cases = [(name, runner) for name, runner in cases
                      if not options.only or name.startswith(options.only)]
    failed = 0
    for name, runner in selected_cases:
        text, ok = runner(options.exe, options.workdir, name)
        print(text)
        failed += 0 if ok else 1
    print(f"\nPROBE {'OK' if not failed else 'FAILED'} "
          f"({len(selected_cases) - failed}/{len(selected_cases)} passed)")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
