import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('both detail episode rails declare exact lazy-list extents', () {
    final source = File('lib/src/metadata/metadata_detail_page.dart')
        .readAsStringSync();
    for (final name in [
      '_CatalogEpisodeRailState',
      '_EpisodePreviewRailState',
    ]) {
      final rail = source.split('class $name ').last.split('\nclass ').first;
      expect(rail, contains('child: ListView.builder('));
      expect(rail, contains('itemExtent:'));
    }
  });

  for (final count in [8, 47]) {
    for (final width in [360.0, 1100.0]) {
      testWidgets('last of $count episodes is fully visible at width $width', (
        tester,
      ) async {
        final controller = ScrollController();
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                height: 236,
                child: ListView.builder(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 10,
                  ),
                  itemExtent: 256,
                  itemCount: count,
                  itemBuilder: (_, index) => Padding(
                    padding: const EdgeInsets.only(right: 18),
                    child: SizedBox(key: ValueKey(index), width: 238),
                  ),
                ),
              ),
            ),
          ),
        );
        final viewport = controller.position.viewportDimension;
        final target = (6 + (count - 1) * 256 + 119 - viewport / 2).clamp(
          0.0,
          controller.position.maxScrollExtent,
        );
        controller.animateTo(
          target,
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeOutCubic,
        );
        await tester.pumpAndSettle();
        final rect = tester.getRect(find.byKey(ValueKey(count - 1)));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(viewport));
      });
    }
  }
}
