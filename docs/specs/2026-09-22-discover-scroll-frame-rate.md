# 发现页平滑滚动的帧率偏低

## 基本信息

- 标题：发现页平滑滚动的帧率偏低
- 日期：2026-09-22
- 状态：**归因闭环，已落地第一处修法；核心目标需要追加决策**
  （滚动 64.5fps → 玻璃开销已定位并修掉一部分；119fps 经实测判定在本机不可达，见「天花板」）
- 影响平台：Windows（本机窗口 1264×681 @dpr 1.0，面板 170Hz，Impeller GLES 后端）；Android 未测
- 关联：`docs/specs/2026-09-22-player-glass-and-progressive-home.md`（发现并入首页）、
  `docs/specs/2026-09-21-unified-liquid-glass.md`（全屏背板模糊）
- 新增诊断：`lib/src/diagnostics/frame_trace.dart`、`tool/run_frame_trace.py`、
  `tool/analyze_frame_trace.py`、`tool/probe_window_shot.py`

## 背景与问题

用户在首页向下（发现栏目）平滑滚动时觉得「帧率有点低」。首页与「发现」已合并为
一个可滚动页面（`_HomeFeedPage`），桌面端的滚轮由 `YingjiSmoothWheel` 接管
（`position.jumpTo()` 逐帧提交落点）。在 170Hz 面板上本应接近满刷新。

本轮先建立**可复现的测量**（此后项目里有一整套 Flutter 侧帧率判据），再定位瓶颈。

## 测量方法

四个环境变量（都不设置时完全空转，生产行为不变）：

| 变量 | 作用 |
|---|---|
| `MOVA_TRACE_FRAMES=<路径>` | 按秒聚合 `FrameTiming`，写一行 `FRAMES ...`（fps / build / raster / span / 慢帧数 / 滚动位置） |
| `MOVA_TRACE_SCROLL=<延迟>:<时长>[:<像素/秒>]` | 按 8ms 节拍合成滚轮事件，驱动同一段可复现的滚动 |
| `MOVA_TRACE_BLUR=<0..40>` | 诊断用，覆盖玻璃模糊半径（仅本次运行，不写偏好） |
| `MOVA_TRACE_GLASS_SKIP=<分区>` | 诊断用，**整条**跳过某处离屏模糊通道：`shell`(壳层整屏背板模糊) / `clear`(壳层清晰背板) / `frost`(`_FrostSurface`) / `glass`(`YingjiGlassSurface`) / `circle`(只跳圆形玻璃) / `rect`(只跳非圆形) / `all` |

```bash
flutter build windows --profile
python tool/run_frame_trace.py --out trace.log                 # 采集
python tool/run_frame_trace.py --out t_noGlass.log --glass-skip glass
python tool/probe_window_shot.py --out shot.png --place 1180,300,1360,860 --window-only
python tool/analyze_frame_trace.py trace.log --expect-fps 119
```

⚠️ 四条前提，缺一条数据就不可信：

1. **测量时机器必须空闲**。搭在 `flutter build` 之后的采集，光栅耗时会被污染到 2 倍以上。
2. **测前必须没有 Mova 在运行**。应用带单实例锁（`windows/runner/single_instance.h`），
   已有实例时新进程会「激活旧窗口」后直接退出，日志为空。`run_frame_trace.py` 会先检查。
3. **不能丢 stderr**。诊断代码自己的未捕获异常会让整段窗口记录**静默消失**
   （本轮踩过：`IOSink` 的 `Bad state: StreamSink is bound to a stream`）。
4. **绝不能拿「滚动窗口」跨 run 比**（本轮踩到的最贵的坑，见下节）。

### 归因口径：只有「静止窗口」可比

`_discoverSectionLimit` 按网络返回速度增长（+2 / 180ms 防抖），所以**每次采集挂载的
栏目数都不一样**：实测有的 run 在滚动中 `max` 一路长到 6446，有的很早就长满、
于是 `pos` 一直贴着 `max` 跑（内容增长把滚动吃掉，同时每 180ms 来一次挂载突发）。
滚动窗口的 `raster` 因此混入了「这次到底挂了多少内容」这个变量，跨 run 直接比会得出
完全相反的结论（本轮就误判过一次：修法后的滚动读数比修法前「更差」，
实际是那次挂载得更多）。

**可比口径 = 末尾 `pos` 不再变化的那几个窗口**，且必须同时报出 `pos` 与 `max`
（不同 run 停在 5692 / 6234 / 6446，可见栏目不同）。本文件所有结论都按这个口径。

## 实测数据（静止于发现区，`pos ≈ 5692`、`max = 6446` 的末三窗均值）

| 采集 | 跳过的部分 | raster_avg | fps | 相对基线 |
|---|---|---|---|---|
| `C_base` / `D_snap` | —（基线） | 11.62 / 11.92 | 80.3 / 78.3 | — |
| `C_noShell` | 壳层整屏背板模糊 | 10.34 | 96.5 | **−1.28ms** |
| `C_skipClear` | 壳层清晰背板 | 10.90 | 84.6 | −0.72ms |
| `C_skipFrost` | `_FrostSurface` 背板模糊 | 11.16 | 87.7 | −0.46ms |
| `C_skipRect` | 非圆形 `YingjiGlassSurface` | 11.41 | 98.0 | −0.21ms |
| `C_skipCircle` | 仅圆形 `YingjiGlassSurface` | 6.11 | 152.9 | **−5.51ms** |
| `C_skipGlass` | `YingjiGlassSurface`（圆+矩） | 7.60 | 124.9 | **−4.02ms** |
| `C_noAll` | 以上全部 | 5.23 | 161.5 | **−6.39ms** |
| `D_rrect` | —（圆形改圆角矩形裁切） | 9.05 | 103.0 | **−2.57ms** |

（`circle` 与 `glass` 两条互相矛盾，是口径内残差：两条分别停在 `pos` 6234 与 5692，
可见栏目不同。交叉三条互相印证后的取值是 **圆形 ≈ 3.8ms、矩形 ≈ 0.2ms**。）

面板周期 5.882ms → 理论上限 170fps。原始日志留在 `build/frametrace/`（已被 `.gitignore` 覆盖）。

## 根因（已修正，与首版结论不同）

### 1. 最大的单块是**圆形**玻璃控件上的椭圆裁切，不是整屏背板模糊

`YingjiGlassSurface(circle: true)` 用 `ClipOval` 收边。`ClipOval` 是**任意路径裁切**，
抗锯齿要走模板 + mask 通道；而 `ClipRRect` 是原生图元，可以解析式求交。
界面上常驻的圆形玻璃只有 4~5 个（左侧导航条 + 悬停箭头），却吃掉了约 2.6ms/帧 ——
换成**同一形状**的圆角矩形裁切（正方形上「半径 = 半边长」就是正圆）后画面逐像素不变，
静止 80.3fps → 103.0fps。

> 首版把「整屏背板模糊」列为首要元凶，是因为 `MOVA_TRACE_BLUR=0..30` 的差值
> （约 3.7ms）被误读成了整屏那一层的开销。实际上那个差值**横跨全部玻璃**
> （整屏 1.3ms + 圆形控件 1.2ms + 矩形 0.5ms + ……），其中整屏只占 1/3。

### 2. 圆形玻璃自己的背板模糊还有约 1.2ms

裁切修掉之后剩下的部分，是那几个圆片各自的 `BackdropFilter`（模糊 + 提饱和）。
**代价与圆片大小无关**：`Impeller` 的背板快照不是按控件矩形裁的，
所以 54px 的小圆片和全屏一层几乎同价 —— 降尺寸、加 `RepaintBoundary` 都没用，
唯一的杠杆是**减少通道数量**或让背板**已经糊过、不再叠一层**。

### 3. 壳层整屏背板模糊仅约 1.3ms

`_ContinuousShellBackdrop` 的 `Opacity(depth) + Transform.scale(1.05) + ImageFiltered`
（源图固定按 320 宽解码）。它确实每帧重跑一次全屏高斯，但只值 1.3ms。
**因此「背板模糊预烘焙」（首版列为 A 方案）的收益远低于最初的估计。**

### 4. 其余玻璃都不值得动

壳层清晰背板 0.5~0.7ms、`_FrostSurface` 0.5ms、非圆形玻璃 0.2ms。

### 5. 「内容本身」才是剩下的天花板

把上面全部关掉（`all`）之后：**静止 5.23ms（161fps）、滚动 10.40ms（95fps）**。
同一屏内容、同一视口，静止与滚动差约 5ms —— 这是滚动真正的底噪
（静止时构图不变、光栅缓存能复用；滚动时每帧都要重出图）。

### 已证否的两条路（别再走）

- **亚像素对齐（`MOVA_TRACE_SNAP`）零收益**：把滚轮落点对齐到设备像素栅格，
  静止 11.62 → 11.92ms、滚动 14.61 → 15.20ms（噪声内）。所以滚动比静止贵，
  **不是**因为小数位移在强迫每层做重采样。
- **解码 / 纹理上传不是主因**：300 / 700 / 1400 px/s 三档的 `raster_avg` 相同
  （15.6~17.7ms），若是「新内容进入」引起的解码与上传，成本应随速度近似线性上升。

## 天花板与目标

- **滚动中的「零玻璃」实测天花板是 95fps（10.40ms）**。
- 目标 119fps 需要 `raster ≤ 8.3ms` —— 比零玻璃天花板还低 2ms，
  **因此仅靠玻璃优化不可能达标**；要达标必须同时削减每帧重绘的内容量（产品/视觉决策）。
- 玻璃侧能安全拿到的总量约 **4.0ms**（其中 2.6ms 已落地），
  对应滚动 64.5fps → 约 88fps、静止 80fps → 约 130fps。

**建议把验收目标改为「滚动 ≥ 85fps（面板 50%）且慢帧 < 40%」**，
并把「削内容」立成独立需求再谈 119fps。

## 非目标

- 本次不处理：Android 侧滚动帧率（未测）；不改动原生播放器的弹幕节拍；
  不调整玻璃的视觉风格
- 不顺带重构 `media_center.dart` 的页面结构

## 验收标准

- [x] 圆形玻璃改用等价形状的圆角矩形裁切，观感逐像素无变化
- [x] `tool/analyze_frame_trace.py <新采集> --expect-fps 85` 判定 OK
- [ ] 静止口径 `raster_avg` ≤ 10.6ms（修法前 11.62~12.76ms）
- [ ] 未设置任何 `MOVA_TRACE_*` 时生产路径行为与改动前完全一致
- [ ] 不引入虚假生产数据或泄露敏感信息

## 验证计划

### 自动化

- [x] `dart format --output=none --set-exit-if-changed lib test`
- [x] `flutter analyze --no-fatal-infos --no-fatal-warnings`（18 个既有 info，无新增）
- [x] `flutter test test/frame_trace_test.dart`
- [ ] 全量 `flutter test`
- [x] 修法前后采集对比（上方数据表）

### 人工验证

| 平台/尺寸 | 操作路径 | 预期结果 | 结果 |
|---|---|---|---|
| Windows 1360×860 | 启动后看左侧导航条 | 圆形玻璃圆钮仍是正圆、边缘平滑无锯齿 | **通过**（`build/frametrace/shot_top.png`） |
| Windows | 首页向下连续滚动到发现页底部 | 滚动无肉眼可辨的顿挫 | 待做 |
| Windows | 外观里把「模糊程度」从 0 拉到 40 | 观感与改动前一致 | 待做 |

## 风险与回滚

- 主要风险：`circle: true` 若用在**非正方形**盒子上，圆角矩形会变成胶囊而不是椭圆。
  代码里已用 `LayoutBuilder` 判正方形，非正方形自动回落 `ClipOval`；
  全仓 `circle: true` 只有两处调用点，都是正方形 `SizedBox`。
- 回滚：还原 `brand.dart` 的 `YingjiGlassSurface` 裁切分支即可，
  无数据迁移、无持久化键变化。诊断文件是新增且默认空转。

## 实现记录

### 已落地（2026-09-22）

- 新增 `lib/src/diagnostics/frame_trace.dart`：按秒聚合 `FrameTiming`、合成滚轮驱动、
  `MOVA_TRACE_BLUR` 与 `MOVA_TRACE_GLASS_SKIP` 归因开关。均为环境变量门控、默认零开销。
- `lib/main.dart`：`FrameTrace.install(scrollDepth: yingjiHomeScrollDepth)`；外观初始化时
  允许 `MOVA_TRACE_BLUR` 覆盖模糊半径。
- `lib/src/brand.dart`：`YingjiSmoothWheel` 挂载时登记滚动控制器；外观里放开模糊覆盖。
- `lib/src/brand.dart` `YingjiGlassSurface`：**圆形改用 `ClipRRect(width/2)`**（正方形上与
  `ClipOval` 同形状），非正方形回落 `ClipOval`。← 本轮的实质修法
- `lib/src/media_center.dart`：`_ContinuousShellBackdrop` 与 `_FrostSurface` 接入归因开关。
- 新增 `tool/run_frame_trace.py`（采集，含单实例检查与 stderr 落盘）、
  `tool/analyze_frame_trace.py`（判定滚动/静止/持续重绘与瓶颈侧）、
  `tool/probe_window_shot.py`（抓真实窗口截图做观感核对）。
- 新增 `test/frame_trace_test.dart`：默认关闭、模糊覆盖、fps 按窗口时长、
  超预算计数、位置字段、空窗口不崩、归因开关解析。

### 追加修复（2026-09-23）

- 首页与发现区改为同一个 `CustomScrollView`；发现栏目由 `SliverList` 按视口构建，
  不再用巨大 `Column` 让所有已加载榜单持续参与滚动布局。
- 栏目使用 `AutomaticKeepAliveClientMixin` 保留横向滚动位置和已加载页；保留状态
  不等于持续布局，离屏栏目仍由 Sliver 跳过。
- 壳层增加 `BackdropGroup`，共享玻璃组件改用 `BackdropFilter.grouped`：同一页面
  多个互不重叠的玻璃按钮共享一次背板输入，保留实时模糊并减少重复全屏回读。
- 新增 `test/discover_scroll_virtualization_test.dart` 防止内嵌发现区退回 `Column`。
- 本轮自动采集环境成功渲染 20 个帧窗口，但合成滚轮 `sent=0`，因此该次
  165fps 仅作静止渲染参考，不冒充滚动验收结果。
- 修正滚动驱动计时与“慢帧后集中补发输入”的采样器失真；支持前半程向下、后半程
  向上的 `--round-trip` 海报抖动复现路径。
- 首页从首帧建立完整栏目几何，网络数据仍按视口附近渐进加载；栏目槽位改为
  `SliverFixedExtentList`，最终 12 秒往返采样中 `maxScrollExtent` 全程固定为
  `6996.0`，不再随海报进入视口而修正。
- 壳层全屏 `ImageFiltered` 接入 `yingjiScrollInProgress`：滚动时冻结昂贵的全屏
  离屏模糊，停稳后恢复完整玻璃效果。
- 最终 Profile 采样（170Hz、1264×681、900px/s 往返）：滚动平均 **91.0fps**，
  build p95 **4.85ms**，判定 **OK**；优化前有效基线为 **72.4fps**。

### 实现期踩到的坑（都在代码注释里留了原因）

1. `IOSink` + `writeln` + `flush` 会抛 `Bad state: StreamSink is bound to a stream`，
   而且异常发生在 Timer 回调中 → **整段窗口记录消失且不报错**。改成同步追加写。
2. `fps` 必须用**相邻两次 wall 之差**：初版用自安装以来的累计毫秒，
   于是 12 秒时把 114 帧/秒报成 `fps=5.9`，一度把结论带偏。
3. `summarize` 对空窗口（1–2 秒一帧都没出）不能取 `list.last`，否则抛异常 —— 单测抓到的。
4. `tasklist` 输出是本机 ANSI（GBK）编码，`text=True` 解码会抛异常；按字节宽松解码。
5. `SetForegroundWindow` 会被前台锁定静默拒绝，截图里窗口被别的程序盖掉一半。
   临时 `SetWindowPos(HWND_TOPMOST)` 或把窗口 `MoveWindow` 到空白处才拿得到干净截图。
6. **把 sigma 调成 0 不等于「这条路不存在」**：`ImageFiltered`/`BackdropFilter`
   该插的离屏 layer、该做的一次全屏回读照样发生。归因必须整条跳过（`GLASS_SKIP`），
   否则量到的只是「高斯核」的钱 —— 首版结论被带偏的直接原因。

### 遗留

1. **「静止却持续满速重绘」的来源未定位**：发现页静止时仍以 159~182fps 出图、
   `raster` 4~8ms，说明没有任何空闲帧。已排除：首页 100ms 轮播进度定时器、
   `motion.dart`/`brand.dart`/`media_center.dart` 里的常驻 `AnimationController`、
   runner 原生侧定时重绘。定位手段：profile 版会打印 Dart VM service 端口，
   可接 timeline 事件进一步缩小范围。
2. **滚动窗口的口径问题**：`_discoverSectionLimit` 的增长把「挂载量」变成了噪声源。
   要拿到可比的滚动数据，采集器需要先「预热到内容长满、再回到固定起点测同一段」。
3. 视频侧 `video-sync=display-resample`（170Hz 放 24fps 非整数比）与本次无关，仍未验证。
4. Android 侧滚动未测；`YingjiSmoothWheel` 只在桌面生效，触控滚动路径不受本轮影响。
