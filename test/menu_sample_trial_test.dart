import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

void main() {
  test('fixed menu does not capture or filter the background', () {
    final source = File('lib/src/brand.dart').readAsStringSync();
    final menu = source.substring(
      source.indexOf('Future<String?> showYingjiContextMenu'),
      source.indexOf('class _YingjiContextActionTile'),
    );
    expect(menu, isNot(contains('sampleOnce')));
    expect(menu, isNot(contains('toImage(')));
    expect(menu, isNot(contains('RawImage(')));
    expect(menu, isNot(contains('BackdropFilter(')));
    expect(source, isNot(contains('yingjiMenuCaptureKey')));
    expect(
      File('lib/src/app.dart').readAsStringSync(),
      isNot(contains('yingjiMenuCaptureKey')),
    );
  });
  testWidgets('fixed menu remains usable', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showYingjiContextMenu(
                context: context,
                position: const Offset(20, 20),
                actions: const [
                  YingjiContextAction(
                    value: 'played',
                    label: '已播放',
                    icon: Icons.check,
                  ),
                ],
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已播放'));
    await tester.pumpAndSettle();
    expect(result, 'played');
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
