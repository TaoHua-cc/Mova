import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

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
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
      1.012,
    );

    final press = await tester.startGesture(
      tester.getCenter(find.byKey(target)),
    );
    await tester.pump();
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
      .975,
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
    // 背板滤镜是「模糊 + vibrancy」的 compose，不再是一个裸的 blur
    // （compose 的 toString 不会展开内层 blur，所以只断言到这一层）。
    expect(yingjiAppearance.glassBlur, 0);
    expect(filter.filter.toString(), contains('ImageFilter.compose'));
    await tester.tap(find.text('two'));
    await tester.pumpAndSettle();
    expect(selection, 'two');
    // 菜单关掉后只剩按钮那一片玻璃。
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(tester.takeException(), isNull);
    yingjiAppearance.apply(glassBlur: 24);
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
}
