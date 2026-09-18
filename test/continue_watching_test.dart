import 'package:flutter_test/flutter_test.dart';

import 'package:yingji/src/history/watch_state_store.dart';

void main() {
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
      normalizeWatchState(row('e1-url', '博登家的女儿', 1).withEpisodeMetadata(
        title: '叛逆的女仆',
        episodeTitle: '博登家的女儿',
      )),
    ];
    final visible = continueWatchingRows(healed);
    expect(visible, hasLength(1));
    expect(visible.single.mediaId, 'e2-url');
  });
}
