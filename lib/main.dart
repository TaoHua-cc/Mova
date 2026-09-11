import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/app.dart';
import 'src/brand.dart';
import 'src/network/network_http_client.dart';
import 'src/platform/window_host.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  configureNetworkHttpOverrides();
  MediaKit.ensureInitialized();
  // 桌面端初始化窗口；安卓/iOS 跳过（windowManager 在移动端会抛 MissingPluginException）
  await WindowHost.ensureInitialized();
  await WindowHost.showAppWindow(
    size: const Size(1440, 900),
    minimumSize: const Size(1060, 680),
    title: 'Mova',
  );
  final prefs = await SharedPreferences.getInstance();
  yingjiAppearance.apply(
    themeMode: switch (prefs.getString('yingji.appearance.theme') ?? 'dark') {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    },
    iconStyle: prefs.getString('yingji.appearance.icon') ?? 'play',
  );
  runApp(const YingjiApp());
}
