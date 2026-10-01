import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';
import 'package:yingji/src/cache/scroll_snapshot.dart';
import 'package:yingji/src/platform/window_host.dart';

void main() {
  testWidgets('discover idle stops decorative backdrop frames', (tester) async {
    final oldDepth = yingjiHomeScrollDepth.value;
    final oldFocus = yingjiSectionFocus.value;
    yingjiSectionFocus.value = 'home';
    yingjiHomeScrollDepth.value = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: const YingjiBackdrop(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 20));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    yingjiHomeScrollDepth.value = 1;
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    yingjiHomeScrollDepth.value = 0;
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    yingjiHomeScrollDepth.value = oldDepth;
    yingjiSectionFocus.value = oldFocus;
  });
  testWidgets('wheel at feed edges does not regenerate scrolling snapshots', (
    tester,
  ) async {
    final controller = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: YingjiSmoothWheel(
          controller: controller,
          child: ListView(
            controller: controller,
            physics: yingjiWheelPhysics,
            children: const [SizedBox(height: 3000)],
          ),
        ),
      ),
    );
    var changes = 0;
    void listener() => changes++;
    yingjiScrollInProgress.addListener(listener);
    for (final delta in [-120.0, -120.0]) {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: const Offset(400, 300),
          scrollDelta: Offset(0, delta),
        ),
      );
      await tester.pump();
    }
    controller.jumpTo(controller.position.maxScrollExtent);
    for (var i = 0; i < 3; i++) {
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(400, 300),
          scrollDelta: Offset(0, 120),
        ),
      );
      await tester.pump();
    }
    expect(changes, 0);
    yingjiScrollInProgress.removeListener(listener);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets('fixed header glass keeps its material during scrolling', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: YingjiStableScrollGlass(
            child: YingjiFixedGlass(
              light: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 30,
                    height: 30,
                    child: YingjiGlassSurface(circle: true),
                  ),
                  SizedBox(width: 10),
                  SizedBox(
                    width: 30,
                    height: 30,
                    child: YingjiGlassSurface(circle: true),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    final material = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .map((widget) => widget.decoration)
        .whereType<BoxDecoration>()
        .where((decoration) => decoration.color != null);
    expect(
      material.any((decoration) => decoration.color == YingjiGlass.chrome()),
      isTrue,
    );
    final owner = Object();
    beginYingjiScrollActivity(owner);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
    endYingjiScrollActivity(owner);
    expect(tester.takeException(), isNull);
  });
  test(
    'feed snapshots exclude live glass headers and bound shelf overflow',
    () {
      final source = File('lib/src/media_center.dart').readAsStringSync();
      final block = source.substring(
        source.indexOf('class _DiscoverBlockState'),
        source.indexOf('class _DiscoveryStylePreview'),
      );
      expect(
        block.indexOf('_SectionHeader('),
        lessThan(block.indexOf('ScrollSnapshot(')),
      );
      expect(block, contains('ClipRect('));
      expect(source, contains('right: _PageScrollCue.width'));
      expect(source, contains('YingjiFixedGlass(light: true, child: header)'));
      final row = source.substring(
        source.indexOf('final section = visibleSections[index - 1]'),
        source.indexOf('final itemCount = visibleSections.isEmpty'),
      );
      expect(row, isNot(contains('ScrollSnapshot')));
    },
  );
  testWidgets('shelf snapshots stop for horizontal browsing and disposal', (
    tester,
  ) async {
    final owner = Object();
    await tester.pumpWidget(
      const MaterialApp(
        home: ScrollSnapshot(child: SizedBox(width: 300, height: 100)),
      ),
    );
    final snapshot = tester.widget<SnapshotWidget>(find.byType(SnapshotWidget));
    expect(snapshot.controller.allowSnapshotting, isFalse);
    beginYingjiScrollActivity(owner);
    expect(snapshot.controller.allowSnapshotting, WindowHost.isDesktop);
    final context = tester.element(find.byType(SizedBox).last);
    final metrics = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 1000,
      pixels: 0,
      viewportDimension: 300,
      axisDirection: AxisDirection.right,
      devicePixelRatio: 1,
    );
    ScrollStartNotification(
      metrics: metrics,
      context: context,
    ).dispatch(context);
    expect(snapshot.controller.allowSnapshotting, isFalse);
    ScrollEndNotification(metrics: metrics, context: context).dispatch(context);
    expect(snapshot.controller.allowSnapshotting, WindowHost.isDesktop);
    endYingjiScrollActivity(owner);
    expect(snapshot.controller.allowSnapshotting, isFalse);
    await tester.pumpWidget(const SizedBox());
    beginYingjiScrollActivity(owner);
    endYingjiScrollActivity(owner);
    expect(tester.takeException(), isNull);
  });
}
