import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yingji/src/player/playback_segments.dart';
import 'package:yingji/src/sources/emby_client.dart';
import 'package:yingji/src/sources/media_source.dart';

void main() {
  test('manual segment marks replace automatic values for the same kind', () {
    final values = applyManualPlaybackSegments(
      const [
        PlaybackSegment(
          type: PlaybackSegmentType.intro,
          start: Duration(seconds: 10),
          end: Duration(seconds: 90),
          provider: 'IntroDB',
        ),
        PlaybackSegment(
          type: PlaybackSegmentType.recap,
          start: Duration.zero,
          end: Duration(seconds: 10),
          provider: 'server',
        ),
        PlaybackSegment(
          type: PlaybackSegmentType.credits,
          start: Duration(minutes: 42),
          provider: 'server',
        ),
      ],
      introEnd: const Duration(seconds: 73),
      outroStart: const Duration(minutes: 40),
    );

    expect(
      values.where((item) => item.type == PlaybackSegmentType.intro),
      hasLength(1),
    );
    expect(values.first.end, const Duration(seconds: 73));
    expect(values.first.provider, '手动设置');
    expect(
      values
          .singleWhere((item) => item.type == PlaybackSegmentType.credits)
          .start,
      const Duration(minutes: 40),
    );
    expect(
      values.any((item) => item.type == PlaybackSegmentType.recap),
      isTrue,
    );
  });

  test('manual segment preference key is stable per episode', () {
    const query = PlaybackSegmentQuery(
      tmdbId: 1396,
      seasonNumber: 2,
      episodeNumber: 3,
    );
    expect(
      playbackSegmentPreferencePrefix(query),
      'yingji.segment.manual.tmdb.1396.s2.e3',
    );
  });

  test('IntroDB parses the documented keyed segment response', () async {
    final client = SegmentClient(
      client: MockClient(
        (_) async => http.Response(
          '{"intro":{"start_sec":2,"end_sec":58},'
          '"recap":null,"outro":{"start_sec":3431,"end_sec":3500}}',
          200,
        ),
      ),
    );

    final values = await client.introDb(
      imdbId: 'tt0903747',
      season: 1,
      episode: 1,
    );

    expect(values, hasLength(2));
    expect(values.first.type, PlaybackSegmentType.intro);
    expect(values.first.end, const Duration(seconds: 58));
    expect(values.last.type, PlaybackSegmentType.credits);
    client.dispose();
  });

  test('AniSkip requests all supported types and parses seconds', () async {
    late Uri requested;
    final client = SegmentClient(
      client: MockClient((request) async {
        requested = request.url;
        return http.Response(
          '{"found":true,"results":[{"skipType":"op",'
          '"interval":{"startTime":12.5,"endTime":102.5}}]}',
          200,
        );
      }),
    );

    final values = await client.aniSkip(
      malId: 9253,
      episode: 1,
      duration: const Duration(minutes: 24),
    );

    expect(
      requested.queryParametersAll['types'],
      containsAll(['op', 'ed', 'recap']),
    );
    expect(requested.queryParameters['episodeLength'], '1440');
    expect(values.single.start, const Duration(milliseconds: 12500));
    client.dispose();
  });

  test('ChaptersDB chooses the highest-rated chapter set', () async {
    final client = SegmentClient(
      client: MockClient(
        (_) async => http.Response(
          '{"chapters":['
          '{"upvotes":2,"downvotes":1,"entries":[{"time":"00:00:00","name":"Intro"}]},'
          '{"upvotes":20,"downvotes":1,"entries":['
          '{"time":"00:00:03.500","name":"Intro"},'
          '{"time":"00:01:33.500","name":"Opening Scene"},'
          '{"time":"00:42:00","name":"Credits"}]}'
          ']}',
          200,
        ),
      ),
    );

    final values = await client.chaptersDb(tvdbEpisodeId: 349232);

    expect(values, hasLength(2));
    expect(values.first.start, const Duration(milliseconds: 3500));
    expect(values.first.end, const Duration(milliseconds: 93500));
    expect(values.last.type, PlaybackSegmentType.credits);
    client.dispose();
  });

  test('Jellyfin native media segments retain exact end timestamps', () async {
    late Uri requested;
    final client = EmbyClient(
      client: MockClient((request) async {
        requested = request.url;
        return http.Response(
          '[{"Type":"Intro","StartTicks":20000000,'
          '"EndTicks":580000000}]',
          200,
        );
      }),
    );
    final source = MediaSource(
      id: 'jellyfin',
      name: 'Jellyfin',
      kind: SourceKind.jellyfin,
      endpoint: Uri.parse('https://media.example/'),
    );

    final values = await client.mediaSegments(
      EmbySession(source: source, token: 'token'),
      'episode-id',
    );

    expect(requested.path, '/MediaSegments/episode-id');
    expect(values.single.start, const Duration(seconds: 2));
    expect(values.single.end, const Duration(seconds: 58));
    client.dispose();
  });
}
