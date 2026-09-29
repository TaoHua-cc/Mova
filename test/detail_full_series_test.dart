import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/cache/media_cache.dart';
import 'package:yingji/src/history/watch_state_store.dart';
import 'package:yingji/src/metadata/metadata_detail_page.dart';
import 'package:yingji/src/metadata/tmdb_client.dart';
import 'package:yingji/src/sources/emby_client.dart';
import 'package:yingji/src/sources/media_source.dart';

void main() {
  final source = MediaSource(
    id: 'full-series-test',
    name: 'Test',
    kind: SourceKind.jellyfin,
    endpoint: Uri.parse('http://localhost:8096/'),
    userId: 'user',
  );
  final session = EmbySession(source: source, token: 'test-token');

  test(
    'WebDAV filenames match only the requested show, season, and episode',
    () {
      expect(
        webDavFilenameMatchesEpisode(
          'The.Simpsons.S25E02.mkv',
          ['辛普森一家', 'The Simpsons'],
          25,
          2,
        ),
        isTrue,
      );
      expect(
        webDavFilenameMatchesEpisode('辛普森一家 第25季 第2集.mp4', ['辛普森一家'], 25, 2),
        isTrue,
      );
      expect(
        webDavFilenameMatchesEpisode(
          'The.Simpsons.S25E020.mkv',
          ['The Simpsons'],
          25,
          2,
        ),
        isFalse,
      );
      expect(
        webDavFilenameMatchesEpisode(
          'Other.Show.S25E02.mkv',
          ['The Simpsons'],
          25,
          2,
        ),
        isFalse,
      );
    },
  );

  test('catalog picks earliest season without history and latest played episode with history', () {
    final seasons = [
      const TmdbSeason(number: 25, name: 'Season 25'),
      const TmdbSeason(number: 1, name: 'Season 1'),
    ];
    expect(detailInitialEpisode(55, [], seasons), (season: 1, episode: null));
    expect(
      detailInitialEpisode(
        55,
        [],
        seasons,
        media: MediaItem(
          id: 'later',
          title: 'Episode',
          type: 'Episode',
          source: source,
          seasonNumber: 25,
          episodeNumber: 8,
        ),
      ),
      (season: 1, episode: null),
    );
    final history = [
      const WatchState(
        mediaId: 'new',
        title: 'Show',
        position: Duration(minutes: 10),
        duration: Duration(minutes: 20),
        tmdbId: 55,
        seasonNumber: 25,
        episodeNumber: 8,
      ),
      const WatchState(
        mediaId: 'old',
        title: 'Show',
        position: Duration(minutes: 10),
        duration: Duration(minutes: 20),
        tmdbId: 55,
        seasonNumber: 1,
        episodeNumber: 2,
      ),
    ];
    expect(detailInitialEpisode(55, history, seasons), (
      season: 25,
      episode: 8,
    ));
  });

  test(
    'selected episode requests only its season and filters other episodes',
    () async {
      final requestedSeasons = <String?>[];
      final client = EmbyClient(
        client: MockClient((request) async {
          requestedSeasons.add(request.url.queryParameters['Season']);
          return http.Response(
            jsonEncode({
              'TotalRecordCount': 3,
              'Items': [1, 2, 3]
                  .map(
                    (number) => {
                      'Id': '$number',
                      'Name': 'Episode $number',
                      'Type': 'Episode',
                      'SeriesId': 'show',
                      'ParentIndexNumber': 25,
                      'IndexNumber': number,
                    },
                  )
                  .toList(),
            }),
            200,
          );
        }),
      );
      addTearDown(client.dispose);
      final versions = await client.episodesForSeries(
        session,
        'show',
        seasonNumber: 25,
        episodeNumber: 2,
      );
      expect(requestedSeasons, ['25']);
      expect(versions.map((item) => item.episodeNumber), [2]);
    },
  );

  test(
    'series matching requests parent series instead of first 50 episodes',
    () async {
      final types = <String?>[];
      final client = EmbyClient(
        client: MockClient((request) async {
          types.add(request.url.queryParameters['IncludeItemTypes']);
          return http.Response('{"Items":[]}', 200);
        }),
      );
      addTearDown(client.dispose);

      await client.findByTmdbId(session, 123, includeItemTypes: 'Series');
      await client.search(session, 'The Simpsons', includeItemTypes: 'Series');
      expect(types, ['Series', 'Series']);
    },
  );

  test(
    'series episodes fetch all pages, including the final short page',
    () async {
      final offsets = <int>[];
      final client = EmbyClient(
        client: MockClient((request) async {
          final offset = int.parse(request.url.queryParameters['StartIndex']!);
          offsets.add(offset);
          final count = (451 - offset).clamp(0, 200);
          return http.Response(
            jsonEncode({
              'TotalRecordCount': 451,
              'Items': List.generate(
                count,
                (index) => {
                  'Id': '${offset + index}',
                  'Name': 'Episode ${offset + index}',
                  'Type': 'Episode',
                  'SeriesId': 'series',
                  'ParentIndexNumber': (offset + index) ~/ 25 + 1,
                  'IndexNumber': (offset + index) % 25 + 1,
                },
              ),
            }),
            200,
          );
        }),
      );
      addTearDown(client.dispose);

      final episodes = await client.episodesForSeries(session, 'series');
      expect(offsets, [0, 200, 400]);
      expect(episodes.length, 451);
      expect(episodes.last.seasonNumber, 19);
    },
  );

  test('series episodes stop if a server ignores StartIndex', () async {
    var requests = 0;
    final client = EmbyClient(
      client: MockClient((request) async {
        requests++;
        return http.Response(
          jsonEncode({
            'TotalRecordCount': 1000,
            'Items': List.generate(
              200,
              (index) => {
                'Id': '$index',
                'Name': 'Episode $index',
                'Type': 'Episode',
              },
            ),
          }),
          200,
        );
      }),
    );
    addTearDown(client.dispose);

    final episodes = await client.episodesForSeries(session, 'series');
    expect(requests, 2);
    expect(episodes.length, 200);
  });

  test('detail snapshot restores more than 800 episodes', () async {
    SharedPreferences.setMockInitialValues({});
    const item = TmdbItem(id: 987654, title: 'Long Show', kind: '剧集');
    final episodes = List.generate(
      825,
      (index) => MediaItem(
        id: '$index',
        title: 'Episode $index',
        type: 'Episode',
        source: source,
        seasonNumber: index ~/ 25 + 1,
        episodeNumber: index % 25 + 1,
      ),
    );
    await MediaDetailCache.save(item, rows: episodes, seasonPosters: {});
    final restored = await MediaDetailCache.load(item);
    expect(restored?.rows.length, 825);
    expect(restored?.rows.last.seasonNumber, 33);
  });
}
