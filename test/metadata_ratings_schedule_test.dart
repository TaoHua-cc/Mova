import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/metadata/ratings.dart';
import 'package:yingji/src/metadata/tmdb_client.dart';
import 'package:yingji/src/tracking/trakt_client.dart';

void main() {
  test('ratings retain provider scale, real zero and unknown sources', () {
    final rows = MediaRating.parse([
      {'source': 'imdb', 'value': 8.8},
      {'source': 'tmdb', 'value': 84},
      {'source': 'popcorn', 'value': 0},
      {'source': 'letterboxd', 'value': 4.3},
      {'source': 'missing', 'value': null},
      {'source': 'new_source', 'value': 6},
    ]);
    expect(rows.map((r) => r.formatted), [
      '8.8/10',
      '84/100',
      '0%',
      '4.3/5',
      '6',
    ]);
  });
  test('schedule respects timezone, ignores aired and missing dates', () {
    final next = upcomingFromTvmaze(
      [
        {
          'season': 1,
          'number': 1,
          'airtime': '20:00',
          'airstamp': '2026-09-03T20:00:00-04:00',
        },
        {
          'season': 1,
          'number': 2,
          'airtime': '20:00',
          'airstamp': '2026-09-04T20:00:00-04:00',
        },
        {'season': 1, 'number': 3},
      ],
      {
        'webChannel': {'name': 'Test network'},
      },
      DateTime.utc(2026, 9, 4, 12),
    );
    expect(next!.episodeNumber, 2);
    expect(next.airDate.toUtc(), DateTime.utc(2026, 9, 5));
    expect(next.timeKnown, isTrue);
  });
  test('date-only schedule never fabricates midnight airtime', () {
    final next = upcomingFromTvmaze(
      [
        {
          'season': 1,
          'number': 1,
          'airdate': '2026-09-04',
          'airtime': '',
          'airstamp': '2026-09-04T00:00:00Z',
        },
      ],
      {},
      DateTime(2026, 9, 4, 12),
    );
    expect(next!.timeKnown, isFalse);
    expect(next.airDate, DateTime(2026, 9, 4));
  });
  test('schedule keeps every announced future episode in order', () {
    final rows = upcomingListFromTvmaze(
      [
        {'season': 2, 'number': 3, 'airdate': '2026-09-12', 'airtime': ''},
        {
          'season': 2,
          'number': 2,
          'airtime': '20:30',
          'airstamp': '2026-09-06T20:30:00+08:00',
        },
      ],
      {
        'network': {'name': 'Example TV'},
      },
      DateTime(2026, 9, 5),
      until: DateTime(2026, 10),
    );
    expect(rows.map((row) => row.episodeNumber), [2, 3]);
    expect(rows.first.timeKnown, isTrue);
    expect(rows.last.timeKnown, isFalse);
  });
  test('schedule ignores TVmaze specials (season 0)', () {
    final rows = upcomingListFromTvmaze(
      [
        {'season': 0, 'number': 1, 'airdate': '2026-09-12', 'airtime': ''},
        {'season': 2, 'number': 3, 'airdate': '2026-09-15', 'airtime': ''},
      ],
      {
        'network': {'name': 'Example TV'},
      },
      DateTime(2026, 9, 5),
      until: DateTime(2026, 10),
    );
    expect(rows.map((row) => row.seasonNumber), [2]);
  });
  test('TVmaze retries TVDB when the IMDb lookup has no match', () async {
    SharedPreferences.setMockInitialValues({});
    final day = DateTime.now().add(const Duration(days: 7));
    final date =
        '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    final lookups = <String>[];
    final client = TmdbClient(
      client: MockClient((request) async {
        final uri = request.url;
        if (uri.host == 'api.tvmaze.com') {
          if (uri.path == '/lookup/shows') {
            lookups.add(uri.query);
            if (uri.queryParameters.containsKey('imdb')) {
              return http.Response('', 404);
            }
            return http.Response(jsonEncode({'id': 55555}), 200);
          }
          return http.Response(
            jsonEncode([
              {
                'season': 1,
                'number': 1,
                'name': 'Return',
                'airtime': '11:00',
                'airstamp': '${date}T11:00:00+08:00',
              },
            ]),
            200,
          );
        }
        if (uri.path.endsWith('/tv/87654321')) {
          return http.Response(
            jsonEncode({
              'external_ids': {'imdb_id': 'tt87654321', 'tvdb_id': 55555},
              'networks': [],
              'seasons': [],
              'next_episode_to_air': {
                'season_number': 1,
                'episode_number': 1,
                'name': 'Return',
                'air_date': date,
              },
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    final rows = await client.upcomingEpisodes(
      const TmdbItem(id: 87654321, title: 'Test', kind: '剧集'),
    );
    expect(lookups, ['imdb=tt87654321', 'thetvdb=55555']);
    expect(rows, hasLength(1));
    expect(rows.single.timeKnown, isTrue);
    expect(rows.single.airDate.toUtc().hour, 3);
    client.dispose();
  });
  test(
    'TVmaze resolves missing external IDs through an exact localized AKA',
    () async {
      SharedPreferences.setMockInitialValues({});
      final instant = DateTime.now().toUtc().add(const Duration(days: 5));
      final uniqueId = DateTime.now().microsecondsSinceEpoch;
      final tmdbId = uniqueId;
      final tvmazeId = uniqueId + 1;
      final title = 'Localized alternate $uniqueId';
      final aliasLookups = <String>[];
      final scheduleRequests = <String>[];
      final client = TmdbClient(
        client: MockClient((request) async {
          final uri = request.url;
          if (uri.host == 'api.tvmaze.com') {
            scheduleRequests.add(uri.path);
            if (uri.path == '/search/shows') {
              expect(uri.queryParameters['q'], title);
              return http.Response(
                jsonEncode([
                  {
                    'score': 0.6,
                    'show': {
                      'id': tvmazeId,
                      'name': 'Zeri Feisheng',
                      'premiered': '2026-01-01',
                    },
                  },
                ]),
                200,
              );
            }
            if (uri.path == '/shows/$tvmazeId/akas') {
              aliasLookups.add(uri.path);
              return http.Response(
                jsonEncode([
                  {'name': title},
                ]),
                200,
              );
            }
            if (uri.path == '/shows/$tvmazeId/episodes') {
              return http.Response(
                jsonEncode([
                  {
                    'season': 1,
                    'number': 14,
                    'name': 'Episode 14',
                    'airtime': '09:00',
                    'airstamp': instant.toIso8601String(),
                  },
                ]),
                200,
              );
            }
          }
          if (uri.path.endsWith('/tv/$tmdbId')) {
            return http.Response(
              jsonEncode({
                'external_ids': {'imdb_id': null, 'tvdb_id': null},
                'number_of_episodes': 20,
                'networks': [],
                'seasons': [],
              }),
              200,
            );
          }
          return http.Response('{}', 404);
        }),
      );

      final rows = await client.upcomingEpisodes(
        TmdbItem(id: tmdbId, title: title, kind: '剧集', year: 2026),
      );

      expect(aliasLookups, ['/shows/$tvmazeId/akas']);
      expect(scheduleRequests, contains('/shows/$tvmazeId/episodes'));
      expect(rows, hasLength(1));
      expect(rows.single.source, 'TVmaze');
      expect(rows.single.timeKnown, isTrue);
      expect(rows.single.episodeNumber, 14);
      expect(rows.single.airDate.toUtc(), instant);
      client.dispose();
    },
  );
  test('TVmaze title fallback rejects a conflicting premiere year', () async {
    SharedPreferences.setMockInitialValues({});
    final client = TmdbClient(
      client: MockClient((request) async {
        final uri = request.url;
        if (uri.host == 'api.tvmaze.com' && uri.path == '/search/shows') {
          return http.Response(
            jsonEncode([
              {
                'show': {
                  'id': 87650002,
                  'name': 'Same Name',
                  'premiered': '2020-01-01',
                },
              },
            ]),
            200,
          );
        }
        if (uri.path.endsWith('/tv/87650001')) {
          return http.Response(
            jsonEncode({
              'external_ids': {'imdb_id': null, 'tvdb_id': null},
              'seasons': [],
              'networks': [],
            }),
            200,
          );
        }
        if (uri.host == 'api.tvmaze.com' &&
            uri.path == '/shows/87650002/akas') {
          fail('Year-conflicting candidates must not be checked or accepted');
        }
        return http.Response('{}', 404);
      }),
    );

    final rows = await client.upcomingEpisodes(
      const TmdbItem(id: 87650001, title: 'Same Name', kind: '剧集', year: 2024),
    );

    expect(rows, isEmpty);
    client.dispose();
  });
  test(
    'Trakt calendar requests 31 days and preserves the exact instant',
    () async {
      late Uri requested;
      final client = TraktClient(
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(
            jsonEncode([
              {
                'first_aired': '2026-09-08T12:30:00Z',
                'show': {
                  'title': 'Test show',
                  'network': 'Test network',
                  'ids': {'tmdb': 42, 'trakt': 314},
                  'images': {
                    'poster': {'full': 'https://img.example/poster.jpg'},
                    'fanart': {'full': 'https://img.example/fanart.jpg'},
                  },
                },
                'episode': {
                  'season': 2,
                  'number': 5,
                  'number_abs': 19,
                  'title': 'Return',
                },
              },
            ]),
            200,
          );
        }),
      );
      final rows = await client.calendar(
        clientId: 'client',
        accessToken: 'token',
        start: DateTime(2026, 9, 5),
      );
      expect(requested.path, endsWith('/2026-09-05/31'));
      expect(rows.single.airDate, DateTime.utc(2026, 9, 8, 12, 30));
      expect(rows.single.timeKnown, isTrue);
      expect(rows.single.tmdbId, 42);
      expect(rows.single.traktId, 314);
      expect(rows.single.absoluteEpisodeNumber, 19);
      expect(
        rows.single.posterUrl,
        Uri.parse('https://img.example/poster.jpg'),
      );
      expect(
        rows.single.backdropUrl,
        Uri.parse('https://img.example/fanart.jpg'),
      );
      client.dispose();
    },
  );
  test(
    'Trakt playback returns resumable episode progress with identity',
    () async {
      final client = TraktClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode([
              {
                'progress': 36.5,
                'paused_at': '2026-09-05T08:30:00Z',
                'show': {
                  'ids': {'tmdb': 42},
                },
                'episode': {'season': 2, 'number': 5},
              },
            ]),
            200,
          ),
        ),
      );

      final rows = await client.playbackProgress(
        clientId: 'client',
        accessToken: 'token',
      );
      expect(rows.single.tmdbId, 42);
      expect(rows.single.seasonNumber, 2);
      expect(rows.single.episodeNumber, 5);
      expect(rows.single.progress, 36.5);
      expect(rows.single.pausedAt, DateTime.utc(2026, 9, 5, 8, 30));
      client.dispose();
    },
  );
  test(
    'Trakt show progress reports watched and unaired/unwatched counts',
    () async {
      late Uri requested;
      final client = TraktClient(
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(jsonEncode({'aired': 12, 'completed': 7}), 200);
        }),
      );
      final result = await client.showWatchedProgress(
        clientId: 'client',
        accessToken: 'token',
        traktId: 314,
      );
      expect(requested.path, '/shows/314/progress/watched');
      expect(result!.aired, 12);
      expect(result.completed, 7);
      expect(result.unwatched, 5);
      client.dispose();
    },
  );
  test(
    'Trakt discovery keeps TMDB identity and weekly ranking period',
    () async {
      late Uri requested;
      final client = TraktClient(
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(
            jsonEncode([
              {
                'watcher_count': 42,
                'show': {
                  'title': 'Test show',
                  'ids': {'tmdb': 321},
                },
              },
            ]),
            200,
          );
        }),
      );

      final rows = await client.discover(
        clientId: 'client',
        type: 'shows',
        list: 'watched',
        page: 2,
      );
      expect(requested.path, '/discover/trakt/shows/watched');
      expect(requested.queryParameters['period'], 'weekly');
      expect(requested.queryParameters['page'], '2');
      expect(rows.single.tmdbId, 321);
      expect(rows.single.kind, '剧集');
      client.dispose();
    },
  );
  test('Trakt discovery accepts direct popular movie responses', () async {
    final client = TraktClient(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode([
            {
              'title': 'Direct movie',
              'ids': {'tmdb': 550},
            },
          ]),
          200,
        ),
      ),
    );

    final rows = await client.discover(
      clientId: 'client',
      type: 'movies',
      list: 'popular',
    );
    expect(rows.single.tmdbId, 550);
    expect(rows.single.kind, '电影');
    client.dispose();
  });
  testWidgets(
    'cached multi-source scores fit narrow poster and expanded detail',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'yingji.ratings.v1.movie/550': jsonEncode({
          'savedAt': DateTime.now().toIso8601String(),
          'ratings': [
            for (final source in [
              'imdb',
              'tmdb',
              'tomatoes',
              'popcorn',
              'letterboxd',
              'metacritic',
              'rogerebert',
            ])
              {'source': source, 'value': 4},
          ],
        }),
      });
      const item = TmdbItem(id: 550, title: 'test', kind: '电影', rating: 8.4);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 150,
                child: Column(
                  children: [
                    MediaRatingRow(item: item),
                    MediaRatingRow(item: item, expanded: true),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RatingPlatformIcon), findsNWidgets(14));
      expect(find.text('4/10'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );
}
