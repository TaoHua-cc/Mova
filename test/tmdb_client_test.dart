import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/metadata/tmdb_client.dart';

void main() {
  test(
    'falls back to managed metadata when a saved direct key cannot connect',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({
        'yingji.tmdb.api-key': 'stale-key',
      });
      final requested = <Uri>[];
      final client = TmdbClient(
        client: MockClient((request) async {
          requested.add(request.url);
          if (request.url.host == 'api.themoviedb.org') {
            throw http.ClientException('direct endpoint unavailable');
          }
          return http.Response(
            jsonEncode({
              'results': [
                {'id': 1, 'title': 'fallback-ok', 'media_type': 'movie'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final items = await client.trending();
      expect(items.single.title, 'fallback-ok');
      expect(requested.any((uri) => uri.host == 'api.themoviedb.org'), isFalse);
      expect(
        requested.any(
          (uri) => uri.host == 'yingji-metadata.gctykxy.workers.dev',
        ),
        isTrue,
      );
      client.dispose();
    },
  );

  test('discover forwards custom category and ranking filters', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    Uri? requested;
    final client = TmdbClient(
      client: MockClient((request) async {
        requested = request.url;
        return http.Response(jsonEncode({'results': <Object>[]}), 200);
      }),
    );

    await client.discover(
      'tv',
      genres: '10764|10767',
      originCountry: 'JP',
      originalLanguage: 'ja',
      year: 2026,
      minimumRating: 8,
      minimumVoteCount: 200,
      minimumRuntime: 20,
      maximumRuntime: 60,
      provider: '337',
      watchRegion: 'TW',
      sortBy: 'vote_average.desc',
      dateFrom: DateTime(2026, 1, 2),
      dateTo: DateTime(2026, 2, 3),
    );

    expect(requested?.path, endsWith('/discover/tv'));
    expect(requested?.queryParameters['with_genres'], '10764|10767');
    expect(requested?.queryParameters['sort_by'], 'vote_average.desc');
    expect(requested?.queryParameters['with_origin_country'], 'JP');
    expect(requested?.queryParameters['with_original_language'], 'ja');
    expect(requested?.queryParameters['first_air_date_year'], '2026');
    expect(requested?.queryParameters['vote_average.gte'], '8.0');
    expect(requested?.queryParameters['vote_count.gte'], '200');
    expect(requested?.queryParameters['with_runtime.gte'], '20');
    expect(requested?.queryParameters['with_runtime.lte'], '60');
    expect(requested?.queryParameters['with_watch_providers'], '337');
    expect(requested?.queryParameters['watch_region'], 'TW');
    expect(requested?.queryParameters['first_air_date.gte'], '2026-01-02');
    expect(requested?.queryParameters['first_air_date.lte'], '2026-02-03');
    client.dispose();
  });

  test(
    'MDBList official feed resolves returned TMDB ids as Chinese details',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final requested = <Uri>[];
      final client = TmdbClient(
        client: MockClient((request) async {
          requested.add(request.url);
          if (request.url.path.startsWith('/discover/mdblist/')) {
            return http.Response(
              jsonEncode({
                'results': [
                  {'tmdbId': 1396, 'mediaType': 'tv'},
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            jsonEncode({
              'id': 1396,
              'name': '绝命毒师',
              'first_air_date': '2008-01-20',
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final items = await client.mdblistOfficial(
        'tv',
        'trending',
        country: 'US',
      );
      expect(items.single.title, '绝命毒师');
      expect(requested.first.path, '/discover/mdblist/tv/trending');
      expect(requested.first.queryParameters['country'], 'US');
      expect(requested.last.path, '/tmdb/tv/1396');
      client.dispose();
    },
  );

  test(
    'Douban public list resolves titles through TMDB movie search',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final client = TmdbClient(
        client: MockClient((request) async {
          if (request.url.path.startsWith('/discover/douban/')) {
            return http.Response(
              jsonEncode({
                'results': [
                  {'title': '霸王别姬', 'mediaType': 'movie'},
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            jsonEncode({
              'results': [
                {'id': 2, 'title': '霸王别姬'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final items = await client.doubanPublicList('chart');
      expect(items.single.title, '霸王别姬');
      client.dispose();
    },
  );
}
