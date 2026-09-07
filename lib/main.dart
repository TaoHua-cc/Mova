import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/brand.dart';
import 'src/network/network_http_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  configureNetworkHttpOverrides();
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(1440, 900),
    minimumSize: Size(1060, 680),
    center: true,
    title: 'Mova',
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
    backgroundColor: Colors.transparent,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  final prefs = await SharedPreferences.getInstance();
  yingjiAppearance.apply(
    themeMode: switch (prefs.getString('yingji.appearance.theme') ?? 'dark') {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    },
    iconStyle: prefs.getString('yingji.appearance.icon') ?? 'play',
  );
  runApp(const _DesktopLifecycle(child: YingjiApp()));
}

class _DesktopLifecycle extends StatefulWidget {
  const _DesktopLifecycle({required this.child});
  final Widget child;

  @override
  State<_DesktopLifecycle> createState() => _DesktopLifecycleState();
}

class _DesktopLifecycleState extends State<_DesktopLifecycle>
    with WindowListener, TrayListener {
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    unawaited(_configureDesktop());
  }

  Future<void> _configureDesktop() async {
    await windowManager.setPreventClose(true);
    await trayManager.setIcon('windows/runner/resources/app_icon.ico');
    await trayManager.setToolTip('Mova');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: '显示 Mova'),
          MenuItem.separator(),
          MenuItem(key: 'exit', label: '退出'),
        ],
      ),
    );
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onWindowClose() async {
    if (_exiting) return;
    final prefs = await SharedPreferences.getInstance();
    final closeToTray = prefs.getBool('yingji.system.close-to-tray') ?? true;
    if (closeToTray) {
      await windowManager.hide();
    } else {
      _exiting = true;
      await trayManager.destroy();
      await windowManager.destroy();
    }
  }

  @override
  void onTrayIconMouseDown() => unawaited(_showWindow());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show') {
      unawaited(_showWindow());
    } else if (menuItem.key == 'exit') {
      _exiting = true;
      unawaited(() async {
        await trayManager.destroy();
        await windowManager.destroy();
      }());
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
