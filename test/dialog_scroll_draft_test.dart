import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

void main() {
  test('new discovery lists remain drafts until explicit save', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    final add = source.substring(
      source.indexOf('Future<void> _addDiscoverSection()'),
      source.indexOf('Future<void> _showSectionSettings('),
    );
    expect(add, contains('isNew: true'));
    expect(add, isNot(contains('_persistLayout')));
    expect(add, isNot(contains('_sections.insert')));
    expect(source, contains('(!saved && !deleted)'));
  });
  test('audio and subtitle controls no longer alias the same menu', () {
    final source = File('lib/src/player/player_page.dart').readAsStringSync();
    final open = source.substring(
      source.indexOf('void _openConsoleTab('),
      source.indexOf('void _openConsoleTab(') + 500,
    );
    expect(open, isNot(contains("tab = '音轨与字幕'")));
    expect(source, contains("_openConsoleTab('字幕')"));
  });
  testWidgets('scroll foreground is outside the stable glass filter layer', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: YingjiStableScrollGlass(
            child: YingjiGlassSurface(
              child: SizedBox(
                width: 400,
                height: 300,
                child: ListView.builder(
                  itemCount: 40,
                  itemBuilder: (_, i) => Text('row $i'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final filter = find.byType(BackdropFilter);
    expect(filter, findsNothing);
    expect(
      find.descendant(of: filter, matching: find.byType(ListView)),
      findsNothing,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('nested menu controls reuse the blurred panel backdrop', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: YingjiStableScrollGlass(
            child: YingjiGlassSurface(
              child: SizedBox(
                width: 400,
                height: 300,
                child: YingjiGlassSurface(child: Text('nested')),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('nested'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
