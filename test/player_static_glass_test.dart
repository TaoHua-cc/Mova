import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

void main() {
  testWidgets('fixed player glass includes nested circular controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: YingjiFixedGlass(
            child: Column(
              children: [
                GlassPanel(child: Text('播放器')),
                SizedBox(
                  width: 44,
                  height: 44,
                  child: YingjiGlassSurface(circle: true),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 44,
            height: 44,
            child: YingjiGlassSurface(circle: true),
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
  });
  testWidgets('player menu glass does not sample the moving video', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GlassPanel(sampleBackdrop: false, child: Text('音轨与字幕')),
        ),
      ),
    );
    expect(find.text('音轨与字幕'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: GlassPanel(child: Text('普通玻璃'))),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
  });
}
