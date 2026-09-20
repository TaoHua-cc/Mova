import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「液态玻璃保持一致」这条要求没法用截图断言，但它的**结构性前提**可以：
///
/// 1. 全站只有一条悬浮提示实现（都在 brand.dart 里）；
/// 2. 详情页背景和首页共用同一个滚动深度算法，且是「清晰层 + 模糊层」叠加；
/// 3. 原生播放器的玻璃浓度由应用侧下发的 `mova-glass-blur` 驱动。
///
/// 任何一条被破坏，用户看到的就是「有的地方是玻璃、有的地方还是黑块」。
void main() {
  List<File> dartFiles() =>
      Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList(growable: false);

  test('every hover tooltip goes through the shared glass shell', () {
    // 之前只有「简介」那处用了玻璃色底，剧集行 / 评分 / 人物卡 / 片单还在用
    // Material 默认的深灰方块 —— 用户报的「鼠标悬浮的简介文字没有统一」。
    final offenders = <String>[];
    for (final file in dartFiles()) {
      if (file.path.endsWith('brand.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (RegExp(r'(?<![A-Za-z_])Tooltip\(').hasMatch(lines[i])) {
          offenders.add('${file.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '悬浮提示必须统一走 YingjiGlassTooltip（液态玻璃，且跟随外观里的模糊程度）：\n'
          '${offenders.join('\n')}',
    );
  });

  test('detail page blurs its backdrop from scroll depth, not up front', () {
    final detail = File('lib/src/metadata/metadata_detail_page.dart')
        .readAsStringSync();
    // 「进入最上面是清晰的，下滑模糊」= 清晰层 + 按滚动深度渐显的模糊层，
    // 两层的 key 前缀是这套叠法的标志。
    expect(detail, contains('yingjiScrollDepth'));
    expect(detail, contains('detail-clear-'));
    expect(detail, contains('detail-blur-'));
    // 模糊层的不透明度必须由深度驱动，不能再是一个常量。
    expect(detail, contains('opacity: depth'));
  });

  test('home and detail page share one scroll depth curve', () {
    final shell = File('lib/src/media_center.dart').readAsStringSync();
    final brand = File('lib/src/brand.dart').readAsStringSync();
    expect(shell, contains('yingjiScrollDepth(position)'));
    expect(
      brand,
      contains('double yingjiScrollDepth(ScrollPosition position)'),
    );
  });

  test('native player glass follows the appearance blur setting', () {
    // 应用侧下发 + 原生侧白名单 + 原生侧真的用这个值换算玻璃浓度。
    final dart = File('lib/src/player/windows_native_player.dart')
        .readAsStringSync();
    final settings = File('lib/src/media_center.dart').readAsStringSync();
    final native = File('windows/native_player/main.cpp').readAsStringSync();
    expect(dart, contains("'mova-glass-blur'"));
    expect(dart, contains('--mova-glass-blur='));
    expect(settings, contains("'yingji.appearance.glass-blur'"));
    expect(native, contains('"mova-glass-blur"'));
    expect(native, contains('float GlassLevel()'));
    expect(native, contains('g_glass_blur'));
  });

  test(
    'player dock draws a full-bleed progress bar without a backdrop plate',
    () {
      final native = File('windows/native_player/main.cpp').readAsStringSync();
      // 进度条通屏：从 0 画到窗口宽度。
      expect(
        native,
        contains('graphics.DrawLine(&track, 0.0f, kSeekLineY, width'),
      );
      // 控件条铺满整个客户区宽度（不再是居中 1040）。
      expect(native, contains('std::max(240, client_width)'));
      // 没有那道 10→124 的整块压暗（用户看到的「控件背景框」）。
      expect(native, isNot(contains('Gdiplus::Color(124, 6, 7, 10)')));
      // 按钮底是常驻的玻璃圆片。
      expect(native, contains('GlassDiscAlpha'));
    },
  );
}
