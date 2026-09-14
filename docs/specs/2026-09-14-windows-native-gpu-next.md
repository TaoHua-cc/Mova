## 基本信息

- 标题：Windows 单播放器原生 gpu-next 视频输出
- 日期：2026-09-14
- 状态：已完成（待 HDR/DV 实机样片验收）
- 影响平台：Windows（Android 保持现有 Flutter 纹理输出）

## 背景与问题

当前 Windows 播放页通过 `media_kit_video` 的 Flutter OpenGL Render API 显示视频。该接口会把输出重设为 `vo=libmpv`，且现有捆绑 DLL 编译时禁用了 libplacebo；DV Profile 5 无法重塑 RPU，实测呈紫色。

## 目标

- Windows 只有一个 Mova/libmpv 播放实例。
- Windows 使用原生子窗口承载 `vo=gpu-next`，由 libplacebo 将 DV 正确映射为 HDR10/SDR。
- 保持 Mova 的播放状态、进度、选集、鉴权请求头、音轨、字幕和快捷键。

## 非目标

- 不输出经 Dolby 授权的原生 Dolby Vision 信号。
- 不恢复外部 WinUI 第二播放器。

## 技术方案

- Flutter Windows runner 注册 `mova/native_video_host`，创建无激活、鼠标穿透的 Win32 子窗口。
- Windows 播放页不创建 `VideoController`，防止其覆盖 `vo` 为 `libmpv`；同一 `Player` 在打开媒体前将 `wid` 绑定到原生子窗口。
- `gpu-next` 原生窗口在 Flutter 控制栏之间显示；字幕由同一 libmpv 原生渲染。设置面板打开时隐藏视频宿主，防止 HWND 覆盖 Flutter 面板。
- CI 从 mpv 官方安装页列出的 shinchiro Windows 构建下载已校验的 `mpv-dev` DLL，替换 media_kit 的旧 DLL。该构建包含 libplacebo。

## 兼容与迁移

- 不更改来源协议、缓存或持久化键。
- Android 继续使用现有 media_kit 纹理和原生 Android DV 路径。
- Windows 发布包体积会增加；不能载入新 DLL 时构建直接失败，不发布旧链路。

## 验收标准

- [x] Windows Release 替换脚本校验并安装含 libplacebo 的 `libmpv-2.dll`。
- [x] Windows 不创建 Flutter `VideoController`，同一 `Player` 在首次打开前绑定原生 HWND。
- [ ] DV Profile 5 不出现紫/绿基层画面，按显示器输出 HDR10 或 SDR（待用户样片验收）。
- [ ] 控制栏、键盘、进度、选集、服务器鉴权和字幕仍可用（待用户样片验收）。
- [x] Android 未改动视频纹理路径，Dart 测试通过。

## 验证计划

- 自动化：Dart 单元测试、静态检查、Windows/Android 构建；CI 校验替换 DLL 的 SHA-256。
- 人工：Windows HDR 和 SDR 分别播放用户的 Profile 5 样片与 HDR10/SDR 对照样片；打开设置/选集后确认原生视频不会覆盖面板。

## 风险与回滚

- Win32 子窗口不能被 Flutter 覆盖，因此视频区域避开顶部和底部控制栏；打开 Flutter 设置面板时临时隐藏视频。
- 上游 mpv 构建更新需要重新校验 SHA-256；失败可回滚本规格提交，不影响用户数据。

## 实现记录

- 新增 Windows runner 的 `mova/native_video_host` 通道与无激活、鼠标穿透的 Win32 子窗口；它不是第二个播放器，只有一个现有 libmpv `Player` 使用该 HWND。
- Windows 播放页跳过 `VideoController`，避免其把 `vo` 覆盖为 `libmpv`；首次打开媒体前强制绑定 `wid` 与 `gpu-next`，失败会显示明确错误而不会静默回退到紫色视频链路。
- 新增受 SHA-256 固定的 shinchiro `mpv-dev` 构建安装脚本；已本地校验 SHA-256、DLL 可加载、导出 `mpv_create`，并检测到 `Video output based on libplacebo` 与 `gpu-next`。
- `flutter build windows --release` 成功。完整 Dart 测试 61 项通过，发现栏目空态的既有测试仍失败；当前用户已有 Mova 单实例运行，不能在不关闭用户程序的前提下启动新二进制进行样片验证。
