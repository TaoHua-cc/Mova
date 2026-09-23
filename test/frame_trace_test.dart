import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/diagnostics/frame_trace.dart';

import 'dart:io';

/// 合成一帧：`buildMs` 记在 build 阶段，`rasterMs` 记在 raster 阶段，
/// `totalSpan` 正好是两者之和（与真实帧的构成一致）。
FrameTiming frame({double buildMs = 1, double rasterMs = 1}) => FrameTiming(
  vsyncStart: 0,
  buildStart: 0,
  buildFinish: (buildMs * 1000).round(),
  rasterStart: (buildMs * 1000).round(),
  rasterFinish: ((buildMs + rasterMs) * 1000).round(),
  rasterFinishWallTime: 0,
);

void main() {
  test('scroll trace driver uses elapsed time from its actual start', () {
    final source = File('lib/src/diagnostics/frame_trace.dart')
        .readAsStringSync();
    expect(source, contains('elapsedMilliseconds ?? startMs) - startMs'));
    expect(source, isNot(contains(') - startMs + 0.0')));
    expect(source, contains("parts[3] == 'roundtrip'"));
    expect(source, contains('final frameMs = (elapsedMs - previousElapsedMs)'));
    expect(source, isNot(contains('while (sent < due)')));
  });
  test('默认关闭：未设置 MOVA_TRACE_FRAMES 时不启用、不建文件、不抛异常', () {
    // 测试环境里不会带这个变量；安装应当是彻底的空操作。
    expect(FrameTrace.enabled, isFalse);
    expect(() => FrameTrace.install(), returnsNormally);
    expect(FrameTrace.enabled, isFalse);
  });

  test('诊断用的玻璃模糊覆盖值：未设置时回落到偏好', () {
    expect(FrameTrace.glassBlurOverride, isNull);
  });

  test('fps 按窗口时长算：用累计时间会把第二个窗口的 fps 报小一个数量级', () {
    // 每个窗口都恰好隔 1 秒；用累计时间算时 wall=12s 会被除成 12 秒。
    expect(FrameTrace.windowSeconds(1000, 0), 1);
    expect(FrameTrace.windowSeconds(12000, 11000), 1);
    // 时钟没走或倒退时不能除零。
    expect(FrameTrace.windowSeconds(1000, 1000), 1);
  });

  test('summarize 按面板周期算预算，并数出超预算的帧', () {
    final line = FrameTrace.summarize(
      index: 3,
      wallMs: 3000,
      seconds: 1,
      // 170Hz 的面板周期是 5.882ms：前三帧余量充足，后两帧 build 超预算。
      frames: [
        frame(buildMs: 1.0, rasterMs: 1.0),
        frame(buildMs: 2.0, rasterMs: 2.0),
        frame(buildMs: 3.0, rasterMs: 2.0),
        frame(buildMs: 9.0, rasterMs: 2.0),
        frame(buildMs: 1.0, rasterMs: 7.5),
      ],
      refreshHz: 170,
      scrollDepth: 0.5,
    );

    expect(line, startsWith('FRAMES window=3 wall=3000 n=5 '));
    expect(line, contains('fps=5.0'));
    expect(line, contains('budget=5.882'));
    // 排序后 build 序列为 1,1,2,3,9：中位数 2，p95 落在末位 9。
    expect(line, contains('build_p50=2.00'));
    expect(line, contains('build_max=9.00'));
    expect(line, contains('raster_max=7.50'));
    // 两帧超预算：一帧 by build（9ms），一帧 by raster（7.5ms）。
    expect(line, contains('slow_build=1 slow_raster=1'));
    expect(line, contains('depth=0.500'));
  });

  test('summarize 带上滚动位置，供区分「在滚」与「没滚却还在出帧」', () {
    final line = FrameTrace.summarize(
      index: 1,
      wallMs: 2000,
      seconds: 1,
      frames: [frame()],
      refreshHz: 170,
      scrollDepth: 1,
      scrollPixels: 1234.5,
      scrollMax: 9999.0,
    );
    expect(line, contains('pos=1234.5 max=9999.0'));
  });

  test('玻璃归因开关：未设置时一律不跳过（生产路径零影响）', () {
    expect(FrameTrace.skipGlass('shell'), isFalse);
    expect(FrameTrace.skipGlass('frost'), isFalse);
    expect(FrameTrace.skipGlass('glass'), isFalse);
    expect(FrameTrace.skipGlass('circle'), isFalse);
    expect(FrameTrace.skipGlass('rect'), isFalse);
  });

  test('玻璃归因开关：按分区名命中，大小写与空格不敏感，all 覆盖全部', () {
    expect(FrameTrace.parseGlassSkips(null), isEmpty);
    expect(FrameTrace.parseGlassSkips('  '), isEmpty);
    // 空项（连续逗号 / 收尾逗号）不能让集合里混进空字符串。
    expect(FrameTrace.parseGlassSkips('shell,,items,'), {'shell', 'items'});
    expect(FrameTrace.parseGlassSkips(' Shell , FROST '), {'shell', 'frost'});
    expect(FrameTrace.parseGlassSkips('circle,rect'), {'circle', 'rect'});
    expect(FrameTrace.parseGlassSkips('all'), {'all'});
  });

  test('描边环开关：候选值固定，未设置时回落到生产默认（方案 B）', () {
    // 这一族取值会被 brand.dart 的绘制器直接分支，集合变动等于外观变动。
    // `linear` 是回到 3.1.112 旧现状的回归对照；生产默认（null）是按角度定值的
    // 「角度均匀 + 左上受光」。
    expect(FrameTrace.edgePlans, {'linear', 'const', 'none'});
    // 测试进程不设置 MOVA_TRACE_EDGE，因此必须回落到 null（= 生产默认）。
    expect(FrameTrace.edgePlan, isNull);
    // 默认必须落在 sweep 分支上（而不是旧现状的 linear 分支），且必须带 `circle`
    // 条件 —— 否则直边卡片会被一起切成 sweep。
    final brand = File('lib/src/brand.dart').readAsStringSync();
    expect(brand, contains('final sweep = circle && plan == null;'));
    // 不留死同义词：`cosine` 曾经与默认同义，实施默认后必须从绘制器里消失。
    expect(brand, isNot(contains("'cosine'")));
  });

  test('summarize 对空窗口不崩且 fps 归零', () {
    final line = FrameTrace.summarize(
      index: 0,
      wallMs: 1000,
      seconds: 1,
      frames: const <FrameTiming>[],
      refreshHz: 0,
      scrollDepth: 0,
    );
    expect(line, contains('n=0'));
    expect(line, contains('fps=0.0'));
    // refreshHz 拿不到时退回 60Hz 预算，不出现除零。
    expect(line, contains('budget=16.667'));
    expect(line, contains('slow_build=0 slow_raster=0'));
  });
}
