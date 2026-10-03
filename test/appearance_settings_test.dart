import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/media_center.dart';

/// The global glass is fixed; only unrelated appearance and home controls remain.
const _removedControls = <String>[
  '颜色模式',
  '玻璃色调',
  '玻璃不透明度',
  '背景模糊',
  '背景卡片颜色',
  '磨砂程度',
  '模糊程度',
];

void main() {
  testWidgets('danmaku area accepts values persisted by the player panel', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'yingji.danmaku.area': 0.249951646639986,
    });
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SizedBox(height: 2200, child: SettingsPage())),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('appearance section describes fixed glass without a slider', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SizedBox(height: 2200, child: SettingsPage())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('外观'), findsWidgets);
    expect(find.text('固定模糊玻璃'), findsOneWidget);
    for (final label in _removedControls) {
      expect(
        find.textContaining(label),
        findsNothing,
        reason: '$label 应已从外观分区移除',
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
