import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

/// 首页浮动导航和详情页顶栏按钮共用尺寸。
///
/// 背景：详情页曾经写死 `size: 44`，首页走 `YingjiMotionIconButton` 的默认 46。
/// 只差 4%，但 `Iconsax.box` 这类实心字形的分面缝只有 ~0.9 物理像素，这点差值
/// 足以把缝的相位推到阈值另一侧 —— 同一份绘制代码，两页看起来不一样。
void main() {
  /// 按大括号配对切出一个 class 的主体，避免用懒匹配正则误伤后续内容。
  String classBody(String source, String className) {
    final start = source.indexOf('class $className');
    expect(start, isNonNegative, reason: '没找到 $className');
    final open = source.indexOf('{', start);
    var depth = 0;
    for (var i = open; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}') {
        depth--;
        if (depth == 0) return source.substring(open, i + 1);
      }
    }
    throw StateError('$className 的大括号不配对');
  }

  test('首页导航与详情顶栏的按钮尺寸来自同一个常量', () {
    final home = classBody(
      File('lib/src/media_center.dart').readAsStringSync(),
      '_FloatingRailButton',
    );
    final detail = classBody(
      File('lib/src/metadata/metadata_detail_page.dart').readAsStringSync(),
      '_DetailRailButton',
    );
    for (final (name, body) in [
      ('_FloatingRailButton', home),
      ('_DetailRailButton', detail),
    ]) {
      expect(
        body,
        contains('size: YingjiLayout.railButtonSize'),
        reason: '$name 必须引用共享常量，否则两页的图标会再次落到不同像素相位上',
      );
      expect(
        RegExp(r'size:\s*\d').hasMatch(body),
        isFalse,
        reason: '$name 里不允许出现写死的尺寸数字（历史 bug：详情页写死 44、首页默认 46）',
      );
    }
  });

  test('共享尺寸常量满足首页导航槽位的宽度约束', () {
    expect(YingjiLayout.railButtonSize, lessThanOrEqualTo(44));
    expect(
      YingjiLayout.railWidth,
      greaterThanOrEqualTo(YingjiLayout.railButtonSize),
    );
  });

  test('图标尺寸只由按钮尺寸推导，绘制器里不再有第二处尺寸来源', () {
    final brand = File('lib/src/brand.dart').readAsStringSync();
    final iconButton = classBody(brand, 'YingjiMotionIconButton');
    expect(iconButton, contains('this.size = 46'));
    // 图标尺寸是 `widget.size * .43`：只要两处传同一个 size，图标就必然一致。
    expect(brand, contains('size: widget.size * .43'));
  });
}
