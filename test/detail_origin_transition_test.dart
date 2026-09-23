import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/metadata/metadata_detail_page.dart';
import 'package:yingji/src/metadata/tmdb_client.dart';

void main() {
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
