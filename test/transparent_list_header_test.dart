import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

void main() {
  testWidgets(
    'list header is outside glass while content retains its material',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: YingjiPinnedDialog(
              transparentHeader: true,
              header: Text('全部剧集'),
              body: Text('剧集内容'),
            ),
          ),
        ),
      );
      expect(
        find.ancestor(of: find.text('全部剧集'), matching: find.byType(GlassPanel)),
        findsNothing,
      );
      expect(
        find.ancestor(of: find.text('剧集内容'), matching: find.byType(GlassPanel)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
