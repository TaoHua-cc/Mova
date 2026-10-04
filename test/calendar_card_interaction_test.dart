import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';
import 'package:yingji/src/motion.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('选中态胶囊的亮面铺满两侧内边距', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: YingjiGlassPillButton(
              icon: YingjiIcons.checkmark_seal,
              label: 'Trakt 已连接',
              tooltip: '',
              selected: true,
              onPressed: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final glass = find.descendant(
      of: find.byType(YingjiGlassPillButton),
      matching: find.byType(YingjiGlassSurface),
    );
    final fill = find.descendant(of: glass, matching: find.byType(Stack));
    expect(tester.getSize(fill).width, tester.getSize(glass).width);
    expect(tester.getSize(fill).height, 46);
    expect(
      tester.getCenter(find.text('Trakt 已连接')).dy,
      tester.getCenter(glass).dy,
    );
  });

  testWidgets('共享表面悬停不缩放，按压与按钮共用回弹令牌', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: YingjiMotionSurface(
              child: SizedBox(width: 180, height: 90, child: Text('卡片')),
            ),
          ),
        ),
      ),
    );
    final surface = find.byType(YingjiMotionSurface);
    final scale = find.descendant(
      of: surface,
      matching: find.byType(AnimatedScale),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(surface));
    await tester.pump();
    expect(tester.widget<AnimatedScale>(scale).scale, 1);

    await mouse.removePointer();
    final touch = await tester.startGesture(
      tester.getCenter(surface),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    expect(
      tester.widget<AnimatedScale>(scale).scale,
      MovaMotion.pressScaleCard,
    );
    await touch.up();
    await tester.pump();
    final released = tester.widget<AnimatedScale>(scale);
    expect(released.scale, 1);
    expect(released.duration, MovaMotion.tapUp);
    expect(released.curve, MovaMotion.spring);
  });

  test('日历海报贴齐卡片左缘，进度继续展示实际三项集数', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    final cardStart = source.indexOf('class _TrackingEventCard');
    final progressStart = source.indexOf('class _CalendarProgressBar');
    expect(cardStart, isNonNegative);
    expect(progressStart, greaterThan(cardStart));

    final card = source.substring(cardStart, progressStart);
    expect(card, contains('YingjiMotionSurface('));
    expect(card, contains('Positioned('));
    expect(card, contains('left: 0'));
    expect(card, contains('top: 0'));
    expect(card, contains('bottom: 0'));
    expect(card, contains('BorderRadius.horizontal('));
    expect(card, isNot(contains('EdgeInsets.all(10)')));

    final progressEnd = source.indexOf('class _CalendarAirtimeBadge');
    final progress = source.substring(progressStart, progressEnd);
    expect(progress, contains('counts.watched'));
    expect(progress, contains('counts.unwatched'));
    expect(progress, contains('counts.total'));
    expect(progress, contains('FractionallySizedBox('));
    expect(progress, contains('indicatorLeft'));
    expect(progress, contains('_calendarProgressAccent'));
    expect(progress, isNot(contains('YingjiColors.success')));

    final localEventsStart = source.indexOf(
      'Future<List<TraktEvent>> _localWatchlistEvents',
    );
    final localEventsEnd = source.indexOf('bool _isDropped', localEventsStart);
    final localEvents = source.substring(localEventsStart, localEventsEnd);
    expect(localEvents, contains('SeriesAiringStore'));
    final airing = File('lib/src/metadata/series_airing.dart')
        .readAsStringSync();
    expect(airing, contains('next.showPosterUrl ?? next.stillUrl'));
  });

  test('共用图标按钮和状态胶囊使用同一套按下回弹节奏', () {
    final source = File('lib/src/brand.dart').readAsStringSync();
    for (final name in [
      '_YingjiMotionIconButtonState',
      '_YingjiGlassPillButtonState',
    ]) {
      final start = source.indexOf('class $name');
      expect(start, isNonNegative, reason: name);
      final body = source.substring(start, source.indexOf('\n}', start) + 2);
      expect(body, contains('MovaMotion.tapDown'), reason: name);
      expect(body, contains('MovaMotion.tapUp'), reason: name);
      expect(body, contains('MovaMotion.press'), reason: name);
      expect(body, contains('MovaMotion.spring'), reason: name);
    }
  });
}
