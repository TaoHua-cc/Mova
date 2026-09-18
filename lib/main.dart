import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/app.dart';
import 'src/brand.dart';
import 'src/network/network_http_client.dart';
import 'src/network/proxy_routing.dart';
import 'src/platform/window_host.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 限制解码后位图常驻内存上限：首页大量全屏 backdrop / 海报默认会按原图分辨率
  // 解码进内存，叠加起来很占内存。限定后超出部分按 LRU 淘汰（单图仍按显示尺寸
  // 经各 CachedNetworkImage 的 memCacheWidth 降采样，见 media_center / 详情页）。
  PaintingBinding.instance.imageCache.maximumSizeBytes = 96 << 20;
  configureNetworkHttpOverrides();
  MediaKit.ensureInitialized();
  // Desktop window APIs must be ready before the first frame. Preferences and
  // proxy state are intentionally loaded after runApp so they cannot delay it.
  await WindowHost.ensureInitialized();
  final startup = _loadStartupSettings();
  runApp(YingjiApp(startup: startup));

  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(
      WindowHost.showAppWindow(
        size: const Size(1440, 900),
        minimumSize: const Size(1060, 680),
        title: 'Mova',
      ),
    );
  });
}

Future<void> _loadStartupSettings() async {
  final prefs = await SharedPreferences.getInstance();
  ProxyRouting.loadFrom(prefs);
  yingjiAppearance.apply(
    themeMode: switch (prefs.getString('yingji.appearance.theme') ?? 'dark') {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    },
    iconStyle: prefs.getString('yingji.appearance.icon') ?? 'play',
    glassOpacity: (prefs.getDouble('yingji.appearance.glass-opacity') ?? .58)
        .clamp(0, 1),
    glassBlur: (prefs.getDouble('yingji.appearance.glass-blur') ?? 24).clamp(
      0,
      40,
    ),
    cardDepth: (prefs.getDouble('yingji.appearance.card-depth') ?? .62).clamp(
      0,
      1,
    ),
    glassTint: prefs.getString('yingji.appearance.glass-tint') ?? 'graphite',
  );
}
