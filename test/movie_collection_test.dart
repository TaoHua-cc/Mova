import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/metadata/tmdb_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'movie extras expose collection identity without loading its movies',
    () async {
      final requests = <String>[];
      final client = TmdbClient(
        client: MockClient((request) async {
          requests.add(request.url.path);
          return http.Response(
            jsonEncode({
              'belongs_to_collection': {'id': 900001234, 'name': '真实系列'},
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(client.dispose);
      final extras = await client.extras(900001235, kind: '电影');
      expect(extras.collectionId, 900001234);
      expect(extras.collectionName, '真实系列');
      expect(requests, isNotEmpty);
      expect(
        requests.every((path) => path.endsWith('/movie/900001235')),
        isTrue,
      );
    },
  );

  test(
    'non collection movies and television do not gain a collection',
    () async {
      final client = TmdbClient(
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      addTearDown(client.dispose);
      expect((await client.extras(900001236, kind: '电影')).collectionId, isNull);
      expect((await client.extras(900001237, kind: '剧集')).collectionId, isNull);
    },
  );

  test('collection sorts by full release date, removes duplicate IDs and retains undated movies', () async {
    final client = TmdbClient(
      client: MockClient((request) async {
        expect(request.url.path, endsWith('/collection/900001238'));
        return http.Response(
          jsonEncode({
            'parts': [
              {'id': 3, 'title': 'later', 'release_date': '2001-10-01'},
              {'id': 2, 'title': 'earlier', 'release_date': '2001-01-01'},
              {'id': 2, 'title': 'duplicate', 'release_date': '2001-01-01'},
              {'id': 4, 'title': 'unknown'},
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(client.dispose);
    final movies = await client.collectionMovies(900001238);
    expect(movies.map((movie) => movie.id), [2, 3, 4]);
    expect(movies.every((movie) => movie.kind == '电影'), isTrue);
    expect(movies.last.year, isNull);
  });

  test('empty collections and invalid IDs remain empty', () async {
    final client = TmdbClient(
      client: MockClient((_) async => http.Response('{"parts":[]}', 200)),
    );
    addTearDown(client.dispose);
    expect(await client.collectionMovies(0), isEmpty);
    expect(await client.collectionMovies(900001239), isEmpty);
  });

  test('collection failure is surfaced for the independent retry UI', () async {
    final client = TmdbClient(
      client: MockClient((_) async => http.Response('unavailable', 503)),
    );
    addTearDown(client.dispose);
    await expectLater(client.collectionMovies(900001240), throwsException);
  });
}
