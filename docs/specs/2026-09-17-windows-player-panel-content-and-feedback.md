# Windows 原生播放器：菜单内容互斥、剧集/资源面板信息补全与交互反馈

## 基本信息

- 标题：Windows 原生播放器菜单内容互斥、剧集/资源面板信息补全与交互反馈
- 日期：2026-09-17
- 状态：已实施（原生 + Flutter 双侧完成，自动化检查通过；实机视觉验收待用户过一遍下表）
- 影响平台：Windows（原生播放器）+ Windows 分支的 Flutter 侧；Android 行为预期不变
- 关联：接续 `docs/specs/2026-09-17-windows-player-episodes-and-resources.md`

## 背景与问题

用户在实机使用 Windows 原生播放器时提出九点问题。以下均为**已核实的可观察事实**，不是推测：

### 1. 打开一个菜单会显示其它菜单的内容（最严重）

`main.cpp:1211 OpenToolPanel()` 只有七个分支：

```
kAudio → ShowTrackMenu(true)      kSubtitle → ShowTrackMenu(false)
kDanmaku → ShowDanmakuMenu        kChapters → ShowChapterMenu
kEpisodes → ShowEpisodeMenu       kSegments → ShowSegmentMenu
kPlaylist → ShowResourceMenu      else → ShowPlaybackMenu
```

而 `kSpeed`（倍速）、`kPicture`（画面）、`kPlaybackSettings`（播放设置）**三者全部落入最后的 `else`**，
进的是 `main.cpp:516 ShowPlaybackMenu()` —— 一个混合面板，行构成是：

```
PanelHeader「播放速度」 + 6 个倍速选项
PanelHeader「画面比例」 + 4 个比例选项
2 条 PanelNote（弹幕状态、片头片尾状态）
= 14 行
```

所以点「倍速」和点「画面」，看到的是**同一个**包含倍速 + 画面比例 + 弹幕说明 + 片头片尾说明的面板。
按行高常量算内容高 812px，超过 `kPanelMaxContentHeight = 470` 被夹住，表现为一个需要滚动的长列表。

### 2. 剧集面板没有预览图，打开时不定位当前集

`main.cpp:641 ShowEpisodeMenu()` 每行只有文字（集名 + 「第 X 季 · 第 Y 集」副标题）。
此外 `main.cpp:1737` 在 `OpenPanel()` 里把 `g_panel_scroll` **硬置为 0**，
所以无论当前播到第几集，面板永远从第一集开始显示。

数据侧：`lib/src/player/windows_native_player.dart:108` 的 `WindowsNativePlaylistEntry`
**已经有 `imageUrl` 字段**，只是打包命令行时（同文件 300–306 行）只下发了
season / episode / episode-title，没有下发图片。

### 3. 资源面板没有服务器图标

`main.cpp:689 ShowResourceMenu()` 每一行都用同一个 `kGlyphServer` 字形，
无法区分版本来自哪个（或哪类）服务器。
数据侧：`WindowsNativeResourceOption`（`windows_native_player.dart:16`）只有 `source` 与 `detail`，
**没有服务器类型字段**。

### 4. 播放器打开时不在屏幕中间

`main.cpp:2590` 用 `CW_USEDEFAULT, CW_USEDEFAULT` 创建主窗口，位置交给系统决定（层叠），未做居中。

### 5. 控件条顶部有一条白条

`main.cpp:2017-2018`：

```cpp
Gdiplus::Pen surface_edge(Gdiplus::Color(76, 255, 255, 255), 1.0f);
graphics.DrawLine(&surface_edge, 18.0f, 1.0f, rect.right - 18.0f, 1.0f);
```

一条纯白、alpha=76 的 1px 水平线。出于「顶部内高光」的意图，但对比度过高。

**像素实测**（用户提供的 1069×53 截屏，逐行扫描）：

| 行 | RGB | 说明 |
|---|---|---|
| y=0–16 | 如 (164,140,93) | 视频画面 |
| y=17 | (27,25,25) | 深色外描边，1px |
| **y=18** | **(103,102,102)** | **白条本体，1px** |
| y=19+ | (43,43,44) → 渐变 | 控件条背景 |

验算：白 255 以 alpha 76/255 叠在背景 (39,41,48) 上 = `39 + (255-39)×0.298 ≈ 103`，与实测吻合。
问题不止是亮，还有**色相**：这条线是中性灰（R≈G≈B），而控件条背景偏蓝 (43,43,44)，两者不协调。

### 6. 全屏时按 ESC 直接退出了播放

`main.cpp:2343`，快捷键 `exit` 绑定 `Escape`（2647 行），其实现是：

```cpp
} else if (action == "exit") {
    SendMessageW(g_window, WM_CLOSE, 0, 0);
}
```

不判断 `g_fullscreen`，所以全屏下按 ESC 会直接关掉播放器，而不是先退出全屏。

### 7. 控件按钮鼠标悬浮时不显示名称

全文件无 tooltip 相关实现。控件条上只有图标，鼠标悬停仅有一个高亮动效
（`HoverAmount()` / `DrawHover()`），不显示这个按钮叫什么。

### 8. 调节亮度 / 音量 / 快进快退时没有符合产品风格的实时提示

`main.cpp:326`：

```cpp
void ShowToast(const std::string& text) { MpvCommand("show-text", text.c_str(), "1200"); }
```

所有提示都转给 **mpv 自己的 OSD** 渲染 —— 用的是 mpv 的默认字体、默认位置与默认样式，
与 Mova 的界面完全不是一套语言。这也解释了为什么用户会同时提出第 9 点。

### 9. 各处 UI 风格不统一

已发现的具体不一致：面板边缘描边 alpha=46（`main.cpp:1592`）、
控件条顶部描边 alpha=76（`main.cpp:2017`），同为「白色内描边」却取了两套值；
OSD 提示走 mpv 渲染，与自绘浮层风格割裂。

## 目标

- 每个工具菜单只呈现该工具自己的内容，互不混入。
- 剧集面板每行显示该集预览图，打开时自动滚动到当前播放的集。
- 资源面板每行显示对应服务器的图标，可区分不同来源。
- 播放器窗口每次打开都位于当前显示器工作区正中。
- 消除控件条顶部的白条，边缘处理与面板统一。
- 全屏状态下按一次 ESC 先退出全屏；非全屏时 ESC 才结束播放。
- 控件按钮鼠标悬停时显示该按钮名称。
- 音量、快进快退、亮度/画面等调整操作给出实时提示，且提示为 Mova 自绘、风格与整体一致。

## 非目标

- 本次明确不处理：
  - Android 侧播放器的对应改动（Android 不使用该原生播放器）。
  - 弹幕在原生窗口的实际渲染（维持现状：只给状态说明）。
  - 面板最大高度 470 的自适应（已在上一份规格记录为独立建议，本轮不捆绑，避免范围失控）。
  - mpv 自身 OSD 的彻底禁用（需评估是否影响其它调试信息，单列风险评估）。

## 用户流程与界面

### 菜单互斥

- 入口：控件条各工具按钮；放不下的工具进「更多」。
- 行为：点击某工具 → 面板只含该工具的行；再点另一个工具 → 面板内容整体替换。
- 空状态：无数据时给一行说明（如「当前内容没有剧集列表」「没有其它可切换的资源版本」），维持现有写法。
- 失败状态：属性读取失败按空处理，不显示假数据。

### 剧集面板

- 每行左侧为该集预览缩略图（圆角裁切，与卡片风格一致），右侧为集名与「第 X 季 · 第 Y 集」。
- 打开面板时，当前播放集滚动到可视区内（尽量居中；首尾处贴边）。
- 缩略图未就绪时显示占位（不显示破图或空白）。
- 多季时保留「第 X 季」分组标题。

### 资源面板

- 每行左侧为服务器图标（按服务器类型区分），右侧为服务器名 + 规格摘要。
- 当前版本仍以选中态标记。

### 交互反馈

- 控件按钮 hover：短暂延迟后在按钮上方显示名称气泡；移开即隐藏。
- 调节类操作（音量、快进快退、倍速、画面比例等）：在画面上方居中显示一条自绘提示，
  约 1.2 秒后淡出；连续操作时刷新内容而不叠加多个提示。

### 平台差异

- 全部改动位于 Windows 原生播放器与其 Flutter 宿主；Android 不受影响。
- 窄窗口下控件条会进入 compact 模式（隐藏上一集/下一集），提示与 tooltip 需尊重该模式。

## 数据与接口

### 原生播放器新增命令行参数（**已实施，以本节为准**）

| 参数 | 含义 | 取值 |
|---|---|---|
| `--mova-playlist-image=<路径或空>` | 第 N 集的预览图**本地文件路径** | 可空，空表示这一集没有预览图 |
| `--mova-playlist-meta=<文本或空>` | 第 N 集卡片副标题里附在季号之后的补充信息 | 如 `2023-05-12 · 44 分钟`，可空 |
| `--mova-playlist-progress=<0..1 或空>` | 第 N 集的观看进度 | 空表示没有观看记录，面板不画进度条 |
| `--mova-playlist-duration=<秒或空>` | 第 N 集总时长 | 空表示时长未知，只画进度不带时间 |
| `--mova-resource-icon=<路径或空>` | 第 N 个资源版本的服务器图标**本地文件路径** | 可空，空则按 `mark` 画兜底标记 |
| `--mova-resource-mark=<1\|2\|3\|0>` | 兜底服务器类型 | 1 Emby（绿）、2 Jellyfin（紫）、3 WebDAV（蓝）、0 不画 |
| `--mova-resource-rank=<1..3 或 0>` | 版本名次，原生给图标描金 / 银 / 铜环 | 0 表示不排名次 |

全部按出现顺序对应第 N 项，与现有 `--mova-playlist-title/season/episode/episode-title`、
`--mova-resource-source/detail` 保持同一约定；原生侧在参数解析结束后把各并行数组统一补齐到
`media_urls.size()` / `g_resource_sources.size()`，因此中间某项缺发也不会错位。

> 与草案的差异：草案里的 `--mova-playlist-thumbnail` 最终实现为 `--mova-playlist-image`；
> 资源侧的 `--mova-resource-icon` 承 **1 类型枚举** 改为「本地路径 + 兜底枚举」两项，
> 理由是详情页的 `ServerMark` 本来就会显示服务器自定义图标，只按类型画图会与详情页不一致。

### 服务器类型到兜底标记的映射（已实施）

不再需要枚举更多来源类型：图标优先用应用取下来的真图，兜底才按 `SourceKind` 三值区分，
且配色与 `lib/src/sources/server_mark.dart` 的 `ServerMark` 逐一对应
（`emby` 绿 `#58D568→#18853A`、`jellyfin` 紫 `#9B5DE5→#3157C8`、`webdav` 蓝 `#4B88C7→#23456B`）。
WebDAV 画云朵，Emby/Jellyfin 画旋转方块套播放三角 —— 这两条也与 `ServerMark._defaultMark` 一致。

### 缩略图的获取方式（**决策：方案 A，已实施**）

选定方案 A：Flutter 侧在起播前把剧照落到本地缓存，只把**文件路径**下发，原生用
`GdipCreateBitmapFromFile` 加载。缓存直接复用 `flutter_cache_manager` 的 `DefaultCacheManager`
—— 也就是详情页剧集栏显示剧照时用的那一份磁盘缓存，因此**不新增缓存目录，也就不需要新的
清理策略**：占用的就是应用本来就有的图片缓存，由既有策略负责淘汰。

### 隐私与敏感信息

- 下发给原生的仍然只有显示用文本、本地图片路径与类型枚举；
  地址、请求头、令牌一概不下发，维持既有边界。
- 本地缓存路径不得包含服务器地址或令牌。

## 技术方案

### 模块划分

- `windows/native_player/main.cpp`
  - 菜单拆分：新增 `ShowSpeedMenu`（只含播放速度）、`ShowAspectMenu`（只含画面比例）；
    调整 `OpenToolPanel` 的分发，使 `kSpeed` / `kPicture` / `kPlaybackSettings` 各走自己的面板；
    `ShowPlaybackMenu` 收缩为真正的「播放设置」（只含属于播放设置的开关与说明，不重复倍速/比例的选项列表）。
  - 面板行扩展：`PanelItem` 增加缩略图字段（可选）；新增带缩略图的行绘制；
    `ShowEpisodeMenu` 填缩略图并设置初始滚动位置。
  - 资源图标：`ShowResourceMenu` 按类型选字形。
  - 窗口居中：创建后按 `MonitorFromWindow` + `GetMonitorInfo` 工作区居中。
  - 白条与描边统一：抽出统一的边缘高光颜色常量，替代现在两处不同的 alpha。
  - ESC 语义：`RunShortcut` 的 `exit` 分支先判断 `g_fullscreen`。
  - Tooltip：新增自绘 tooltip（复用面板的圆角/渐变/字体语言），需要 hover 延迟与定时器。
  - OSD：新增自绘提示浮层（`WS_POPUP` + layered，与面板同一套渲染路径），
    替代 `ShowToast` 的 mpv `show-text`。
- `lib/src/player/windows_native_player.dart`
  - `WindowsNativeResourceOption` 增加服务器类型字段；`WindowsNativePlaylistEntry`
    的 `imageUrl` 纳入命令行下发（转本地路径）。
  - 新增缩略图缓存（若确认走方案 A）。
- `lib/src/player/player_page.dart` / `lib/src/metadata/metadata_detail_page.dart`
  - 补齐服务器类型与缩略图路径的构造与传递。

### 复用

- 面板渲染走既有 `PaintPanelContent` / `AddRoundedRectPath` / `DrawPanelOptionRow`，
  不另起一套绘制风格。
- 字体统一走 `MakeInterfaceFont`；图标统一走 `g_iconsax_font_family`。
- 提示浮层与面板共用「layered window + UpdateLayeredWindow + 预乘位图」这条路径，
  以获得同样的圆角抗锯齿与投影。

### 关键取舍

- Tooltip 与 OSD 都不使用系统原生控件（`TOOLTIPS_CLASS` / `TrackPopupMenu`），
  因为它们无法匹配自绘风格，这正是当前 mpv OSD 的问题根源。
- 剧集缩略图选择「本地文件路径」而非 URL，理由见上。

## 兼容与迁移

- 旧版本数据是否可继续读取：本轮不涉及持久化键与缓存格式变更。
- 新增命令行参数全部可选，缺省时回落为现状（无缩略图、通用图标），
  因此新旧 Flutter 与原生 exe 交叉组合不会崩溃。
- Windows / Android 差异：Android 不受影响；Windows 分支的 Flutter 改动需保证移动端仍可编译运行。
- 回滚后是否安全：回滚原生 exe 与 `lib/` 即可，无数据迁移。
- 是否需要迁移、清理或功能开关：缩略图缓存需要清理策略（上限 + 过期），需在实施时定。

## 验收标准

- [ ] 点「倍速」只看到播放速度选项；点「画面」只看到画面比例选项；两者不再混入弹幕与片头片尾说明
- [ ] 「更多」里的「播放设置」不再重复倍速与画面比例的完整选项列表
- [ ] 剧集面板每行显示该集预览图，无图时显示占位而非空白或破图
- [ ] 打开剧集面板时当前播放集位于可视区内
- [ ] 资源面板各行显示可区分来源的服务器图标
- [ ] 播放器每次打开位于当前显示器工作区正中
- [ ] 控件条顶部不再有突兀白线，其边缘处理与面板一致
- [ ] 全屏下按一次 ESC 退出全屏；再次按 ESC 才结束播放
- [ ] 控件按钮鼠标悬停显示名称，移开后消失，窄窗口 compact 模式下同样正确
- [ ] 音量/快进快退/倍速等调整有实时提示，提示为自绘且风格与面板一致
- [ ] 空数据和失败路径可恢复（无剧集 / 无多资源 / 缩略图缺失）
- [ ] 不引入虚假生产数据或泄露敏感信息（不下发地址、令牌与 headers）
- [ ] Windows 与 Android 的预期差异已说明

## 验证计划

### 自动化

- [x] `dart format lib` → 43 文件 0 待改（`FMT_EXIT=0`）
- [x] `flutter analyze --no-fatal-infos --no-fatal-warnings` → 18 条 info 全部既有，
      本轮改动的三个文件 0 条（`ANALYZE_EXIT=0`）
- [x] `flutter test` → 71 项 / 70 通过；唯一失败为既有失败（见实现记录）
- [x] `windows/native_player/main.cpp` 通过 MSVC `/W4 /WX /std:c++17` 独立编译（`CL_EXIT=0`）
- [x] 新增图标码点（`kGlyphGauge` / `kGlyphCrop` / `kGlyphEpisodes` / `kGlyphServer`）沿用既有已验证字形
- [ ] 几何回归脚本扩展用例：倍速 / 画面 各自的面板高度应等于其**单独**内容的高度
      （而不是 470 夹住值），以此断言菜单互斥已生效 —— **未执行**，脚本仍在 `%TEMP%` 未入库
- [ ] 剧集面板初始滚动位置断言：当前集的行矩形落在面板可视区内 —— **未执行**
- [ ] 像素断言：控件条顶部 1px 区域的亮度与背景差值应低于阈值（修复前实测 103 vs 43）—— **未执行**
- [ ] 播放器窗口首次显示时，窗口矩形中心与工作区中心偏差在容差内 —— **未执行**

> 后四项几何/像素断言本轮改为人工目视，原因是验证脚本尚未纳入仓库（见实现记录「遗留」）。
> 待脚本移入 `tool/` 后补跑。

### 人工验证

| 平台/尺寸 | 操作路径 | 预期结果 | 结果 |
|---|---|---|---|
| Windows 1280×760 | 依次打开倍速、画面、弹幕、片头片尾 | 每个面板只含自己的内容 | 待验证 |
| Windows 1280×760 | 打开剧集面板（播到第 5 集） | 面板定位到第 5 集，各行有预览图 | 待验证 |
| Windows 1280×760 | 打开资源面板（多服务器） | 各行图标可区分来源 | 待验证 |
| Windows 1280×760 | 关闭后重新打开播放器 | 窗口出现在屏幕正中 | 待验证 |
| Windows 1280×760 | 观察控件条上边缘 | 无白色横条 | 待验证 |
| Windows 全屏 | 全屏后按 ESC | 退出全屏，播放继续 | 待验证 |
| Windows 全屏 | 退出全屏后再按 ESC | 结束播放 | 待验证 |
| Windows 1280×760 | 鼠标依次悬停每个控件按钮 | 显示对应名称 | 待验证 |
| Windows 1280×760 | 按方向键调音量、方向键快进快退 | 出现自绘提示，风格与面板一致 | 待验证 |
| Windows 极窄窗口 | 缩小后重复上述操作 | 浮层不越界，compact 模式正确 | 待验证 |

## 风险与回滚

- 主要风险：
  1. 一次性改动面较大（原生菜单分发、行绘制、窗口定位、按键语义、新增两类浮层），
     容易引入回归；建议按「菜单互斥 + 窗口居中 + ESC + 白条」与
     「剧集缩略图 + 资源图标 + tooltip + OSD」两批交付，每批独立验证。
  2. 缩略图引入本地缓存，涉及磁盘占用与清理策略。
  3. 用自绘 OSD 替代 mpv `show-text` 后，需确认 mpv 侧不再残留旧提示
     （可能要显式设置 `osd-level=0` 或 `osd-bar=no`）。
- 监测方式：几何回归脚本 + 像素断言 + 退出码检查；人工过一遍上表。
- 回滚步骤：还原 `windows/native_player/main.cpp` 与相关 Dart 文件；无数据迁移，直接可用。

## 实现记录

九点需求全部落地，改动集中在原生 `windows/native_player/main.cpp` 与 Flutter 三处
（`windows_native_player.dart`、`metadata_detail_page.dart`、`server_mark.dart`）。

### 原生侧（`windows/native_player/main.cpp`）

**菜单互斥（需求 1）** —— 删掉混合的 `ShowPlaybackMenu`，拆成两个只含自己内容的面板：

- `ShowSpeedMenu()`：只含播放速度（`SpeedLabel()` 生成「1.0×」这类标签）。
- `ShowPictureMenu()`：只含画面比例 4 项 + 亮度 5 档（-30 / -15 / 0 / 15 / 30，走 mpv
  `brightness` equalizer）。
- `OpenToolPanel` 改为 `switch` 穷举 `kAudio`/`kSubtitle`/`kDanmaku`/`kChapters`/`kEpisodes`/
  `kSegments`/`kPicture`/`kSpeed`/`kPlaylist`，兜底不再混装。

**剧集面板（需求 2）** —— `PanelItem` 新增 `image` / `progress` / `duration` 字段；
新增 `DrawPanelEpisodeCard()`：圆角裁切缩略图 + 封面下方渐变遮罩内的进度条与时间
（复用 `ClockLabel`）+ 当前集右上角勾选 + 标题「第 X 集 · 集名」+ 副标题「第 X 季 · meta」。
面板布局由一维行高改为二维：新增 `PanelBox` / `g_panel_boxes` / `LayoutPanelRows()`，
剧集卡按 `kPanelGridColumns = 3` 列排布、行高取该行最高盒子；`PanelIndexAt()` 改为按盒子
命中测试。`OpenPanel()` 新增 `PanelMetrics.reveal`，剧集面板把当前集的行下标传进去，
打开即滚动到该行（`g_panel_scroll` 不再被硬置 0）。

**资源面板图标（需求 3）** —— 新增 `DrawServerMark()`（按 `mark` 选渐变：2 紫 = Jellyfin、
3 蓝 = WebDAV、默认绿 = Emby；WebDAV 画云朵，其余画旋转方块套播放三角），
有真图时走新增的 `CachedImage()` + `DrawCoverImage()`；`item.rank` 为 1..3 时给图标描金 / 银 / 铜环。

**窗口居中（需求 4）** —— `wWinMain` 里改用 `SPI_GETWORKAREA` 算工作区矩形，居中创建窗口，
不再用 `CW_USEDEFAULT`。

**白条（需求 5）** —— 控件条顶部描边由 `Color(76, 255, 255, 255)` 改为
`Color(BYTE{kSurfaceEdgeAlpha}, ...)`，新增常量 `kSurfaceEdgeAlpha = 46`；
`PaintPanelContent` 的面板边缘一并改用该常量，两处描边从此同值。

**ESC（需求 6）** —— `RunShortcut` 的 `exit` 分支先判 `g_fullscreen`：全屏时
`ToggleFullscreen()` 并提示「再按一次退出播放器」，非全屏才 `WM_CLOSE`。

**hover 名称与实时提示（需求 7、8）** ——
新增自绘提示浮层：`HintMode{Hidden, Tooltip, Toast}`、`ShowHint()` / `ShowAdjustHint()` /
`ShowVolumeHint()` / `ControlTooltip()` / `ControlCenterX()` / `HideHint()`，
底层是 `g_hint` 分层窗口（`WS_EX_TOOLWINDOW|WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_NOACTIVATE`），
`PaintHint()` 与面板同字体、同灰阶、同描边。`ShowToast()` 不再调 mpv `show-text`。
控件条上进度拖动、快进退、静音、音量都接 `ShowAdjustHint` / `ShowVolumeHint`（拖动去抖），
hover 走 `ControlTooltip` + `ControlCenterX` 取锚点，`WM_TIMER` 里提示随控件条淡出而隐藏。

**风格统一（需求 9）** —— 描边常量统一（见需求 5），提示浮层与面板共用同一套绘制路径与字体，
不再有 mpv OSD 的异质样式。

### Flutter 侧

- `lib/src/sources/server_mark.dart`：新增 `cacheServerMarkFile(source, token)`，按 `ServerMark`
  同一规则把服务器图标落到应用支持目录 `server_marks/`（base64url 文件名），自定义图标去平底色、
  同主机时带 `X-Emby-Token`；同一 URL 只取一次（`_markFileCache`）。失败返回 null。
- `lib/src/player/windows_native_player.dart`：
  - `WindowsNativeResourceOption` 新增 `iconPath` / `mark` / `rank`。
  - `WindowsNativePlaylistEntry` 新增 `imagePath` / `progress` / `duration` / `meta`。
  - 参数循环下发上述七项，空值下发空串（原生有兜底）。
  - 新增 `cacheImageFile(url)` 与 `cacheImageFiles(map, budget)`：后者**先在磁盘缓存里找**
    （`getFileFromCache`，离线瞬时），只有真缺图的才并发下载，整体还有 3 秒预算。
    串行 `getSingleFile` 会在没缓存时把起播卡住好几秒、网络不通时卡到 HTTP 超时 ——
    这是本地实现里特意避开的坑，超预算的那几集在面板里退化为占位图。
- `lib/src/metadata/metadata_detail_page.dart`：`_play` 在重播循环之外一次性备齐素材 ——
  按 `_episodeImage`（TMDB 剧照优先、退回服务器图）批量取剧照路径、并发取服务器图标路径
  （整体 4 秒预算，超时退回兜底标记）、按 `_resourceVersionsFor` 的顺序算 1..3 名次；
  新增 `_resourceKey` / `_serverMarkOf` / `_episodeSeconds` / `_episodeMetaLine` 四个辅助方法。
  进度直接复用 `_episodeProgress`，与详情页剧集栏显示的是同一个值。

### 与草案的偏差

1. 缩略图未新建缓存目录，直接复用 `DefaultCacheManager`（即详情页剧集栏用的那份缓存），
   因此**不需要新增清理策略**。
2. `--mova-playlist-thumbnail` 落地为 `--mova-playlist-image`；资源图标为「本地路径 + 兜底枚举」两项。
3. 剧集卡采用 3 列网格而非单列宽行 —— 一次能看到更多集，也更接近详情页的剧集栏。
4. mockup 里的「亮度」并入了画面面板（与 mpv 的 `brightness` equalizer 同属画面调整）。

### 验证结果

- [x] `dart format lib`：43 文件，0 待改
- [x] `flutter analyze --no-fatal-infos --no-fatal-warnings`：18 条 info，**全部为既有**，
      本轮改动的三个文件 0 条（`ANALYZE_EXIT=0`）
- [x] `flutter test`：71 项中 70 项通过，唯一失败项为既有的「发现栏目可显示并持久化布局」
      Widget 测试（已在 `docs/specs/2026-09-16-episode-transition-preheat.md:97` 记录为既有失败）
- [x] `main.cpp` 通过 MSVC `/W4 /WX /std:c++17 /utf-8 /O2` 独立编译（`CL_EXIT=0`）
- [x] `scripts/dev-verify.ps1 -SkipChecks` → `BUILD_OK elapsed 00:45`，
      `Release\MovaNativePlayer.exe` 227,328 B @ 22:00:57（含本轮全部原生改动），libmpv gpu-next 已换
- [x] **部署完成**（用户退出 Mova 后重跑 `-SkipChecks -Deploy` → `BUILD_OK elapsed 00:20`）：
      `D:\Mova` 与 Release 目录大小 / 时间戳 / 内容一致，安装副本 `app.so` 二进制内
      可检索到全部 7 个新参数名与 `server_marks` 字面量
- [x] **几何回归 8/8 通过**（`tool/verify_native_panels.py`，真实拉起 `MovaNativePlayer.exe`
      并投递点击）：剧集 / 资源 / 章节 / 更多 / 更多子面板 5 个面板全部
      「悬挂在控件条上方 8px + 中心对齐所点按钮 delta=0」；`06_dock_only` 正确断言无面板；
      `10/11` 两个全参数用例同时验证新绘制路径。退出码全部 0。
      每个用例还记录了窗口居中证据：`centre=(1280,696)` 与工作区中心 `(1280,696)` 重合
- [x] **新绘制路径实机目视**（用例 10/11 截图，位于 `%TEMP%\mova_verify\`）：
      剧集卡真封面 + 45% 进度（`00:22:12 / 00:49:20`，0.45×2960s 换算精确）、
      未看集显示 `00:00:00 / 00:45:00` 无填充、无图集显示占位字形且不画进度条、
      副标题 `第 1 季 · 2016-07-15 · 49 分钟`（meta 空时降级为只有季号）；
      资源面板真图标文件 / mark=1 绿渐变（Emby）/ mark=3 蓝渐变云朵（WebDAV）、
      名次环 rank1 金 / rank2 银 / rank3 铜（rank1 与选中描边叠合）
- [x] 参数解析的阵列对齐：原生在解析后把七个新数组统一补齐到对应长度，缺发不错位
- [x] 回归脚本已纳入仓库 `tool/verify_native_panels.py`（8 用例），
      修复了原脚本的采样竞态：面板窗口启动即创建并隐藏在 1×1，
      `wait_class` 必须等待 `IsWindowVisible` 而不是仅等 `FindWindow` 命中

### 待用户确认的决策点（均已按下方结论实施）

1. **缩略图获取方式** → 方案 A，复用 `DefaultCacheManager`。
2. **服务器类型枚举** → 只用 `SourceKind` 三值做兜底，正常路径显示应用取下来的真图。
3. **交付批次** → 未分批，九项一次性交付（改动虽大但都在同一套面板/浮层机制内）。

### 遗留

1. **人工验收未做**：见下方人工验证表（几何与内容已由 `tool/verify_native_panels.py`
   8/8 覆盖，剩余是用户主观体验：悬浮名称文案、OSD 时长手感、整体风格）。
2. **`kPlaybackSettings` 是死枚举**：`ControlId` 里存在但没有任何工具 / 字形 / 标签映射到它
   （全文件仅声明处一处命中），因此 `OpenToolPanel` 的 `default:` 分支对工具按钮不可达。
   本轮未删除（属无关重构），可后续清理。
3. **回归脚本尚未接入 CI / `dev-verify.ps1`**：当前是独立命令
   `python tool/verify_native_panels.py`，需要前台桌面（抓屏 + SetForegroundWindow），
   不适合放进无头构建，保持手动触发。

## 追加轮（2026-09-17 晚）：资源信息行 / 剧集一行一集 / 全局悬浮提示

用户验收九项改动后追加三项：

1. **资源面板信息行补齐**：展示「分辨率 · 色彩范围 · 码率 · 大小」。
   - Flutter `_resourceSummary` 重写：删去 codec / container，补 `videoRange`
     （`VideoRangeType` 收敛为 SDR / HDR10 / HDR10+ / HLG / 杜比视界，未知值原样）
     与 `size`（≥1 GiB 显示 `X.X GB`，否则 `X MB`）。`MediaItem` 三个字段本就
     有解析（`emby_client.dart` 取 `MediaSources.Size` / `Bitrate` / 视频流的
     `VideoRangeType`），无需动客户端。
   - 该函数同时喂原生资源面板明细、应用内播放器资源标签、`resourceInfo`，
     一处改动三处生效。
   - 原生资源面板加宽 344 → 430（`kPanelResourceWidth`），否则更长的信息行
     会被省略号截掉末尾的大小。
2. **剧集面板一行一集**：三列网格（卡片 186px，标题几乎必截断）改为纵向列表，
   一行一集 —— 缩略图在左 128×72（16:9），右侧两行文字整宽可用。
   - 常量：`kEpisodeRowInset/ThumbWidth/ThumbHeight/Height`、`kPanelEpisodeWidth=480`；
     删除 `kPanelGrid*` 一族与 `PanelMetrics::Mode`（排版不再有网格分支，
     `LayoutPanelRows` 退化为每项独占一行的循环）。
   - `DrawPanelEpisodeCard` 改横向布局：进度条与已看/全长时间戳仍叠在缩略图
     底部（与应用播放页剧集卡同款），当前集勾选仍在缩略图右上角，选中描边
     改为整行描边。
   - 行高 88px，每行信息不再互相挤压；`reveal` 定位逻辑不变（按盒子 y 居中滚动）。
3. **全局悬浮提示主题**：`YingjiMotionIconButton` 等大量裸 `Tooltip` 弹出的
   是框架默认白底黑字（「加入待看」按钮最明显）。在 `app.dart` 加
   `tooltipTheme`：当前色调深端（`YingjiGlassTints.of(...).deep @ .96`）
   + 白字 + 白 20% 描边 + 投影，12px 圆角、320ms 延迟。深色材质在两种主题
   下都压得住背景（HUD 语义）。`YingjiSynopsisTooltip` 有自己的富样式，不受影响。

验证：`main.cpp` MSVC `/W4 /WX /std:c++17 /utf-8 /O2 /DNOMINMAX` → `CL_EXIT=0`
（独立编译**必须**带 `/DNOMINMAX`，工程 CMake 有定义、命令行没有会满屏
C2589 min/max 宏冲突假错误，已补进工具链技能）；`dart format` 1 文件、
`flutter analyze` 18 条 info 全部既有。

几何回归（`tool/verify_native_panels.py --exe <Release\MovaNativePlayer.exe>`）
8/8 通过：剧集面板宽 480（内容 532 含阴影边）、资源面板宽 430、
锚点与窗口居中全部保持 `delta=0`；一行一集的剧集行（缩略图 128×72 左置、
标题「第 1 集 · 第一章 开镖」整行不截断、进度与时间戳叠缩略图底部）、
资源信息行 `3840×2160 · 杜比视界 · 24.0 Mbps · 46.2 GB` 等三种写法均完整显示。
回归脚本的合成资源明细已同步为新格式，后续回归覆盖真实字符串长度。

## 追加轮 2（2026-09-17 深夜）：剧集面板观感 / 对勾语义 / ESC 分层退出

用户实机验收一行一集布局后又报四项：

1. **面板内容出框（已修复）**：截图显示滚动后某行的缩略图与时间戳完整画在
   面板圆角边框之外（卡片底色 alpha 仅 14 看不出来，只有不透明的图和文字显形）。
   - **根因（用调试色块注入位图后锁定）**：`PaintPanelContent` 外层
     `SetClip(content_rect)` 定义了内容视口，但行内绘制缩略图 / 进度条时用的
     `SetClip(&thumb_path)` 是 **Replace 模式 —— 把视口裁切整个换掉**。滚动定位
     后上方行 top 为负，缩略图段在 Replace 期间画进了视口上方的位图区域；
     `Restore(state)` 只恢复裁切状态，救不回已画的像素。
   - **修复**：三处行内裁切（剧集缩略图 ×2、资源图标 tile）全部改为
     `CombineModeIntersect`（视口 ∩ 圆角矩形）；外层同步收紧为内容视口
     （body 内缩 padding），滚动行在视口边界干净切断，与任何滚动列表一致。
   - **验证**：12 集跨 2 季 + `--pause` 复现 → 修复后越界内容消失，只剩部分
     可见行在视口内的合法边缘。
   - **教训**：GDI+ `SetClip(path)` 默认 Replace；在已有全局裁切的内层做局部
     裁切必须显式 `CombineModeIntersect`，且 Save/Restore 并不能阻止替换期间
     的越界绘制。已沉淀进 `windows-native-render-qa` 技能。
2. **打开面板定位当前集**：`reveal` 从「滚到视口中央」改为「滚到内容区顶部」
   （`box.y - kPanelPadding`），一打开视线就落在当前集上，列表末尾由 clamp 兜底。
   同时暴露并修正了回归脚本的缺陷：`media_urls` 只由位置参数构成，脚本每用例
   只传 1 个 wav，mpv 播放列表只有 1 项，`playlist-pos` 恒为 0，selected/reveal
   全部错位 —— 现在按 `--mova-playlist-title` 出现次数补齐 URL，并用
   `--pause=yes` 固定时序（3 秒样例播完会跳集、淡出控件条，04 用例曾因此假失败）。
3. **对勾语义重定义**：对勾从「当前集」改为「已播完的集」。
   - 新参数 `--mova-playlist-watched`（0/1），Flutter 用
     `_completedResourceIds.contains(episode.id)` 组装。**必须显式下发**：
     `_deriveProgress` 里服务器标记「已播放」但没有播放位置的集 progress 是 0，
     单看进度会把这类集漏掉。
   - 绘制规则：已播完 → 白勾徽章、**不画**进度条与时间戳；播放中（0<p<1）→
     进度条 + 双时间戳；未播 → 只画右侧全长（左侧不再出现无意义的 00:00:00）。
     当前集只靠整行白描边标识，不再画对勾。
   - 徽章去掉黑色实心圆底（用户明确要求）：改为白色 tick-circle 字形 +
     向右下偏移 0.9px 的半透明黑影勾叠出轮廓，亮暗封面上都认得出来。
4. **ESC 分层退出**：全屏 → 退出全屏；最大化（`IsZoomed`）→ `SW_RESTORE` 还原；
   窗口化 → 才 `WM_CLOSE` 退出播放器返回详情页。最大化这一档此前缺失，在
   最大化窗口按 ESC 会直接把播放器关掉。

验证：MSVC `/W4 /WX /std:c++17 /utf-8 /O2 /DNOMINMAX` → `CL_EXIT=0`；
`dart format` 0 changed；`flutter analyze` 18 条 info 全部既有；部署 `BUILD_OK`。
