import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resource cards share poster feedback and omit redundant icons', () {
    final source = File('lib/src/metadata/metadata_detail_page.dart')
        .readAsStringSync();
    final card = source
        .split('class _ResourceCard ')
        .last
        .split('class _DetailCardMotion ')
        .first;
    expect(card, contains('_DetailPosterHover('));
    expect(card, isNot(contains('checkmark_circle_fill')));
    expect(card, isNot(contains('Border.all')));
    final picker = source
        .split('class _ResourcePickerCard ')
        .last
        .split('class _ResourceBadge ')
        .first;
    expect(picker, isNot(contains('chevron_right')));
    expect(picker, contains('if (selected)'));
  });
}
