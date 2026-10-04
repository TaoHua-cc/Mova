import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:yingji/src/history/watch_state_store.dart';

void main() {
  test('episode posters upgrade once while resolved stills stay cached', () {
    const row = WatchState(
      mediaId: 'episode',
      title: 'Series',
      position: Duration(minutes: 2),
      duration: Duration(minutes: 40),
      episodeNumber: 3,
      imageUrl: 'https://image.tmdb.org/t/p/w500/poster.jpg',
    );
    expect(needsWatchArtwork(row), isTrue);
    expect(watchArtworkResolutionId(row), 'episode:episode-still-v2');
    expect(
      needsWatchArtwork(
        row.withImage('https://image.tmdb.org/t/p/w780/still.jpg'),
      ),
      isFalse,
    );
  });
  test(
    'continue shelf returns latest 20 without deleting episode history',
    () async {
      SharedPreferences.setMockInitialValues({});
      final history = List.generate(
        30,
        (i) => WatchState(
          mediaId: 'movie-$i',
          title: '电影 $i',
          position: const Duration(minutes: 5),
          duration: const Duration(minutes: 90),
          updatedAt: DateTime(2026, 10, 1).add(Duration(minutes: i)),
        ),
      );
      final store = await WatchStateStore.create();
      await store.replaceAll(history);
      final visible = store.visibleContinueRows(store.load());
      expect(visible, hasLength(20));
      expect(visible.first.mediaId, 'movie-29');
      expect(visible.last.mediaId, 'movie-10');
      expect(store.load(), hasLength(30));
      await store.hideFromContinueWatching(visible.first);
      expect(store.visibleContinueRows(store.load()).last.mediaId, 'movie-9');
    },
  );

  test('server name update preserves progress and playback identity', () {
    final row = WatchState(
      mediaId: 'url',
      title: '剧名',
      sourceId: 'a',
      serverItemId: 'e2',
      position: const Duration(minutes: 12),
      duration: const Duration(minutes: 45),
      updatedAt: DateTime(2026, 10, 4),
    );
    final named = row.withEpisodeMetadata(progressOriginName: '主线路');
    expect(named.progressOriginName, '主线路');
    expect(named.position, row.position);
    expect(named.updatedAt, row.updatedAt);
    expect(named.sourceId, 'a');
    expect(WatchState.fromJson(named.toJson()).progressOriginName, '主线路');
  });

  test('resume refresh is wired without refreshing home posters', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    expect(source, contains('onResume: _handleHomeFocus'));
    expect(source, contains('AppLifecycleListener(onResume: _load)'));
    expect(
      source,
      contains('WindowsNativePlayer.retryPendingWatchSync().timeout('),
    );
    expect(source, contains('state.progressOriginName!'));
    final focus = source.substring(
      source.indexOf('void _handleHomeFocus()'),
      source.indexOf('/// 后台刷新可能'),
    );
    expect(focus, contains('_loadHistory()'));
    expect(focus, isNot(contains('_loadCarouselItems()')));
  });
  WatchState episode(
    String id,
    int seconds,
    int day, {
    int number = 1,
    int season = 1,
    bool played = false,
  }) => WatchState(
    mediaId: id,
    title: '示例剧',
    seasonNumber: season,
    isPlayed: played,
    episodeNumber: number,
    position: Duration(seconds: seconds),
    duration: const Duration(seconds: 1000),
    updatedAt: DateTime(2026, 9, day),
  );

  test('same series shows latest record while retaining episode history', () {
    final history = [
      episode('old-url', 600, 1),
      episode('new-url', 200, 2, number: 2),
    ];
    expect(continueWatchingRows(history).single.mediaId, 'new-url');
    expect(history.length, 2);
  });
  test(
    'removing a series hides all its episodes until new playback progress',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = await WatchStateStore.create();
      final first = episode('s1e1', 400, 1);
      final latest = episode('s1e2', 500, 2, number: 2);
      await store.replaceAll([first, latest]);
      final staleRefreshSnapshot = store.visibleContinueRows(store.load());

      await store.hideFromContinueWatching(latest);
      expect(store.visibleContinueRows(store.load()), isEmpty);
      expect(store.visibleContinueRows(staleRefreshSnapshot), isEmpty);
      expect(store.load(), hasLength(2));

      final serverReplica = WatchState(
        mediaId: 'server-playback-url',
        title: '示例剧',
        position: const Duration(seconds: 600),
        duration: const Duration(seconds: 1000),
        sourceId: 'server-a',
        serverItemId: 'item-2',
        seasonNumber: 1,
        episodeNumber: 3,
        progressOrigin: 'server',
      );
      final restoredStore = await WatchStateStore.create();
      expect(
        restoredStore.visibleContinueRows([
          ...restoredStore.load(),
          serverReplica,
        ]),
        isEmpty,
      );

      await restoredStore.save(
        episode('new-playback', 100, 3, number: 3),
        updatedAt: DateTime(2027),
      );
      expect(
        restoredStore.visibleContinueRows(restoredStore.load()),
        hasLength(1),
      );
      expect(
        restoredStore.visibleContinueRows(restoredStore.load()).single.mediaId,
        'new-playback',
      );
    },
  );
  test('marking episode one watched preserves episode two resume progress', () {
    final history = [
      episode('episode-one-old', 400, 1),
      episode('episode-two', 250, 2, number: 2),
      episode('episode-one-marked', 0, 3, played: true),
    ];
    final row = continueWatchingRows(history).single;
    expect(row.mediaId, 'episode-two');
    expect(row.position, const Duration(seconds: 250));
    expect(history.length, 3);
  });
  test('episode state does not suppress the same number in another season', () {
    expect(
      continueWatchingRows([
        episode('season-two', 300, 1, season: 2),
        episode('season-one', 950, 2),
      ]).single.mediaId,
      'season-two',
    );
  });
  test('resetting an episode hides its stale partial duplicate only', () {
    expect(
      continueWatchingRows([
        episode('old', 400, 1),
        episode('other', 200, 2, number: 2),
        episode('reset', 0, 3),
      ]).single.mediaId,
      'other',
    );
  });
  test(
    'completion uses duration; latest completion hides stale duplicates',
    () {
      expect(episode('zero', 0, 1).isCompleted, isFalse);
      expect(episode('partial', 500, 1).isCompleted, isFalse);
      expect(episode('done', 950, 2).isCompleted, isTrue);
      expect(
        continueWatchingRows([episode('old', 400, 1), episode('done', 950, 2)]),
        isEmpty,
      );
    },
  );

  test('watch progress origin survives local storage serialization', () {
    final source = WatchState(
      mediaId: 'server-url',
      title: '示例剧',
      position: const Duration(minutes: 8),
      duration: const Duration(minutes: 45),
      progressOrigin: 'server',
      progressOriginName: '客厅服务器',
    );

    final restored = WatchState.fromJson(source.toJson());
    expect(restored.progressOrigin, 'server');
    expect(restored.progressOriginName, '客厅服务器');
  });

  test(
    'continue origin is shared in sync mode and distinct in local-only mode',
    () {
      WatchState row(String origin) => WatchState(
        mediaId: origin,
        title: '示例剧',
        position: const Duration(minutes: 8),
        duration: const Duration(minutes: 45),
        progressOrigin: origin,
        sourceId: 'server-a',
      );

      for (final origin in ['local', 'server', 'trakt']) {
        expect(row(origin).visibleProgressOrigin(localOnly: false), 'server');
        expect(row(origin).visibleProgressOrigin(localOnly: true), origin);
      }
    },
  );

  test('dated rows lead by time, then undated rows use source priority', () {
    WatchState row(String id, String origin, {DateTime? time}) => WatchState(
      mediaId: id,
      title: id,
      position: const Duration(minutes: 5),
      duration: const Duration(minutes: 45),
      updatedAt: time,
      progressOrigin: origin,
    );

    final sorted = sortWatchStatesByRecency([
      row('local-undated', 'local'),
      row('server-undated', 'server'),
      row('older-local', 'local', time: DateTime(2026, 9, 4)),
      row('trakt-undated', 'trakt'),
      row('newer-server', 'server', time: DateTime(2026, 9, 5)),
    ]);

    expect(sorted.map((state) => state.mediaId), [
      'newer-server',
      'older-local',
      'trakt-undated',
      'server-undated',
      'local-undated',
    ]);
  });

  test('normalize drops an episode title that repeats the series name', () {
    final state = WatchState(
      mediaId: 'url-e2',
      title: '叛逆的女仆',
      episodeTitle: '叛逆的女仆',
      seasonNumber: 1,
      episodeNumber: 2,
      position: const Duration(seconds: 45),
      duration: const Duration(minutes: 53),
    );

    final cleaned = normalizeWatchState(state);
    expect(cleaned.episodeTitle, isNull);
    expect(cleaned.title, '叛逆的女仆');
    // 已经干净的记录原样返回，避免无谓的副本。
    expect(identical(normalizeWatchState(cleaned), cleaned), isTrue);
  });

  test('normalize drops generic episode labels but keeps real names', () {
    WatchState row(String episodeTitle) => WatchState(
      mediaId: 'url',
      title: '完美世界',
      episodeTitle: episodeTitle,
      seasonNumber: 2,
      episodeNumber: 2,
      position: const Duration(seconds: 30),
      duration: const Duration(minutes: 57),
    );

    expect(normalizeWatchState(row('第 2 集')).episodeTitle, isNull);
    expect(normalizeWatchState(row('第2话')).episodeTitle, isNull);
    expect(normalizeWatchState(row('  ')).episodeTitle, isNull);
    expect(normalizeWatchState(row('沈家灭门，嘉兰入林府')).episodeTitle, '沈家灭门，嘉兰入林府');
    // 非剧集记录（电影）不清洗副标题。
    final movie = WatchState(
      mediaId: 'movie',
      title: '某些电影',
      episodeTitle: '某些电影',
      position: const Duration(seconds: 30),
      duration: const Duration(minutes: 90),
    );
    expect(normalizeWatchState(movie).episodeTitle, '某些电影');
  });

  test('withEpisodeMetadata replaces naming and keeps everything else', () {
    final state = WatchState(
      mediaId: 'url-e1',
      title: '第 1 集',
      episodeTitle: '沈家灭门，嘉兰入林府',
      tmdbId: 282326,
      seasonNumber: 1,
      episodeNumber: 1,
      position: const Duration(seconds: 2),
      duration: const Duration(minutes: 46),
      updatedAt: DateTime(2026, 9, 18),
      progressOrigin: 'local',
    );

    final healed = state.withEpisodeMetadata(
      title: '叛逆的女仆',
      episodeTitle: '博登家的女儿',
      tmdbId: null, // null = 保留原值
    );
    expect(healed.title, '叛逆的女仆');
    expect(healed.episodeTitle, '博登家的女儿');
    expect(healed.tmdbId, 282326);
    expect(healed.position, state.position);
    expect(healed.updatedAt, state.updatedAt);
    expect(healed.progressOrigin, 'local');
  });

  test('server-healed titles reunite one series split across two rows', () {
    // 复刻线上脏数据：同一部剧的两集，旧版本把单集条目名写成了记录标题，
    // 其中一条还挂着错误剧集的 tmdbId。合并自愈把标题统一后，
    // 分组别名（series:剧名）应当把它们并成一张卡。
    WatchState row(String id, String title, int day) => WatchState(
      mediaId: id,
      title: title,
      episodeTitle: title,
      seasonNumber: 1,
      episodeNumber: id.endsWith('e2') ? 2 : 1,
      position: const Duration(seconds: 40),
      duration: const Duration(minutes: 53),
      updatedAt: DateTime(2026, 9, day),
    );

    final healed = [
      row('e2-url', '叛逆的女仆', 2),
      normalizeWatchState(
        row(
          'e1-url',
          '博登家的女儿',
          1,
        ).withEpisodeMetadata(title: '叛逆的女仆', episodeTitle: '博登家的女儿'),
      ),
    ];
    final visible = continueWatchingRows(healed);
    expect(visible, hasLength(1));
    expect(visible.single.mediaId, 'e2-url');
  });
}
