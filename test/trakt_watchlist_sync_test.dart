import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/history/watchlist_store.dart';
import 'package:yingji/src/metadata/tmdb_client.dart';
import 'package:yingji/src/tracking/trakt_client.dart';
import 'package:yingji/src/tracking/trakt_watchlist_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'first sync imports Trakt items and adds Mova items without deletion',
    () async {
      SharedPreferences.setMockInitialValues({
        'yingji.watchlist': [
          jsonEncode(
            const TmdbItem(id: 7, title: 'Mova title', kind: '剧集').toJson(),
          ),
        ],
      });
      final requests = <http.Request>[];
      final client = TraktClient(
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/users/settings') {
            return http.Response(
              jsonEncode({
                'user': {'uuid': 'account-a'},
              }),
              200,
            );
          }
          if (request.url.path == '/sync/watchlist/shows') {
            return http.Response(
              jsonEncode([
                {
                  'show': {
                    'title': 'Trakt title',
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
      final store = await WatchlistStore.create();

      await TraktWatchlistSync(client)
          .synchronize(store: store, clientId: 'client', accessToken: 'token');

      expect(store.load().map((item) => item.id).toSet(), {7, 42});
      expect(
        store.load().singleWhere((item) => item.id == 7).title,
        'Mova title',
      );
      final write = requests.singleWhere((request) => request.method == 'POST');
      expect(write.url.path, '/sync/watchlist');
      expect(jsonDecode(write.body)['shows'][0]['ids']['tmdb'], 7);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs
            .getStringList('yingji.trakt.watchlist-sync.v1.account-a')!
            .toSet(),
        {'shows:7', 'shows:42'},
      );
      client.dispose();
    },
  );

  test(
    'deletions on either side mirror only after a prior shared snapshot',
    () async {
      SharedPreferences.setMockInitialValues({
        'yingji.watchlist': [
          jsonEncode(
            const TmdbItem(id: 1, title: 'Remote-removed', kind: '剧集').toJson(),
          ),
        ],
        'yingji.trakt.watchlist-sync.v1.account-a': ['shows:1', 'shows:2'],
      });
      final requests = <http.Request>[];
      final client = TraktClient(
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/users/settings') {
            return http.Response(
              jsonEncode({
                'user': {'uuid': 'account-a'},
              }),
              200,
            );
          }
          if (request.url.path == '/sync/watchlist/shows') {
            return http.Response(
              jsonEncode([
                {
                  'show': {
                    'title': 'Mova-removed',
                    'ids': {'tmdb': 2},
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
      final store = await WatchlistStore.create();

      await TraktWatchlistSync(client)
          .synchronize(store: store, clientId: 'client', accessToken: 'token');

      final removal = requests.singleWhere(
        (request) => request.url.path == '/sync/watchlist/remove',
      );
      expect(jsonDecode(removal.body)['shows'][0]['ids']['tmdb'], 2);
      expect(store.load(), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList('yingji.trakt.watchlist-sync.v1.account-a'),
        isEmpty,
      );
      client.dispose();
    },
  );
}
