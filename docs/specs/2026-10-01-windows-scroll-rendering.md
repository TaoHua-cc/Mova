# Windows 页面滚动期间暂停玻璃采样

## 基本信息

- 标题：Windows 页面滚动期间暂停玻璃采样
- 日期：2026-10-01
- 状态：已部署本机，待用户体验确认
- 影响平台：Windows；Android 行为保持不变
- 关联：`docs/specs/2026-10-01-android-scroll-rendering.md`

## 背景与问题

Windows 首页/发现页在 1264×681、170Hz 窗口中以 1400px/s 合成滚动时，Build P50 约
0.5–0.7ms，但 Raster P50 达 23–26ms、P95 达 30–34ms。瓶颈主要在光栅侧。
对照 Android 平板修复后，发现 Windows 侧虽已给 `YingjiGlassSurface` 加入滚动暂停，
`_FrostSurface` 却仍以 `WindowHost.isDesktop` 强制走常开 `BackdropFilter`，绕过了共享滚动信号。

## 目标

- Windows 的共享平滑滚动期间暂停玻璃背板采样，停稳后恢复。
- 保持玻璃底色、轮廓和现有非滚动视觉。
- Android 触控滚动和明确包裹的稳定弹窗行为不变。

## 非目标

- 不调整 Windows 页面转场、滚轮速度、布局或配色。
- 不改变播放器渲染与硬件解码。
- 不承诺所有内容滚动都达到屏幕 170Hz；图片内容和平台光栅路径仍有独立开销。

## 技术方案

- `YingjiSmoothWheel(stableGlass: true)` 在 Windows 根据 `yingjiScrollInProgress` 提供动态稳定玻璃范围：
  空闲保持模糊，滚动期间交给现有 `BackdropFilter.enabled` 旁路机制，停止后恢复。
- `_FrostSurface` 不再因 Windows 平台条件而无条件启用滤镜；继续遵循最近的稳定玻璃范围或共享滚动信号。
- 显式稳定玻璃弹窗仍由 `YingjiStableScrollGlass` 包裹，不随本次页面滚动策略改变。
- 添加源码回归断言，防止 `_FrostSurface` 再次绕过共享状态。

## 兼容与迁移

- 无持久化键、缓存格式、服务端协议变更。
- Android 保持平板优化行为；Windows 仅在滚动时暂停背板滤镜。
- 回滚只需还原 `YingjiSmoothWheel` 的动态范围与 `_FrostSurface` 平台分支。

## 验收与验证

- [x] `flutter test test/scroll_activity_test.dart test/backdrop_idle_test.dart test/smooth_vertical_pages_test.dart`：19 项通过。
- [x] `dart analyze`（目标文件）：无错误；`media_center.dart` 存在 3 条既有大括号风格 info（设置逻辑，非本次改动）。
- [x] Release 构建成功，按 `tool/install_windows_gpu_next.ps1` 校验并部署到 `D:\Mova`。
- [x] 相同尺寸、刷新率、滚速的本机 FrameTiming 前后对比：

| 状态 | 活动滚动 Raster P50（3 个连续窗口中位数） | P95 中位数 |
|---|---:|---:|
| 修改前 | 24.16ms | 33.66ms |
| 修改后 | 16.35ms | 23.28ms |

Build P50 仍低于 0.7ms，证实本轮主要改善的是光栅压力。修改后滚动 Raster P50 仍高于
5.88ms 的 170Hz 帧预算，因此这是实测改善，不代表已达到满刷新率或所有页面完全无卡顿。

## 风险与回滚

- 风险：滚动中暂时失去实时玻璃模糊，保留材质底色与边缘；滚动停稳后恢复。
- 监测：继续使用 `tool/run_frame_trace.py` 对比实际滚动页的 Raster P50/P95。
- 回滚：恢复 `_FrostSurface` 桌面常开滤镜条件及滚动期间稳定玻璃策略。

## 实现记录

- 已部署最终 Release 至 `D:\Mova`。帧采样脚本会自动关闭测试实例；当前应用保持关闭，供用户自行启动验收。
- 在 170Hz 本机上，改善约为 Raster P50 −32%、P95 −31%。额外“全跳过玻璃”诊断组结果波动，
  未用于夸大结论；滚动后的内容光栅化仍是剩余优化空间。
