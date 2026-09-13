import 'dart:io' show Platform;

/// Mova 的版本号。
///
/// 与 `pubspec.yaml` 里的 `version:` 前缀保持同步，发版脚本（`scripts/cut-release.ps1`
/// 与 `tools/cut_release_api.py`）会同时改写这两处。**不要在别处再硬编码版本字符串**
/// ——「关于 Mova」面板就曾长期停在 3.1.65，比实际发布版本落后了十几个版本。
const String movaVersion = '3.1.97';

/// 当前运行平台名。
///
/// 「关于」面板用它显示发行平台，网络请求头用它声明客户端平台（旧代码在
/// 安卓上也写死 `Windows`，服务端日志里完全分不出来）。
String get movaPlatform => Platform.isAndroid
    ? 'Android'
    : Platform.isWindows
    ? 'Windows'
    : Platform.operatingSystem;
