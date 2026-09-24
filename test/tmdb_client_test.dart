import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/metadata/tmdb_client.dart';

void main() {
  test(
    'ranking lists do not refresh a cache younger than eight hours',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final uri = Uri.parse('${TmdbClient.managedEndpoint}/tmdb/movie/popular')
          .replace(
            queryParameters: {
              'language': 'zh-CN',
              'region': 'CN',
              'client': 'yingji-flutter',
            },
          );
      final stableKey = base64UrlEncode(utf8.encode(uri.toString()))
          .replaceAll('=', '');
      final cacheKey = 'yingji.tmdb.cache.$stableKey';
      SharedPreferences.setMockInitialValues({
        cacheKey: jsonEncode({
          'results': [
            {'id': 1, 'title': '缓存榜单'},
          ],
        }),
        '$cacheKey.savedAt': DateTime.now()
            .subtract(const Duration(hours: 7))
            .toIso8601String(),
      });
      var requests = 0;
      final client = TmdbClient(
        client: MockClient((_) async {
          requests++;
          return http.Response(jsonEncode({'results': <Object>[]}), 200);
        }),
      );

      final items = await client.popularMovies();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(items.single.title, '缓存榜单');
      expect(requests, 0);
      client.dispose();
    },
  );

  test('Windows deduplicates and bounds stale background refreshes', () async {
    if (!Platform.isWindows) return;
    TestWidgetsFlutterBinding.ensureInitialized();
    // 只用不会碰到用户真实磁盘缓存的页号，避免测试读到本机的新鲜榜单。
    final pages = List.generate(4, (index) => 900000000 + index);
    final stale = <String, Object>{};
    for (final page in pages) {
      final uri =
          Uri.parse('${TmdbClient.managedEndpoint}/tmdb/trending/tv/day')
              .replace(
                queryParameters: {
                  'language': 'zh-CN',
                  'page': '$page',
                  'client': 'yingji-flutter',
                },
              );
      final key =
          'yingji.tmdb.cache.${base64UrlEncode(utf8.encode(uri.toString())).replaceAll('=', '')}';
      stale[key] = jsonEncode({'results': <Object>[]});
      stale['$key.savedAt'] = DateTime.now()
          .subtract(const Duration(hours: 9))
          .toIso8601String();
    }
    SharedPreferences.setMockInitialValues(stale);
    final releaseRequests = Completer<void>();
    var active = 0;
    var peak = 0;
    var requests = 0;
    final client = TmdbClient(
      client: MockClient((_) async {
        requests++;
        active++;
        if (active > peak) peak = active;
        await releaseRequests.future;
        active--;
        return http.Response('unavailable', 503);
      }),
    );

    await Future.wait(
      pages.map((page) => client.trendingToday('tv', page: page)),
    );
    await client.trendingToday('tv', page: pages.first);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(requests, 3);
    expect(peak, 3);
    releaseRequests.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(requests, 4);
    expect(peak, 3);
    client.dispose();
  });

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
      withoutGenres: '16,10764,10767',
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
    expect(requested?.queryParameters['without_genres'], '16,10764,10767');
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
