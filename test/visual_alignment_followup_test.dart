import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/metadata/tmdb_client.dart';
import 'package:yingji/src/playlists/playlist_store.dart';
import 'package:yingji/src/playlists/playlist_detail_page.dart';

void main() {
  test('track and proxy selection borders are overlays', () {
    final detail = File('lib/src/metadata/metadata_detail_page.dart')
        .readAsStringSync();
    final main = File('lib/src/media_center.dart').readAsStringSync();
    for (final body in [
      detail.split('class _TrackPickerOption ').last.split('\nclass ').first,
      main.split('class _ProxyServerCardState ').last.split('\nclass ').first,
    ]) {
      expect(
        body.indexOf('Border.all'),
        greaterThan(body.indexOf('foregroundDecoration:')),
      );
    }
  });
  testWidgets('changing overlay stroke preserves content position and size', (
    tester,
  ) async {
    Rect? initial;
    for (final width in [1.0, 2.0, 1.4]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: Container(
              padding: const EdgeInsets.all(14),
              foregroundDecoration: BoxDecoration(
                border: Border.all(width: width),
              ),
              child: const SizedBox(
                key: Key('content'),
                width: 100,
                height: 40,
              ),
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byKey(const Key('content')));
      initial ??= rect;
      expect(rect, initial);
    }
  });
  test('season centering and resource inset follow actual geometry', () {
    final source = File('lib/src/metadata/metadata_detail_page.dart')
        .readAsStringSync();
    final season = source
        .split('class _SeasonRailState ')
        .last
        .split('\nclass ')
        .first;
    expect(season, contains('index * (_cardWidth + _cardGap)'));
    expect(season, contains('(viewport - _cardWidth) / 2'));
    expect(season, contains('width: _cardWidth'));
    expect(season, contains('horizontal: _railInset'));
    final resources = source
        .split('class _ResourceSectionState ')
        .last
        .split('\nclass ')
        .first;
    expect(resources, contains('height: 164'));
    expect(resources, contains('vertical: 10'));
    final picker = source
        .split('class _ResourcePickerCard ')
        .last
        .split('\nclass ')
        .first;
    expect(
      picker.indexOf('Border.all'),
      greaterThan(picker.indexOf('foregroundDecoration:')),
    );
  });
  for (final width in [320.0, 390.0, 1280.0]) {
    testWidgets('playlist content fits width $width', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = await PlaylistStore.create();
      await store.save(
        YingjiPlaylist(
          id: 'one',
          name: '片单',
          createdAt: DateTime(2026),
          items: const [
            TmdbItem(
              id: 1,
              title: '很长的影片名称用于检查窄屏布局不会溢出',
              kind: '电影',
              year: 2026,
              ratings: {'imdb': 8.1, 'tmdb': 80},
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        const MaterialApp(home: PlaylistDetailPage(playlistId: 'one')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('从「片单」移除'), findsOneWidget);
    });
  }
}
