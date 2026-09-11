import 'dart:io' show Platform;

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
