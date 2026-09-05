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
  testWidgets('settings menu never scrolls an enclosing page', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final outer = ScrollController(initialScrollOffset: 120);
    addTearDown(outer.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: outer,
            child: const Column(
              children: [
                SizedBox(height: 200),
                SizedBox(height: 1000, child: SettingsPage()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(outer.offset, 120);

    await tester.tap(find.widgetWithText(TextButton, '关于映迹').first);
    await tester.pumpAndSettle();

    expect(outer.offset, 120);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('discover shelves can be shown and persist their layout', (
    tester,
  ) async {
    const sections = <String>[
      '今日热门电视剧',
      '今日热门电影',
      '今日播出剧集',
      '本周播出剧集',
      '院线热映',
      '高分电影',
      '高分剧集',
      '热门国产电视剧',
      '热门国产电影',
      '热门综艺',
      '热门国产动漫',
      '热门番剧',
      '热门韩剧',
      '热门日剧',
      '热门台剧',
      '按分类',
      '按平台',
    ];
    SharedPreferences.setMockInitialValues({
      'yingji.discover.hidden-sections': sections,
    });
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: MediaCenterShell())),
    );
    await tester.pump();
    yingjiSectionRequest.value = 'discover';
    await tester.pumpAndSettle();
    expect(find.text('所有栏目均已隐藏'), findsOneWidget);

    await tester.tap(find.byTooltip('发现页设置'));
    await tester.pumpAndSettle();
    expect(find.text('发现页栏目编排'), findsOneWidget);
    expect(find.text('数据来源'), findsWidgets);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(find.text('显示的列表'), findsOneWidget);
    expect(find.text('隐藏的列表'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('显示的列表')).dy,
      lessThan(tester.getTopLeft(find.text('隐藏的列表')).dy),
    );
    await tester.tap(find.text('TMDB · 今日热门电视剧').first);
    await tester.pumpAndSettle();
    expect(find.text('TMDB · 科幻电影'), findsOneWidget);
    await tester.ensureVisible(find.text('TMDB · 科幻电影'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TMDB · 科幻电影'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('固定列表').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义筛选').last);
    await tester.pumpAndSettle();
    expect(find.text('影视'), findsWidgets);
    expect(find.text('类型'), findsWidgets);
    expect(find.text('热度类别'), findsWidgets);
    await tester.tap(find.byTooltip('关闭').last);
    await tester.pump(const Duration(milliseconds: 400));

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getStringList('yingji.discover.hidden-sections') ??
          const <String>[],
      isNot(contains('今日热门电视剧')),
    );
    expect(
      prefs.getString('yingji.discover.section-sources'),
      contains('custom|tmdb|movie|all|popularity.desc'),
    );
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
