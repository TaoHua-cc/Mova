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
  // 外观只保留「模糊程度」一项：底色、不透明度与色调固定为中性磨砂玻璃
  // （见 YingjiGlass），颜色模式固定深色。旧的玻璃色调 / 不透明度 / 背景卡片
  // 颜色与颜色模式偏好都不再读取，留在 SharedPreferences 里也不影响。
  yingjiAppearance.apply(
    iconStyle: prefs.getString('yingji.appearance.icon') ?? 'play',
    // 默认值与 `YingjiAppearance.glassBlur` / 设置页保持一致，三处必须同数，
    // 否则「首次启动」和「改过一次再启动」看到的玻璃厚度不一样。
    glassBlur: (prefs.getDouble('yingji.appearance.glass-blur') ?? 30).clamp(
      0,
      40,
    ),
  );
}
