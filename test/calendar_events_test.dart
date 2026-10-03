import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/tracking/calendar_events.dart';
import 'package:yingji/src/tracking/trakt_client.dart';

void main() {
  test(
    'missing episode platform inherits observed same-season broadcast source',
    () {
      final rows = mergeCalendarEvents([
        TraktEvent(
          title: '剧集',
          episode: 'Episode 1',
          tmdbId: 1,
          seasonNumber: 1,
          episodeNumber: 1,
          airDate: DateTime(2026, 10, 2),
          platform: 'iQIYI',
        ),
        TraktEvent(
          title: '剧集',
          episode: 'Episode 2',
          tmdbId: 1,
          seasonNumber: 1,
          episodeNumber: 2,
          airDate: DateTime(2026, 10, 3),
          platform: 'tencentQQ',
        ),
        TraktEvent(
          title: '其他剧',
          episode: 'Episode 2',
          tmdbId: 2,
          seasonNumber: 1,
          episodeNumber: 2,
          airDate: DateTime(2026, 10, 3),
        ),
      ]);
      expect(rows[0].broadcastPlatforms.keys, ['爱奇艺', '腾讯视频']);
      expect(rows[1].broadcastPlatforms.keys, ['爱奇艺', '腾讯视频']);
      expect(rows[2].broadcastPlatforms, isEmpty);
    },
  );
  test('broadcast platforms preserve source logos and survive cached JSON', () {
    final tencent = Uri.parse('https://example.com/tencent.png');
    final iqiyi = Uri.parse('https://example.com/iqiyi.png');
    final rows = mergeCalendarEvents([
      TraktEvent(
        title: '剧集',
        episode: 'Episode 1',
        tmdbId: 1,
        seasonNumber: 1,
        episodeNumber: 1,
        airDate: DateTime(2026, 10, 2),
        platform: 'tencentQQ',
        platformLogoUrl: tencent,
      ),
      TraktEvent(
        title: '剧集',
        episode: 'Episode 1',
        tmdbId: 1,
        seasonNumber: 1,
        episodeNumber: 1,
        airDate: DateTime(2026, 10, 2),
        platform: 'iQIYI',
        platformLogoUrl: iqiyi,
      ),
    ]);
    expect(rows, hasLength(1));
    expect(rows.single.broadcastPlatforms, {'腾讯视频': tencent, '爱奇艺': iqiyi});
    expect(
      TraktEvent.fromJson(rows.single.toJson()).broadcastPlatforms,
      rows.single.broadcastPlatforms,
    );
    final legacy = Map<String, dynamic>.from(rows.single.toJson())
      ..remove('platforms');
    expect(TraktEvent.fromJson(legacy).broadcastPlatforms, isNotEmpty);
  });
  test(
    'Trakt conflicting absolute numbers cannot swap same-season episodes',
    () {
      TraktEvent local(int n, int day) => TraktEvent(
        tmdbId: 282326,
        title: '兰香如故',
        seasonNumber: 1,
        episodeNumber: n,
        episode: '第 1 季 · 第 $n 集',
        airDate: DateTime(2026, 10, day, 18),
        timeKnown: true,
      );
      final rows = mergeCalendarEvents([
        local(40, 2),
        local(41, 3),
        for (var n = 42; n <= 47; n++) local(n, 4),
        for (final pair in [
          (40, 40),
          (43, 41),
          (44, 42),
          (41, 43),
          (45, 44),
          (46, 45),
          (47, 46),
          (42, 47),
        ])
          TraktEvent(
            tmdbId: 282326,
            title: 'Against the Current',
            seasonNumber: 1,
            episodeNumber: pair.$1,
            absoluteEpisodeNumber: pair.$2,
            episode: '第 1 季 · 第 ${pair.$1} 集 · Episode ${pair.$1}',
            airDate: DateTime(
              2026,
              10,
              pair.$2 <= 42
                  ? 2
                  : pair.$2 <= 46
                  ? 3
                  : 4,
              21,
              30,
            ),
            timeKnown: true,
          ),
      ]);
      expect(rows, hasLength(8));
      expect(rows.where((e) => e.airDate.day == 2).single.episodeNumber, 40);
      expect(rows.where((e) => e.airDate.day == 3).single.episodeNumber, 41);
      final last = rows.where((e) => e.airDate.day == 4).toList();
      expect(last.map((e) => e.episodeNumber), [42, 43, 44, 45, 46, 47]);
      expect(calendarEpisodeSummary(last), '第 1 季 · 第 42–47 集 · 更新 6 集');
      expect(
        mergeCalendarEvents(rows).map((e) => e.episodeNumber),
        rows.map((e) => e.episodeNumber),
      );
    },
  );
  test('same-day show cards summarize ranges and retain actual episodes', () {
    TraktEvent episode(int number, {int day = 4, int id = 282326}) =>
        TraktEvent(
          title: '兰香如故',
          tmdbId: id,
          seasonNumber: 1,
          episodeNumber: number,
          episode: '第 1 季 · 第 $number 集',
          airDate: DateTime(2026, 10, day, 18),
          timeKnown: true,
        );
    final rows = [for (var i = 42; i <= 47; i++) episode(i)];
    final groups = groupCalendarEvents([
      ...rows,
      episode(42),
      episode(48, day: 5),
      episode(1, id: 10),
    ]);
    expect(groups.length, 3);
    expect(groups.first.length, 6);
    expect(calendarEpisodeSummary(groups.first), '第 1 季 · 第 42–47 集 · 更新 6 集');
    expect(
      calendarEpisodeSummary([episode(42), episode(44)]),
      '第 1 季 · 第 42–44 集 · 更新 2 集',
    );
    expect(groupCalendarEvents([]), isEmpty);
    expect(calendarEpisodeSummary([episode(42)]), episode(42).episode);
  });
  test(
    'calendar progress uses announced total while retaining aired floor',
    () {
      final announced = calendarProgressCounts(
        const TraktShowProgress(aired: 12, completed: 7),
        announcedTotal: 30,
      );
      expect(announced.watched, 7);
      expect(announced.unwatched, 23);
      expect(announced.total, 30);

      final staleMetadata = calendarProgressCounts(
        const TraktShowProgress(aired: 12, completed: 7),
        announcedTotal: 5,
      );
      expect(staleMetadata.total, 12);
      expect(staleMetadata.unwatched, 5);
    },
  );

  test('local watch history fills calendar progress without Trakt', () {
    final counts = localCalendarProgressCounts(watched: 5, total: 30);
    expect(counts.watched, 5);
    expect(counts.unwatched, 25);
    expect(counts.total, 30);

    final clamped = localCalendarProgressCounts(watched: 40, total: 30);
    expect(clamped.watched, 30);
    expect(clamped.unwatched, 0);
  });

  test('Chinese title is retained when merged source only has English', () {
    final rows = mergeCalendarEvents([
      TraktEvent(
        tmdbId: 42,
        title: '择日飞升',
        episode: '第 1 季 · 第 13 集',
        seasonNumber: 1,
        episodeNumber: 13,
        airDate: DateTime(2026, 9, 26),
        timeKnown: false,
      ),
      TraktEvent(
        tmdbId: 42,
        title: 'A Record of a Mortal\'s Journey to Immortality',
        episode: '第 1 季 · 第 13 集',
        seasonNumber: 1,
        episodeNumber: 13,
        airDate: DateTime(2026, 9, 26, 9),
        timeKnown: true,
      ),
    ]);
    expect(rows, hasLength(1));
    expect(rows.single.title, '择日飞升');
    expect(rows.single.timeKnown, isTrue);
  });

  test('different season numbering for the same absolute episode merges', () {
    final date = DateTime(2026, 9, 26);
    final rows = mergeCalendarEvents([
      TraktEvent(
        tmdbId: 11,
        title: '凡人修仙传',
        episode: '第 1 季 · 第 193 集 · 第 193 集',
        seasonNumber: 1,
        episodeNumber: 193,
        absoluteEpisodeNumber: 193,
        airDate: date,
        timeKnown: false,
      ),
      TraktEvent(
        tmdbId: 11,
        title: '凡人修仙传',
        episode: '第 8 季 · 第 17 集 · Episode 193',
        seasonNumber: 8,
        episodeNumber: 17,
        airDate: DateTime(2026, 9, 26, 11),
        timeKnown: true,
        platform: 'Bilibili',
      ),
    ]);
    expect(rows, hasLength(1));
    expect(rows.single.absoluteEpisodeNumber, 193);
    expect(rows.single.airDate.hour, 11);
    expect(rows.single.timeKnown, isTrue);
    expect(rows.single.platform, 'Bilibili');
  });

  test('separate episodes of one show remain separate', () {
    final rows = mergeCalendarEvents([
      for (final number in [193, 194])
        TraktEvent(
          tmdbId: 11,
          title: '凡人修仙传',
          episode: '第 $number 集',
          seasonNumber: 1,
          episodeNumber: number,
          airDate: DateTime(2026, 9, 26),
          timeKnown: false,
        ),
    ]);
    expect(rows, hasLength(2));
  });

  test('same-day source copies merge when one source omits episode fields', () {
    final rows = mergeCalendarEvents([
      TraktEvent(
        tmdbId: 7031,
        title: '兰香如故',
        episode: '第 1 季 · 第 6 集 · 旧梦',
        airDate: DateTime(2026, 10, 4, 20),
        timeKnown: false,
      ),
      TraktEvent(
        tmdbId: 7031,
        title: 'Lan Xiang Ru Gu',
        episode: 'S01E06 · Old Dream',
        seasonNumber: 1,
        episodeNumber: 6,
        airDate: DateTime(2026, 10, 4, 21),
        timeKnown: true,
        platform: 'Trakt',
      ),
    ]);

    expect(rows, hasLength(1));
    expect(rows.single.timeKnown, isTrue);
    expect(rows.single.platform, 'Trakt');
  });

  test('same episode number in different seasons is not merged', () {
    final rows = mergeCalendarEvents([
      for (final season in [1, 2])
        TraktEvent(
          tmdbId: 7031,
          title: '兰香如故',
          episode: '第 $season 季 · 第 6 集',
          seasonNumber: season,
          episodeNumber: 6,
          airDate: DateTime(2026, 10, 4),
        ),
    ]);

    expect(rows, hasLength(2));
  });

  test('Mova watchlist and Trakt personal calendar are additive sources', () {
    final rows = mergeCalendarEvents([
      TraktEvent(
        tmdbId: 11,
        title: '仅在 Mova 待看的剧',
        episode: '第 1 季 · 第 2 集',
        seasonNumber: 1,
        episodeNumber: 2,
        airDate: DateTime(2026, 10, 1),
        timeKnown: false,
      ),
      TraktEvent(
        tmdbId: 22,
        title: 'Trakt 个人日历中的剧',
        episode: '第 1 季 · 第 3 集',
        seasonNumber: 1,
        episodeNumber: 3,
        airDate: DateTime(2026, 10, 2),
        timeKnown: true,
      ),
    ]);

    expect(rows.map((event) => event.title), ['仅在 Mova 待看的剧', 'Trakt 个人日历中的剧']);
  });

  test('Trakt global calendar is filtered to Mova watchlist TMDB IDs', () {
    final rows = filterCalendarEventsByShowIds(
      [
        for (final id in [11, 22])
          TraktEvent(
            tmdbId: id,
            title: 'Show $id',
            episode: '第 1 集',
            airDate: DateTime(2026, 10, id),
          ),
        TraktEvent(
          title: 'No TMDB identity',
          episode: '第 1 集',
          airDate: DateTime(2026, 10, 3),
        ),
      ],
      {22},
    );

    expect(rows.map((event) => event.tmdbId), [22]);
  });

  test('old cached event can recover an explicit absolute episode title', () {
    final old = TraktEvent.fromJson({
      'tmdbId': 11,
      'title': '凡人修仙传',
      'episode': '第 1 季 · 第 193 集 · 第 193 集',
      'seasonNumber': 1,
      'episodeNumber': 193,
      'airDate': '2026-09-26',
      'timeKnown': false,
    });
    expect(calendarAbsoluteEpisode(old), 193);
  });

  test('calendar cache round-trips landscape art and reads older entries', () {
    final old = TraktEvent.fromJson({
      'title': '旧缓存',
      'episode': '第 1 集',
      'airDate': '2026-09-26',
    });
    expect(old.backdropUrl, isNull);

    final event = TraktEvent(
      title: '横图剧集',
      episode: '第 1 集',
      airDate: DateTime(2026, 9, 26),
      backdropUrl: Uri.parse('https://image.tmdb.org/t/p/w1280/backdrop.jpg'),
    );
    expect(TraktEvent.fromJson(event.toJson()).backdropUrl, event.backdropUrl);

    final enriched = TraktEvent(
      title: '有平台标识与总集数',
      episode: '第 1 集',
      airDate: DateTime(2026, 9, 26),
      totalEpisodes: 30,
      platformLogoUrl: Uri.parse('https://image.tmdb.org/logo.png'),
    );
    final restored = TraktEvent.fromJson(enriched.toJson());
    expect(restored.totalEpisodes, 30);
    expect(restored.platformLogoUrl, enriched.platformLogoUrl);
  });

  test('merge retains backdrop when the preferred row lacks it', () {
    final date = DateTime(2026, 9, 26);
    final rows = mergeCalendarEvents([
      TraktEvent(
        tmdbId: 11,
        title: '同一部剧',
        episode: '第 1 季 · 第 193 集',
        seasonNumber: 1,
        episodeNumber: 193,
        absoluteEpisodeNumber: 193,
        airDate: date,
        timeKnown: false,
        backdropUrl: Uri.parse('https://image.tmdb.org/backdrop.jpg'),
        platformLogoUrl: Uri.parse('https://image.tmdb.org/logo.png'),
        totalEpisodes: 30,
      ),
      TraktEvent(
        tmdbId: 11,
        title: '同一部剧',
        episode: '第 8 季 · 第 17 集',
        seasonNumber: 8,
        episodeNumber: 17,
        absoluteEpisodeNumber: 193,
        airDate: date,
        timeKnown: true,
      ),
    ]);
    expect(rows, hasLength(1));
    expect(
      rows.single.backdropUrl,
      Uri.parse('https://image.tmdb.org/backdrop.jpg'),
    );
    expect(
      rows.single.platformLogoUrl,
      Uri.parse('https://image.tmdb.org/logo.png'),
    );
    expect(rows.single.totalEpisodes, 30);
  });
}
