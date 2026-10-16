import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/metadata/tmdb_client.dart';
import 'package:yingji/src/playlists/playlist_detail_page.dart';
import 'package:yingji/src/playlists/playlist_store.dart';

void main() {
  testWidgets('detail menu persists removal only in the current playlist', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = await PlaylistStore.create();
    const item = TmdbItem(id: 1, title: '目标影片', kind: '电影');
    const keep = TmdbItem(id: 2, title: '保留影片', kind: '电影');
    await store.save(
      YingjiPlaylist(
        id: 'one',
        name: '片单一',
        createdAt: DateTime(2026),
        items: [item, keep],
      ),
    );
    await store.save(
      YingjiPlaylist(
        id: 'two',
        name: '片单二',
        createdAt: DateTime(2026),
        items: [item],
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(home: PlaylistDetailPage(playlistId: 'one')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('目标影片'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('从「片单一」移除'));
    await tester.pumpAndSettle();
    expect(find.text('目标影片'), findsNothing);
    expect(find.text('保留影片'), findsOneWidget);
    final persisted = (await PlaylistStore.create()).load();
    expect(persisted.firstWhere((p) => p.id == 'one').items.map((i) => i.id), [
      2,
    ]);
    expect(persisted.firstWhere((p) => p.id == 'two').items.map((i) => i.id), [
      1,
    ]);
  });
  for (final longPress in [false, true]) {
    testWidgets('playlist removal requires menu confirmation ($longPress)', (
      tester,
    ) async {
      var removed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaylistItemMenu(
              onRemove: () async {
                removed++;
              },
              child: const SizedBox(
                width: 200,
                height: 100,
                child: Text('测试影片'),
              ),
            ),
          ),
        ),
      );
      if (longPress) {
        await tester.longPress(find.text('测试影片'));
      } else {
        await tester.tap(find.text('测试影片'), buttons: kSecondaryMouseButton);
      }
      await tester.pumpAndSettle();
      expect(removed, 0);
      expect(find.text('从片单移除'), findsOneWidget);
      await tester.tap(find.text('从片单移除'));
      await tester.pumpAndSettle();
      expect(removed, 1);
    });
  }
  testWidgets('dismiss leaves membership unchanged', (tester) async {
    var removed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaylistItemMenu(
            label: '从待看移除',
            onRemove: () async {
              removed = true;
            },
            child: const SizedBox(width: 200, height: 100, child: Text('测试影片')),
          ),
        ),
      ),
    );
    await tester.tap(find.text('测试影片'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('从待看移除'), findsOneWidget);
    await tester.tapAt(const Offset(700, 500));
    await tester.pumpAndSettle();
    expect(removed, isFalse);
  });
}
