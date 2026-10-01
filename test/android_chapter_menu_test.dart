import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

void main() {
  test('chapters share segment menu with no separate configured button', () {
    expect(YingjiPlayerTools.contains('章节'), isFalse);
    expect(YingjiPlayerTools.contains('片头片尾'), isTrue);
    final source = File('lib/src/player/player_page.dart').readAsStringSync();
    final start = source.indexOf("case '章节':");
    final end = source.indexOf("case '资源':", start);
    final menu = source.substring(start, end);
    expect(menu, contains("case '片头片尾':"));
    expect(menu, contains('_segmentPanel()'));
    expect(menu, contains('_chapterGroup()'));
    expect(menu, contains('当前媒体未提供章节信息'));
    expect(source, contains('onTap: () => _seek(chapter.start)'));
  });
}
