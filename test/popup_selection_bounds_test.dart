import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

void main() {
  test(
    'resource and track rows cannot enlarge their selection outside the list',
    () {
      final source = File('lib/src/metadata/metadata_detail_page.dart')
          .readAsStringSync();
      final motion = source
          .split('class _DetailCardMotionState ')
          .last
          .split('class _ResourcePickerCard ')
          .first;
      expect(motion, isNot(contains('AnimatedScale')));
      expect(motion, contains('child: widget.child'));
      final poster = source
          .split('class _DetailPosterHoverState ')
          .last
          .split('class ')
          .first;
      expect(poster, contains('ModalRoute.of(context) is PopupRoute'));
      expect(poster, contains('lifted && !inPopup'));
      final surfaces = File('lib/src/media_center.dart')
          .readAsStringSync()
          .split('class _FrostSurfaceState ')
          .last;
      expect(surfaces, contains('ModalRoute.of(context) is! PopupRoute'));
    },
  );

  testWidgets(
    'shared selected surface stays inside narrow and wide clipped lists',
    (tester) async {
      for (final width in [280.0, 600.0]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                height: 140,
                child: ListView(
                  children: const [
                    YingjiMotionSurface(
                      selected: true,
                      child: SizedBox(height: 64),
                    ),
                    SizedBox(height: 9),
                    YingjiMotionSurface(child: SizedBox(height: 64)),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final selected = find.byType(YingjiMotionSurface).first;
        final rect = tester.getRect(selected);
        expect(rect.left, 0);
        expect(rect.right, width);
        final scale = tester.widget<AnimatedScale>(
          find.descendant(of: selected, matching: find.byType(AnimatedScale)),
        );
        expect(scale.scale, 1);
      }
    },
  );
}
