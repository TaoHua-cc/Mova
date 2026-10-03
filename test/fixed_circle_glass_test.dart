import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

void main() {
  test('windows and Android use the same fixed frosted surface', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final windows = YingjiGlass.fixedFrost();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(YingjiGlass.fixedFrost(), windows);
    expect(windows.a, closeTo(.30, .005));
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets('rectangular panel defaults to fixed frost', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: GlassPanel(child: Text('固定面板'))),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('固定面板'), findsOneWidget);
  });
  testWidgets('circle frost has no backdrop and uses fixed coverage', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 44,
            height: 44,
            child: YingjiGlassSurface(circle: true, child: Icon(Icons.add)),
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    Color surfaceColor() => tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .map((box) => box.decoration)
        .whereType<BoxDecoration>()
        .firstWhere((box) => box.shape == BoxShape.circle && box.color != null)
        .color!;
    expect(surfaceColor(), YingjiGlass.fixedFrost());
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byIcon(Icons.add), findsOneWidget);
  });
}
