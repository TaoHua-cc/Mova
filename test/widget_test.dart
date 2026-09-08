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
import 'package:yingji/src/metadata/tmdb_client.dart';

void main() {
  test('all-list genre filter matches actual media genres', () {
    const item = TmdbItem(
      id: 1,
      title: '测试影片',
      kind: 'movie',
      genres: ['剧情', '科幻'],
    );
    expect(matchesDiscoverGenre(item, 'all'), isTrue);
    expect(matchesDiscoverGenre(item, 'drama'), isTrue);
    expect(matchesDiscoverGenre(item, 'scifi'), isTrue);
    expect(matchesDiscoverGenre(item, 'comedy'), isFalse);
  });

  testWidgets('pushed pages use unified window controls', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: YingjiPageChrome())),
    );
    expect(find.byType(YingjiWindowControls), findsOneWidget);
    expect(find.byTooltip('最小化'), findsOneWidget);
    expect(find.byTooltip('最大化'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);
  });

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
    for (final label in ['关于 Mova', '首页', '字幕与弹幕', '外观', '关于 Mova']) {
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

    await tester.tap(find.widgetWithText(TextButton, '关于 Mova').first);
    await tester.pumpAndSettle();

    expect(outer.offset, 120);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('changing one setting writes only that preference', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SettingsPage())),
    );
    await tester.pumpAndSettle();

    final settingRow = find
        .ancestor(of: find.text('显示首页图标'), matching: find.byType(Row))
        .first;
    final toggle = find.descendant(
      of: settingRow,
      matching: find.byType(Switch),
    );
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('yingji.home.show-icon'), isFalse);
    expect(prefs.containsKey('yingji.player.hardware'), isFalse);
    expect(prefs.containsKey('yingji.appearance.theme'), isFalse);
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
    expect(find.byTooltip('排序与显示栏目'), findsOneWidget);
    await tester.tap(find.byTooltip('排序与显示栏目'));
    await tester.pumpAndSettle();
    expect(find.text('发现页栏目编排'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('添加列表'));
    await tester.pumpAndSettle();
    expect(find.text('列表设置'), findsOneWidget);
    expect(find.textContaining('当前筛选  TMDB · 电影'), findsOneWidget);
    expect(find.text('内容筛选'), findsWidgets);
    expect(find.text('来源'), findsWidgets);
    expect(find.text('影视类型'), findsWidgets);
    expect(find.text('地区'), findsWidgets);
    expect(find.text('来源榜单'), findsWidgets);
    expect(find.text('题材类型'), findsWidgets);
    expect(find.text('原始语言'), findsWidgets);
    expect(find.text('发行年份'), findsWidgets);
    expect(find.text('发行时间'), findsWidgets);
    expect(find.text('最低评分'), findsWidgets);
    expect(find.text('评分人数'), findsWidgets);
    expect(find.text('内容时长'), findsWidgets);
    expect(find.text('新列表 18'), findsWidgets);
    await tester.enterText(
      find.byKey(const ValueKey('discover-name-新列表 18')),
      '我的电影榜',
    );
    await tester.ensureVisible(find.text('保存当前列表'));
    await tester.tap(find.text('保存当前列表'));
    await tester.pumpAndSettle();
    expect(find.text('我的电影榜'), findsWidgets);
    expect(find.byTooltip('设置我的电影榜'), findsOneWidget);
    await tester.tap(find.byTooltip('设置我的电影榜'));
    await tester.pumpAndSettle();
    expect(find.text('列表设置'), findsOneWidget);
    await tester.ensureVisible(find.text('保存当前列表'));
    await tester.tap(find.text('保存当前列表'));
    await tester.pump(const Duration(milliseconds: 400));

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getStringList('yingji.discover.hidden-sections') ??
          const <String>[],
      contains('今日热门电视剧'),
    );
    expect(prefs.getStringList('yingji.discover.sections'), contains('我的电影榜'));
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('renders the Mova shell', (WidgetTester tester) async {
    await tester.pumpWidget(const YingjiApp());
    expect(find.byType(YingjiMark), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  });
}
