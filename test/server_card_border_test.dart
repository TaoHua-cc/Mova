import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

void main() {
  test('server cards disable nested outlines and hover displacement', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    final card = source
        .split('class _SourceCardState ')
        .last
        .split('class _IconPackEntry ')
        .first;
    expect(card, contains('decorateChild: false'));
    expect(card, contains('liftOnHover: false'));
  });

  testWidgets(
    'self-decorated menu keeps one surface on hover and right click',
    (tester) async {
      var opened = false;
      var activated = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: YingjiGlassMenu(
              secondaryOnly: true,
              decorateChild: false,
              onOpen: () => opened = true,
              entries: [
                MenuItemButton(onPressed: () {}, child: const Text('线路')),
              ],
              child: YingjiGlassSurface(
                child: InkWell(
                  onTap: () => activated = true,
                  child: const SizedBox(width: 340, height: 144),
                ),
              ),
            ),
          ),
        ),
      );
      final card = find.byType(YingjiGlassSurface);
      final original = tester.getRect(card);
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await mouse.addPointer(location: const Offset(700, 500));
      await mouse.moveTo(original.center);
      await tester.pumpAndSettle();
      expect(find.byType(YingjiMotionSurface), findsNothing);
      expect(tester.getRect(card), original);
      await tester.tapAt(original.center);
      expect(activated, isTrue);
      await mouse.down(original.center);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(opened, isTrue);
      expect(find.text('线路'), findsOneWidget);
      expect(find.byType(YingjiMotionSurface), findsNothing);
      await mouse.removePointer();
    },
  );
}
