# Android Exo / mpv 共用播放器界面

## 基本信息

- 标题：Android Exo 与 mpv 共用播放器控件
- 日期：2026-09-30
- 状态：已实现，待平板实播验收
- 影响平台：Android（Windows 播放界面不变）
- 关联：用户确认 Android Exo 与 mpv 共用 Flutter 控件 UI

## 背景与问题

Android 默认 Exo 目前从 Flutter 独立启动原生 `PlayerView`，显示 AndroidX 自带控制栏；切换 mpv 后则进入 Mova 的 Flutter `PlayerPage`。因此两种内核在按钮、提示、菜单、自动隐藏时间和交互上不一致，Windows 更新过的播放器体验也无法复用到 Exo。

## 目标

- Exo 与 mpv 使用同一套 Mova Flutter 播放器外框、控件、提示层及菜单样式。
- Exo 仍是默认播放内核；用户显式选择 mpv 才使用 mpv，不自动切换。
- 两种内核共用播放/暂停、进度拖动、快进/快退、音量、全屏、剧集切换、进度保存等核心操作。
- 尽量保留 Android Exo 的原生 `SurfaceView` 输出和 E-AC-3 FFmpeg 扩展。
- Windows 播放流程和界面保持不变。

## 非目标

- 本次不改 Android 默认内核、设置持久化键、服务端协议或媒体缓存格式。
- 不要求 Exo 复制 mpv 独有的弹幕渲染、逐帧调节或 libmpv 专属参数；不支持的功能以明确禁用/说明呈现，不显示无效控件。
- 不部署 Windows、不发布、不提交、不推送。

## 用户流程与界面

- Android 由首页、详情页进入播放后，Exo 与 mpv 都进入 Mova 的同一播放器页面。
- 页面保留 Mova 当前控件按钮造型及统一玻璃提示/二级菜单；Exo 仅通过隐藏原生控制栏避免双层控件。
- 核心控制布局、提示刷新/自动隐藏、触控手势与返回行为保持一致；音轨/字幕等菜单共用视觉壳，按内核可用能力展示选项。
- 兼容平板横屏与手机窄屏；Exo 视频优先保留 SurfaceView 原生输出，需真机确认 Flutter 控件叠加和 Dolby Vision/E-AC-3。

## 技术方案

- 将 Android Exo 从独立全屏 Activity 改为 Flutter `PlayerPage` 的 Android PlatformView 视频层；PlatformView 内仍由 Media3 ExoPlayer 解码，Flutter 层负责统一控件。
- 在 `PlayerPage` 提供轻量播放器后端接口/适配器，保留现有 media_kit/mpv 实现，并为 Android Exo 提供播放状态、position、buffer、duration、seek、play/pause、音量及 track 能力。
- 从详情页和首页统一进入 `PlayerPage`，并沿用现有剧集列表、progress reporting 和 watch-state 保存流程。
- 除 Dolby Vision 原生 SurfaceView 的显示能力外，不改变现有播放地址代理、Exo E-AC-3 解码器扩展与许可证材料。

## 兼容与迁移

- 旧设置键 `yingji.player.android-engine` 与默认 Exo 的行为不变。
- watch-state、缓存、播放地址、服务器鉴权格式不变。
- mpv 与 Windows 路径不变；发生 Exo 初始化/PlatformView 错误时显示错误并允许用户手动选择 mpv，不自动切核。
- 若部分机型不能在 Flutter 页面中正确叠加原生 SurfaceView，则不静默退回不同风格；记录设备/输出路径并保留可回滚的 Activity 播放实现，待修正叠加方案。

## 验收标准

- [x] Android Exo 与 mpv 使用同一个 `PlayerPage`；控件、提示、工具栏和菜单共用同一份 Flutter 实现。
- [ ] 切换播放/拖动进度/上一集下一集/退出后，位置、进度记录和播放状态正确。
- [ ] Exo 的 E-AC-3 有声；控制操作不触发自动切换 mpv。
- [ ] 弹幕、字幕、音轨、缓存等能力准确反映后端支持状态。
- [ ] 平板横屏和窄屏触控下布局、视频层和菜单可用。
- [x] Android arm64 local-test Release APK 构建并覆盖部署到连接平板；Windows 本地部署按本次要求跳过。

## 验证计划

### 自动化

- [x] Android Gradle/Flutter arm64 Release 构建。
- [ ] 针对后端选择与状态映射执行可重复的定向检查。

### 人工验证

| 平台/尺寸 | 操作路径 | 预期结果 | 结果 |
|---|---|---|---|
| Android 平板横屏 | Exo 播放、触控隐藏/显示控件、拖进度、暂停恢复、切集、音轨菜单、返回 | 只有 Mova 控件，视频无卡死，位置与声音正常 | 待验证 |
| Android 平板横屏 | 设置切到 mpv，播放同一集并使用核心控件 | 控件外观和核心交互与 Exo 一致，mpv 特有功能按支持情况显示 | 待验证 |

## 风险与回滚

- 原生 `SurfaceView` 与 Flutter PlatformView 叠加在不同 GPU/Android 版本上的合成行为存在差异；以目标平板真机为准。
- 若统一页面令 Dolby Vision 原生输出退化，保留当前 Activity 作为仅 DV 内容的原生输出通路；普通 Exo/mpv 仍共享 Flutter 控件。此例外需在实测后记录，不影响 Exo 默认或自动切核规则。
- 回滚时可恢复原生 Exo Activity 入口及 mpv 原入口；不迁移或清理用户数据。

## 实现记录

- 增加 Exo PlatformView：Media3 ExoPlayer + 原生 PlayerView/SurfaceView，无原生控制栏；通过 MethodChannel/EventChannel 提供状态、播放、seek、音量、速度及音轨/字幕轨切换。
- Exo 与 mpv 路由统一进入现有 `PlayerPage`。Exo 只替换底层视频 surface，并通过状态适配接入同一页面的 Flutter 控件、提示、控制台和二级菜单；详情页仍保留按需搜索未解析剧集。
- 平板 `OPD2401` 安装包 `com.taohua.mova.debug` 覆盖安装成功，保留应用数据；启动后未发现 AndroidRuntime/Fatal Flutter 异常。还未手工进入视频页验证 SurfaceView 叠层、操控命中、E-AC-3 声音与切集。
- Flutter 定向分析无错误或 warning，只有原有 lint info。Android arm64 local-test Release 构建成功并覆盖安装到平板；Windows 部署按用户指示跳过。
- 受限 shell 不含完整 Flutter 工具 PATH，Android 构建时使用本机受管 Java / PowerShell 路径；不影响 APK 构建。
