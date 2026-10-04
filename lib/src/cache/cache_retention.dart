import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../platform/window_host.dart';
import 'video_cache.dart';
import 'danmaku_cache.dart';

/// Process-local leases protect playback and warm-up across Store instances.
class CacheRetention {
  static const maxIdle = Duration(days: 7);
  static final _active = <String, int>{};
  static final _pending = <String, Future<void> Function()>{};
  static final _finished = <String>{};
  static bool isFinished(String url) => _finished.contains(url);
  static bool isActive(String url) => (_active[url] ?? 0) > 0;
  static Iterable<String> get activeUrls => _active.keys;
  static void cancelCompleted(String url) {
    _pending.remove(url);
    _finished.remove(url);
  }

  static void Function() beginPlayback(String url) {
    cancelCompleted(url);
    return protect(url);
  }

  static void Function() protect(String url) {
    _active[url] = (_active[url] ?? 0) + 1;
    var released = false;
    return () {
      if (released) return;
      released = true;
      final count = (_active[url] ?? 1) - 1;
      if (count > 0) {
        _active[url] = count;
        return;
      }
      _active.remove(url);
      final clean = _pending.remove(url);
      if (clean != null) unawaited(clean().catchError((_) {}));
    };
  }

  static Future<void> completed({
    required String url,
    required String title,
    int? season,
    int? episode,
  }) async {
    _finished.add(url);
    Future<void> clean() async {
      if (!isFinished(url)) return;
      if (isActive(url)) {
        _pending[url] = clean;
        return;
      }
      await (await VideoCacheStore.tryCreate())?.deleteEpisode(url);
      if (!isFinished(url)) return;
      final prefs = await SharedPreferences.getInstance();
      final apis =
          prefs.getStringList('yingji.danmaku.apis') ??
          [prefs.getString('yingji.danmaku.url') ?? ''];
      await (await DanmakuCache.tryCreate())?.deleteEpisode(
        title: title,
        season: season,
        episode: episode,
        legacyApis: apis,
      );
      await WindowHost.cleanNativeVideoCache(url: url);
    }

    if (isActive(url)) {
      _pending[url] = clean;
    } else {
      await clean();
    }
  }

  static Future<void> maintain() async {
    await (await VideoCacheStore.tryCreate())?.pruneExpired();
    await (await DanmakuCache.tryCreate())?.pruneExpired();
    await WindowHost.cleanNativeVideoCache();
  }
}
