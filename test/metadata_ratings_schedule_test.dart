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
                  'ids': {'tmdb': 42},
                },
                'episode': {'season': 2, 'number': 5, 'title': 'Return'},
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
      expect(requested.path, '/shows/watched');
      expect(requested.queryParameters['period'], 'weekly');
      expect(requested.queryParameters['page'], '2');
      expect(rows.single.tmdbId, 321);
      expect(rows.single.kind, '剧集');
      client.dispose();
    },
  );
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
