import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('both artwork previews opt out of themed dialog outlines', () {
    final source = File('lib/src/metadata/metadata_detail_page.dart')
        .readAsStringSync();
    for (final marker in [
      'maxWidth: 1100,',
      'maxWidth: 1200, maxHeight: 780',
    ]) {
      final end = source.indexOf(marker, source.indexOf("title: '艺术图'"));
      // Restrict to the artwork preview near the corresponding constraint.
      expect(end, greaterThan(0));
      final start = source.lastIndexOf('builder: (context) => Dialog(', end);
      expect(
        source.substring(start, end),
        contains('shape: const RoundedRectangleBorder()'),
      );
      expect(source.substring(start, end), contains('elevation: 0'));
    }
  });
}
