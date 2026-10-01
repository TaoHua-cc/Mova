import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/motion.dart';

void main() {
  testWidgets('mouse drag scrolls without opening cards; taps still open', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 160,
              child: MovaHorizontalDrag(
                child: ListView.builder(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  itemCount: 12,
                  itemExtent: 120,
                  itemBuilder: (_, i) => InkWell(
                    onTap: () => taps++,
                    child: Center(child: Text('card $i')),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      const Offset(520, 300),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(-140, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
    expect(taps, 0);
    await tester.tapAt(const Offset(350, 300));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  test(
    'scoped pages keep all-list entries but remove directional controls',
    () {
      final main = File('lib/src/media_center.dart').readAsStringSync();
      expect(
        main.substring(0, main.indexOf('class _CalendarPage')),
        isNot(contains('YingjiDirectionalArrow(')),
      );
      final detail = File('lib/src/metadata/metadata_detail_page.dart')
          .readAsStringSync();
      expect(detail, isNot(contains('YingjiDirectionalArrow(')));
      expect(detail, contains("tooltip: '全部剧集'"));
      expect(main, contains('notification.metrics.extentAfter < 240'));
    },
  );
}
