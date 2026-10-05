import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

void main() {
  test(
    'resource picker overrides inherited sheet frame, retains selected row',
    () {
      final source = File('lib/src/metadata/metadata_detail_page.dart')
          .readAsStringSync();
      final picker = source.substring(
        source.indexOf('Future<void> _showResourcePicker'),
        source.indexOf('Future<void> _showTrackPicker'),
      );
      expect(picker, contains('shape: const RoundedRectangleBorder()'));
      expect(picker, contains('backgroundColor: Colors.transparent'));
      expect(picker, contains('showDragHandle: false'));
      expect('GlassPanel('.allMatches(picker), hasLength(1));
      final row = source.substring(
        source.indexOf('class _ResourcePickerCard'),
        source.indexOf('String _resourcePickerSummary'),
      );
      expect(row, contains('selected ? 2.2 : 1'));
      expect(row, contains('YingjiIcons.checkmark_circle_fill'));
    },
  );

  for (final width in [390.0, 1280.0]) {
    testWidgets('transparent sheet has one panel at width $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            bottomSheetTheme: const BottomSheetThemeData(
              shape: RoundedRectangleBorder(
                side: BorderSide(color: Colors.white),
              ),
            ),
          ),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                showModalBottomSheet<void>(
                  context: context,
                  backgroundColor: Colors.transparent,
                  shape: const RoundedRectangleBorder(),
                  elevation: 0,
                  showDragHandle: false,
                  builder: (_) => const Padding(
                    padding: EdgeInsets.all(18),
                    child: GlassPanel(
                      child: SizedBox(height: 120, child: Text('切换资源')),
                    ),
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.color, Colors.transparent);
      expect((material.shape! as RoundedRectangleBorder).side, BorderSide.none);
      expect(find.byType(GlassPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
