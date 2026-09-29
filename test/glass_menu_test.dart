import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';
import 'package:yingji/src/motion.dart';

void main() {
  testWidgets('motion surface responds to hover and press without relayout', (
    tester,
  ) async {
    const target = Key('motion-target');
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: YingjiMotionSurface(
            child: SizedBox(key: target, width: 80, height: 40),
          ),
        ),
      ),
    );
    final originalSize = tester.getSize(find.byKey(target));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byKey(target)));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    final hoverOutline = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    final outline = hoverOutline.foregroundDecoration! as BoxDecoration;
    expect(outline.border, isNotNull);

    final press = await tester.startGesture(
      tester.getCenter(find.byKey(target)),
    );
    await tester.pump();
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
      MovaMotion.pressScaleCard,
    );
    expect(tester.getSize(find.byKey(target)), originalSize);
    await press.up();
    await mouse.removePointer();
  });

  testWidgets('choice menu has shared blur, selects and closes', (
    tester,
  ) async {
    var selection = 'one';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: YingjiGlassChoiceButton<String>(
            value: selection,
            items: const ['one', 'two'],
            labelBuilder: (v) => v,
            onChanged: (v) => selection = v,
          ),
        ),
      ),
    );
    await tester.tap(find.text('one'));
    await tester.pumpAndSettle();
    // 两片玻璃：按钮自己（常驻）+ 展开的菜单面板。控件不再是「一层半透明色」，
    // 整个应用的可点表面都走 YingjiGlassSurface，才会一起跟「模糊程度」变。
    expect(find.byType(BackdropFilter), findsNWidgets(2));
    final menuGlass = find.descendant(
      of: find.byType(GlassPanel),
      matching: find.byType(BackdropFilter),
    );
    expect(menuGlass, findsOneWidget);
    yingjiAppearance.apply(glassBlur: 0);
    await tester.pump();
    final filter = tester.widget<BackdropFilter>(menuGlass);
    // 直接使用平台原生高斯模糊，避免只剩透明色底。
    expect(yingjiAppearance.glassBlur, 0);
    expect(filter.filter.toString(), contains('ImageFilter.blur'));
    await tester.tap(find.text('two'));
    await tester.pumpAndSettle();
    expect(selection, 'two');
    // 菜单关掉后只剩按钮那一片玻璃。
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(tester.takeException(), isNull);
    yingjiAppearance.apply(glassBlur: 24);
  });

  testWidgets('secondary-only context menu also opens on long press', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: YingjiGlassMenu(
            secondaryOnly: true,
            entries: const [Text('上下文操作')],
            child: const SizedBox(width: 120, height: 52, child: Text('项目')),
          ),
        ),
      ),
    );

    await tester.longPress(find.text('项目'));
    await tester.pumpAndSettle();

    expect(find.text('上下文操作'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'secondary-only context menu opens on a Windows-style right click',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: YingjiGlassMenu(
              secondaryOnly: true,
              entries: const [Text('右键菜单')],
              child: const SizedBox(width: 120, height: 52, child: Text('项目')),
            ),
          ),
        ),
      );

      final rightClick = await tester.startGesture(
        tester.getCenter(find.text('项目')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await rightClick.up();
      await tester.pumpAndSettle();

      expect(find.text('右键菜单'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('shared content context menu keeps material text and glass', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showYingjiContextMenu(
              context: context,
              position: const Offset(20, 20),
              actions: const [
                YingjiContextAction(
                  value: 'played',
                  label: '标记为已播放',
                  icon: YingjiIcons.checkmark_circle_fill,
                ),
              ],
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final action = find.text('标记为已播放');
    expect(action, findsOneWidget);
    expect(
      find.ancestor(of: action, matching: find.byType(Material)),
      findsWidgets,
    );
    expect(
      find.ancestor(of: action, matching: find.byType(GlassPanel)),
      findsOneWidget,
    );
    expect(
      find.ancestor(of: action, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );
    final style = DefaultTextStyle.of(tester.element(action)).style;
    expect(style.fontSize, 14);
    expect(style.color, YingjiColors.ink);
    expect(style.decoration, TextDecoration.none);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolling dialog keeps header and actions pinned', (
    tester,
  ) async {
    const headerKey = Key('pinned-header');
    const actionKey = Key('pinned-action');
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: YingjiPinnedDialog(
          maxHeight: 560,
          header: const Text('固定标题', key: headerKey),
          body: Column(
            children: List.generate(
              30,
              (index) => SizedBox(height: 48, child: Text('滚动内容 $index')),
            ),
          ),
          actions: const Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: actionKey,
              onPressed: null,
              child: Text('保存'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final headerBefore = tester.getTopLeft(find.byKey(headerKey));
    final actionBefore = tester.getTopLeft(find.byKey(actionKey));
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -420),
    );
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(find.byKey(headerKey)), headerBefore);
    expect(tester.getTopLeft(find.byKey(actionKey)), actionBefore);
    expect(find.text('滚动内容 20'), findsOneWidget);
  });

  testWidgets('smooth pinned dialog keeps its shell in stable glass scope', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: YingjiPinnedDialog(
          header: const Text('全部剧集'),
          body: const SizedBox(height: 900),
          scrollController: controller,
          maxHeight: 360,
          insetPadding: EdgeInsets.zero,
        ),
      ),
    );

    final shellGlass = find.ancestor(
      of: find.byType(GlassPanel).first,
      matching: find.byType(YingjiStableScrollGlass),
    );
    expect(shellGlass, findsOneWidget);
    expect(find.byType(YingjiSmoothWheel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
