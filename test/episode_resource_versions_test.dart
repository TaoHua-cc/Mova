import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yingji/src/sources/emby_client.dart';
import 'package:yingji/src/sources/media_source.dart';
import 'package:yingji/src/metadata/metadata_detail_page.dart';

void main() {
  final source = MediaSource(
    id: 'server',
    name: 'Test',
    kind: SourceKind.emby,
    endpoint: Uri.parse('http://localhost/'),
    userId: 'user',
  );
  final session = EmbySession(source: source, token: 'test-token');
  Map<String, dynamic> item() => {
    'Id': 'episode',
    'Name': 'Episode 8',
    'Type': 'Episode',
    'ParentIndexNumber': 1,
    'IndexNumber': 8,
    'MediaSources': [
      for (final width in [1920, 3840])
        {
          'Id': 'version-$width',
          'RunTimeTicks': width * 10000000,
          'MediaStreams': [
            {'Type': 'Video', 'Width': width},
            {
              'Type': 'Audio',
              'Index': 1,
              'Codec': width == 1920 ? 'aac' : 'eac3',
            },
          ],
        },
    ],
  };
  for (final operation in ['episodes', 'search', 'tmdb']) {
    test('$operation preserves merged versions and server identity', () async {
      final client = EmbyClient(
        client: MockClient(
          (request) async => http.Response(
            jsonEncode({
              if (request.url.path.endsWith('/Items/episode')) ...item(),
              'Items': [item()],
              'TotalRecordCount': 1,
            }),
            200,
          ),
        ),
      );
      addTearDown(client.dispose);
      final rows = switch (operation) {
        'episodes' => await client.episodesForSeries(
          session,
          'series',
          seasonNumber: 1,
          episodeNumber: 8,
        ),
        'search' => await client.search(session, 'show'),
        _ => await client.findByTmdbId(session, 1),
      };
      expect(rows.length, 2);
      expect(rows.map((row) => row.id).toSet(), {'episode'});
      expect(rows.map((row) => row.resourceKey).toSet().length, 2);
      expect(rows.map((row) => row.width), [1920, 3840]);
      expect(rows.map((row) => row.audioTracks.single.codec), ['aac', 'eac3']);
      expect(
        rows.map((row) => row.playbackUrl!.queryParameters['MediaSourceId']),
        ['version-1920', 'version-3840'],
      );
    });
  }
  test(
    'pagination uses server item count rather than expanded versions',
    () async {
      final starts = <String>[];
      final client = EmbyClient(
        client: MockClient((request) async {
          starts.add(request.url.queryParameters['StartIndex']!);
          final row = item()..['Id'] = 'episode-${starts.length}';
          return http.Response(
            jsonEncode({
              'Items': [row],
              'TotalRecordCount': 2,
            }),
            200,
          );
        }),
      );
      addTearDown(client.dispose);
      expect((await client.episodesForSeries(session, 'series')).length, 4);
      expect(starts, ['0', '1']);
    },
  );
  test('detail deduplication and selections include media source identity', () {
    final page = File('lib/src/metadata/metadata_detail_page.dart')
        .readAsStringSync()
        .replaceAll(RegExp(r'\s+'), ' ');
    expect(page, contains('for (final row in results) row.resourceKey: row'));
    expect(
      page,
      contains('resource.resourceKey == _selectedResource?.resourceKey'),
    );
    expect(page, contains('version.resourceKey == current.resourceKey'));
  });

  test(
    'selected episode hydrates versions omitted from list response',
    () async {
      final paths = <String>[];
      final client = EmbyClient(
        client: MockClient((request) async {
          paths.add(request.url.path);
          final full = item();
          final limited = item()
            ..['MediaSources'] = [(item()['MediaSources'] as List).first];
          return http.Response(
            jsonEncode(
              request.url.path.endsWith('/Items/episode')
                  ? full
                  : {
                      'Items': [limited],
                      'TotalRecordCount': 1,
                    },
            ),
            200,
          );
        }),
      );
      addTearDown(client.dispose);
      final rows = await client.episodesForSeries(
        session,
        'series',
        seasonNumber: 1,
        episodeNumber: 8,
      );
      expect(rows.map((row) => row.width), [1920, 3840]);
      expect(paths, ['/Shows/series/Episodes', '/Users/user/Items/episode']);
    },
  );

  test(
    'merged version uses its actual server item and selected card',
    () async {
      final response = item();
      (response['MediaSources'] as List)[1]['ItemId'] = 'alternate-episode';
      final client = EmbyClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'Items': [response],
              'TotalRecordCount': 1,
            }),
            200,
          ),
        ),
      );
      addTearDown(client.dispose);
      final rows = await client.episodesForSeries(session, 'series');
      expect(rows[0].id, 'episode');
      expect(rows[1].id, 'alternate-episode');
      expect(rows[1].playbackUrl!.path, '/Videos/alternate-episode/stream');
      expect(
        rows[1].playbackUrl!.queryParameters['MediaSourceId'],
        'version-3840',
      );
      expect(
        serverResourceRepresentatives(rows, rows[1]).single,
        same(rows[1]),
      );
      expect(
        serverResourceRepresentatives(rows.reversed, rows[0]).single,
        same(rows[0]),
      );
      expect(serverResourceRepresentatives(rows, null).single, same(rows[0]));
    },
  );
}
