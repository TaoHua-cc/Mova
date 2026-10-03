import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

void main() {
  testWidgets('Windows glass uses the shared fixed frost', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: YingjiGlassSurface(child: Text('固定玻璃'))),
      ),
    );
    expect(YingjiGlass.fixedFrost().a, closeTo(.30, .005));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('settings no longer persist or preview glass level', () {
    final settings = File('lib/src/media_center.dart').readAsStringSync();
    final player = File('lib/src/player/windows_native_player.dart')
        .readAsStringSync();
    expect(settings, contains('固定模糊玻璃'));
    expect(settings, isNot(contains('_appearanceGlassBlur')));
    expect(settings, isNot(contains("'yingji.appearance.glass-blur'")));
    expect(player, contains('final glassBlur = YingjiGlass.fixedBlur;'));
    expect(player, isNot(contains('previewGlassOpacity')));
  });
}
