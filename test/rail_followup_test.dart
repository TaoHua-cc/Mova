import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'server result refresh does not recenter unchanged selected episode',
    () {
      final detail = File('lib/src/metadata/metadata_detail_page.dart')
          .readAsStringSync();
      final start = detail.indexOf(
        'void didUpdateWidget(covariant _CatalogEpisodeRail',
      );
      final body = detail.substring(
        start,
        detail.indexOf('void dispose()', start),
      );
      expect(body, isNot(contains('oldWidget.episodes != widget.episodes')));
      expect(
        body,
        contains('oldWidget.selectedEpisode != widget.selectedEpisode'),
      );
      expect(
        body,
        contains('oldWidget.episodes.isEmpty && widget.episodes.isNotEmpty'),
      );
      final extras = detail.substring(
        detail.indexOf("title: '演职人员'"),
        detail.indexOf('Future<void> _showCast'),
      );
      expect(extras, isNot(contains('yingjiWheelPhysics')));
      expect(extras.split('MovaHorizontalDrag(').length - 1, 3);
      final title = detail.substring(
        detail.indexOf('class _DetailSectionTitle'),
        detail.indexOf('class _SectionShelfControls'),
      );
      expect(title, contains('=> Row('));
      expect(title, contains('Expanded('));
    },
  );
  test(
    'scroll stop restores pointer hover and rechecks snapshot hit testing',
    () {
      final main = File('lib/src/media_center.dart').readAsStringSync();
      final hover = main.substring(
        main.indexOf('class _MediaHoverState'),
        main.indexOf('class _MediaHoverState') + 1800,
      );
      expect(hover, contains('_hovered = _pointerInside'));
      expect(hover, contains('_pointerInside = false'));
      expect(
        File('lib/src/cache/scroll_snapshot.dart').readAsStringSync(),
        contains('mouseTracker.updateAllDevices()'),
      );
    },
  );
}
