import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yingji/src/metadata/tmdb_client.dart';
import 'package:yingji/src/tracking/trakt_client.dart';

void main() {
  test(
    'Trakt all-shows calendar uses the requested 31-day public endpoint',
    () async {
      late http.Request requested;
      final client = TraktClient(
        client: MockClient((request) async {
          requested = request;
          return http.Response(
            jsonEncode([
              {
                'first_aired': '2026-09-24T00:00:00Z',
                'show': {
                  'title': 'Date-only schedule',
                  'ids': {'tmdb': 22},
                },
                'episode': {'season': 1, 'number': 1, 'title': 'Pilot'},
              },
            ]),
            200,
          );
        }),
      );

      final rows = await client.allShowsCalendar(
        clientId: 'client',
        start: DateTime(2026, 9, 24),
      );

      expect(requested.url.path, '/calendars/all/shows/2026-09-24/31');
      expect(requested.url.queryParameters['extended'], 'full');
      expect(requested.headers['trakt-api-key'], 'client');
      expect(requested.headers.containsKey('authorization'), isFalse);
      expect(rows.single.timeKnown, isFalse);
      client.dispose();
    },
  );

  test(
    'Trakt watchlist reads both kinds and add/remove sends TMDB IDs',
    () async {
      final requests = <http.Request>[];
      final client = TraktClient(
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET' && request.url.path.endsWith('/shows')) {
            return http.Response(
              jsonEncode([
                {
                  'show': {
                    'title': 'Remote show',
                    'year': 2026,
                    'ids': {'tmdb': 42},
                  },
                },
              ]),
              200,
            );
          }
          if (request.method == 'GET') return http.Response('[]', 200);
          return http.Response('{}', 200);
        }),
      );

      final remote = await client.watchlist(
        clientId: 'client',
        accessToken: 'token',
      );
      expect(remote.single.id, 42);
      expect(remote.single.title, 'Remote show');
      expect(remote.single.kind, '剧集');
      await client.addWatchlistItems(
        clientId: 'client',
        accessToken: 'token',
        items: const [TmdbItem(id: 7, title: 'Local show', kind: '剧集')],
      );
      await client.removeWatchlistItems(
        clientId: 'client',
        accessToken: 'token',
        items: const [TmdbItem(id: 42, title: 'Remote show', kind: '剧集')],
      );

      final writes = requests.where((request) => request.method == 'POST');
      expect(writes.map((request) => request.url.path), [
        '/sync/watchlist',
        '/sync/watchlist/remove',
      ]);
      expect(jsonDecode(writes.first.body)['shows'][0]['ids']['tmdb'], 7);
      expect(jsonDecode(writes.last.body)['shows'][0]['ids']['tmdb'], 42);
      client.dispose();
    },
  );
}
