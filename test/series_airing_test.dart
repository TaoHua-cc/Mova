import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/metadata/series_airing.dart';
import 'package:yingji/src/metadata/tmdb_client.dart';
import 'package:yingji/src/tracking/calendar_events.dart';
import 'package:yingji/src/tracking/trakt_auth.dart';
import 'package:yingji/src/tracking/trakt_client.dart';

class FakeTmdb extends TmdbClient {
  int calls = 0;
  Map<String, dynamic> metadata = {'status': 'Returning Series'};
  List<TmdbUpcomingEpisode> episodes = [];
  bool fail = false;
  @override
  Future<Map<String, dynamic>> seriesAiringMetadata(TmdbItem item) async {
    calls++;
    if (fail) throw StateError('offline');
    return metadata;
  }

  @override
  Future<List<TmdbUpcomingEpisode>> upcomingEpisodes(
    TmdbItem item, {
    String apiKey = '',
    Duration horizon = const Duration(days: 90),
  }) async => episodes;
}

class FakeTrakt extends TraktClient {
  int calls = 0;
  bool fail = false;
  ({Map show, Map? next, Map? last})? airing;
  @override
  Future<({Map show, Map? next, Map? last})?> showAiring({
    required int tmdbId,
    required String clientId,
    required String accessToken,
  }) async {
    calls++;
    if (fail) throw StateError('offline');
    return airing;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('mova-airing-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => temp.path,
        );
  });
  tearDownAll(() async => temp.delete(recursive: true));
  const disconnected = TraktCredentials(clientId: 'test', accessToken: '');
  const connected = TraktCredentials(clientId: 'test', accessToken: 'fixture');
  final now = DateTime(2026, 10, 4, 12);
  TmdbItem item(int id) => TmdbItem(id: id, title: '测试作品', kind: '剧集');

  test(
    'persisted series snapshot avoids all requests after re-enter/restart',
    () async {
      SharedPreferences.setMockInitialValues({});
      final tmdb = FakeTmdb()
        ..episodes = [
          TmdbUpcomingEpisode(
            seasonNumber: 1,
            episodeNumber: 2,
            title: '第二集',
            airDate: now.add(const Duration(days: 1)),
          ),
        ];
      final trakt = FakeTrakt();
      final first = await SeriesAiringStore(
        tmdb: tmdb,
        trakt: trakt,
      ).load(item(10001), credentials: disconnected, now: now);
      expect(first.nextAt(now)?.episodeNumber, 2);
      tmdb.fail = true;
      final second = await SeriesAiringStore(tmdb: tmdb, trakt: trakt).load(
        item(10001),
        credentials: disconnected,
        now: now.add(const Duration(minutes: 1)),
      );
      expect(second.events.single.episodeNumber, 2);
      expect(tmdb.calls, 1);
      expect(trakt.calls, 0);
      tmdb.dispose();
      trakt.dispose();
    },
  );

  test(
    'detail and calendar share persisted schedule and completion policy',
    () {
      final detail = File('lib/src/metadata/next_episode.dart')
          .readAsStringSync();
      final calendar = File('lib/src/media_center.dart').readAsStringSync();
      expect(detail, contains('SeriesAiringStore'));
      expect(detail, contains('completedAt(DateTime.now())'));
      expect(detail, contains("'已完结'"));
      expect(
        calendar,
        contains('SeriesAiringStore(tmdb: _tmdb, trakt: _trakt)'),
      );
      expect(calendar, contains('calendarGroupCompleted(episodes)'));
    },
  );

  test(
    'connected Trakt exact time wins while localized metadata remains',
    () async {
      SharedPreferences.setMockInitialValues({});
      final tmdb = FakeTmdb()
        ..episodes = [
          TmdbUpcomingEpisode(
            seasonNumber: 1,
            episodeNumber: 2,
            title: '中文集名',
            airDate: now.add(const Duration(days: 1)),
            timeKnown: true,
            source: 'TVmaze',
            platforms: const {'iQIYI': null},
          ),
        ];
      final exact = now.add(const Duration(days: 1, hours: 3)).toUtc();
      final trakt = FakeTrakt()
        ..airing = (
          show: {
            'ids': {'tmdb': 10002, 'trakt': 7},
            'status': 'returning series',
            'network': 'Tencent Video',
          },
          next: {
            'season': 1,
            'number': 2,
            'first_aired': exact.toIso8601String(),
          },
          last: null,
        );
      final result = await SeriesAiringStore(
        tmdb: tmdb,
        trakt: trakt,
      ).load(item(10002), credentials: connected, now: now);
      expect(result.events.single.airDate, exact);
      expect(result.events.single.source, 'Trakt');
      expect(result.events.single.episode, contains('中文集名'));
      expect(result.events.single.traktId, 7);
      expect(result.events.single.broadcastPlatforms.length, 2);
      expect(result.completed, false);
      await SeriesAiringStore(
        tmdb: tmdb,
        trakt: trakt,
      ).load(item(10002), credentials: connected, now: now);
      expect(trakt.calls, 1);
      tmdb.dispose();
      trakt.dispose();
    },
  );

  test(
    'ended final episode is marked, unknown next is not completion',
    () async {
      SharedPreferences.setMockInitialValues({});
      final tmdb = FakeTmdb()
        ..metadata = {
          'status': 'Ended',
          'seasons': [
            {'season_number': 1, 'episode_count': 3},
          ],
          'last_episode_to_air': {
            'season_number': 1,
            'episode_number': 3,
            'air_date': '2026-10-03',
            'name': '终章',
          },
        };
      final trakt = FakeTrakt();
      final ended = await SeriesAiringStore(
        tmdb: tmdb,
        trakt: trakt,
      ).load(item(10003), credentials: disconnected, now: now);
      expect(ended.completed, true);
      expect(calendarGroupCompleted(ended.events, now: now), true);
      tmdb.metadata = {'status': 'Returning Series'};
      final ongoing = await SeriesAiringStore(
        tmdb: tmdb,
        trakt: trakt,
      ).load(item(10004), credentials: disconnected, now: now);
      expect(ongoing.completed, false);
      expect(ongoing.events, isEmpty);
      tmdb.dispose();
      trakt.dispose();
    },
  );

  test(
    'Trakt series finale works without TMDB and persists across fields',
    () async {
      SharedPreferences.setMockInitialValues({});
      final tmdb = FakeTmdb()..fail = true;
      final trakt = FakeTrakt()
        ..airing = (
          show: {'status': 'ended'},
          next: null,
          last: {
            'season': 2,
            'number': 10,
            'first_aired': '2026-10-02T10:00:00Z',
            'episode_type': 'series_finale',
          },
        );
      final result = await SeriesAiringStore(
        tmdb: tmdb,
        trakt: trakt,
      ).load(item(10005), credentials: connected, now: now);
      expect(result.completed, true);
      expect(
        TraktEvent.fromJson(result.events.single.toJson()).seriesFinale,
        true,
      );
      expect(
        TraktEvent.fromJson({'title': 'old', 'airDate': now.toIso8601String()})
            .seriesFinale,
        false,
      );
      tmdb.dispose();
      trakt.dispose();
    },
  );

  test(
    'future finale is not already completed and passed airing expires cache',
    () {
      final finale = TraktEvent(
        title: 'Show',
        episode: 'S01E10',
        seriesFinale: true,
        airDate: now.add(const Duration(hours: 1)),
        timeKnown: true,
      );
      final snapshot = SeriesAiringSnapshot(events: [finale], savedAt: now);
      expect(calendarGroupCompleted([finale], now: now), false);
      expect(snapshot.freshAt(now.add(const Duration(minutes: 59))), true);
      expect(snapshot.freshAt(now.add(const Duration(hours: 1))), false);
      expect(
        calendarGroupCompleted([
          finale,
        ], now: now.add(const Duration(hours: 1))),
        true,
      );
    },
  );

  test(
    'Trakt lookup requires exact TMDB identity and handles 204 next',
    () async {
      final paths = <String>[];
      final client = TraktClient(
        client: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.startsWith('/search/'))
            return http.Response(
              jsonEncode([
                {
                  'show': {
                    'ids': {'tmdb': 99, 'trakt': 100},
                    'status': 'ended',
                  },
                },
                {
                  'show': {
                    'ids': {'tmdb': 88, 'trakt': 101},
                    'status': 'ended',
                  },
                },
              ]),
              200,
            );
          if (request.url.path.endsWith('/next_episode'))
            return http.Response('', 204);
          return http.Response(
            jsonEncode({
              'season': 1,
              'number': 3,
              'first_aired': '2026-10-02T10:00:00Z',
              'episode_type': 'series_finale',
            }),
            200,
          );
        }),
      );
      final result = await client.showAiring(
        tmdbId: 88,
        clientId: 'fixture',
        accessToken: '',
      );
      expect(result?.next, null);
      expect(result?.last?['number'], 3);
      expect(paths, contains('/shows/101/next_episode'));
      expect(paths, isNot(contains('/shows/100/next_episode')));
      client.dispose();
    },
  );
}
