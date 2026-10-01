# 全部列表与 Android 应用切换

日期：2026-10-02；状态：已实现，真机流畅度待复测；平台：Windows / Android。

## 问题与目标

继续播放、发现完整列表和榜单进退卡顿；Android 启动及回桌面动画卡顿。保留动画、玻璃和真实数据，不变更数据格式、播放器或版本，不修改系统动画速度。

## 方案

全部列表复用 Flutter 内置支持页面快照的 Zoom 转场，避免 Windows 同时逐帧重绘两张整页并进行 alpha 合成。首屏已有数据立即展示，预热和榜单刷新推迟至进入动画完成；退出等待动画结束再刷新首页。Android 对应用失去前台时暂停首页轮播与 Flutter 装饰动画，正常窗口不重复绘制启动图标。

## 验收与验证

进入/返回仍有动画；快速返回时不执行已销毁页面的预热；宽窄屏、Windows 鼠标及 Android 触控检查；测试动画期间/完成后的工作调度与释放。完整测试、分析、双端 Release 构建，本地部署。Android HWUI gfxinfo 不等于 Flutter 视频/光栅帧率，系统桌面动画需独立真机复测，不能仅凭构建声称流畅。

## 兼容与风险

无持久化/网络协议变化。转场期间图片或数据更新停稳后显示；内置 permissive 快照遇平台视图回退实时绘制。未完成实测时如实记录，不强制结束用户播放器，不提交或发版。

## 实现与验证记录

### 返回桌面复查（02:04 系统记录）

2026-10-02 真机 OPPO OPD2401 / Android 16。已保存系统 Perfetto 和 atrace 轨迹于本地 build（不提交，可能含设备进程名称）。分析工具下载失败，未完成 PerfettoSQL 帧归因。系统 events/logcat 显示 02:04:25.930 杀死 pid 28868，02:04:27.053 新启动 pid 31081，02:04:37.877 再杀死 pid 31081；ActivityManager 原因 o-stop(40)，Athena 原因 `with swipe up`，ApplicationExitInfo 为 OTHER KILLS BY SYSTEM，并非 Dart 异常。这是采样中海报重新显示的一个确定解释：内存与 Flutter Engine 被系统销毁，再进入为冷启动。不能据此断言普通 Home 手势也会杀进程，必须先确认用户手势并单独采样。未发现热返回主动清理图片缓存，clear/emptyCache 仅设置页显式缓存清理流程。未更改系统后台权限或关闭动画，未添加保活服务，也未据此修改/部署应用。

全部列表入口改用 MovaListRoute，使用 Flutter ZoomPageTransitionsBuilder 并提供 delegatedTransition，让底层页面也使用快照转场；不改变其他页面转场。继续播放首帧复用真实首页记录，再按原流程本机/服务器更新。发现预热及榜单联网刷新在入场完成后调度；继续播放和发现返回刷新等待 route.completed。应用 LifecycleScope 暂停离开前台时的 ticker，首页轮播另外停止 Timer；NormalTheme 底图为黑色，仅 LaunchTheme 显示启动图标。复用已有动效/缓存组件，无新依赖。

完整 Flutter 测试 301 项通过；静态分析无错误/警告，既有 19 项 info；Windows、Android 测试版 Release 构建成功。Windows 已覆盖 D:\Mova，构建与部署 app.so SHA256 一致：7BD7CCEFD582375BD7C2396BC21EBE21ED1194D51C81D69BF4ECC2AEA020E8CA。

Android 旧版热启动 am start -W 为 81ms，仅为 Activity 启动耗时，不是动画帧率。用户切换后 gfxinfo 无法返回 Mova 统计；Launcher 数据是长时间累计，不能作为此次两次切换的对照。没有完成新版真实动画帧率验收，不能声称已消除系统桌面动画卡顿。人工复测：Windows 1440×900 及窄窗口、平板横竖屏分别进入继续播放/榜单/发现完整列表、快速返回、静止后正常返回；桌面与应用图标往返四次，检查画面连续和停稳后内容刷新。
