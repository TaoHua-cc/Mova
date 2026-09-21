# 原生播放器：换集时按目标集自己的进度起播

## 基本信息

- 标题：切换上下集后，新的这一集从上一集的进度开始播
- 日期：2026-09-21
- 状态：已实现并验证（待用户实机确认观感）
- 影响平台：Windows 原生播放器（`MovaNativePlayer.exe`）；Android 走播放页重建播放器，起播点由应用侧显式 seek，不受影响
- 关联：v3.1.109 之后的修复

## 背景与问题

用户报告（原话：「有BUG，切换上下集时，没有正确根据上下集进度播放，都是从上一集的进度播放」）。

用代码与实测可观察的事实描述：

1. 应用侧起播时把本集续播点交给 mpv 的**命令行选项** `--start=<秒>`（`windows_native_player.dart` 的 `'--start=${request.initialPosition…}'`）。
2. `--start` 是**普通（非文件局部）选项**。mpv 手册 Per-File Options 一节：

   > When playing multiple files, any option given on the command line usually affects all files.
   > Also, if any option is changed at runtime (via input commands), they are not reset when a new file is played.

   即：mpv 在换文件时不重置它，命令行给的 `--start` 会对**每一个**后来加载的文件重新生效。
3. 原生换集（控件条上一集/下一集、剧集面板选集、自动连播、跳过片尾）统一走 `LoadPlaylistEntry()` → `loadfile <url> replace`。于是第 1 集的续播点被 mpv 重新应用到第 2 集上。
4. 于是用户看到的现象是：**切到哪一集，都从上一集的位置开始播**；第 2 集自己的观看进度（如果有）完全不生效。

实测证据（`tool/probe_episode_switch_resume.py`，修复前）：

```
第 1 集 20s，以 --start=10 起播；读数 155 条
MOVA_COMPLETED: 第 1 集播完，已自动连播
第 2 集源站请求数 = 1
第 2 集读数 317 条，最小位置 10.00s
VERDICT BAD 第 2 集从 10.00s 起 —— 继承了第 1 集的续播点
```

另一个**独立**的缺口：原生换集只做 `loadfile`，应用侧不参与，所以即便没有 `--start` 的污染，第 2 集也只能从 0 开始 —— 每一集「看到哪儿」这份数据从来没有交到原生手里（播放列表里只有「观看比例」与「时长」，够用但没被用来定位）。

## 目标

- 换集之后，新的这一集从**它自己的**续播点起播；没有记录的集从头播。
- 起播点不再依赖 mpv 命令行选项，换成每集显式设置，杜绝跨集串味。
- 应用侧起播那一集仍使用应用给的精确续播点（可能来自服务器端进度，比本地比例准）。

## 非目标

- 不改动应用侧播放页的换集逻辑（`_switchEpisode` 重建播放器，本来就正确）。
- 不引入服务端协议或持久化键变化。
- 不改「看完的集从头播」之外的起播策略（不做「自动跳过片头」之类的联动）。

## 用户流程与界面

| 入口 | 修复前 | 修复后 |
|---|---|---|
| 控件条「上一集 / 下一集」 | 新集从上一集位置起播 | 新集从自己的续播点起播（无记录则 0） |
| 剧集面板选集 | 同上 | 同上 |
| 自动连播（播完 EOF 后） | 同上 | 同上 |
| 跳过片尾 → 下一集 | 同上 | 同上 |
| 应用侧播放页换集 | 正确（重建进程 + `--start`） | 正确（重建进程 + `--mova-start`） |

界面没有新增元素，没有新增交互，用户只看到「位置对了」。

## 数据与接口

新增两个**自定义启动参数**（`--mova-` 前缀，原生自己解析，不交给 mpv）：

| 参数 | 含义 |
|---|---|
| `--mova-start=<秒>` | 本次**起播**这一集的续播点（可含小数）。原来这里是 mpv 的 `--start=` |
| `--mova-playlist-resume=<秒 或 空>` | 播放列表**每一集**的续播点，与 URL 同序；空 = 该集没有记录 |

- 无新增持久化键、无缓存格式变化、无服务端协议变化。
- 不打印 URL 或令牌（沿用既有约束）。

## 技术方案

`windows/native_player/main.cpp`：

1. 新增全局 `g_playlist_resumes`（每集续播秒数，与 `g_media_urls` 同序）与 `g_initial_position`（本次起播点的精确值）。
2. 参数解析新增 `mova-start`、`mova-playlist-resume`，并补齐数组长度。
3. 新增 `EntryResumeSeconds(index)`（< 1 秒的残值当 0）与 `ApplyPlaylistStart(index)` —— 后者发 `set start <秒>` 命令，**每次 loadfile 之前都调用一次**，没有记录时也显式归零。
4. `LoadPlaylistEntry(index)`：在 `loadfile` 之前调 `ApplyPlaylistStart(index)`。
5. `RetryCurrentEpisode()`：起播点设为**断点** `g_resume_seconds`（而不是该集最早的续播点），避免「先跳到旧位置、再由 `FILE_LOADED` 的补 seek 拉回」的可见跳动。
6. 启动首集：用 `g_initial_position` 覆盖该集在 `g_playlist_resumes` 里的值，再 `ApplyPlaylistStart(start_index)`，最后 `loadfile`。

`lib/src/player/windows_native_player.dart`：

7. `--start=` → `--mova-start=`（总是下发，含 0）。
8. `WindowsNativePlaylistEntry` 新增 `resumeSeconds`，并逐集下发 `--mova-playlist-resume=`。

`lib/src/metadata/metadata_detail_page.dart`：

9. `nativeEntry()` 用「观看比例 × 时长」估出每集秒数。**看完的（比例 ≥ 95%）与刚开头 5 秒内的当作没有记录**：前者从片尾接上会立刻触发连播，后者与从头播没有区别、还多一次 seek。

未选方案：

- `set start none` 清空选项：语义更贴切，但依赖 mpv 对 `none` 的解析；显式设 0 一定被接受且行为等价（从 0 秒起播）。
- 把续播点直接拼进 URL / 用 `loadfile … start=`：`loadfile` 没有该语法，只能 `set` 选项或 `seek`。
- 换集后在 `FILE_LOADED` 里补一次 seek：文件加载完才动，起播瞬间会先从头解码一小段再跳走（可见跳动），不如在 `loadfile` 前设 `start` 干净。
- 让原生自己读观看记录：原生不联网、也不该持有存储格式，交给应用侧下发更合适。

## 兼容与迁移

- 无数据格式变化，旧版本数据可继续读取。
- `WindowsNativePlaylistEntry.resumeSeconds` 是可空新增字段，唯一的构造点已更新；Dart 侧其它构造处（单集兜底）不传即为 null → 从头播。
- Windows 与 Android 差异：Android 不走该原生播放器；本次 Dart 改动（`nativeEntry`、参数名）只影响 `WindowsNativePlayer.play`，Android 路径不经过它。
- 回滚安全：还原 `main.cpp` 的六处与 Dart 的三处即可；无功能开关。

## 验收标准

- [x] 换集（上一集/下一集/选集/自动连播）后，新集从**自己的**续播点起播；无记录时从头
- [x] 第 1 集的续播点不再影响后续任何一集
- [x] 应用侧起播仍使用精确续播点（`--mova-start`）
- [x] 中断重试 / 「重新播放」仍回到断点，且没有可见的位置跳动
- [x] 看完的集（比例 ≥ 95%）换到它时从头播，不会立刻触发连播
- [x] 不引入虚假生产数据或泄露敏感信息
- [x] Windows 与 Android 的预期差异已说明

## 验证计划

### 自动化

- [x] 独立编译 `main.cpp`（`/W4 /WX /wd4100 /EHsc /std:c++17 /DNOMINMAX`）
- [x] `tool/probe_episode_switch_resume.py`（新增）：修复前 BAD、修复后 OK（2/2）
- [x] `tool/probe_interrupt_retry.py`（`01`/`02`/`03`）：中断重试与手动恢复不回归（3/3）
- [x] `tool/verify_controls_dock_surface.py`、`tool/verify_native_panels.py`
- [x] `flutter analyze`（0 error / 0 warning）

### 人工验证

| 平台/尺寸 | 操作路径 | 预期结果 | 结果 |
|---|---|---|---|
| Windows 1920×1080 | 第 1 集播一会儿 → 下一集 | 第 2 集从头播（或从它自己记录的位置） | 待用户确认 |
| Windows 1920×1080 | 在第 2 集看到中途 → 回上一集 → 再回第 2 集 | 两次都回到各自记录的位置 | 待用户确认 |
| Windows 1920×1080 | 看完一集（比例 ≥ 95%）→ 切到它 | 从头播，不立刻跳走 | 待用户确认 |

## 风险与回滚

- 主要风险：
  1. `--mova-start` 若拼写/解析失配，起播就不再定位（表现为「续播失效，从头播」）。缓解：Dart 侧原有的 `_awaitSeekableTarget + seek` 仍在，是第二道保险。
  2. `resumeSeconds` 由「比例 × 时长」估出，比例保留 4 位小数——对 1 小时片约 0.4 秒误差，可接受。
  3. 看完的集若被误判为未看完，会从片尾接上并立刻连播。缓解：`progress ≥ .95` 与 `watched` 双条件之外还加了「>= 5 秒才跳」的下限。
- 监测方式：`MOVA_POSITION`（状态行）、`MOVA_COMPLETED`、`MOVA_RETRY`、`MOVA_REPLAY` 与探针退出码。
- 回滚步骤：还原 `main.cpp`（`g_playlist_resumes` / 解析 / `ApplyPlaylistStart` / `LoadPlaylistEntry` / `RetryCurrentEpisode` / 启动首集）与 Dart 三处（参数名、`resumeSeconds`、`nativeEntry`）。

## 实现记录

2026-09-21 实现并验证。

### 实际修改（`windows/native_player/main.cpp`）

| 位置 | 改动 |
|---|---|
| 状态声明（`g_playlist_watched` 之后） | 新增 `std::vector<double> g_playlist_resumes`、`double g_initial_position`、`bool g_initial_position_explicit` |
| `Wide()` 之后 | 新增 `EntryResumeSeconds(index)`（越界返回 0；< 1 秒的残值当 0） |
| `LoadPlaylistEntry()` 之前 | 新增 `ApplyPlaylistStart(index)`：发 `set start <秒>`，无记录时也显式归零 |
| `LoadPlaylistEntry()` | `loadfile` 之前调 `ApplyPlaylistStart(index)` |
| `RetryCurrentEpisode()` | `loadfile` 之前 `set start` 为**断点** `g_resume_seconds`（不是该集最早的续播点），避免「先跳到旧位置、再由 `FILE_LOADED` 补 seek 拉回」的可见跳动 |
| 参数解析 | 新增 `mova-start`（设 `g_initial_position` + 置 `g_initial_position_explicit`）、`mova-playlist-resume`（逐集 push） |
| 参数解析（兜底） | 新增 `else if (name == "start")`：接受 mpv 自己的 `--start=<秒>` 但**只记成起播点、不 SetOption 给 mpv**；`mova-start` 明确给过值时以它为准 |
| 参数解析收尾 | `while (g_playlist_resumes.size() < g_media_urls.size()) push_back(0.0)` 补齐数组 |
| 启动首集 | `g_playlist_resumes[start_index] = g_initial_position;` → `ApplyPlaylistStart(start_index)` → `loadfile` |

### 实际修改（Dart）

| 文件 | 改动 |
|---|---|
| `lib/src/player/windows_native_player.dart` | 新增顶层函数 `episodeResumeSeconds({progress, duration})`：比例 ≥ .95（看完）或 < 5 秒、时长 ≤ 0 一律返回 `null` |
| 同上 | `WindowsNativePlaylistEntry` 新增可空字段 `final double? resumeSeconds;`（唯一的构造点已更新） |
| 同上 | `'--start=…'` → `'--mova-start=…'`（**总是下发**，含 0），并在播放列表参数处逐集下发 `--mova-playlist-resume=`（空值表示无记录） |
| `lib/src/metadata/metadata_detail_page.dart` | `nativeEntry()` 改用 `episodeResumeSeconds(progress: progress, duration: seconds)` 填 `resumeSeconds`（仅加逻辑，未做格式化重排） |

### 测试结果

- 独立编译 `main.cpp`（`/W4 /WX /wd4100 /EHsc /std:c++17 /utf-8 /O2 /DNOMINMAX`）：**CL_EXIT=0，零警告**
- `tool/probe_episode_switch_resume.py`（新增，2 用例）**PROBE OK (2/2)**：
  - `01` 第 1 集 20s、以起播点 10s 播放 → 读数首 10.00s → `MOVA_COMPLETED` 自动连播 → **第 2 集读数首 0.00s**，`VERDICT OK 第 2 集从 0.00s 起，没有继承第 1 集的续播点`，exit code 0
  - `02` 第 2 集带自己的 200s 续播点 → **第 2 集读数首 200.00s**，`VERDICT OK 第 2 集从自己的 200.00s 起`，exit code 0
  - 修复前同一探针为 `VERDICT BAD 第 2 集从 10.00s 起`（见「背景与问题」的实测证据）
- `tool/probe_interrupt_retry.py` **3/3 OK**（`01_seek_interrupt_retry` / `02_replay_via_play_key` / `03_replay_via_capsule`）—— 「断点恢复不跳动」与上一轮的失败恢复入口均未回归
- `tool/verify_segments_and_danmaku.py --only 03`（自动跳过片头）：**OK** —— 见下方「与规格的偏差」
- `tool/verify_native_panels.py` **8/8**、`tool/verify_controls_dock_surface.py` **VERDICT OK**（改动只动了起播点，未碰绘制与命中）
- `test/episode_resume_test.dart`（新增 6 用例覆盖 `episodeResumeSeconds` 边界）随 `flutter test` 通过；全套 **91 passed / 1 failed** —— 失败的是既有历史遗留 `discover shelves can be shown and persist their layout`（`widget_test.dart:163`），与本改动无关
- 部署：`scripts/dev-verify.ps1 -Deploy -SkipChecks` → `D:\Mova\MovaNativePlayer.exe` **13:07:04**（与 `build\windows\x64\runner\Release\` 一致）

### 与规格的偏差

- **额外保留了对 mpv `--start=` 的兼容解析**（规格未写）。原因：端到端回归 `verify_segments_and_danmaku.py --only 03` 用 `--start=38` 把播放器定位到片头位置，本次若不认它，播放器会从 0 起播、自动跳过片头不再触发，`03_auto_skip` 变 BAD。处理方式是「认它，但只当成本次起播点，不 SetOption 给 mpv」——既修好串集，又不动既有调用方。`--mova-start` 优先级更高。
- 探针最初试图用 `PostMessageW` 点控件条的「下一集」按钮，实测点不到（控件条窗口宽度小于 780 走 compact 布局，不画上一集/下一集按钮）。改为让 `FakeOrigin(seconds=20)` 使第 1 集自动播完触发 `kPlaylistAdvance` —— 与按钮**同一条换集路径**（`LoadPlaylistEntry`），断言等价且不依赖 UI 布局。
- 位置读数最初误信 mpv 的 `--term-status-msg`，实测**在管道下根本不输出**（不是终端）；有效来源是原生自己的 `EmitProgress`（三段 `pos|duration|index`，自带集索引），探针据此按集索引分集。

### 遗留

- 应用侧「观看比例 × 时长」估续播点，比例保留 4 位小数 —— 对 1 小时片约 0.4 秒误差，可接受（已记入风险）。
- 用户实机确认：换集后位置是否正确、看完的集是否从头播，待验证。
- 本次改动与上一轮「播放失败后的恢复入口」**均未提交**；按协作约定不主动 commit / push / tag。
