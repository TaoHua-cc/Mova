import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

void main() {
  test(
    'nested scroll activity keeps the glass pause active until all stop',
    () {
      final dialogScroll = Object();
      final listScroll = Object();

      endYingjiScrollActivity(dialogScroll);
      endYingjiScrollActivity(listScroll);
      beginYingjiScrollActivity(dialogScroll);
      beginYingjiScrollActivity(listScroll);

      expect(yingjiScrollInProgress.value, isTrue);

      endYingjiScrollActivity(dialogScroll);
      expect(yingjiScrollInProgress.value, isTrue);

      endYingjiScrollActivity(listScroll);
      expect(yingjiScrollInProgress.value, isFalse);
    },
  );

  testWidgets('stable glass wrapper tracks touch scrolling and settles', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: YingjiStableScrollGlass(
          stable: false,
          child: SizedBox(
            height: 140,
            child: ListView(
              children: [
                for (var index = 0; index < 24; index++) Text('$index'),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.fling(find.byType(ListView), const Offset(0, -440), 1700);
    await tester.pump(const Duration(milliseconds: 16));
    expect(yingjiScrollInProgress.value, isTrue);

    await tester.pumpAndSettle();
    expect(yingjiScrollInProgress.value, isFalse);
  });

  testWidgets('stable glass keeps its blur enabled throughout touch scroll', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: YingjiStableScrollGlass(
          child: SizedBox(
            height: 140,
            child: YingjiGlassSurface(
              child: ListView(
                children: [
                  for (var index = 0; index < 24; index++) Text('$index'),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final filterFinder = find.byType(BackdropFilter);
    expect(tester.widget<BackdropFilter>(filterFinder).enabled, isTrue);

    await tester.fling(find.byType(ListView), const Offset(0, -440), 1700);
    await tester.pump(const Duration(milliseconds: 16));
    expect(yingjiScrollInProgress.value, isTrue);
    expect(tester.widget<BackdropFilter>(filterFinder).enabled, isTrue);

    await tester.pumpAndSettle();
    expect(tester.widget<BackdropFilter>(filterFinder).enabled, isTrue);
  });

  testWidgets('dynamic glass pauses backdrop sampling while scrolling', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(width: 240, height: 120, child: YingjiGlassSurface()),
      ),
    );

    final filterFinder = find.byType(BackdropFilter);
    expect(tester.widget<BackdropFilter>(filterFinder).enabled, isTrue);

    final owner = Object();
    beginYingjiScrollActivity(owner);
    await tester.pump();
    expect(tester.widget<BackdropFilter>(filterFinder).enabled, isFalse);

    endYingjiScrollActivity(owner);
    await tester.pump();
    expect(tester.widget<BackdropFilter>(filterFinder).enabled, isTrue);
  });

  test('shared scroll wheel does not force stable glass on Android', () {
    final source = File('lib/src/brand.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(
      source,
      contains('final child = widget.stableGlass && WindowHost.isDesktop'),
    );
    expect(source, contains('valueListenable: yingjiScrollInProgress'));
    expect(source, contains('stable: !scrolling'));
    final shell = File('lib/src/media_center.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(
      shell,
      contains(
        'final shellBody = YingjiStableScrollGlass(\n      stable: WindowHost.isDesktop,',
      ),
    );
    final sectionSwitch = shell.substring(
      shell.indexOf('void _selectSection('),
      shell.indexOf('void _handlePointerSignal('),
    );
    expect(
      sectionSwitch,
      contains('if (WindowHost.isAndroid || (target - current).abs() > 1)'),
    );
    expect(shell, contains('allowImplicitScrolling: !WindowHost.isAndroid'));
    expect(
      sectionSwitch,
      contains('beginYingjiScrollActivity(_pageGlassOwner)'),
    );
    expect(sectionSwitch, contains('Duration(milliseconds: 160)'));
  });

  test('desktop frost surfaces honor dynamic scroll glass scopes', () {
    final source = File('lib/src/media_center.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final frostSurface = source.substring(
      source.indexOf('class _FrostSurfaceState'),
      source.indexOf('class ', source.indexOf('class _FrostSurfaceState') + 1),
    );

    expect(
      frostSurface,
      contains('if (YingjiStableScrollGlass.enabled(context))'),
    );
    expect(
      frostSurface,
      isNot(
        contains(
          'WindowHost.isDesktop || YingjiStableScrollGlass.enabled(context)',
        ),
      ),
    );
  });
}
