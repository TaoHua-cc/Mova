import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/metadata/metadata_detail_page.dart';
import 'package:yingji/src/metadata/tmdb_client.dart';
import 'package:yingji/src/sources/emby_client.dart';
import 'package:yingji/src/sources/media_source.dart';

void main() {
  test(
    'resume detail selection matches season and episode across versions',
    () {
      final source = MediaSource(
        id: 'server-a',
        name: '媒体库 A',
        kind: SourceKind.emby,
        endpoint: Uri.parse('http://localhost:8096'),
      );
      MediaItem episode(String id, int season, int number) => MediaItem(
        id: id,
        title: '第 $number 集',
        type: 'Episode',
        source: source,
        seasonNumber: season,
        episodeNumber: number,
      );

      final resources = [
        episode('s1e2', 1, 2),
        episode('s2e1', 2, 1),
        episode('s2e2-a', 2, 2),
        episode('s2e2-b', 2, 2),
      ];
      final selected = episodeResourcesForResume(
        resources,
        seasonNumber: 2,
        episodeNumber: 2,
      );

      expect(selected.map((item) => item.id), ['s2e2-a', 's2e2-b']);
      expect(
        episodeResourcesForResume(
          resources,
          seasonNumber: null,
          episodeNumber: 2,
        ),
        isEmpty,
      );
    },
  );

  test(
    'continue watching forwards its saved episode coordinates to detail',
    () {
      final mediaCenter = File('lib/src/media_center.dart').readAsStringSync();
      final resumeOpen = mediaCenter.substring(
        mediaCenter.indexOf('Future<void> _openWatchDetail('),
        mediaCenter.indexOf('Future<void> _resumePlayback('),
      );
      final detail = File('lib/src/metadata/metadata_detail_page.dart')
          .readAsStringSync();
      final initialSelection = detail.substring(
        detail.indexOf('Future<MediaItem?> _initialResource('),
        detail.indexOf('Future<void> _selectSeason('),
      );

      expect(resumeOpen, contains('initialSeasonNumber: state.seasonNumber'));
      expect(resumeOpen, contains('initialEpisodeNumber: state.episodeNumber'));
      expect(
        initialSelection,
        contains('final resumedEpisode = episodeResourcesForResume('),
      );
      expect(initialSelection, contains('return _preferredResource('));
      expect(
        initialSelection,
        contains('resumedEpisode.isEmpty ? resources : resumedEpisode'),
      );
    },
  );

  test('detail route snapshots a lightweight anchored transition', () {
    final source = File('lib/src/metadata/metadata_detail_page.dart')
        .readAsStringSync();
    final route = source.substring(
      source.indexOf('PageRouteBuilder<void>('),
      source.indexOf('State<MetadataDetailPage> createState()'),
    );

    expect(route, contains('allowSnapshotting: true'));
    expect(route, contains('ScaleTransition('));
    expect(route, contains('RepaintBoundary(child: child)'));
    expect(route, isNot(contains('Rect.lerp(')));
    expect(route, isNot(contains('FittedBox(')));
  });

  testWidgets(
    'detail opens from a tapped card and keeps a visible back action',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const item = TmdbItem(id: 0, title: '测试作品', kind: '电影');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomLeft,
              child: SizedBox(
                width: 120,
                height: 180,
                child: Builder(
                  builder: (cardContext) => TextButton(
                    onPressed: () =>
                        MetadataDetailPage.open(cardContext, item: item),
                    child: const Text('打开作品'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开作品'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(MetadataDetailPage), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(find.byTooltip('返回'), findsOneWidget);
      expect(find.byTooltip('首页'), findsNothing);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.byType(MetadataDetailPage), findsNothing);
    },
  );
}
