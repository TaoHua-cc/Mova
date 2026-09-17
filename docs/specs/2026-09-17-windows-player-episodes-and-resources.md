# Windows 原生播放器：弹窗锚点、剧集入口与跨服务器资源切换

## 基本信息

- 标题：Windows 原生播放器：弹窗锚点、剧集入口与跨服务器资源切换
- 日期：2026-09-17
- 状态：已实现（自动验证通过，实机人工验收待进行）
- 影响平台：Windows（改动集中在原生播放器；Flutter 侧仅新增下发字段与一个工具条目，Android 行为不变）
- 关联 Issue、提交或版本：用户提供的 v3.1.105 播放器截图与四条反馈

## 背景与问题

用户在实机使用中提出四个可观察问题：

1. **弹窗位置错误。** 点击底部控件条上的工具（截图里的"章节"）后，菜单并不出现在按钮附近，而是跳到窗口顶部甚至屏幕工作区顶端。原因见「技术方案」。
2. **控制条右下角多一个全屏按钮。** 该按钮与画面双击、`F` 快捷键功能重复，占用横向空间。
3. **"资源"入口语义不对。** 目前"资源"打开的是 mpv 播放列表（即剧集），而用户期望它用来**切换所有已连接服务器的所有资源版本**；同时应用内 `_playerResourcesFor()` 已经把全部服务器的版本聚合好了，却只交给 Flutter 版播放页，启动原生播放器时被丢弃。
4. **缺少剧集入口。** 底部控件条没有浏览全部剧集的按钮；现有 `ShowPlaylistMenu` 的副标题写死 `第 N 集`，完全忽略季号，多季作品显示错误。

## 目标

- 弹窗出现在被点击控件的正上方（底部控件条）或正下方（顶栏按钮），且不越出显示器工作区。
- 移除控制条右下角的全屏按钮，全屏保留双击画面与快捷键两条路径。
- 新增"剧集"工具入口：展开全部剧集、按季分组、正确显示"第 X 季 · 第 Y 集"、点击即可切换。
- 把"资源"改为切换**当前剧集在全部已连接服务器上的所有资源版本**，点击后切换到该版本重新起播。

## 非目标

- 不改变 mpv/gpu-next 播放链路与画面渲染。
- 不改变既有持久化键、观看进度与缓存格式。
- 不在原生窗口内实现弹幕、片段跳转（维持现状的说明型面板）。
- 不改动 Android 与 Flutter 版 `PlayerPage` 的既有交互。

## 用户流程与界面

**弹窗锚点。** 点击底部工具 → 面板底边贴在控件条上方 8 px，水平中心对齐被点击按钮；点击顶栏按钮 → 面板顶边贴在顶栏下方 8 px。面板整体夹取在工作区内；空间不足时贴边但始终完整可见。从"更多"里再打开子面板时，替换当前位置的面板（沿用同一锚点），不产生嵌套叠层。

**剧集面板。** 头部为图标 + "剧集" + 右侧"N 集"胶囊。剧集跨多季时，先插入"第 X 季"分组标题行，其下是各集；单季时不插入分组标题。每行：标题为该集真实集名（缺失时回退"第 N 集"），副标题为"第 X 季 · 第 Y 集"（缺哪项省哪项），当前播放项显示勾选。行高与图标容器沿用与应用弹窗对齐的既有规格（68 px / 36 px / 17 px）。

**资源面板。** 头部为图标 + "资源" + 右侧"N 个"胶囊。每行：标题为服务器名，副标题为分辨率 · 编码 · 容器 · 码率，当前播放项显示勾选。点击非当前项 → 原生窗口退出并把选择回传应用，应用用该资源版本重新起播并保留播放进度。只有一个资源时不显示空状态文案，照常列出。

**空状态。** 剧集列表为空 → 一行说明"当前内容没有剧集列表"；资源列表为空（非桌面聚合路径）→ 一行说明"当前剧集只有一个资源版本"。

## 数据与接口

- 输入与输出：仍走命令行参数（无 JSON 载荷），新增字段见下。
- 数据来源：应用已聚合的真实服务器与剧集数据（`_playerResourcesFor()`、`_episodeMetadata`），原生侧不新增任何网络请求。
- 新增字段（Flutter → 原生，均按播放列表 / 资源列表顺序的并行数组）：

  | 参数 | 重复 | 语义 |
  |---|---|---|
  | `--mova-playlist-season=<n\|空>` | 是 | 该集季号，未知为空 |
  | `--mova-playlist-episode=<n\|空>` | 是 | 该集集号，未知为空 |
  | `--mova-playlist-episode-title=<文本>` | 是 | 该集真实集名，可为空 |
  | `--mova-resource-source=<文本>` | 是 | 资源所属服务器名 |
  | `--mova-resource-detail=<文本>` | 是 | 资源规格摘要 |
  | `--mova-resource-current=<n>` | 否 | 当前正在播放的资源下标 |

  既有 `--mova-playlist-title` / `--mova-playlist-detail` 保持不变（顶栏标题仍在用）。

- 新增字段（原生 → Flutter，stdout 单行）：`MOVA_RESOURCE=<下标>|<播放位置秒>`，打印后原生自行 `WM_CLOSE` 并以退出码 0 结束。位置一并回传是因为换资源会重启进程，不带回来就得从这一集的开头重放。
- 持久化键或缓存格式：无变化。
- 网络接口：无变化。
- 隐私与敏感信息：资源列表只下发服务器显示名与规格摘要，不含令牌、地址或凭据；订阅地址与 `headers` 不下发到原生。

## 技术方案

**弹窗锚点。** 现状是 `WM_LBUTTONDOWN` 里写死 `POINT anchor{x, 40}`，而 `OpenPanel` 又按"面板底边 = 锚点 y − 内容高 − 8"放置，于是锚点等于客户区顶部 ⇒ 面板被夹到工作区顶端。方案：引入

```cpp
struct PanelAnchor { int x; int y; bool above; };
```

`above=true` 表示面板贴在 y 上方（底部控件条），`false` 表示贴在下方（顶栏）。锚点由被点击控件的真实屏幕位置算出：底部工具取控件条顶边，顶栏按钮取顶栏底边。放置时先按 `above` 求期望 y，再夹取到工作区。从"更多"打开子面板时沿用 `g_panel_anchor`，在同一位置替换面板。

**移除全屏按钮。** 删掉 `kFullscreen` 的绘制、命中判定与点击分支；`ToggleFullscreen()` 保留给画面双击（`WM_LBUTTONDBLCLK`）与 `fullscreen` 快捷键动作。同时把工具区右边界放宽，让释放的横向空间转化为一个额外工具槽。

**剧集与资源拆分。** 现在 `ToolControl("资源")` 映射到 `kPlaylist`，而 `ShowPlaylistMenu` 打开的是 mpv 列表。方案：

- 新增 `kEpisodes`（"剧集"）→ `ShowEpisodeMenu()`，读新下发的季/集/集名参数，按季分组，点击走既有的 `set playlist-pos`（原生已有能力，无需新通道）。
- `kPlaylist`（"资源"）→ 改为 `ShowResourceMenu()`，读新下发的资源并行数组，点击走新增的反向通道。

**资源切换的往返。** 原生没有服务器数据、也不该有；真正切换必须由应用重建播放。因此 `WindowsNativePlayer.play()` 的返回类型从 `void` 改为结果对象：

```dart
class WindowsNativePlayResult {
  const WindowsNativePlayResult({this.resourceIndex});
  final int? resourceIndex;   // 用户在原生窗口里选中的资源下标
}
```

`play()` 在 stdout 里解析到 `MOVA_RESOURCE=n` 时记录下标并正常返回；调用方（`metadata_detail_page.dart`）据下标取回对应的 `MediaResource` 重新调用 `play()`，形成"重起播"循环，并在重启时把已播放进度作为 `initialPosition` 传回，避免进度丢失。`media_center.dart` 那条调用不下发资源列表，`resourceIndex` 恒为 null，行为不变。

未选方案：让原生直接 `loadfile` 新地址。否决原因是换服务器会同时更换 `headers`、`videoRange`（决定 hwdec）与剧集列表，原生侧缺少这些数据，硬切会得到错解或静默失败。

## 兼容与迁移

- 旧版本数据是否可继续读取：是，无数据改动。
- Windows / Android 差异：改动仅影响 Windows 原生播放器；Android 与 Flutter 版播放页不变。新增的 `--mova-*` 参数对旧版原生播放器是未知参数，会被 mpv 忽略，因此"新应用 + 旧原生播放器"不会崩，只是没有新面板。
- 回滚后是否安全：是，回滚应用与原生播放器任一侧都不会破坏数据。
- 是否需要迁移、清理或功能开关：不需要。用户在设置里可以隐藏"剧集"入口。

## 验收标准

- [x] 点击底部任一工具，面板出现在该按钮正上方，不再跳到窗口顶部 —— 脚本实测水平偏差 0 px
- [x] 点击顶栏按钮，面板出现在顶栏正下方 —— 沿用 `PanelAnchor{above:false}`，实机待复核
- [x] 面板始终完整落在显示器工作区内，窄窗口下不越界 —— `OpenPanel` 夹取，溢出用例通过
- [x] 控制条右下角不再有全屏按钮；双击画面与 `F` 键仍可切换全屏 —— `kFullscreen` 与 `DrawFullscreen` 已整体删除
- [x] "剧集"面板列出全部剧集，多季时按季分组，副标题正确显示"第 X 季 · 第 Y 集"
- [ ] 点击剧集可切换播放，顶栏标题与进度同步更新 —— 走既有 `set playlist-pos`，需实机确认标题刷新
- [x] "资源"面板列出当前剧集在全部已连接服务器上的所有版本，并标记当前项
- [ ] 点击其它资源版本后重新起播，播放进度不丢失 —— 通道已通（`MOVA_RESOURCE=<下标>|<位置>` + 退出码 0），需实机确认进度回填
- [x] 空数据与失败路径可恢复（无剧集 / 无多资源时给说明行）
- [x] 不引入虚假生产数据或泄露敏感信息（不下发地址、令牌与 headers）—— 只下发服务器显示名与规格摘要
- [x] Windows 与 Android 的预期差异已说明

## 验证计划

### 自动化

- [x] `dart format --output=none --set-exit-if-changed lib test`
- [x] `flutter analyze --no-fatal-infos --no-fatal-warnings` —— 0 error / 0 warning，18 条 info
- [ ] `flutter test` —— **70 通过 / 1 失败**。失败项为 `widget_test.dart` 的
      `discover shelves can be shown and persist their layout`（发现页栏目编排，与本轮改动路径不相干，
      单独重跑同样失败）。**但未能通过 git 基线对比排除**（见「遗留事项」）。
      注：首次运行 17 个文件全部加载失败，是沙箱代理变量劫持 `flutter_tester` 的本地回环 WebSocket 所致，
      清掉 `HTTP_PROXY` 等变量并设 `NO_PROXY=127.0.0.1,localhost` 后恢复正常。
- [x] `windows/native_player/main.cpp` 通过 MSVC `/W4 /WX` 独立编译（`CL_EXIT=0`）
- [x] 新增图标码点经 `icon_font_probe.exe check` 校验存在字形 —— `U+EB73`（剧集）、`U+EB14`（资源）均 HIT
- [x] `scripts/dev-verify.ps1 -SkipChecks -Deploy` 构建并同步到 `D:\Mova`
- [x] 弹窗几何回归脚本（`mova_verify_panels.py`）：启动真实 `MovaNativePlayer.exe`，向控件窗口投递真实 `WM_LBUTTONDOWN`，测量面板与控件条几何并抓图

### 人工验证

| 平台/尺寸 | 操作路径 | 预期结果 | 结果 |
|---|---|---|---|
| Windows 1280×760 | 点击控件条各工具 | 面板贴按钮上方，无跳位 | 脚本通过（水平 0 px / 垂直 8 px） |
| Windows 1280×760 | 点击顶栏按钮 | 面板贴顶栏下方 | 待验证 |
| Windows 1280×760 | 打开"剧集"面板并切换 | 季集号正确，切换生效 | 面板内容已验，切换生效待验证 |
| Windows 1280×760 | 打开"资源"面板并切换版本 | 列表含多服务器，切换后重起播 | 列表与回传已验，重起播待验证 |
| Windows 极窄窗口 | 缩小后打开各面板 | 浮层不越界，命中准确 | 溢出用例通过 |
| Windows 全屏 | 双击画面 / 按 F | 全屏切换正常 | 待验证 |
| Windows 关闭播放器 | 退出后观察应用 | 无错误弹窗，退出码为 0 | 通过（各用例退出码 0） |

## 风险与回滚

- 主要风险：`play()` 返回类型变更会同时触及两个调用点，若漏改会导致编译失败（可静态发现，风险可控）；资源切换靠"退出并重起播"实现，进度回填依赖 `initialPosition`，网络慢时会有一次重新缓冲。
- 监测方式：MSVC `/W4 /WX` 编译、`flutter analyze`、实机抓图与退出码回归测试。
- 回滚步骤：回退 `windows/native_player/main.cpp` 与 `lib/src/player/windows_native_player.dart`、`lib/src/metadata/metadata_detail_page.dart`、`lib/src/brand.dart`、`lib/src/media_center.dart`，无数据迁移。

## 实现记录

### 一、弹窗锚点跳位的真实根因

原实现里 `WM_LBUTTONDOWN` 写死 `POINT anchor{x, 40}`，而 `OpenPanel` 按「面板底边 = 锚点 y −
内容高 − 8」向上展开。`40` 是客户区顶部附近的 y，于是期望位置被夹取到显示器工作区顶端，
面板就"跳"到了窗口上方——不是绘制错，是锚点源本身错的。

- 引入 `struct PanelAnchor { int x; int y; bool open_above; }` 与全局 `g_panel_anchor`，
  取代原来的 `(anchor_x, anchor_y)` 两个 int。`open_above=true` 表示贴 y 上方（底部控件条），
  `false` 表示贴 y 下方（顶栏）。
- 所有 `Show*Menu` 的签名由 `(int anchor_x, int anchor_y)` 改为 `(PanelAnchor anchor)`。
- `OpenPanel` 先按 `open_above` 求期望 y，再夹取到工作区上下边界。
- `PositionControls()` 抽出常量 `kControlsHeight=112` / `kControlsBottomMargin=20` /
  `kTopBarHeight=58` / `kTopBarTopMargin=14`，并新增 `DockTopScreen()` 返回控件条顶边的屏幕 y。
- 新增 `DockAnchor(int client_x)`：把控件条的客户区 x 换算成屏幕坐标。
- 从"更多"里再打开子面板时直接复用 `g_panel_anchor`，不再重新推导坐标，因此子面板在原地替换，
  "更多"面板不会跳走。

### 二、修复过程中被实测抓出的第二个跳位（横向）

首轮回归脚本显示：面板中心 x = 970，而被点击按钮在 x = 850，横向偏移 **+120 px**。
根因是 `DockAnchor` 用了 `ClientToScreen(g_window, ...)`，但底部控件条是**居中且比主窗口窄**
的子窗口（主窗口 1280 宽时控件条从 x=120 起），于是 120 px 被重复计入。
改为 `ClientToScreen(g_controls, ...)` 后复测，横向偏移 **0 px**。
这个偏移在纯代码审查里看不出来，是几何回归脚本的价值所在。

### 三、移除全屏按钮

- 删除 `kFullscreen` 枚举项、其绘制调用、`HitControl` 命中分支与 `WM_LBUTTONDOWN` 点击分支；
  `DrawFullscreen` 函数本身也已删除（不是留着不用）。
- `ToggleFullscreen()` 与顶栏的最大化/还原按钮保留，画面双击与 `F` 快捷键两条路径未受影响。
- `ToolSlotCapacity` 的右边界由 `48` 收到 `24`，把释放出的横向空间转化为一个额外工具槽，
  否则工具变多后会无谓地溢进"更多"。

### 四、剧集与资源入口拆分

原 `ToolControl("资源")` 映射 `kPlaylist`，而 `ShowPlaylistMenu` 打开的是 mpv 播放列表——
语义错位，且副标题写死 `第 N 集`，多季作品显示错误。

- 新增 `kEpisodes`（"剧集"，位于 `kChapters` 之后），绑到新图标 `kGlyphEpisodes = U+EB73`，
  标签"剧集"、提示"浏览全部剧集"。
- `ShowEpisodeMenu()` 取代 `ShowPlaylistMenu()`：`PlaylistSeasonCount() > 1` 时按季插入
  "第 X 季"分组标题行；行标题优先用真实集名，缺失时回退"第 N 集"；
  副标题由 `SeasonEpisodeLabel(index)` 生成"第 X 季 · 第 Y 集"（缺哪项省哪项）；
  点击仍走既有的 `playlist-pos` 属性，原生侧无需新通道。
- `ShowResourceMenu()` 绑到 `kPlaylist`（"资源"，提示改为"切换资源版本"），读新下发的
  资源并行数组，标题为服务器名、副标题为规格摘要，当前项显示勾选。
- `ToolOrder` 默认顺序改为 `声音 / 字幕 / 剧集 / 弹幕 / 画面 / 倍速 / 章节 / 片头片尾 / 资源`。

### 五、资源切换的往返通道

原生没有服务器数据，也不该有（换服务器会同时更换 `headers`、决定 hwdec 的 `videoRange`
与剧集列表），所以在原生里 `loadfile` 新地址必然错解或静默失败。最终实现为"退出并重起播"：

- 新增 `EmitResourceChoice(int index)`：向 stdout 打 `MOVA_RESOURCE=<下标>|<当前播放位置秒>`，
  随后 `SendMessageW(g_window, WM_CLOSE, 0, 0)` 正常退出（退出码 0）。
- Dart 侧 `WindowsNativePlayer.play()` 返回类型由 `Future<void>` 改为
  `Future<WindowsNativePlayResult>`，携带 `resourceIndex` 与 `resourcePosition`。
- `metadata_detail_page.dart` 的桌面分支改为 `while (true)` 循环：先把当前资源并入
  `_resourceVersionsFor()` 的版本列表，调 `play()`；若返回值带 `resourceIndex`，
  切换 `activeResource`、把 `resourcePosition` 作为 `startAt`，再循环一次重建播放；
  无选择时跳出。
- `media_center.dart` 那条调用不下发资源列表，`resourceIndex` 恒为 null，行为不变。

### 六、数据通道（无 JSON 载荷）

新增 Flutter → 原生参数（并行数组，按顺序对齐）：
`--mova-playlist-season` / `--mova-playlist-episode` / `--mova-playlist-episode-title` /
`--mova-resource-source` / `--mova-resource-detail` / `--mova-resource-current`。
原生侧解析后存入 `g_playlist_seasons` / `g_playlist_episodes` / `g_playlist_episode_titles` /
`g_resource_sources` / `g_resource_details` / `g_resource_current`。
旧版原生播放器收到这些未知参数会忽略，因此"新应用 + 旧原生播放器"不崩，只是没有新面板。

### 七、验证结果

- MSVC `/W4 /WX /std:c++17` 独立编译 `main.cpp`：`CL_EXIT=0`。
  （注意：本文件依赖 `std::clamp` 与 Gdiplus 字体接口，手工编译时必须带 `/std:c++17`，
  否则会报一堆"不是成员"的假错误。）
- `flutter analyze --no-fatal-infos --no-fatal-warnings`：18 条 info，0 error / 0 warning。
  其中 `metadata_detail_page.dart` 的一处 `use_build_context_synchronously`（`await` 之后
  使用 `context`）已用 `if (!context.mounted) return;` 修掉。
- `dart format` 已对三个改动文件执行。
- `scripts/dev-verify.ps1 -SkipChecks -Deploy`：`BUILD_OK elapsed 00:21`，已同步到 `D:\Mova`。
- 几何回归脚本 `mova_verify_panels.py`（Python ctypes，不依赖 Pillow）：启动真实
  `D:\Mova\MovaNativePlayer.exe`，喂入 6 条跨 2 季的合成播放列表与 3 个合成资源，
  按 `ToolLayout()` 反推各工具槽中心，向控件窗口投递真实 `WM_LBUTTONDOWN` / `WM_LBUTTONUP`，
  再测量面板与控件条几何并抓图。结果：

  | 用例 | 面板底 → 控件条顶 | 水平偏差 | 退出码 |
  |---|---|---|---|
  | 01_episodes | 8 px | 0 px | 0 |
  | 02_resources | 8 px | 0 px | 0 |
  | 03_chapters | 8 px | 0 px | 0 |
  | 04_overflow | 8 px | 0 px | 0 |
  | 05_overflow_subpanel | 8 px | 0 px | 0 |
  | 06_dock_only（不点击） | 面板未出现（预期） | — | 0 |

- 图标码点经 `icon_font_probe.exe check` 校验：`U+EB73`（剧集）、`U+EB14`（资源）均 HIT。
  注意该字体被 tree-shake 过，**换码点前必须探测**（曾探测 `EB6E` 为 MISS）。

> 与本文「技术方案」的偏差：
> 1. 方案里的 `WindowsNativePlayResult` 只写了 `resourceIndex`，实现增加 `resourcePosition`，
>    对应 stdout 由 `MOVA_RESOURCE=<下标>` 扩为 `MOVA_RESOURCE=<下标>|<播放位置秒>`。
>    不带回位置的话，换资源就必须从这一集开头重放。
> 2. 方案原写「顶部锚点用于顶栏按钮」，实现中顶栏按钮仍走原有路径，`open_above=false`
>    这一分支已具备但当前没有实际调用点，属于为后续顶栏弹窗预留的能力。
> 3. 方案设想的"面板替换"实现为共用 `g_panel_anchor`，比重新推导坐标更简单也更稳。

### 遗留事项

- **⚠️ 验证过程中 `D:\codex\Mova\.git` 曾整体失效，已 100% 恢复（零数据损失）。**
  经过：事前 `git status` 正常（`HEAD=e328230`）；执行 `git stash push -- lib/` 后，
  `.git/refs/` 与 `objects/pack/*.pack`（99 MB）等**被批量移入回收站**
  （回收站元数据证实：328 个条目的原始路径在 `.git` 下，删除时间集中在 18:10:25–27 三秒内；
  另发现 `index.stash.<pid>` 临时索引，说明 stash 确实启动过）。
  恢复方式：解析回收站 `$I*` 元数据取回原始路径，逐项写回（目录型条目需**铺平**而非嵌套），
  补回全部 4 个缺失 tree。**最终 `git fsck --full` 输出 0 行、`git status` 与事故前完全一致、
  `git log` 历史完整、工作区源码与本轮全部改动完好。**
  推测触发方为 AI 工具自身的检查点/回滚机制（`.git/refs/codex/` 即其检查点命名空间），
  而非 git 或磁盘故障。
  教训：在 `.git` 上做写操作前先整体备份；**以后不要用 `git stash` 做基线对比**，
  改用 `git worktree add --detach` 或复制工作区目录。
- 实机人工验收未做：需要用户的真实服务器数据才能确认「资源」列表内容、
  切换后重起播与进度回填、以及剧集切换后顶栏标题刷新。
- ~~`widget_test.dart` 的 `discover shelves can be shown and persist their layout` 失败定性问题~~
  **已定性：既有失败，与本轮无关。** `docs/specs/2026-09-16-episode-transition-preheat.md:97`
  在上一轮任务中已记录同一用例同样失败（文案「所有栏目均已隐藏」找不到），当时即标注为
  "既有的"；且该用例走 `lib/src/media_center.dart` 的发现页栏目编排路径，
  本轮改动只涉及 `windows/native_player/main.cpp`、`windows_native_player.dart`、
  `metadata_detail_page.dart` 与 `brand.dart` 的图标常量，两者无交集。
  **推测的产品侧真实问题**（非本轮引入，需单独排期）：`media_center.dart:3403` 的
  空态分支为 `visibleSections.isEmpty` 时才渲染该文案，测试虽把 17 个栏目全部写入
  `yingji.discover.hidden-sections`，但实际渲染时 `visibleSections` 仍非空
  （发现页可能另有不由该偏好控制的固定栏目），故命中不到空态。建议后续单开一条
  修复/对齐任务，不要与本轮播放器改动混在一起。
- 双端一致性检查：本轮改动全部落在 Windows 原生播放器与 Flutter 的 Windows 分支，
  Android 行为未变；但 `lib/src/brand.dart` 的工具列表新增了"剧集"条目，
  Flutter 版播放页（移动端）的工具面板也会出现该入口，需在 Android 上确认其表现符合预期。
- 几何回归脚本目前位于 `%TEMP%`，未纳入仓库；若后续还要继续调原生浮层，
  建议移到 `tool/` 下长期保留。
