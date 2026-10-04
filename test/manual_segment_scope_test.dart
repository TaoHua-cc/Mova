import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/player/playback_segments.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('both menus remove scope switch and use default season save', () {
    final android = File('lib/src/player/player_page.dart').readAsStringSync();
    final windows = File('windows/native_player/main.cpp').readAsStringSync();
    final bridge = File('lib/src/player/windows_native_player.dart')
        .readAsStringSync();
    expect(android, isNot(contains('_segmentSeasonScope')));
    expect(android, isNot(contains('seasonScope:')));
    expect(windows, isNot(contains('mova-segment-scope')));
    expect(windows, isNot(contains('g_segment_season_scope')));
    expect(bridge, isNot(contains('seasonScope:')));
    expect(android, contains('手动设置应用于当前季全部剧集'));
    expect(windows, contains('手动设置应用于当前季全部剧集'));
  });
  PlaybackSegmentQuery query(int episode, {int season = 1, int id = 10}) =>
      PlaybackSegmentQuery(
        tmdbId: id,
        title: 'Show',
        seasonNumber: season,
        episodeNumber: episode,
      );

  test('season default, independent overrides, clear and isolation', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await saveManualPlaybackSegment(prefs, query(1), 'intro', 90000);
    await saveManualPlaybackSegment(prefs, query(1), 'outro', 2400000);
    expect(readManualPlaybackSegment(prefs, query(2), 'intro'), 90000);
    expect(readManualPlaybackSegment(prefs, query(2), 'outro'), 2400000);
    expect(
      readManualPlaybackSegment(prefs, query(2, season: 2), 'intro'),
      null,
    );
    expect(readManualPlaybackSegment(prefs, query(2, id: 11), 'intro'), null);
    await saveManualPlaybackSegment(
      prefs,
      query(2),
      'intro',
      60000,
      seasonScope: false,
    );
    expect(readManualPlaybackSegment(prefs, query(2), 'intro'), 60000);
    expect(readManualPlaybackSegment(prefs, query(2), 'outro'), 2400000);
    await saveManualPlaybackSegment(prefs, query(1), 'intro', 80000);
    expect(readManualPlaybackSegment(prefs, query(2), 'intro'), 60000);
    await saveManualPlaybackSegment(
      prefs,
      query(2),
      'intro',
      null,
      seasonScope: false,
    );
    expect(readManualPlaybackSegment(prefs, query(2), 'intro'), 80000);
    await saveManualPlaybackSegment(
      prefs,
      query(2),
      'intro',
      70000,
      seasonScope: false,
    );
    await saveManualPlaybackSegment(prefs, query(2), 'intro', 75000);
    expect(readManualPlaybackSegment(prefs, query(2), 'intro'), 75000);
    await prefs.reload();
    expect(readManualPlaybackSegment(prefs, query(3), 'intro'), 75000);
  });

  test('legacy marks retained and clear cannot resurrect them', () async {
    SharedPreferences.setMockInitialValues({
      'yingji.segment.Show.1.intro': 1000,
      'yingji.segment.manual.tmdb.10.s1.e2.outro': 2000,
    });
    final prefs = await SharedPreferences.getInstance();
    expect(readManualPlaybackSegment(prefs, query(1), 'intro'), 1000);
    expect(readManualPlaybackSegment(prefs, query(2), 'outro'), 2000);
    await saveManualPlaybackSegment(prefs, query(1), 'intro', null);
    expect(readManualPlaybackSegment(prefs, query(1), 'intro'), null);
    expect(readManualPlaybackSegment(prefs, query(2), 'outro'), 2000);
  });

  test(
    'source fallback isolates servers and unknown season stays single',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      const a = PlaybackSegmentQuery(
        title: 'Show',
        sourceId: 'a',
        serverItemId: 'one',
        seasonNumber: 1,
        episodeNumber: 1,
      );
      const b = PlaybackSegmentQuery(
        title: 'Show',
        sourceId: 'a',
        serverItemId: 'two',
        seasonNumber: 1,
        episodeNumber: 2,
      );
      const c = PlaybackSegmentQuery(
        title: 'Show',
        sourceId: 'b',
        serverItemId: 'two',
        seasonNumber: 1,
        episodeNumber: 2,
      );
      await saveManualPlaybackSegment(prefs, a, 'intro', 1000);
      expect(readManualPlaybackSegment(prefs, b, 'intro'), 1000);
      expect(readManualPlaybackSegment(prefs, c, 'intro'), null);
      const movie = PlaybackSegmentQuery(sourceId: 'a', serverItemId: 'movie');
      expect(playbackSeasonSegmentPreferencePrefix(movie), null);
      await saveManualPlaybackSegment(prefs, movie, 'outro', 5000);
      expect(readManualPlaybackSegment(prefs, movie, 'outro'), 5000);
    },
  );
}
