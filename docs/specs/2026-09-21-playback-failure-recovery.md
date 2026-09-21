# 原生播放器：播放失败后的恢复入口

## 基本信息

- 标题：播放失败后无法恢复（无可操作入口）
- 日期：2026-09-21
- 状态：实现中
- 影响平台：Windows 原生播放器（`MovaNativePlayer.exe`）；Android 走 media_kit 播放页，失败面板自带「重试」，不受影响
- 关联：v3.1.109 之后的修复

## 背景与问题

用户报告（原话：「播放时，如果播放失败就无法恢复」），选定的现象是**原生播放器控件条出现红字「播放失败」**之后无法继续。

用代码可观察的事实描述：

1. 播放中 mpv 报 `end-file`（`ERROR`，或「离片尾很远的 EOF」——断流常被 ffmpeg 记成 EOF）时，事件线程投递 `kPlaybackInterrupted`。
2. 主线程先自动重开一次（`kMaxInterruptRetries = 1`）。再失败就置 `g_playback_error = true`，控件条左下显示红字「播放失败 · 请更换资源」。
3. 此时 mpv 已经处于 **idle**。控件条的播放键与空格快捷键都只发 `cycle pause` —— 对没有文件在播的 mpv 是**空操作**；进度条的 `seek` 同样无效。
4. `g_playback_error` 只在两处清除：`LoadPlaylistEntry()`（换集）与 `MPV_EVENT_FILE_LOADED`。单集影片没有换集按钮可用。

结论：失败之后，除换集或退出播放页重进之外，**没有任何就地恢复的路径**。这不是阈值或次数问题，是入口缺失。

## 目标

- 播放失败后，用户能就地重新播放当前集，并从最后一次有效位置接上。
- 恢复动作有可见入口与明确反馈，不依赖用户猜「再点一次播放键试试」。

## 非目标

- 本次不提高自动重试次数（保持 1 次），不做无限重试/指数退避。
- 不修改 Dart 侧播放页的失败面板（它已有「重试」按钮）。
- 不做「失败后自动换源或跳集」——那会把播不出来变成悄悄放了别的资源。

## 用户流程与界面

失败态（`g_playback_error == true`）下的界面与入口：

| 入口 | 行为 |
|---|---|
| 控件条左下 | 红字「播放失败」+ 玻璃胶囊按钮「重新播放」（悬停提亮） |
| 控制区中央播放键 | 重新播放（不再发 `cycle pause`） |
| 空格（快捷键可在设置里改） | 重新播放（不再发 `cycle pause`） |
| 接续 | `loadfile` 当前集 → `FILE_LOADED` 后 seek 回 `g_last_valid_position`，既有提示「连接中断，已从原位置继续」 |

- 成功反馈：toast「正在重新播放…」。
- 失败反馈（`loadfile` 命令被拒）：toast「重新播放失败」，界面保持失败态。
- 失败态出现的提示文案由「播放中断，已停在当前位置」改为「播放中断 · 点播放键重新播放」（给出动作，而不只是状态）。
- 不改变非失败态的任何交互。

窄窗（`width < 780`）：左半区只有时间码，`kReplay` 命中区取 `x ∈ [20, 152]`；窗口宽度 ≥ 512 时与中央按钮区（`center - 104`）不重叠，重叠时也优先恢复（见技术方案）。

## 数据与接口

- 新增 stdout 轨迹：`MOVA_REPLAY=<index>|<resume>`（供探针断言；`MOVA_RETRY` / `MOVA_SUSPECT_EOF` / `MOVA_ENDFILE` 保持原样）。
- 无新增持久化键、无缓存格式变化、无服务端协议变化。
- 无隐私与敏感信息影响（不打印 URL）。

## 技术方案

`windows/native_player/main.cpp`：

1. `ReplayAfterPlaybackFailure()`（新）：失败态下清零重试预算 `g_retry_count = 0`，再复用 `RetryCurrentEpisode()`（同集 `loadfile replace`，位置在 `FILE_LOADED` 里补 seek）。返回 `true` 表示本次动作已被当成「重新播放」处理。
   - **为什么必须清零预算**：`RetryCurrentEpisode()` 故意不清预算（防止自动重试变成无限循环）。用户显式点击是另一回事——不清零的话，自动补的那一次失败之后，用户再点也只是白发一次命令，永远停在「播放失败」。
2. `ControlId::kReplay`（枚举末尾）+ `kControlCount` 改为按 `kReplay` 计算（hover 数组随之 +1）。
3. `HitControl()`：仅在 `g_playback_error` 为真、且 `x ∈ [20, 152]` 时返回 `kReplay`；放在 `y < 34` 之后，进度条带（含拖动）不受影响。
4. 状态行绘制：红字「播放失败」+ 圆角玻璃胶囊「重新播放」（`HoverAmount(kReplay)` 提亮），与控件条其它玻璃圆片同一套材质。
5. 点击链：新增 `else if (hit == kReplay)`，位置在工具面板/溢出菜单判断之前、中央按钮的 x 区间之前 —— 窄窗下即使与「后退 10 秒」的命中区重叠，也优先恢复（失败态下 seek 本来无效）。
6. 播放键分支与 `RunShortcut` 的 `playPause` 分支：先调 `ReplayAfterPlaybackFailure()`，未被处理时才发 `cycle pause`。

未选方案：

- 用 `keep-open=yes` 让 mpv 自己停在 idle 后自动重开：行为不可控（何时重开、重开几次都交给 mpv），且会与现有「停在原地」的设计冲突。
- 在 Dart 侧加恢复按钮：失败反馈来自原生浮层，跨进程同步状态成本高，而且用户在播放器窗口里操作时根本看不到应用窗口。
- 把「播放失败 · 请更换资源」的措辞保留、只加提示：实测用户已经看不到恢复路径，仅改文案不解决问题。

## 兼容与迁移

- 无数据格式变化，旧版本数据可继续读取。
- Windows 与 Android 差异：Android 没有该原生播放器，走播放页的失败面板；本次改动不影响它。
- 回滚安全：纯控制流 + 自绘 UI，回滚即恢复旧行为（无恢复入口）。
- 不需要迁移、清理或功能开关。

## 验收标准

- [ ] 失败态下，点播放键 / 空格 / 「重新播放」三者都能重新起播当前集，并回到断点位置（±2 秒）
- [ ] 手动恢复会重置重试预算（之后再次中断仍会有一次自动重试）
- [ ] 非失败态不受影响：播放键仍只切暂停、进度条（y<34）与工具按钮命中不变
- [ ] 空数据和失败路径可恢复
- [ ] 不引入虚假生产数据或泄露敏感信息
- [ ] Windows 与 Android 的预期差异已说明

## 验证计划

### 自动化

- [ ] 独立编译 `main.cpp`（`/W4 /WX /std:c++17 /DNOMINMAX`）
- [ ] `tool/probe_interrupt_retry.py`（含 `08_interrupt_retry`）：既有中断/重试路径不回归
- [ ] 新增探针用例：失败态下发播放键 → 断言 `MOVA_REPLAY` / `MOVA_RETRY` 轨迹与画面恢复
- [ ] `tool/verify_controls_dock_surface.py`（控件条 + 顶栏离屏面、退出码）
- [ ] `tool/verify_native_panels.py`（8 用例）
- [ ] `flutter analyze` / `flutter test`（Dart 侧本次未改，跑一遍确认）

### 人工验证

| 平台/尺寸 | 操作路径 | 预期结果 | 结果 |
|---|---|---|---|
| Windows 1920×1080 | 播到中断（红字出现）→ 点播放键 | 重新起播并回到断点 | 待用户确认 |
| Windows 1920×1080 | 同上 → 点「重新播放」胶囊 | 同上，胶囊悬停有提亮反馈 | 待用户确认 |
| Windows 窄窗（<780） | 失败态点左下胶囊 | 命中恢复而不是后退 10 秒 | 待用户确认 |

## 风险与回滚

- 主要风险：
  1. `kReplay` 命中区抢占进度条左端 —— 已用 `y < 34` 的先后顺序规避（进度条带先返回 `kNone`）。
  2. 新枚举值让 hover 数组越界 —— `kControlCount` 同步改为 `kReplay + 1`，数组按它定义。
  3. 恢复后若源仍然不可用，会出现「点一次 → 自动补一次 → 再失败」的短循环（毫秒级），观感是提示闪两下后仍停在失败态，可接受。
- 监测方式：`MOVA_ENDFILE` / `MOVA_SUSPECT_EOF` / `MOVA_RETRY` / `MOVA_REPLAY` 四条轨迹 + 探针退出码。
- 回滚步骤：还原 `main.cpp` 的六处改动（枚举、命中、绘制、点击链、播放键、快捷键）。

## 实现记录

2026-09-21 实现并验证。

### 实际修改（`windows/native_player/main.cpp`）

| 位置 | 改动 |
|---|---|
| `ControlId` 枚举 | 末尾新增 `kReplay`；`kControlCount` 改为按 `kReplay` 计算（hover 数组随之 +1） |
| `RetryCurrentEpisode()` 之后 | 新增 `ReplayAfterPlaybackFailure()`：清零 `g_retry_count` + 复用同集重开，位置在 `FILE_LOADED` 里补回，并打印 `MOVA_REPLAY=<index>\|<resume>` |
| `HitControl()` | 失败态且 `x ∈ [20,152]` 返回 `kReplay`（放在 `y < 34` 之后，进度条带不受影响） |
| 状态行绘制 | 红字改为「播放失败」+ 圆角玻璃胶囊「重新播放」（`HoverAmount(kReplay)` 提亮） |
| `WM_LBUTTONDOWN` 链 | 新增 `else if (hit == kReplay)`，置于工具面板与中央按钮的 x 判断**之前** |
| 播放键 / `playPause` 快捷键 | 失败态先走恢复，未被处理才发 `cycle pause` |
| `TickFrame` 的 `play_target` | 失败态按「未播放」算 → 中间那颗键画**播放三角**（mpv 在 idle 时 `pause=false`，只看 `g_paused` 会画成双竖线，读作「点一下会暂停」，与它此刻真正做的事正好相反） |
| `kPlaybackInterrupted` 末端 | toast 改为「播放中断 · 点播放键重新播放」；新增 `MOVA_FAILED` 轨迹 |

### 测试结果

- 独立编译（`/W4 /WX /wd4100 /EHsc /std:c++17 /utf-8 /O2 /DNOMINMAX`）：**CL_EXIT=0，零警告**
- `tool/probe_interrupt_retry.py`（本次由 1 个用例扩到 3 个）：
  - `01_seek_interrupt_retry` **OK** —— 既有「一次重试吃掉抖动」路径不回归
  - `02_replay_via_play_key` **OK** —— 注入 2 次故障：`MOVA_ENDFILE reason=0 played=40.000`（假 EOF）→ 自动重试 → `reason=4 error=-16` → `MOVA_RETRY x1 / MOVA_FAILED x1` → 点控件条播放键 → `MOVA_REPLAY x1`，位置 40.0 → 44.9 继续前进，exit code 0
  - `03_replay_via_capsule` **OK** —— 同现场，入口换成左下「重新播放」胶囊
- `tool/verify_native_panels.py` **8/8 cases OK**（exit code 0）
- `tool/verify_controls_dock_surface.py` **VERDICT OK**（exit code 0）：控件条 `alpha=0 2.14%`、顶栏 `zero=93.57%`、提示 `224×120` 且夹在窗口内 —— 与改动前**逐项一致**，命中与命中带无回归
- 部署：`scripts/dev-verify.ps1 -Deploy -SkipChecks` → `BUILD_OK`，`D:\Mova\MovaNativePlayer.exe` 12:34:32（与 build 目录一致）
- Dart 侧本次未改（改动全在 `windows/`、`tool/`、`docs/`），未重跑 `flutter test`

### 与规格的偏差

- 额外加了 `MOVA_FAILED` 轨迹与探针的第 3 个用例（规格里只写了 1 个新用例）：失败态在日志里原本是**隐含**的，没有它只能靠数错误次数猜，断言不稳。
- `FakeOrigin` 由「只注入一次」扩展为「可注入 N 次」（`fault_count=<n>`），默认仍为 1，`01` 用例行为不变。

### 遗留

- 失败态下**拖动进度条仍然是无效操作**（mpv 在 idle）：本次未改，属可选优化（可做成「从该位置重新打开当前集」）。
- 用户实机确认：三个入口的观感与断点恢复精度待验证。
- ⚠️ 发现技能 `windows-sandbox-toolchain-workarounds` 的独立编译命令缺少 `/wd4100 /EHsc`（会把既有的 `ShowHint` 未使用参数误报成 C2220 硬错误），已修正。
