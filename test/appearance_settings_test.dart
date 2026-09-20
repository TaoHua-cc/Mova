import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/media_center.dart';

/// 外观分区最终只保留「模糊程度」一项：底色、不透明度与色调固定为中性磨砂
/// 玻璃，颜色模式固定深色。这四个控件撤掉之后不应再出现。
const _removedControls = <String>['颜色模式', '玻璃色调', '玻璃不透明度', '背景模糊', '背景卡片颜色'];

void main() {
  testWidgets('appearance section keeps only the blur slider', (tester) async {
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
    expect(find.textContaining('模糊程度'), findsWidgets);
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
