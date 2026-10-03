import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/update/update_checker.dart';
import 'package:yingji/src/update/update_flow.dart';

void main() {
  for (final width in [320.0, 1280.0]) {
    testWidgets('update dialog fits width $width and scrolls notes', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MovaUpdateDialog(
              release: UpdateRelease(
                version: '99.0.0',
                tag: 'v99.0.0',
                body: List.filled(40, '更新说明：改善体验').join('\n'),
                pageUrl: Uri.parse(
                  'https://github.com/TaoHua-cc/Mova/releases',
                ),
                assets: const [],
              ),
            ),
          ),
        ),
      );
      expect(find.text('更新内容'), findsOneWidget);
      expect(find.text('稍后'), findsOneWidget);
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
