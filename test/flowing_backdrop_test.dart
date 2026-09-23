import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

void main() {
  testWidgets('shared backdrop colors drift without rebuilding the page', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(width: 800, height: 600, child: YingjiBackdrop()),
      ),
    );

    final layers = find.byType(SlideTransition);
    expect(layers, findsNWidgets(2));
    final before = tester.widget<SlideTransition>(layers.first).position.value;
    await tester.pump(const Duration(seconds: 7));
    final after = tester.widget<SlideTransition>(layers.first).position.value;
    expect(after, isNot(before));
    final source = File('lib/src/brand.dart').readAsStringSync();
    final backdrop = source.substring(
      source.indexOf('class YingjiBackdrop'),
      source.indexOf('abstract final class YingjiColors'),
    );
    expect(backdrop, isNot(contains('RadialGradient')));
    expect(backdrop, contains('width: size.maxWidth * 1.8'));
  });
}
