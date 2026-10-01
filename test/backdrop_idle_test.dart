import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

void main() {
  test(
    'home progress repaint is isolated and the carousel timer sleeps offscreen',
    () {
      final source = File('lib/src/media_center.dart').readAsStringSync();
      expect(
        source,
        contains(
          RegExp(
            r'child: RepaintBoundary\(\s*child: ValueListenableBuilder<double>\(\s*valueListenable: _heroProgress',
          ),
        ),
      );
      expect(source, contains("yingjiSectionFocus.value == 'home'"));
      expect(source, contains('ModalRoute.of(context)?.isCurrent != false'));
      expect(source, contains('bool get _canAdvanceHero'));
      expect(source, contains('if (!_canAdvanceHero)'));
      expect(source, contains('_heroTimer?.cancel();'));
      expect(source, contains('final period = Platform.isAndroid'));
      expect(source, contains('Duration(milliseconds: 500)'));
      expect(
        source,
        contains('yingjiHomeScrollDepth.addListener(_syncHeroTimer)'),
      );
      expect(
        source,
        contains('yingjiSectionFocus.addListener(_syncHeroTimer)'),
      );
      expect(source, contains('enabled: clarity < 1'));
    },
  );
  testWidgets('Android backdrop is idle while retaining real glass', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: const Stack(
          children: [
            Positioned.fill(child: YingjiBackdrop()),
            GlassPanel(child: Text('glass')),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, false);
    expect(find.byType(BackdropFilter), findsOneWidget);
    yingjiScrollInProgress.value = true;
    await tester.pump();
    yingjiScrollInProgress.value = false;
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, false);
  });

  testWidgets('Windows backdrop animates only when enabled', (tester) async {
    Widget page(bool enabled) => MaterialApp(
      theme: ThemeData(platform: TargetPlatform.windows),
      home: TickerMode(enabled: enabled, child: const YingjiBackdrop()),
    );
    await tester.pumpWidget(page(true));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, true);
    await tester.pumpWidget(page(false));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, false);
  });
}
