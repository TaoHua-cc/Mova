// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/app.dart';
import 'package:yingji/src/brand.dart';
import 'package:yingji/src/media_center.dart';

void main() {
  testWidgets('settings menu reaches distant cards repeatedly', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SettingsPage())),
    );
    await tester.pumpAndSettle();
    final scrollable = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .controller!;
    for (final label in ['关于映迹', '首页', '字幕与弹幕', '外观', '关于映迹']) {
      await tester.tap(find.widgetWithText(TextButton, label).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (label == '首页') {
        expect(scrollable.position.pixels, lessThan(140));
      }
    }
    expect(scrollable.position.pixels, greaterThan(1000));
    expect(find.text('私人媒体中心').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('renders the Yingji shell', (WidgetTester tester) async {
    await tester.pumpWidget(const YingjiApp());
    expect(find.byIcon(YingjiIcons.play_fill), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  });
}
