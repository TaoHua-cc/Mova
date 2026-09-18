# Windows 原生播放器：弹幕「看不清」与「一顿一顿」的根因修复

## 基本信息

- 标题：弹幕排版（同轨叠压）与动画平滑度（时间源粒度）修复
- 日期：2026-09-19
- 状态：已实施（原生侧完成，自动化验收通过；**真实片源的实机观感需用户过一遍**）
- 影响平台：Windows（原生播放器 `MovaNativePlayer.exe`）；Android / Flutter 侧不受影响
- 关联：接续 `docs/specs/2026-09-17-windows-player-panel-content-and-feedback.md`

## 背景与问题

用户实机反馈：**「弹幕这样显示看不清，而且非常卡，一点都不平滑，一顿一顿」**（附截图）。
截图与程序导出的弹幕层位图（`MOVA_TRACE_PANEL`）一致：**同一句文字叠在自己上面、几十条糊成一片**。

两个症状是**两个独立根因**，不能只修一个。

### 根因 A —— 看不清：轨道分配四个缺陷叠加

用 `tool/probe_danmaku_layout.py` 以真实长度分布（2–40 字，87% 滚动 / 8% 顶 / 5% 底）
复现，修复前：

| 指标 | 修复前 | 说明 |
|---|---|---|
| 同屏条数 peak | 109 | 与用户截图相当 |
| **`overlap`（同轨滚动压滚动）** | **99–108** | ≈90% 的弹幕在互相叠压 |
| `draw` / `post` | 2.26 / 0.55ms | **绘制没有超预算** |
| mpv `drop` | 0 | **视频也没掉帧** |

即：卡顿观感**不是**绘制超预算造成的，而是上百条弹幕叠压（既看不清，又让每帧多贴几十张图）。

`PaintDanmaku()` 激活循环的四个缺陷：

1. 同一帧里一起激活的条目读到的都是**旧的**轨道占用值，并列时就**全都挑 0 号轨道**；
2. 轨道占用只在**绘制循环**里更新（激活时看不到本帧的新值）；
3. 把整段「穿越 8 秒」都算成占用 → 容量只剩每轨 1 条 / 8 秒，16 条轨道顶不住每秒十几条；
4. 速度写成 `(窗口宽 + 文字宽) / 8` → 每条都正好 8 秒穿越，代价是**同轨前后速度不同，后车追上前车**。

### 根因 B —— 一顿一顿：时间源被量化到系统节拍

弹幕位置 = `(动画时钟 − 出现时刻) × 速度`，而 `DanmakuAnimationClock()` 用的是
`GetTickCount64()`。**本机实测**（`tool/tick_clock_probe.cpp`，已先 `timeBeginPeriod(1)`，
复刻播放器用法）：

| 时间源 | 3 秒内的推进台阶 |
|---|---|
| `GetTickCount64` | 只有 **15ms ×71、16ms ×120**（平均 15.7ms）|
| `QueryPerformanceCounter` | 1ms ×2995 |

时钟每 15.7ms 才动一格，而帧间隔是 16.3ms → 绝大多数帧走一格、约 4% 的帧走两格 →
**持续微抖**。这个成因的隐蔽之处在于：`gap`（最大帧间隔）和 `draw` 都很正常，
只看帧率指标**发现不了**。

## 目标

- 同一轨道的滚动弹幕互不叠压（可度量：`depth` ≤ 2px）；
- 弹幕滚动平滑，位置推进不再被时间源粒度量化（可度量：`avg` ≤ 18ms，`late33` 不反复超时）；
- 密集弹幕下不因「叠上去」而看不清 —— 同屏满了就丢，与真实播放器一致；
- 把「看不清」「一顿一顿」两类缺陷变成**常驻断言**，防止回退。

## 非目标

- 本次明确不处理：
  - **不给弹幕文字加描边**（真实播放器常用 1–2px 黑边提升亮画面上的可读性）。本轮
    先解决「互相压住」这个主因；加描边会改变观感且增加栅格化成本，留待用户看过修复
    效果后再定；
  - 不调整弹幕字号、速度、行高等外观参数；
  - 不改动应用侧（Flutter）弹幕相关逻辑与设置项。

## 用户流程与界面

无新增入口。改动只影响播放画面上弹幕层的排版与运动：

- 同一轨道上，前一条的尾巴离开右边缘并让出 32px 之后，后一条才从右边进入；
- 顶 / 底固定弹幕仍然居中停留 4 秒；轨道不空时**直接丢弃**（不排队，排队等于糊在轨道正中）；
- 同屏容量满了（所有轨道都要等超过 1.5 秒）时丢弃该条 —— 与主流播放器的「同屏上限」一致；
- 播放中在设置里改弹幕参数（关掉某一类、调显示区域）时，只有被撤掉那一类**让出**轨道，
  仍在屏上的条目继续占位。

## 数据与接口

- 输入与输出：无变化。弹幕仍由应用侧拉取后以 stdin 行协议下发
  （`MOVA_DANMAKU_INFO` / `MOVA_DANMAKU=<文件>`），设置仍走 `MOVA_APPLY` 与
  `MOVA_SETTING=` 回执白名单（仅 `yingji.danmaku.*`）。
- 新增诊断字段（仅 `MOVA_TRACE_DANMAKU=1` 时输出，不影响正常运行）：
  `MOVA_DANMAKU_DRAW=… mixed=  depth=  olane=  orect=  avg=  late20=  late33=`
- 持久化键、网络接口、隐私：无变化。

## 技术方案

改动的模块全部在 `windows/native_player/main.cpp`：

1. **统一滚动速度**：`speed_px = width / kDanmakuScrollBaseSeconds * speed`，替换原来的
   `(width + text_width) / 8`。同轨间距恒定后，轨道才能安全地「尾巴一让开就让给下一条」。
2. **占轨规则重写**：按「最早空出」挑轨道；占用时刻在**激活时**写入；
   `hold = max(0.6, (text_width + kDanmakuLaneGapPx) / speed_px)`（滚动）或
   `kDanmakuExitSeconds`（顶/底）；等待超过 `kDanmakuMaxDelaySeconds = 1.5s` 则丢弃；
   顶/底固定弹幕**不排队**，轨道不空就丢。
3. **`kDanmakuLaneGapPx = 32` 最小同轨间距**（本轮的关键补充）：只按「尾巴刚离开右边缘」
   放行是不够的 —— 那一刻两条的间距**正好是 0**，浮点误差让它们压上几像素。
   表现为修复后 `overlap` 仍残留 2–23（密集时）。加上固定间距后 `overlap` 与 `depth`
   双双归零，反过来说明那点残量确实是**贴边**而不是真叠压。
4. **轨道占用的局部回收**：每条弹幕记下自己的 `free_at`；改设置撤掉一类弹幕时，用仍在屏上
   的条目**重建** `lane_free`，而不是 `ResetDanmakuLaneFree()` 整体归零 —— 整体归零会把
   仍被占用的轨道当成空的，新弹幕立刻压上去。
5. **时间源改用 QPC**：`DanmakuAnimationClock()`、`DanmakuPlayhead()`、
   `g_last_frame_ms`（驱动缓冲转圈与控件淡出 dt）全部改用已有的 `NowMs()`
   （`QueryPerformanceCounter`）。**互动计时 / deadline 保持 `GetTickCount64`**
   （跳过倒计时 `g_skip_deadline`、重试健康窗口 `g_retry_stamp`、提示停留 `g_hint_until`、
   自动隐藏 `g_last_interaction`）—— 它们只要几十毫秒精度，且两套时间源**绝不能相减**。

### 备选方案与未选原因

- **给固定弹幕预留专用轨道**（避免被滚动弹幕挤到全丢）：能提高顶/底弹幕的显示率，但会
  减少滚动弹幕可用轨道数、在密集场景下加重滚动叠压。本轮不引入新的轨道划分，先保证
  「不叠压」这条硬指标。
- **固定弹幕改为排队（1.5s 内等待）**：观感上等价于「该出现时没出现、过一会儿突然
  出现在正中」，比直接丢弃更突兀，且需要额外处理「在屏但未到 appear 时刻」的绘制分支。
  未采用。

## 兼容与迁移

- 旧版本数据是否可继续读取：是，弹幕文件格式与设置键均未变。
- Windows / Android 差异：改动全在 Windows 原生播放器内；Android 使用系统解码与本项目
  自己的 Flutter 覆盖层，不受影响。
- 回滚后是否安全：安全。改动是纯本地排版 / 计时逻辑，无数据迁移、无持久化变更。
- 是否需要迁移、清理或功能开关：不需要。

## 验收标准

- [x] 同轨滚动弹幕不再互相叠压：`depth ≤ 2px`（三场景与压力场景实测 `depth = 0.0`）
- [x] 弹幕稳态平均帧间隔贴住 60fps：`avg ≤ 18ms`（实测 16.3–16.5ms）
- [x] 密集弹幕下绘制仍在预算内：`draw ≤ 12ms`（实测 peak 2.5–3.1ms）
- [x] 弹幕层仍在绘制文字（导出层位图 `ink > 500px`，防止「不画了所以快」）
- [ ] 真实片源上的实机观感（滚动平滑、可读性）—— 待用户确认
- [x] 空数据和失败路径可恢复：无弹幕 / 弹幕文件缺失时层不绘制，不影响播放
- [x] 不引入虚假生产数据或泄露敏感信息：诊断仅走环境变量开关，不写盘、不联网
- [x] Windows 与 Android 的预期差异已说明

## 验证计划

### 自动化

- [x] `flutter analyze --no-fatal-infos --no-fatal-warnings` → EXIT=0（18 条 info 均为历史遗留）
- [ ] `flutter test` —— 本轮未改 Dart 代码；历史失败 `widget_test.dart:163` 与本轮无关
      （已于 2026-09-19 定性）
- [x] `python tool/probe_danmaku_layout.py`（WAV / 合成视频 / 3× 密集）→ 三场景
      `overlap=0 depth=0.0`，`avg` 16.3–16.5ms
- [x] `python tool/verify_segments_and_danmaku.py` → **8/8 OK**（`06_danmaku_frame_pacing`
      新增 `depth>2px` 与 `avg>18ms` 断言）
- [x] `python tool/verify_native_panels.py` → **8/8 cases OK，0 BAD**
- [x] 退出码回归（`run_close.py` ×3，`D:\Mova\MovaNativePlayer.exe`）→ `EXITCODE=0` ×3
- [x] `python tool/analyze_danmaku_bitmap.py`（新增）在修复前后位图上结论不同：
      修复前 6 处同轨间距 < 32px（BAD），修复后 0 处（OK）

### 人工验证

| 平台/尺寸 | 操作路径 | 预期结果 | 结果 |
|---|---|---|---|
| Windows 1920×1080 | 播放密集弹幕的剧集 | 弹幕一行一条、滚动连续无微抖 | 待用户确认 |
| Windows 1920×1080 | 设置 → 弹幕显示：关掉「顶部弹幕」 | 顶部弹幕立即消失，滚动弹幕不叠压 | 待用户确认（已自动化覆盖） |

## 风险与回滚

- 主要风险：
  1. **同屏丢弃率上升**：加入 32px 最小间距后单轨吞吐略降（约 -11%），极密集片源丢得更多
     （3× 密集合成场景实测 410 条 / 1040 条）。这是「不叠压」的必然代价，与主流播放器行为一致；
  2. **顶/底弹幕在极密集时被全部丢弃**（轨道全被滚动弹幕占用）。正常密度（14 条/秒）
     实测 `mixed=7~9`，说明顶/底弹幕正常显示；3× 密集合成场景下 `mixed=0`，属预期。
- 监测方式：`MOVA_TRACE_DANMAKU=1` 看 `overlap / depth / mixed / dropped / avg / late33`。
- 回滚步骤：还原 `windows/native_player/main.cpp` 后 `scripts\dev-verify.ps1 -Deploy`。

## 实现记录

**实际修改**

- `windows/native_player/main.cpp`
  - `DanmakuItem` 新增 `free_at`（让出轨道的时刻），用于局部回收轨道；
  - `PaintDanmaku()`：统一速度、占轨规则重写、32px 最小间距、丢弃策略、
    诊断指标（`mixed / depth / olane / orect / avg / late20 / late33`）；
  - `ApplyDanmakuSetting()`：撤掉一类弹幕时按在屏条目**重建** `lane_free`（不再整体归零）；
  - `DanmakuAnimationClock()` / `DanmakuPlayhead()` / `g_last_frame_ms` 改用 QPC
    （`g_position_tick` 由 `uint64_t` 改为 `double` 毫秒）；
  - `UpdateAutoSkip(GetTickCount64())`、重试健康窗口比较改回 `GetTickCount64` ——
    换时间源时这两处被 `/WX` 的 `C4244` 与逐处排查发现，属**真 bug**（混用会得负值，
    导致跳过倒计时永不触发、重试预算永不重置）。
- 新增工具
  - `tool/probe_danmaku_layout.py`（已有，本轮扩展 `mixed / depth / avg / late` 输出与判据）
  - `tool/analyze_danmaku_bitmap.py`（新）：像素层面量轨道带与同轨间距
  - `tool/tick_clock_probe.cpp` + `tool/build_clock_probe.cmd`（新）：量
    `GetTickCount64` vs QPC 粒度
  - `tool/verify_segments_and_danmaku.py`：`draws()` 解析扩展；`06_danmaku_frame_pacing`
    新增 `depth` / `avg` / `late33` 断言

**与原规格的偏差**

- 原计划只修「同轨叠压 + 拖影」两点，实施中额外发现并要求修复：最小同轨间距（浮点贴边）、
  设置变更时的轨道局部回收、以及两处时间源混用。
- 判据做了调整：**不看 `overlap` 条数，看 `depth` 像素深度**（条数会把浮点贴边算进来）；
  **不看 `gap` 最大值，看 `avg` 与 late 计数**（本机密集场景偶发 40.8ms 单帧停顿，连跑
  三次复现不出来（19.3 / 19.4 / 22.9ms），判定为后台编译 / DWM 合成噪声；一次抖动不再
  判 BAD，`late33 ≥ 3` 或 `late20 > 6` 才判）。

**测试结果**

- 修复前后对照（`probe_danmaku_layout.py`，同参数）：

| 场景 | 修复前 `overlap` | 修复后 `overlap` | 修复后 `depth` | `avg` |
|---|---|---|---|---|
| 静音 WAV | 99（基线） | **0** | **0.0** | 16.36ms |
| 合成 1080p 视频 | — | **0** | **0.0** | 16.35ms |
| 3× 密集（40 条/秒） | — | **0** | **0.0** | 16.53ms |

- 位图交叉验证（`analyze_danmaku_bitmap.py`）：修复后 16 条轨道全部使用、每条轨道内
  相邻弹幕墨迹间距 **39–44px**（设计间距 32px），修复前 6 处不足 32px。
- 部署：`D:\Mova\MovaNativePlayer.exe` 06:50:26（已确认 exe 内含新增诊断字面量）。

**遗留事项**

1. 弹幕文字**未加描边**：亮画面上白字的可读性仍依赖阴影。若用户看过后仍觉不足，
   下一步用 `GraphicsPath + DrawPath`（圆角接合的黑笔）加 1.5–2px 描边。
2. 顶/底弹幕在极密集片源上会被滚动弹幕挤掉（见「风险」），如需提高显示率要引入
   专用轨道划分 —— 属独立议题，不在本轮。
3. 代码仍随未提交的 `3.1.108` 一起待发版。
