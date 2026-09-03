import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
    title: '映迹',
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
  runApp(const YingjiApp());
}
