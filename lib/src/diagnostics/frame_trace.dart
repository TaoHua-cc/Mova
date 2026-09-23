import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 逐帧耗时诊断：**只在显式设置环境变量时启用**。
///
/// 默认运行时这个类不注册任何回调、不打开文件、不打印任何内容，行为与没有它
/// 完全一致。四个环境变量（都只在桌面端有意义）：
///
/// - `MOVA_TRACE_FRAMES=<文件路径>`：开启记录，按秒聚合一行 `FRAMES ...`。
/// - `MOVA_TRACE_SCROLL=<延迟ms>:<时长ms>[:<像素/秒>]`：按固定节拍合成滚轮事件，
///   用可复现的方式驱动一次平滑滚动（默认 `6000:8000:1400`）。不设置就只是
///   记录手动滚动时的帧耗时。
/// - `MOVA_TRACE_BLUR=<0..40>`：诊断用，覆盖玻璃模糊半径，用于归因实验
///   （只影响本次运行，不写偏好）。见 [glassBlurOverride]。
/// - `MOVA_TRACE_GLASS_SKIP=<分区[,分区]>`：诊断用，**整条**跳过某处离屏模糊通道
///   （不是把 sigma 归零 —— 归零仍会插一层离屏 layer，测不出通道本身的代价）。
///   分区名：`shell`（壳层整屏背板模糊）、`clear`（壳层整屏清晰背板）、
///   `frost`（`_FrostSurface` 的背板模糊）、`glass`（`YingjiGlassSurface` 的背板
///   模糊）、`circle`/`rect`（只跳过圆形 / 非圆形的 `YingjiGlassSurface`）、
///   `all`（以上全部跳过）。用来把「模糊」的账分到具体某一处，见 [skipGlass]。
/// - `MOVA_TRACE_EDGE=<linear|const|none>`：诊断用，覆盖**圆形**玻璃的描边环画法
///   （见 [edgePlan]）。不设置时是生产默认的「角度均匀 + 左上受光」。只影响圆形：
///   直边（卡片 / 面板）上的线性渐变在几何上是正确的，任何情况下都不动。
///
/// ### `FRAMES` 行长（字段稳定，改动要同步 `tool/analyze_frame_trace.py`）
///
/// ```text
/// FRAMES window=<i> wall=<ms> n=<帧数> fps=<帧数/秒> budget=<ms>
///   build_avg= build_p50= build_p95= build_max=
///   raster_avg= raster_p50= raster_p95= raster_max=
///   span_p95= span_max= slow_build=<n> slow_raster=<n> depth=<0..1>
///   pos=<滚动像素> max=<可滚总长>
/// ```
///
/// 「慢帧」定义：`build` 或 `raster` 超过一个面板刷新周期（`budget`）。在
/// 170Hz 面板上 budget 约 5.88ms —— 这是弹幕 / 滚动掉帧的判据基准。
abstract final class FrameTrace {
  static const String _framesVar = 'MOVA_TRACE_FRAMES';
  static const String _scrollVar = 'MOVA_TRACE_SCROLL';
  static const String _blurVar = 'MOVA_TRACE_BLUR';
  static const String _glassSkipVar = 'MOVA_TRACE_GLASS_SKIP';

  static Set<String>? _glassSkips;

  static const String _edgeVar = 'MOVA_TRACE_EDGE';

  /// 描边环画法的候选值。
  ///
  /// `linear` / `const` / `none` 都只是**诊断对照**：生产默认（开关未设置）是
  /// 「按角度定值 + 保留左上受光」。`linear` 可以回到 3.1.112 的线性渐变做观感
  /// 回归，`none` 是「整条去掉」，供方案 C 的前半做观感对照。
  static const Set<String> edgePlans = <String>{'linear', 'const', 'none'};

  static String? _edgePlan;
  static bool _edgePlanRead = false;

  static File? _file;
  static Stopwatch? _clock;
  static final List<FrameTiming> _window = <FrameTiming>[];
  static int _windowIndex = 0;
  static int _lastWallMs = 0;
  static ValueListenable<double>? _scrollDepth;
  static ScrollController? _scrollController;

  /// 诊断是否已启用。生产路径上恒为 false。
  static bool get enabled => _file != null;

  /// 由 `YingjiSmoothWheel` 在挂载时登记它驱动的滚动控制器。
  ///
  /// 每行 `FRAMES` 会带上 `pos=` / `max=`：滚动停了却还在出帧（`pos` 不变而帧数
  /// 很高）说明是**别的**东西在持续重绘，与「还在滚」是两回事。
  static void attachScrollController(ScrollController controller) {
    if (!enabled) return;
    _scrollController ??= controller;
  }

  static void detachScrollController(ScrollController controller) {
    if (identical(_scrollController, controller)) _scrollController = null;
  }

  /// 诊断用的玻璃模糊半径覆盖值；未设置时为 null（调用方应回落到偏好值）。
  static double? get glassBlurOverride {
    final raw = Platform.environment[_blurVar]?.trim();
    if (raw == null || raw.isEmpty) return null;
    final value = double.tryParse(raw);
    if (value == null) return null;
    return value.clamp(0, 40);
  }

  /// 归因用的「玻璃分区」开关：命中的分区会**整条**不画，用于把每帧的离屏
  /// 模糊开销分到具体某一处。生产路径上恒为 false（不设置环境变量时集合为空）。
  ///
  /// 与 [glassBlurOverride] 的区别是根本性的：把 sigma 调成 0 只是让模糊核变成
  /// 恒等，`ImageFilterLayer` / `BackdropFilter` 该插的离屏 layer、该做的一次全屏
  /// 回读**照样发生**，所以量出来的差值只是「高斯核」的钱，不是「这条路」的钱。
  static bool skipGlass(String part) {
    final skips = _glassSkips ??= parseGlassSkips(
      Platform.environment[_glassSkipVar],
    );
    if (skips.isEmpty) return false;
    return skips.contains('all') || skips.contains(part);
  }

  /// 解析 `MOVA_TRACE_GLASS_SKIP`；大小写不敏感，允许空格。纯函数，便于单测。
  @visibleForTesting
  static Set<String> parseGlassSkips(String? raw) {
    final text = raw?.trim();
    if (text == null || text.isEmpty) return const <String>{};
    return text
        .split(',')
        .map((part) => part.trim().toLowerCase())
        .where((part) => part.isNotEmpty)
        .toSet();
  }

  /// `MOVA_TRACE_EDGE`：覆盖**圆形**玻璃描边环的画法，供真机观感比对。
  ///
  /// 取值（[edgePlans]）：
  /// - `linear`：回到 3.1.112 的线性渐变环 —— 等 α 线是**弦**，同一条等 α 线在
  ///   不同方位扫过的弧长不同，亮度绕圈极差 2.91×，看起来就是「锯齿感」。
  /// - `const`：环改成**常量白**（α .34）—— 亮度完全不随角度变化。
  /// - `none`：整条环不画（方案 C 的前半）。
  ///
  /// 未设置 / 无法识别 → null，即**生产默认**：α = .34 ± .16·cos(θ − 225°)，
  /// 角度均匀但保留「左上受光」的方向感。环宽始终 1.5 物理像素，不随开关变化。
  ///
  /// ⚠️ 这里必须缓存：`_YingjiGlassEdgePainter.paint` **每一帧**都会问一次，而
  /// `Platform.environment` 在 Windows 上是一次 `GetEnvironmentStrings` 调用，
  /// 放在绘制路径上代价可观。第一帧读一次，之后只读静态字段。
  static String? get edgePlan {
    if (_edgePlanRead) return _edgePlan;
    _edgePlanRead = true;
    final raw = Platform.environment[_edgeVar]?.trim().toLowerCase();
    _edgePlan = (raw != null && edgePlans.contains(raw)) ? raw : null;
    return _edgePlan;
  }

  /// 在 `runApp` 之前调用。未设置 `MOVA_TRACE_FRAMES` 时立刻返回。
  ///
  /// [scrollDepth] 用于在每行结尾记录当前滚动深度（首页的
  /// `yingjiHomeScrollDepth`），用来把帧耗时与滚动位置对齐。
  static void install({ValueListenable<double>? scrollDepth}) {
    final path = Platform.environment[_framesVar]?.trim();
    if (path == null || path.isEmpty || _file != null) return;
    final file = File(path);
    try {
      file.parent.createSync(recursive: true);
      // 先探一次写权限，免得跑到一半才发现写不出去。
      file.writeAsStringSync('', mode: FileMode.append, flush: true);
    } on FileSystemException {
      // 诊断写不出去不该影响应用启动：静默放弃。
      return;
    }
    _file = file;
    _scrollDepth = scrollDepth;
    _clock = Stopwatch()..start();
    final view = PlatformDispatcher.instance.views.isEmpty
        ? null
        : PlatformDispatcher.instance.views.first;
    final size = view == null
        ? null
        : view.physicalSize / view.devicePixelRatio;
    final skips = _glassSkips ??= parseGlassSkips(
      Platform.environment[_glassSkipVar],
    );
    _write(
      'FRAMETRACE start view=${size == null ? '?' : '${size.width.toInt()}x${size.height.toInt()}'}'
      ' dpr=${view?.devicePixelRatio ?? 0}'
      ' refresh=${view?.display.refreshRate.toStringAsFixed(3) ?? '?'}'
      ' blur=${glassBlurOverride ?? 'pref'}'
      ' glass_skip=${skips.isEmpty ? '-' : skips.join('+')}',
    );
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    // 进程存活期间一直按秒聚合；不需要保留句柄来取消（install 只会走一次）。
    Timer.periodic(const Duration(seconds: 1), (_) => _emitWindow());
    _startScrollDriver();
  }

  static void _onTimings(List<FrameTiming> timings) => _window.addAll(timings);

  static void _emitWindow() {
    final clock = _clock;
    if (clock == null || _window.isEmpty) return;
    final view = PlatformDispatcher.instance.views.isEmpty
        ? null
        : PlatformDispatcher.instance.views.first;
    final wallMs = clock.elapsedMilliseconds;
    // fps 必须按**本窗口时长**算：用累计时间会让第二个窗口之后的数值一路变小。
    final seconds = windowSeconds(wallMs, _lastWallMs);
    _lastWallMs = wallMs;
    final controller = _scrollController;
    final scroll = controller != null && controller.hasClients
        ? controller.position
        : null;
    _write(
      summarize(
        index: _windowIndex++,
        wallMs: wallMs,
        seconds: seconds,
        frames: List<FrameTiming>.unmodifiable(_window),
        refreshHz: view?.display.refreshRate ?? 60,
        scrollDepth: _scrollDepth?.value ?? 0,
        scrollPixels: scroll?.pixels ?? 0,
        scrollMax: scroll?.maxScrollExtent ?? 0,
      ),
    );
    _window.clear();
  }

  /// 本窗口时长（秒）。**必须**用相邻两次 `wall` 之差来算。
  ///
  /// 初版用的是自安装以来的累计毫秒，于是第二个窗口起 fps 一路变小 ——
  /// 114 帧挤在 1 秒里被报成 `fps=5.9`（除以了 19 秒），差点把结论带偏。
  @visibleForTesting
  static double windowSeconds(int wallMs, int previousWallMs) {
    final delta = wallMs - previousWallMs;
    return delta > 0 ? delta / 1000 : 1;
  }

  /// 把一批帧耗时聚合成一行 `FRAMES ...`。纯函数，便于单测。
  @visibleForTesting
  static String summarize({
    required int index,
    required int wallMs,
    required double seconds,
    required List<FrameTiming> frames,
    required double refreshHz,
    required double scrollDepth,
    double scrollPixels = 0,
    double scrollMax = 0,
  }) {
    final budget = refreshHz > 0 ? 1000 / refreshHz : 1000 / 60;
    final build = <double>[];
    final raster = <double>[];
    final span = <double>[];
    var slowBuild = 0;
    var slowRaster = 0;
    for (final frame in frames) {
      final b = frame.buildDuration.inMicroseconds / 1000;
      final r = frame.rasterDuration.inMicroseconds / 1000;
      build.add(b);
      raster.add(r);
      span.add(frame.totalSpan.inMicroseconds / 1000);
      if (b > budget) slowBuild++;
      if (r > budget) slowRaster++;
    }
    build.sort();
    raster.sort();
    span.sort();
    final fps = seconds > 0 ? frames.length / seconds : 0.0;
    return 'FRAMES window=$index wall=$wallMs n=${frames.length}'
        ' fps=${fps.toStringAsFixed(1)} budget=${budget.toStringAsFixed(3)}'
        ' build_avg=${_avg(build).toStringAsFixed(2)}'
        ' build_p50=${_pct(build, .5).toStringAsFixed(2)}'
        ' build_p95=${_pct(build, .95).toStringAsFixed(2)}'
        ' build_max=${_max(build).toStringAsFixed(2)}'
        ' raster_avg=${_avg(raster).toStringAsFixed(2)}'
        ' raster_p50=${_pct(raster, .5).toStringAsFixed(2)}'
        ' raster_p95=${_pct(raster, .95).toStringAsFixed(2)}'
        ' raster_max=${_max(raster).toStringAsFixed(2)}'
        ' span_p95=${_pct(span, .95).toStringAsFixed(2)}'
        ' span_max=${_max(span).toStringAsFixed(2)}'
        ' slow_build=$slowBuild slow_raster=$slowRaster'
        ' depth=${scrollDepth.toStringAsFixed(3)}'
        ' pos=${scrollPixels.toStringAsFixed(1)}'
        ' max=${scrollMax.toStringAsFixed(1)}';
  }

  static double _avg(List<double> sorted) {
    if (sorted.isEmpty) return 0;
    var sum = 0.0;
    for (final value in sorted) {
      sum += value;
    }
    return sum / sorted.length;
  }

  static double _pct(List<double> sorted, double fraction) {
    if (sorted.isEmpty) return 0;
    final index = ((sorted.length - 1) * fraction).round();
    return sorted[index];
  }

  /// 已排序序列的最大值；空窗口（一两秒内一帧都没出）时归零。
  static double _max(List<double> sorted) => sorted.isEmpty ? 0 : sorted.last;

  /// 合成滚轮事件驱动一次平滑滚动，让「同一段路径」可以在不同构建之间复现对比。
  static void _startScrollDriver() {
    final spec = Platform.environment[_scrollVar]?.trim();
    if (spec == null || spec.isEmpty) return;
    final parts = spec.split(':');
    final delayMs = int.tryParse(parts[0]) ?? 6000;
    final durationMs = parts.length > 1
        ? (int.tryParse(parts[1]) ?? 8000)
        : 8000;
    final speed = parts.length > 2 ? (double.tryParse(parts[2]) ?? 1400) : 1400;
    final roundTrip = parts.length > 3 && parts[3] == 'roundtrip';
    Timer(Duration(milliseconds: delayMs), () {
      final binding = SchedulerBinding.instance;
      final view = PlatformDispatcher.instance.views.isEmpty
          ? null
          : PlatformDispatcher.instance.views.first;
      if (view == null) return;
      final size = view.physicalSize / view.devicePixelRatio;
      // 落在正文区中间：避开左侧导航条与右侧滚动提示，且必定在首页列表之上。
      final target = Offset(size.width * .5, size.height * .55);
      const device = 99;
      final clock = _clock;
      final startMs = clock?.elapsedMilliseconds ?? 0;
      var previousElapsedMs = 0;
      var sent = 0;
      _write(
        'SCROLLDRIVE state=start delay=$delayMs duration=$durationMs'
        ' pxPerSec=$speed roundTrip=$roundTrip'
        ' at=${target.dx.toInt()},${target.dy.toInt()}',
      );
      void pump(Duration _) {
        final elapsedMs = (clock?.elapsedMilliseconds ?? startMs) - startMs;
        if (elapsedMs >= durationMs) {
          _write('SCROLLDRIVE state=stop sent=$sent');
          return;
        }
        // 每个真实渲染帧只发一个滚轮事件。旧实现按 8ms 补发“欠下”的事件，
        // 一旦有慢帧就会在下一帧 while 补几十个输入，制造真实鼠标不可能产生的
        // 事件风暴，并把采样工具自身误判成页面卡顿。
        final frameMs = (elapsedMs - previousElapsedMs).clamp(0, 50);
        previousElapsedMs = elapsedMs;
        sent++;
        GestureBinding.instance.handlePointerEvent(
          PointerScrollEvent(
            viewId: view.viewId,
            timeStamp: Duration(milliseconds: elapsedMs),
            device: device,
            kind: PointerDeviceKind.mouse,
            position: target,
            scrollDelta: Offset(
              0,
              speed *
                  frameMs /
                  1000 *
                  (roundTrip && elapsedMs >= durationMs / 2 ? -1 : 1),
            ),
          ),
        );
        binding.scheduleFrameCallback(pump);
      }

      binding.scheduleFrameCallback(pump);
    });
  }

  /// 同步追加一行。
  ///
  /// 不要改回 `openWrite` + `writeln` + `flush`：`IOSink` 在 flush 未完成时再来一次
  /// 写会抛 `Bad state: StreamSink is bound to a stream`，而异常发生在 Timer 回调里，
  /// 表现为**窗口记录整段消失**（实测：滚动一开始就再也写不出 `FRAMES` 行，
  /// 只剩驱动行），却完全不报错到日记文件上。诊断每秒只写一行，同步写没有代价。
  static void _write(String line) {
    final file = _file;
    if (file == null) return;
    try {
      file.writeAsStringSync('$line\n', mode: FileMode.append);
    } on FileSystemException {
      // 写不出去就静默放弃，绝不影响应用运行。
    }
  }
}
