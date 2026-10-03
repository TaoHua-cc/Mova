import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/history/watch_state_store.dart';
import 'package:yingji/src/player/playback_progress.dart';

WatchState episode(String id, {int number = 2, double progress = .5}) =>
    WatchState(
      mediaId: id,
      title: 'series',
      tmdbId: 123,
      seasonNumber: 1,
      episodeNumber: number,
      sourceId: id,
      serverItemId: id,
      position: Duration(seconds: (100 * progress).round()),
      duration: const Duration(seconds: 100),
    );

void main() {
  test('marks publish once after persistence, reset all aliases, retain other episodes', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await WatchStateStore.create();
    await store.save(episode('a'));
    await store.save(episode('b'));
    await store.save(episode('catalog'));
    await store.save(episode('other', number: 3));
    var revisions = 0;
    void changed() => revisions++;
    WatchStateStore.revision.addListener(changed);
    try {
      await store.setPlayed(episode('a'), true);
      expect(revisions, 1);
      expect(
        store
            .load()
            .where((row) => row.episodeNumber == 2)
            .every((row) => row.isCompleted && row.progress == 1),
        isTrue,
      );
      await store.setPlayed(episode('a'), false);
      expect(revisions, 2);
      final reopened = await WatchStateStore.create();
      expect(
        reopened
            .load()
            .where((row) => row.episodeNumber == 2)
            .every((row) => !row.isCompleted && row.position == Duration.zero),
        isTrue,
      );
      expect(
        reopened.load().firstWhere((row) => row.episodeNumber == 3).progress,
        .5,
      );
      expect(continueWatchingRows(reopened.load()).single.episodeNumber, 3);
      await reopened.replaceAll([
        episode('remote', progress: .8).withUpdatedAt(DateTime(2020)),
      ]);
      expect(
        reopened
            .load()
            .where((row) => row.episodeNumber == 2)
            .every((row) => row.progress == 0),
        isTrue,
      );
      await reopened.save(episode('a', progress: .2));
      expect(reopened.load().first.progress, .2);
    } finally {
      WatchStateStore.revision.removeListener(changed);
    }
  });

  test('zero throughput distinguishes buffered, stalled, paused and local', () {
    String label({
      double bytes = 0,
      bool buffering = false,
      bool playing = true,
      bool local = false,
    }) => playbackNetworkLabel(
      bytesPerSecond: bytes,
      position: const Duration(seconds: 10),
      buffer: const Duration(seconds: 40),
      buffering: buffering,
      playing: playing,
      local: local,
    );
    expect(label(), '0 KB/s · 已缓冲 30s');
    expect(label(bytes: 1048576), '1.0 MB/s · 可播 30s');
    expect(label(buffering: true), '0 KB/s · 缓冲中');
    expect(label(playing: false), '0 KB/s · 已暂停');
    expect(label(local: true), '本地播放');
    expect(label(bytes: double.nan), '0 KB/s · 已缓冲 30s');
  });

  test('detail and native manual marks retain explicit local resets', () {
    final detail = File('lib/src/metadata/metadata_detail_page.dart')
        .readAsStringSync();
    final native = File('lib/src/player/windows_native_player.dart')
        .readAsStringSync();
    expect(detail, contains('await watchStore.setPlayed('));
    expect(detail, contains('await store.setPlayed('));
    expect(detail, contains('saved != null ? savedPosition : remotePosition'));
    expect(native, contains('await store.setPlayed('));
    expect(native, isNot(contains('await store.remove(entry.url)')));
  });
}
