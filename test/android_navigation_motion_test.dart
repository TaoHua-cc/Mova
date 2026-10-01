import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/motion.dart';

void main() {
  testWidgets('glass dialogs retain platform entry animations', (tester) async {
    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      AnimationStyle? style;
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(platform),
          theme: ThemeData(platform: platform),
          home: Builder(
            builder: (context) {
              style = MovaMotion.dialogAnimationStyle(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(style, isNull);
    }
  });

  test('Android startup and video avoid duplicate animated layers', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('startup: WindowHost.isAndroid ? null : startup'));
    expect(main, contains('await startup.catchError'));
    final detail = File('lib/src/metadata/metadata_detail_page.dart')
        .readAsStringSync();
    expect(
      detail,
      contains('transitionDuration: const Duration(milliseconds: 280)'),
    );
    expect(
      detail,
      contains('animationStyle: MovaMotion.dialogAnimationStyle(context)'),
    );
    final motion = File('lib/src/motion.dart').readAsStringSync();
    expect(motion, contains('ZoomPageTransitionsBuilder().buildTransitions'));
  });
}
