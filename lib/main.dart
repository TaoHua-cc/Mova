import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/app.dart';
import 'src/brand.dart';
import 'src/cache/windows_metadata_cache.dart';
import 'src/cache/cache_retention.dart';
import 'src/history/watch_state_store.dart';
import 'src/diagnostics/frame_trace.dart';
import 'src/network/network_http_client.dart';
import 'src/network/proxy_routing.dart';
import 'src/platform/window_host.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 逐帧耗时诊断：默认不设置 `MOVA_TRACE_FRAMES` 时完全空转，不影响生产行为。
  FrameTrace.install(scrollDepth: yingjiHomeScrollDepth);
  // 限制解码后位图常驻内存上限：首页大量全屏 backdrop / 海报默认会按原图分辨率
  // 解码进内存，叠加起来很占内存。限定后超出部分按 LRU 淘汰（单图仍按显示尺寸
  // 经各 CachedNetworkImage 的 memCacheWidth 降采样，见 media_center / 详情页）。
  PaintingBinding.instance.imageCache.maximumSizeBytes = 96 << 20;
  configureNetworkHttpOverrides();
  MediaKit.ensureInitialized();
  // Desktop window APIs must be ready before the first frame. Android keeps
  // preferences/proxy initialization behind its single native launch splash.
  await WindowHost.ensureInitialized();
  final startup = _loadStartupSettings();
  // Android already owns the centered-icon splash until Flutter's first frame.
  // Initialize behind that splash, rather than presenting a second animation.
  if (WindowHost.isAndroid) await startup.catchError((_) {});
  runApp(YingjiApp(startup: WindowHost.isAndroid ? null : startup));

  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(
      () async {
        await CacheRetention.maintain();
        await (await WatchStateStore.create()).cleanCompletedCaches();
      }().catchError((_) {}),
    );
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
  await WindowsMetadataCache.migrateLegacy();
  FrameTrace.mark('metadata_migrated');
  final prefs = await SharedPreferences.getInstance();
  FrameTrace.mark('preferences_ready');
  ProxyRouting.loadFrom(prefs);
  // 玻璃材质固定为统一浓度；旧玻璃滑块偏好保留在存储中但不再读取。
  yingjiAppearance.apply(
    iconStyle: prefs.getString('yingji.appearance.icon') ?? 'play',
  );
}
