import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/player/next_episode_preload.dart';

void main() {
  bool ready(
    int position,
    int buffered, {
    int? outro,
    bool buffering = false,
  }) => shouldPreloadNextEpisode(
    position: Duration(seconds: position),
    duration: const Duration(seconds: 1000),
    bufferedEnd: Duration(seconds: buffered),
    outroStart: outro == null ? null : Duration(seconds: outro),
    buffering: buffering,
  );

  test('ratio and buffered outro trigger without a minute threshold', () {
    expect(ready(799, 850), isFalse);
    expect(ready(750, 810), isFalse);
    expect(ready(800, 850), isTrue);
    expect(ready(750, 810, outro: 850), isTrue);
    expect(ready(300, 850, outro: 850), isTrue);
    expect(ready(300, 400, outro: 450), isFalse);
  });
  test(
    'both settings and Android use the shared trigger, not lead minutes',
    () {
      final settings = File('lib/src/media_center.dart').readAsStringSync();
      final android = File('lib/src/player/player_page.dart')
          .readAsStringSync();
      expect(settings, isNot(contains('preload-lead-minutes')));
      expect(android, isNot(contains('preload-lead-minutes')));
      expect(android, contains('shouldPreloadNextEpisode('));
      expect(android, contains("invokeMethod<bool>('preloadNext'"));
      expect(android, contains('_prepareNextResource(next)'));
      final native = File(
        'android/app/src/main/kotlin/com/taohua/mova/ExoPlayerPlatformView.kt',
      ).readAsStringSync();
      expect(native, contains('CacheWriter('));
      expect(native, contains('.setCacheWriteDataSinkFactory(null)'));
      expect(native, contains('preloadWriter?.cancel()'));
    },
  );

  test('never compete with starvation or invalid playback', () {
    expect(ready(900, 902), isFalse);
    expect(ready(900, 1000, buffering: true), isFalse);
    expect(ready(0, 1000), isFalse);
    expect(
      shouldPreloadNextEpisode(
        position: const Duration(seconds: 900),
        duration: Duration.zero,
        bufferedEnd: const Duration(seconds: 1000),
      ),
      isFalse,
    );
    expect(ready(999, 1000), isTrue);
  });

  test('native preparation updates next URL without starting playback', () {
    final source = File('windows/native_player/main.cpp').readAsStringSync();
    final branch = source
        .split('if (update && update->prepared) {')[1]
        .split('if (!update ||')[0];
    expect(branch, contains('g_playlist_position.load() + 1'));
    expect(branch, isNot(contains('LoadPlaylistEntry(')));
    expect(branch, isNot(contains('MpvCommand(')));
    expect(source, contains('MOVA_PRELOAD_STATE='));
  });
  test(
    'playback behavior changes are wired through both native setting gates',
    () {
      final native = File('windows/native_player/main.cpp').readAsStringSync();
      final dart = File('lib/src/player/windows_native_player.dart')
          .readAsStringSync();
      for (final name in ['cache-secs', 'demuxer-readahead-secs']) {
        expect(native, contains('name == "$name"'));
        expect(dart, contains("'$name'"));
      }
      expect(dart, contains('session.reloadPreloadSettings(preferences);'));
      final disable = dart.split('if (!preloadNext) {')[1].split('};')[0];
      expect(disable, contains("sendLine('MOVA_PREPARE_CANCEL')"));
      expect(disable, contains('preparedIndices.clear()'));
      expect(dart, contains('var preloadNext ='));
      expect(dart, isNot(contains('preload-lead-minutes')));
    },
  );
}
