import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/metadata/metadata_detail_page.dart';

void main() {
  test('episode progress clocks preserve seconds and hour boundaries', () {
    expect(episodeProgressTime(const Duration(milliseconds: 1609200)), '26:49');
    expect(episodeProgressTime(const Duration(seconds: 3601)), '1:00:01');
    expect(episodeProgressTime(const Duration(seconds: -1)), '00:00');
  });
  test('episode previews use saved timings before metadata estimates', () {
    final source = File('lib/src/metadata/metadata_detail_page.dart')
        .readAsStringSync();
    expect(source, contains('final exact = watch?.position ?? position'));
    expect(source, contains('_episodeWatchHistory = history'));
    expect(source, contains('widget.timings[_episodeKey('));
  });
}
