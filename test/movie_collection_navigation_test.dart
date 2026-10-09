import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/metadata/metadata_detail_page.dart';
import 'package:yingji/src/metadata/tmdb_client.dart';

class _RouteCounter extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
  }
}

void main() {
  testWidgets(
    'collection changes content without pushing a route; one back returns to origin',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final observer = _RouteCounter();
      const first = TmdbItem(id: 0, title: 'First', kind: '电影');
      const second = TmdbItem(id: -1, title: 'Second', kind: '电影');
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => MetadataDetailPage.open(context, item: first),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final before = observer.pushes;
      final bodyFinder = find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_MetadataDetailBody',
      );
      final dynamic originalBody = tester.widget(bodyFinder);
      final originalState = tester.state(bodyFinder);
      expect(originalBody.item.id, first.id);
      (originalBody.onCollectionMovieSelected as ValueChanged<TmdbItem>)(
        second,
      );
      await tester.pumpAndSettle();
      final dynamic changedBody = tester.widget(bodyFinder);
      expect(identical(tester.state(bodyFinder), originalState), isTrue);
      expect(changedBody.item.id, second.id);
      expect(changedBody.media, isNull);
      expect(observer.pushes, before);
      (changedBody.onCollectionMovieSelected as ValueChanged<TmdbItem>)(first);
      await tester.pumpAndSettle();
      expect(observer.pushes, before);
      Navigator.of(tester.element(bodyFinder)).pop();
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
      expect(find.byType(MetadataDetailPage), findsNothing);
    },
  );

  test('collection cards use the in-page selection callback', () {
    final source = File('lib/src/metadata/metadata_detail_page.dart')
        .readAsStringSync();
    final section = source
        .split('class _MovieCollectionSectionState ')
        .last
        .split('class _DetailExtrasSection ')
        .first;
    expect(section, contains('widget.onSelect(movie)'));
    expect(section, isNot(contains('MetadataDetailPage.open')));
  });
}
