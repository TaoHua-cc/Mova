# Android 原生 Dolby Vision 播放

## 基本信息

- 标题：Android 原生 Dolby Vision 播放通道
- 日期：2026-09-14
- 状态：已完成（等待真机验证）
- 影响平台：Android；Windows 行为不变
- 关联版本：待定

## 背景与问题

现有播放器在 Android 上通过 libmpv 的 `mediacodec-copy` 与 Flutter 视频纹理显示画面。该链路会把解码结果复制回 GPU 合成，不能保证把 Dolby Vision 动态元数据交给 Android 的 Dolby 解码与显示管线，部分片源会回退为 HDR10/SDR，Profile 5 还可能出现绿紫偏色。

## 目标

- 被识别为 Dolby Vision 的服务器片源，在设备解码器和当前显示屏均支持 DV 时走 Android 原生 Media3 播放。
- 视频由系统 Dolby Vision MediaCodec 直接渲染到 `SurfaceView`。
- 支持鉴权请求头、续播位置、系统播放控制、横屏沉浸式和返回后的本地进度保存。
- 不支持原生 DV 时保留现有 libmpv 兼容播放，并向用户说明实际回退。

## 非目标

- Windows 原生 Dolby Vision。
- 绕过设备/OEM 的 Dolby 授权与 Profile 限制。
- 第一阶段不在原生 Surface 上叠加 Flutter 弹幕，也不替换普通 SDR/HDR10 播放链路。
- 第一阶段不新增服务器实时转码协商。

## 用户流程与界面

1. 用户在详情页选择被服务器标记为 Dolby Vision 的资源。
2. Mova 查询当前 Android 设备是否同时拥有 DV 解码器和 DV 显示能力。
3. 支持：打开原生横屏播放器，从已有进度开始播放；返回后保存最终进度。
4. 不支持：显示兼容模式提示，继续进入现有播放器，避免无法播放。
5. 原生播放器失败：返回错误信息，用户仍可再次选择资源并使用兼容路径。

## 数据与接口

- 输入：播放 URL、HTTP 请求头、标题、初始毫秒位置。
- 能力：`MediaCodecList` 的 `video/dolby-vision` 解码器与 `Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION`。
- Flutter/Android 通信：现有 `mova/platform` MethodChannel。
- 输出：最终位置、时长、是否播完、是否实际选中 DV 解码轨、错误。
- 凭据仅作为内存中的 Intent extra 传给同一应用 Activity，不落盘、不记录日志。

## 技术方案

- 新增 `DolbyVisionSupport`，集中查询解码器与显示能力。
- 新增 `DolbyVisionPlayerActivity`，使用 Media3 ExoPlayer 1.11.0 和默认 `PlayerView`（SurfaceView）。
- `MainActivity` 负责能力查询、启动原生播放器并把 ActivityResult 返回 Flutter。
- Dart 新增 `NativeDolbyVisionPlayer` 桥接层，隔离平台调用与 DV 标记判断。
- 详情页播放入口在满足条件时改走原生通道；Windows 和普通片源完全沿用当前逻辑。

## 兼容与迁移

- 不修改任何现有持久化键或缓存格式。
- Android 7.0 以下仍不支持；项目现有 minSdk 24 不变。
- 不支持 DV 的设备继续使用 libmpv，不导致功能阻断。
- 删除新 Activity、桥接层和 Media3 依赖即可回滚。

## 验收标准

- [ ] 支持 DV 的 Android 设备上，DV 资源使用系统 `video/dolby-vision` 解码器并由 SurfaceView 输出。
- [ ] 鉴权媒体 URL 可以播放。
- [ ] 能从保存位置续播，返回 Flutter 后本地进度正确更新。
- [ ] 非 DV 资源与 Windows 播放行为不变。
- [ ] 不支持 DV 的设备给出清晰提示并安全回退。
- [ ] 不记录 Token、URL 请求头或其他敏感信息。

## 验证计划

### 自动化

- [ ] `dart format --output=none --set-exit-if-changed lib test`
- [ ] `flutter analyze --no-fatal-infos --no-fatal-warnings`
- [ ] `flutter test`
- [ ] `flutter build apk --split-per-abi --release`

### 人工验证

| 平台/尺寸 | 操作路径 | 预期结果 | 结果 |
|---|---|---|---|
| 支持 DV 的 Android 手机/电视 | 详情页选择 DV Profile 5/8 MP4 | 进入原生播放器，设备触发 DV 模式 | 待验证 |
| 不支持 DV 的 Android | 选择相同资源 | 提示兼容模式并进入 libmpv | 待验证 |
| Android | 播放后返回详情页 | 本地续播进度刷新 | 待验证 |
| Windows | 播放任意资源 | 行为与改动前一致 | 待验证 |

## 风险与回滚

- 设备可能只支持部分 DV Profile；Media3 最终仍以系统解码器选择结果为准。
- 部分 MKV/TS 封装不会被 Android 系统提取器识别为 `video/dolby-vision`；后续需按真实样本增加重封装或服务器回退。
- 原生播放器第一阶段不提供 Flutter 弹幕与现有自定义工具栏。
- 回滚时删除 Media3 Activity 与路由判断，所有片源恢复 libmpv。

## 实现记录

- 已加入 Media3 1.11.0、原生 SurfaceView 播放 Activity、解码器/显示能力检测和 Flutter MethodChannel 桥接。
- 详情页识别服务器 `VideoRangeType` / `VideoRange` 的 DV 标记后自动选择原生通道。
- 原生播放器支持请求头、续播和播放结果回传；返回后更新本地观看记录。
- 已完成 XML 解析与 `git diff --check`。当前环境未安装 Flutter/Android SDK，Dart 测试、Kotlin 编译、APK 构建和 DV 真机验证未执行。
- 与原规格一致的已知限制：第一阶段原生 Surface 播放不叠加 Flutter 弹幕和自定义播放器工具栏；服务器实时进度上报仍待后续补齐。
