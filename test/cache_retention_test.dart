import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/cache/cache_retention.dart';
import 'package:yingji/src/cache/danmaku_cache.dart';
import 'package:yingji/src/cache/video_cache.dart';
import 'package:yingji/src/history/watch_state_store.dart';
import 'package:yingji/src/player/danmaku_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory base;
  late VideoCacheStore video;
  late DanmakuCache danmaku;
  const url = 'https://example.test/episode-1';
  const comments = [
    DanmakuComment(time: Duration(seconds: 1), content: 'test'),
  ];
  const apis = ['https://example.test/danmaku'];
  String getKey(int episode) => DanmakuCache.keyFor(
    apis: apis,
    title: 'Series',
    season: 1,
    episode: episode,
  );

  setUp(() async {
    base = await Directory.systemTemp.createTemp('mova-retention-');
    SharedPreferences.setMockInitialValues({'yingji.danmaku.apis': apis});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => base.path,
        );
    video = (await VideoCacheStore.tryCreate())!;
    danmaku = (await DanmakuCache.tryCreate())!;
  });
  tearDown(() async {
    await video.closePlaybackProxy();
    await base.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
  });
  Future<File> media(String url, {String suffix = '.bin'}) async {
    final proxy = await video.playbackUrl(url);
    final key = Uri.parse(proxy).pathSegments.last;
    return File('${base.path}/mova-video-cache/$key$suffix')
      ..writeAsBytesSync([1, 2, 3]);
  }

  test('seven-day boundary removes stale video prefixes, not recent or active files', () async {
    final now = DateTime.now();
    final old = await media(url, suffix: '.window.part');
    final legacy = await media('$url-legacy', suffix: '.bin.part');
    final legacyMeta = File(legacy.path.replaceAll('.bin.part', '.json'));
    await legacyMeta.writeAsString('{}');
    await legacy.setLastModified(now.subtract(const Duration(days: 8)));
    final active = await media('$url-active');
    final recent = await media('$url-recent');
    await old.setLastModified(now.subtract(const Duration(days: 7)));
    await active.setLastModified(now.subtract(const Duration(days: 8)));
    await recent.setLastModified(now.subtract(const Duration(days: 6)));
    final release = CacheRetention.protect('$url-active');
    await video.pruneExpired(now: now);
    expect(await old.exists(), isFalse);
    expect(await legacy.exists(), isFalse);
    expect(await legacyMeta.exists(), isFalse);
    expect(await active.exists(), isTrue);
    expect(await recent.exists(), isTrue);
    release();
    await video.pruneExpired(now: now);
    expect(await active.exists(), isFalse);
  });

  test('cache reuse renews last use even for legacy video metadata', () async {
    final file = await media(url);
    final now = DateTime.now();
    await file.setLastModified(now.subtract(const Duration(days: 8)));
    await File(file.path.replaceAll('.bin', '.json')).writeAsString(
      jsonEncode({
        'lastUsedAt': now
            .subtract(const Duration(days: 8))
            .millisecondsSinceEpoch,
      }),
    );
    await video.playbackUrl(url);
    await video.pruneExpired(now: now);
    expect(await file.exists(), isTrue);
  });

  test(
    'danmaku read renews retention without pretending contents were refreshed',
    () async {
      await danmaku.write(
        getKey(1),
        comments,
        title: 'Series',
        season: 1,
        episode: 1,
      );
      await danmaku.pruneExpired();
      final file = File('${base.path}/mova-danmaku-cache/${getKey(1)}.json');
      final saved = jsonDecode(await file.readAsString())['savedAt'];
      await file.setLastModified(
        DateTime.now().subtract(const Duration(days: 6)),
      );
      expect(await danmaku.read(getKey(1)), isNotNull);
      await danmaku.pruneExpired(
        now: DateTime.now().add(const Duration(days: 2)),
      );
      expect(await file.exists(), isTrue);
      expect(jsonDecode(await file.readAsString())['savedAt'], saved);
      await danmaku.pruneExpired(
        now: DateTime.now().add(const Duration(days: 8)),
      );
      expect(await file.exists(), isFalse);
    },
  );

  test('manual completion deletes video and all identified danmaku, after leases release', () async {
    final file = await media(url);
    await danmaku.write(
      getKey(1),
      comments,
      title: 'Series',
      season: 1,
      episode: 1,
    );
    await danmaku.write(
      'other-api',
      comments,
      title: 'Series',
      season: 1,
      episode: 1,
    );
    await danmaku.write(
      getKey(2),
      comments,
      title: 'Series',
      season: 1,
      episode: 2,
    );
    await danmaku.pruneExpired();
    final release = CacheRetention.protect(url);
    final store = await WatchStateStore.create();
    await store.setPlayed(
      const WatchState(
        mediaId: url,
        title: 'Series',
        seasonNumber: 1,
        episodeNumber: 1,
        position: Duration.zero,
        duration: Duration(seconds: 100),
      ),
      true,
    );
    expect(await file.exists(), isTrue);
    expect(await danmaku.read(getKey(1)), isNotNull);
    release();
    for (var i = 0; i < 100 && await file.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // Wait for the asynchronous completion cleanup including danmaku.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await file.exists(), isFalse);
    expect(await danmaku.read(getKey(1)), isNull);
    expect(await danmaku.read('other-api'), isNull);
    expect(await danmaku.read(getKey(2)), isNotNull);
    expect(
      store.load().firstWhere((row) => row.mediaId == url).isCompleted,
      isTrue,
    );
  });

  test('percentage completion and legacy danmaku also clear, keeping watch history', () async {
    final file = await media(url);
    await danmaku.write(getKey(1), comments);
    await danmaku.pruneExpired();
    final store = await WatchStateStore.create();
    await store.save(
      const WatchState(
        mediaId: url,
        title: 'Series',
        seasonNumber: 1,
        episodeNumber: 1,
        position: Duration(seconds: 92),
        duration: Duration(seconds: 100),
      ),
    );
    await store.cleanCompletedCaches();
    expect(await file.exists(), isFalse);
    expect(await danmaku.read(getKey(1)), isNull);
    expect(store.load(), hasLength(1));
  });
  test('unplayed cancels pending cleanup and late danmaku cannot resurrect completed cache', () async {
    final file = await media(url);
    final release = CacheRetention.protect(url);
    const state = WatchState(
      mediaId: url,
      title: 'Series',
      seasonNumber: 1,
      episodeNumber: 1,
      position: Duration.zero,
      duration: Duration(seconds: 100),
    );
    final store = await WatchStateStore.create();
    await store.setPlayed(state, true);
    await danmaku.write(
      getKey(1),
      comments,
      title: 'Series',
      season: 1,
      episode: 1,
      mediaUrl: url,
    );
    expect(await danmaku.read(getKey(1)), isNull);
    await store.setPlayed(state, false);
    release();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await file.exists(), isTrue);
    expect(store.load().single.isCompleted, isFalse);
    await danmaku.write(
      getKey(1),
      comments,
      title: 'Series',
      season: 1,
      episode: 1,
      mediaUrl: url,
    );
    expect(await danmaku.read(getKey(1)), isNotNull);
    await danmaku.pruneExpired();
  });
}
