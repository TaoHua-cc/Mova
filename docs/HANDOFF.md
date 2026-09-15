# Mova 开发接续说明

本文用于更换电脑、重装系统或改用新的 AI 编程工具后快速接续开发。开始工作前仍需完整阅读根目录 `AGENTS.md`、`docs/DEVELOPMENT_GUIDE.md`、`DESIGN.md` 和 `RELEASE.md`。

## 当前基线

- 发布版本：v3.1.104，Android build 号 115。
- Windows 播放入口：`lib/src/player/windows_native_player.dart`。
- Windows 原生播放器：`windows/native_player/main.cpp`，构建产物为 `MovaNativePlayer.exe`。
- 播放核心：动态加载 `libmpv-2.dll`，视频输出固定使用 `vo=gpu-next`、D3D11 和 libplacebo。
- Windows 只有一个播放器实例；不得恢复独立 `mpv.exe`、Lua OSC 或 Flutter 播放页叠加方案。
- Android 播放路径保持现状，不要把 Windows 专属实现直接复制到 Android。

## 已实现的 Windows 功能

- DV/HDR 色彩映射、硬件解码和 gpu-next 输出。
- 原生沉浸式窗口、顶部标题栏、控制条、自绘选择浮层和自动渐隐。
- 播放暂停、前后 10 秒、音量/静音、全屏、倍速、画面比例。
- 音轨、内嵌字幕、关闭字幕、外部字幕拖放。
- 整季播放列表、上一集/下一集、选集和逐集历史记录。
- 持久前向视频缓存；设置的 GB 数是保留容量，`.part` 分片可跨启动复用。
- 控制条区分播放进度、持久缓存进度并支持悬停时间预览和拖动。

## 关键构建步骤

```powershell
flutter build windows --release
pwsh -File tool/install_windows_gpu_next.ps1 `
  -TargetDirectory build/windows/x64/runner/Release
ISCC.exe /DAppVersion=3.1.104 installer/Mova.iss
```

`install_windows_gpu_next.ps1` 会下载并校验启用 libplacebo 的 libmpv。安装包必须包含 `MovaNativePlayer.exe` 和 `libmpv-2.dll`，不得包含旧 `mpv.exe` 或 `mpv/scripts`。

正式发布需同步修改 `pubspec.yaml`、`lib/src/version.dart`、`installer/Mova.iss`，提交 main 后推送 `vX.Y.Z` tag。仓库工作流会生成 Windows 安装包/便携包和 Android APK，并创建 GitHub Release。

## 后续优先事项

1. 使用真实 DV、HDR10、SDR、多音轨、多字幕和整季内容做回归测试。
2. 继续细化 Windows 控件 UI；若要求真正的模糊、弹簧动画和更细腻渲染，优先把控件层迁移到 Direct2D/DirectComposition，不要改变 libmpv 播放核心。
3. 增加原生播放器 C++ 层的自动化/集成测试，目前主要依赖编译检查与实机验收。
4. 检查极窄窗口、多显示器 DPI、HDR 开关切换和超长选集列表滚动。
5. 进一步完善切集时的历史完成状态和下一集缓存预热策略。

## 已知限制

- “原生 DV”指 libplacebo 解析/应用 DV 元数据并按 Windows 显示链路输出；是否以 Dolby Vision 信号直通由 Windows、GPU 驱动和显示设备共同决定，应用不能绕过系统授权链路。
- 自绘控件当前使用 GDI+ 双缓冲，并非 DirectComposition 亚克力材质。
- GitHub 推送在原开发环境使用代理 `http://127.0.0.1:7897`；新系统若代理地址不同，应按实际环境配置，不要写死到源码。
