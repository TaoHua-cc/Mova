import 'dart:io' show File, Platform, Process, ProcessException;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

/// 窗口操作的跨平台适配层。
///
/// 桌面端（Windows / macOS / Linux）走 `window_manager`；
/// 移动端（Android / iOS）没有窗口概念，窗口操作降级为：
/// · 全屏 → 系统沉浸式（隐藏状态栏/导航栏）
/// · 最小化 / 最大化 / 关闭 → no-op（调用方应配合 [isDesktop] 隐藏对应按钮）
///
/// 直接调用 `windowManager.*` 在安卓上会抛 MissingPluginException，
/// 所有窗口相关调用必须经由本类。
class WindowHost {
  WindowHost._();

  /// 是否为桌面平台。用于决定是否渲染自定义标题栏 / 窗口控制按钮。
  static bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static Future<void> ensureInitialized() async {
    if (!isDesktop) return;
    await windowManager.ensureInitialized();
  }

  /// 桌面端：按给定选项显示主窗口。移动端：无操作。
  static Future<void> showAppWindow({
    required Size size,
    required Size minimumSize,
    required String title,
  }) async {
    if (!isDesktop) return;
    final options = WindowOptions(
      size: size,
      minimumSize: minimumSize,
      center: true,
      title: title,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
      backgroundColor: Colors.transparent,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  static Future<void> minimize() async {
    if (!isDesktop) return;
    await windowManager.minimize();
  }

  static Future<void> close() async {
    if (!isDesktop) return;
    await windowManager.close();
  }

  static Future<void> toggleMaximize() async {
    if (!isDesktop) return;
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  static Future<bool> isMaximized() async {
    if (!isDesktop) return false;
    return windowManager.isMaximized();
  }

  /// 全屏切换。桌面端切窗口全屏；移动端切系统沉浸式。
  /// 返回切换后的全屏状态。
  static Future<bool> toggleFullScreen() async {
    if (!isDesktop) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      return true;
    }
    final active = await windowManager.isFullScreen();
    await windowManager.setFullScreen(!active);
    return !active;
  }

  static Future<void> setFullScreen(bool value) async {
    if (!isDesktop) {
      await SystemChrome.setEnabledSystemUIMode(
        value ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
      return;
    }
    await windowManager.setFullScreen(value);
  }

  static Future<bool> isFullScreen() async {
    if (!isDesktop) return false;
    return windowManager.isFullScreen();
  }

  /// 桌面端返回可拖动窗口的区域；移动端没有窗口可拖，原样返回 [child]。
  ///
  /// `DragToMoveArea` 在拖动时会调用 `windowManager.startDragging()`，
  /// 在安卓上会抛 MissingPluginException，因此移动端不可用。
  static Widget dragArea({required Widget child}) =>
      isDesktop ? DragToMoveArea(child: child) : child;

  /// 安卓宿主暴露的平台通道（见 MainActivity.kt）：屏幕亮度 + 打开外部链接。
  static const MethodChannel _platformChannel = MethodChannel('mova/platform');

  /// 用系统默认浏览器打开外部链接。
  ///
  /// 桌面端走 `cmd /c start`；移动端交给宿主的 `Intent.ACTION_VIEW`——旧实现
  /// 在 Android 上直接跑 `Process.run('cmd', ...)`，会抛异常，Trakt 设备授权
  /// 按钮点了没有任何反应。返回是否成功发起。
  static Future<bool> openUrl(String url) async {
    if (url.isEmpty) return false;
    if (isDesktop) {
      try {
        await Process.run('cmd', ['/c', 'start', '', url]);
        return true;
      } on ProcessException {
        return false;
      }
    }
    try {
      final opened = await _platformChannel.invokeMethod<bool>('openUrl', {
        'url': url,
      });
      return opened ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 安卓：是否已被允许「安装未知来源应用」。
  ///
  /// Android 8.0 起这是逐应用授权，没授权就调不起安装器。低于 8.0 的系统
  /// 没有这个开关，宿主直接回 true。
  static Future<bool> canInstallApk() async {
    if (isDesktop) return false;
    try {
      final allowed = await _platformChannel.invokeMethod<bool>('canInstallApk');
      return allowed ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 安卓：跳到本应用的「安装未知应用」授权页。返回是否成功跳转。
  static Future<bool> requestInstallApk() async {
    if (isDesktop) return false;
    try {
      final opened = await _platformChannel.invokeMethod<bool>(
        'requestInstallApk',
      );
      return opened ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 安卓：把下载好的 APK 交给系统安装器。返回是否成功调起。
  ///
  /// 这里只管「调起」，安装结果由系统界面负责：用户取消、签名不符、
  /// 版本号更低都在那边提示，应用不需要也不应该自己判断。
  static Future<bool> installApk(String path) async {
    if (isDesktop || path.isEmpty) return false;
    try {
      final launched = await _platformChannel.invokeMethod<bool>('installApk', {
        'path': path,
      });
      return launched ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 桌面端：在文件管理器里打开某个文件所在的目录。移动端无操作。
  ///
  /// 用「打开目录」而不是 `explorer /select,<路径>`：后者要求 `/select,`
  /// 后面原样跟着路径，参数里一旦有空格就会被 Dart 加上引号，explorer
  /// 解析不了。打开目录在各种路径下都稳。
  static Future<bool> revealInFileManager(String path) async {
    if (!Platform.isWindows || path.isEmpty) return false;
    try {
      await Process.run('explorer.exe', [File(path).parent.path]);
      return true;
    } on ProcessException {
      return false;
    }
  }

  /// 当前屏幕亮度，取值 0..1。
  ///
  /// 桌面端没有这个概念，返回 null。安卓端读的是**窗口级**亮度，
  /// 宿主会在窗口未覆盖亮度时回读系统设定值。
  static Future<double?> get screenBrightness async {
    if (isDesktop) return null;
    try {
      final value = await _platformChannel.invokeMethod<double>('getBrightness');
      return value?.clamp(0.0, 1.0);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 设置屏幕亮度（0..1）。桌面端无操作。
  ///
  /// 只影响本应用窗口，离开后系统亮度自动还原；调用失败不影响播放，
  /// 因此这里静默吞掉异常。
  static Future<void> setScreenBrightness(double value) async {
    if (isDesktop) return;
    try {
      await _platformChannel.invokeMethod<void>('setBrightness', {
        'value': value.clamp(0.0, 1.0),
      });
    } on PlatformException {
      // 亮度属于可选增强能力，失败时保持原样。
    } on MissingPluginException {
      // 同上。
    }
  }

  /// 恢复成跟随系统亮度。桌面端无操作。
  static Future<void> resetScreenBrightness() async {
    if (isDesktop) return;
    try {
      await _platformChannel.invokeMethod<void>('resetBrightness');
    } on PlatformException {
      // 忽略。
    } on MissingPluginException {
      // 忽略。
    }
  }

  /// 移动端进入播放：保持屏幕常亮 + 隐藏系统栏 + 允许横竖屏。
  /// 桌面端无操作（窗口由用户控制，常亮由系统电源管理负责）。
  static Future<void> enterMediaSession() async {
    if (isDesktop) return;
    await WakelockPlus.enable();
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp,
    ]);
  }

  /// 退出播放：关闭常亮、恢复系统栏与竖屏。
  static Future<void> exitMediaSession() async {
    if (isDesktop) return;
    await WakelockPlus.disable();
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }
}
