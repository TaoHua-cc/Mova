# 侧栏图标在两页不一致（同一入口、两种尺寸）

- 状态：方案 1「统一尺寸」已实施；方案 2「换字形」经用户决定**不做**（2026-09-23），保持现状
- 触发：用户连续三次反馈「侧栏图标的玻璃背景有锯齿感」→「图标显示有问题，上下边框有横条」
  →「为什么进入详情页后左侧的图标没有那么严重」
- 相关：`docs/specs/2026-09-23-glass-edge-ring-uniformity.md`（同一批侧栏取证的另一半：**描边环**）

## 1. 症状

首页浮动导航第 4 颗（tooltip「服务器」，`YingjiIcons.rectangle_stack` = `Iconsax.box` 0xe9f6）
看起来是「上下两条横条 + 中间糊掉」，而详情页侧栏同一颗能看出是立方体。

用户最初把它描述为「锯齿感」，导致前几轮先去查了描边环（见姊妹篇）。环确实另有一个真缺陷，
但**「上下横条」是字形自己的问题**，两者是独立的两件事。

## 2. 排除项（都量过）

| 假设 | 证据 | 结论 |
|---|---|---|
| 图标码位错 / 字形缺失 | 从 `iconsax_flutter-1.0.1` 的 `FlutterIconsax.ttf` 按同尺寸光栅化 `0xe9f6`，与应用像素对齐后 RMS 明显低于相邻候选（`box` 42 / `box_copy` 97 / `box_1_copy` 103） | 排除，字形正确 |
| 悬停/选中态导致 | `strength` 静止 .92 / 悬停 1.3 / 选中 1.8，`alpha=.10`；由实测盘面亮度反推 α≈.092 → 两页都是静止态 | 排除 |
| 版本差异 | 用户截图与本机 Release 在 8 个方位角的径向剖面逐点一致 | 排除 |
| 放大倍率差 | 用户两张图分别是 60×66 与 53×57，**都是 1:1**；圆盘 45px vs 43px，比值 1.047 = 46/44 | 排除（此结论曾一度写错） |

## 3. 根因：同一入口在两页用了两种尺寸，而字形的分面缝是亚像素

代码事实（修复前）：

- 首页 `_FloatingRailButton`（`lib/src/media_center.dart`）不传 `size` → 吃
  `YingjiMotionIconButton` 的默认 **46**。
- 详情页 `_DetailRailButton`（`lib/src/metadata/metadata_detail_page.dart`）写死 **44**。

`_YingjiMotionIconButtonState` 里图标尺寸 = `widget.size * .43` → **19.78px vs 18.92px**。

关键不在差 4%，而在 `Iconsax.box` 的内部分面缝从字体量出来只有 **0.0469 em**：

| | 首页 46 | 详情页 44 |
|---|---|---|
| 圆盘 / 图标 | 45px / 19.78px | 43px / 18.92px |
| 竖缝宽度 | ~0.93px | ~0.89px |

缝宽不足 1 物理像素时，「被单个像素吸收（两片白面糊成一片）」还是「摊成两个 50% 灰像素
（一条清楚的线）」**完全由相位决定**。46→44 只差 0.86px，却把相位推了约 0.43px ≈ 缝宽的 46%，
两页正好落在分界线两侧。

> ⚠️ 早期把缝宽算成 1.2px 是符号搞反了（把亮段当成缝）。真实值更小，所以**光靠放大解决不了**：
> 实心 `box` 要缝到 1.2px，图标得 26px（= 圆盘 46 × .56）。

不对称规律：**~1px 的暗缝会整条消失，~1px 的亮线却仍可见** —— 实心款天生比描边款脆弱。

## 4. 修法（已实施）

新增 `YingjiLayout.railButtonSize = 44`，两处侧栏按钮都引用它：

| 文件 | 改动 |
|---|---|
| `lib/src/brand.dart` | `YingjiLayout.railButtonSize = 44` + 取值理由注释 |
| `lib/src/media_center.dart` | `_FloatingRailButton` 传 `size: YingjiLayout.railButtonSize` |
| `lib/src/metadata/metadata_detail_page.dart` | `_DetailRailButton` 的 `size: 44` → 常量 |
| `test/rail_icon_consistency_test.dart` | 新增 3 项源码契约测试（见下） |

**取 44 而不是 46 的理由**：详情页侧栏在窄屏下槽位只有 44
（`detailSidebarWidth` 64 − 内边距 10+10），46 会溢出；桌面槽位（88 − 18 + 14 = 56）
与首页浮动导航槽位（`railWidth` 54）都装得下 44。也就是说 44 是栅格本来就声明过的值
（`detailSidebarPadding` 的注释：「两种宽度下都保证按钮槽位是 44」），首页那个 46 才是
「从没声明过、只是继承了组件默认值」的漂移方。

回归测试（`test/rail_icon_consistency_test.dart`）：
1. 两处按钮都出现 `size: YingjiLayout.railButtonSize`，且类体内不允许再出现 `size: <数字>`；
2. 常量满足两侧槽位宽度约束（窄屏 ≤ 44、桌面槽位 ≥ 常量、`railWidth` ≥ 常量）；
3. 图标尺寸只由 `widget.size * .43` 推导（绘制器里没有第二处尺寸来源）。

## 5. 验证（真机 + 用户截图互证）

`flutter build` → 部署 `D:\Mova`（`data\app.so` 05:16:07）→ 真机取窗口图
`build/frametrace/pw_rail44.png`。

详情页那次修复**没有改尺寸**（44 → 44），所以用户此前那张详情页截图仍是有效基准。

`tool/probe_rail_icon_consistency.py`（只读）：

| 样本 | 圆盘直径（环脊 2r） | 字形 ink | >210 像素 |
|---|---|---|---|
| 首页 修复后（44） | 41.5px | 16×15 | **160** |
| 首页 修复前（46） | 44.0px | 16×16 | 174 |
| 详情页（44，用户截图） | 42.0px | 16×15 | **160** |

字形二值图按 ink bbox 中心对齐后的位不一致率：

| 对比 | 不一致 |
|---|---|
| 首页修复后 vs 详情页 | **0 / 841 = 0.0%** |
| 首页修复前 vs 详情页 | 34 / 841 = 4.0% |

即：修复后两页的字形**逐位相同**，差异集中在分面缝那几十个像素上（也正是「横条」的来源）。
视觉对照 `build/frametrace/rail_44_vs_46.png`（20×，左=修复后 / 中=修复前 / 右=详情页）。

## 6. 遗留

- **方案 2 不做（用户决定，2026-09-23）**：换掉 `box` 这颗实心字形能彻底摆脱相位依赖，
  但用户看过候选数据后决定保持现状。当时已实施到别名替换（`rectangle_stack` →
  `Iconsax.box_copy`、`square_stack_3d_up` → `Iconsax.box_copy`，并预告要加
  `MOVA_TRACE_ICON` 门控做真机比选）即被叫停，改动**已全部回退**，工作区与部署产物都
  回到方案 1 的状态。数据留档，将来若重启可直接用（@19.78px）：

  | 字形 | 最小特征 em | @19.78px |
  |---|---|---|
  | `box` 0xe9f6（当前） | 0.0469 | 0.93px |
  | `box_copy` 0xe9fd（描边） | 0.0625 | 1.24px |
  | `element_4` 0xeb96 | 0.0840 | 1.66px |
  | `layer` 0xed05 | 0.1211 | 2.40px |

- 详情页侧栏 `_DetailRailButton` **没有 `selected` 参数** → 详情页侧栏永远不显示当前所在分区
  （首页侧栏有选中态）。属设计不一致，未改。
- 详情页顶栏「返回」键仍是字面量 `size: 44`（值相同，但同类漂移风险）。本轮未纳入。
- `YingjiLayout.railLeft` / `railWidth` 定义了但无人引用，`_FloatingRail` 里写着同样的
  16 / 54 字面量。同类问题，未改。
- `YingjiIcons.gear` 与 `gear_alt` 指向同一码位（`Iconsax.setting_2`），两个别名并存。
