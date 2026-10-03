import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';
import 'package:yingji/src/motion.dart';

void main() {
  test('all public glass colors share one fixed coverage', () {
    final color = YingjiGlass.fixedFrost();
    expect(color.r, closeTo(88 / 255, .001));
    expect(color.g, closeTo(96 / 255, .001));
    expect(color.b, closeTo(98 / 255, .001));
    expect(YingjiGlass.surface(), color);
    expect(YingjiGlass.chrome(strength: 1), color);
    expect(YingjiGlass.hud(strength: 1), color);
    expect(color.a, closeTo(.30, .005));
    expect(YingjiGlass.fixedFrost(strength: .82).a, color.a);
    expect(YingjiGlass.fixedFrost(strength: 1.5).a, color.a);
  });
  testWidgets('even legacy opt-in cannot sample the background', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: YingjiGlassSurface(sampleBackdrop: true, child: Text('固定玻璃')),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('固定玻璃'), findsOneWidget);
    final tint = YingjiGlass.fixedFrost();
    final clear = YingjiGlass.fixedDepth();
    final soft = YingjiGlass.fixedDepth();
    expect(clear.stops, soft.stops);
    expect(clear.colors, soft.colors);
    expect(YingjiGlass.fixedFrost(), tint);
    expect(YingjiGlass.fixedFrost().r, tint.r);
    expect(YingjiGlass.fixedFrost().g, tint.g);
    expect(YingjiGlass.fixedFrost().b, tint.b);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
  });
  testWidgets('player HUD has no video backdrop filter', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: MovaHudPill(icon: Icons.volume_up, label: '50%', blur: 40),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
  });
  test('app and shared surfaces contain no background capture hooks', () {
    final app = File('lib/src/app.dart').readAsStringSync();
    final brand = File('lib/src/brand.dart').readAsStringSync();
    expect(app, isNot(contains('FixedGlassScene(')));
    expect(app, isNot(contains('fixedGlassRouteObserver')));
    expect(brand, isNot(contains('CachedGlassSurface(')));
    expect(brand, isNot(contains('BackdropFilter(')));
    final native = File('windows/native_player/main.cpp').readAsStringSync();
    expect(
      native,
      contains('FillStaticPlayerMenuSurface(graphics, path, body)'),
    );
    expect(native, contains('Gdiplus::Color(77, 88, 96, 98)'));
  });
}
