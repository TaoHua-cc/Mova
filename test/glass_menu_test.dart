import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

void main() {
  testWidgets('motion surface responds to hover and press without relayout', (
    tester,
  ) async {
    const target = Key('motion-target');
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: YingjiMotionSurface(
            child: SizedBox(key: target, width: 80, height: 40),
          ),
        ),
      ),
    );
    final originalSize = tester.getSize(find.byKey(target));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byKey(target)));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
      1.012,
    );

    final press = await tester.startGesture(
      tester.getCenter(find.byKey(target)),
    );
    await tester.pump();
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
      .975,
    );
    expect(tester.getSize(find.byKey(target)), originalSize);
    await press.up();
    await mouse.removePointer();
  });

  testWidgets('choice menu has shared blur, selects and closes', (
    tester,
  ) async {
    var selection = 'one';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: YingjiGlassChoiceButton<String>(
            value: selection,
            items: const ['one', 'two'],
            labelBuilder: (v) => v,
            onChanged: (v) => selection = v,
          ),
        ),
      ),
    );
    await tester.tap(find.text('one'));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);
    yingjiAppearance.apply(glassBlur: 0, glassOpacity: 0);
    await tester.pump();
    final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
    expect(filter.filter, ImageFilter.blur(sigmaX: 0, sigmaY: 0));
    await tester.tap(find.text('two'));
    await tester.pumpAndSettle();
    expect(selection, 'two');
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
    yingjiAppearance.apply(glassBlur: 24, glassOpacity: .58);
  });
}
