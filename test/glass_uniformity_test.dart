import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

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

  test('native glass panel routes secondary text through contrast outline', () {
    final native = File('windows/native_player/main.cpp').readAsStringSync();
    expect(native, contains('constexpr float outline = 0.7f;'));
    expect(
      RegExp(r'DrawGlassText\(graphics, item\.detail\.c_str\(\)')
          .allMatches(native)
          .length,
      greaterThanOrEqualTo(2),
    );
    expect(
      native,
      contains('DrawGlassText(graphics, item.label.c_str(), skin.note'),
    );
  });

  test('shared glass keeps readable contrast over bright artwork', () {
    expect(YingjiGlass.surface().a, inInclusiveRange(.07, .18));
    expect(YingjiGlass.chrome().a, inInclusiveRange(.11, .24));
    expect(YingjiGlass.hud().a, inInclusiveRange(.14, .30));
    expect(YingjiGlass.vibrancy, inInclusiveRange(1.2, 1.5));
  });

  test('shared glass edge stays aligned to physical pixels', () {
    final brand = File('lib/src/brand.dart').readAsStringSync();
    final shell = File('lib/src/media_center.dart').readAsStringSync();
    // 环宽按**物理像素**换算（口径），不锁具体数值：3.1.112 把它从 1 提到 1.5 时
    // 这条断言没跟上，测试一直是红的。断言口径才不会被观感调整打破。
    expect(brand, contains(RegExp(r'strokeWidth = [^;\n]*/ devicePixelRatio')));
    expect(brand, contains('..isAntiAlias = true'));
    expect(brand, contains('scale: _pressed ? MovaMotion.pressScaleIcon : 1'));
    expect(
      shell,
      isNot(contains('color: Colors.black.withValues(alpha: .58)')),
    );
  });

  test('selected controls share a glossy pearl theme', () {
    final brand = File('lib/src/brand.dart').readAsStringSync();
    final selected = brand.substring(
      brand.indexOf('child: widget.selected'),
      brand.indexOf('Center(', brand.indexOf('child: widget.selected')),
    );
    expect(brand, contains('static const Color accent = Color(0xFFF3F4F7)'));
    expect(selected, contains('LinearGradient'));
    expect(selected, contains('RadialGradient'));
    expect(selected, contains('Color(0x36D5DEE9)'));
    expect(selected, isNot(contains('Color(0x48D99A68)')));
    expect(brand, contains('Colors.white.withValues(alpha: .92)'));
    expect(brand, contains('const Color(0xFF111824)'));
  });

  test('player dock draws a full-bleed progress bar without a backdrop plate', () {
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
    // 顶栏与控制条是独立 layered window，采样前必须同步各自的屏幕原点；
    // 否则会从视频错误位置取色，中央按钮就会整排漂成灰白色。
    expect(native, contains('void SyncGlassWindowOrigin(HWND window)'));
    expect(
      RegExp(r'SyncGlassWindowOrigin\(window\);').allMatches(native).length,
      greaterThanOrEqualTo(2),
    );
    expect(native, contains('(g_controls && IsWindowVisible(g_controls))'));
    expect(native, contains('(g_top_bar && IsWindowVisible(g_top_bar))'));
    // 中央播放键和失败后的重播入口也必须取实时背板，不能各自画实心圆或静态渐变。
    expect(native, contains('FillGlassSurface(graphics, play_path'));
    expect(native, contains('FillGlassSurface(graphics, replay_path'));
    expect(
      native,
      isNot(
        matches(
          RegExp(
            r'graphics\.FillEllipse\(\s*&white,\s*Gdiplus::RectF\(center - 24',
          ),
        ),
      ),
    );
    // 背景通过路径抗锯齿填充，避免图片硬裁切与播放键重叠光圈。
    expect(native, contains('graphics.FillPath(&backdrop, &path)'));
    expect(native, isNot(contains('const float glow_size')));
    // 原生降采样已经自带低通，不能再按完整 DPI 强度把视频颜色洗成灰块。
    expect(native, contains('g_glass_blur.load() * 0.55'));
    // 弹幕和 mpv 字幕都要避开播放器自己的顶部、底部控制区域。
    expect(native, contains('origin.y + safe_top'));
    expect(native, contains('SetOption(g_handle, "sub-pos", "84")'));
    // 截图和模糊在后台连续产帧，UI 帧循环只消费完成帧，不能再同步调用采集。
    expect(native, contains('std::thread glass_backdrop'));
    expect(
      native,
      contains('constexpr ULONGLONG kGlassBackdropRefreshMs = 16;'),
    );
    expect(native, contains('constexpr int kGlassDownscale = 6;'));
    expect(native, contains('Sleep(1);'));
    expect(native, contains('bool CaptureGlassLayer('));
    expect(native, isNot(contains('HDC screen = GetDC(nullptr);')));
    expect(native, contains('const std::array<HWND, 4> windows'));
    expect(native, contains('PrintWindow(g_window'));
    expect(native, contains('g_backdrop.captured_at.load()'));
    expect(
      RegExp(r'UpdateGlassBackdrop\(false\);').allMatches(native).length,
      1,
    );
  });
}
