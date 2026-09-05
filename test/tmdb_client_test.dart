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

    await client.discover('tv', genre: 16, sortBy: 'vote_average.desc');

    expect(requested?.path, endsWith('/discover/tv'));
    expect(requested?.queryParameters['with_genres'], '16');
    expect(requested?.queryParameters['sort_by'], 'vote_average.desc');
    client.dispose();
  });
}
