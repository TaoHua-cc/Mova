# 整体软件帧率优化

## 基本信息

- 标题：整体软件帧率优化
- 日期：2026-09-30
- 状态：已按发现“全部列表”完成设置页同机对比、优化与验证
- 影响平台：Windows / Android
- 关联 Issue、提交或版本：无

## 背景与问题

用户反馈整个软件操作和画面有时整体卡顿。本轮 Android 平板为 3000×2120，使用 Flutter `FrameTiming` 采样。此前外观模糊值为 30 时，首页窗口 Raster P50 约 20–52ms、P95 约 66–81ms，Build P50 约 0.7–3.8ms；滚动窗口 Raster P50 约 27–32ms。对比实现后发现，发现“全部列表”是 `CustomScrollView + SliverGrid + SliverChildBuilderDelegate`，只构建视口附近海报；设置页则将 11 个设置分组放入一个 `SingleChildScrollView + Column`，宽屏外层还叠着整块 `YingjiGlassSurface`。将玻璃背板滤镜临时旁路后，Raster P50 曾降至约 6.7–12.6ms，确认主要成本在 GPU 背板滤镜/合成，而非 Flutter build。Windows 本轮未部署或采样。

## 目标

- 区分 UI 构建、光栅/合成、动画和视频表面成本。
- 先修复可复现的后台重复工作与过密刷新，并保留现有视觉行为。
- Android 改动部署到连接平板的本地测试包；本轮不部署 Windows。

## 非目标

- 不将视频解码帧率与 Flutter UI 帧率混为一谈。
- 不整站删除玻璃材质、海报动画或盲目降低模糊来换取未经验证的视觉退化。
- 不改协议、持久化格式、播放器选择或发布版本。

## 技术方案与实现

- 隐藏导航页由 `TickerMode` 停止动画。
- 首页轮播计时器仅在首页顶层可见、自动轮播开启且未滚动时运行；离开或滚动时取消，返回时恢复。
- Android 首页轮播进度节拍从 100ms 调整为 500ms，用单调时钟保持实际轮播时长；桌面节拍仍为 100ms。圆点层单独 `RepaintBoundary`，避免计时更新扩散重绘。
- 帧计时器增加默认关闭的 logcat/编译期诊断能力，用于同设备逐秒对照；正式部署不带 trace define。
- 玻璃全旁路对照确认背板滤镜是主要 GPU 热点，但本轮不绕过生产玻璃滤镜。后续优化应按页面与 surface 类别进一步分拆 profile，再处理滤镜覆盖面积与重复层数。
- Android 页面切换的根滚动通知现在同步维护滚动态；Android 上即使位于 `YingjiStableScrollGlass` 子树中，玻璃面也会在滚动时暂停采样，Windows 保留原有稳定玻璃行为。
- 设置页宽屏双栏由一片连续的 `YingjiGlassSurface` 统一承载，覆盖左侧导航与右侧设置内容；两栏之间仅保留分隔线。11 个设置分组不再绘制各自的玻璃填充、模糊或阴影，组内控件仍保留原样式，避免右栏分组卡片独立凸起。设置分组暂不改为懒构建 Sliver，以保留现有 `GlobalKey` 分组定位与滚动高亮逻辑。

## 兼容与迁移

- 不触及用户数据、协议或缓存。
- Android 对常驻背景渲染更严格，保留静态品牌渐变；Windows 保持已有背景动画与 100ms 轮播节拍。
- 变更可安全回滚，不需迁移。

## 验收与验证

- [x] 热点用同设备 Flutter 帧耗时与玻璃旁路 A/B 复现。
- [x] `frame_trace_test.dart` 与 `backdrop_idle_test.dart` 定向测试 13 项通过。
- [x] 静态分析无 error/warning；`media_center.dart` 存在 3 条既有 info。
- [x] OPD2401 平板同机采样：发现“全部列表”滚动 Raster P50/P95 约 2.7–3.8/4.3–4.5ms；本轮恢复设置页双栏共享玻璃背板后，采样到的持续滚动段约 5.1/13.6ms。设置页首次打开/启动采样时出现较高瞬时帧耗时；短时样本有波动，不代表所有设备和场景。
- [x] Android arm64 Release 本地测试包构建并安装至 OPD2401 平板；最终安装包不含帧日志诊断开关。
- [x] Windows/Android 共用代码通过定向检查；未部署 Windows。
- [ ] 用户复验平板触控交互；本轮没有覆盖所有页面或视频解码。

## 已知限制

采样聚焦 Android 设置页与发现“全部列表”的单机短时滚动，其他页面尚未逐一测量，settings 的 eager `Column` 也仍在（目前分组数量有限且跳转依赖已挂载的 key）。不宣称全软件所有页面帧率问题都已解决。Windows 未实测。

## 2026-10-01 Windows 详情页复查

- 对比详情页外层与“全部剧集”弹窗：弹窗由 `ListView.builder` 虚拟化剧集行，并通过 `YingjiStableScrollGlass` 固定保留一片玻璃背板；详情页外层同时移动季/集货架、资源面板和整屏背景。背景的模糊深度原来跟随每次 `_pageScroll` 更新，滤镜玻璃也保持实时背板采样。
- Windows 修复在外层滚轮活动期间冻结整屏背景模糊深度，滚动停稳后一次性追上；页面内 `YingjiGlassSurface` 同期暂停背板滤镜，停滚后恢复。“全部剧集”弹窗继续稳定模糊，Android 原有的触控滚动与背景更新行为不变。
- Windows 与 Android 的输入路径不同：Android 由 `ListView` 原生触控滚动物理处理；Windows 使用 `YingjiSmoothWheel` 逐帧写入滚动位置。发现“全部列表”虽同样接入共享滚轮组件，但其卡片由 `SliverChildBuilderDelegate` 懒构建；详情页外层是多区段视图并叠加滚动驱动的全屏背景滤镜。
- 回归测试检查 Windows 外层采用动态玻璃策略、滚动期间冻结背景模糊/关闭玻璃采样并在停滚后恢复，同时确认全部剧集弹窗仍处于稳定玻璃范围。该机制说明了可避免的合成开销；本轮尚无 Windows 用户设备的逐帧 A/B 样本，不将其表述为设备实测帧率结论。
- 后续修订已通过 12 项定向滚动测试，Windows Release 本地构建成功并部署到 `D:\Mova`；安装目录与构建目录的 `data/app.so` SHA-256 一致。应用保持关闭，供用户启动复验。
