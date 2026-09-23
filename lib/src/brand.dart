// ignore_for_file: constant_identifier_names

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import 'diagnostics/frame_trace.dart';
import 'platform/window_host.dart';
import 'motion.dart';

/// 桌面端把滚轮交给 [YingjiSmoothWheel] 接管，移动端保留原生触摸滚动。
///
/// 这是 [YingjiSmoothWheel] 能生效的前提：内层滚动视图若保留了可滚动的
/// physics，它的 `Scrollable` 会先一步消费掉滚轮事件，平滑动画永远不会触发。
ScrollPhysics? get yingjiWheelPhysics =>
    WindowHost.isDesktop ? const NeverScrollableScrollPhysics() : null;

/// Windows/Impeller 在滚动中重复读取整屏背板的代价远高于静止合成。滚轮滑行时
/// 暂停玻璃采样，材质底色与边缘仍保留；停稳后下一帧恢复真实模糊。
final yingjiScrollInProgress = ValueNotifier<bool>(false);

/// 把鼠标滚轮的离散刻度，换成一段连续、可被下一次滚动接续的平滑位移。
///
/// 落点由滚轮增量累加得出，每一帧再用与帧率无关的指数收敛去追赶它：快速连续
/// 滚动会合成一次滑行，而不是一格一格地跳；松手后速度自然衰减到静止，不会在
/// 每个刻度末尾停顿。`controller` 始终是唯一真相，因此滚动条与程序化定位都不
/// 受影响。
///
/// 仅在桌面端生效——移动端保留系统原生的触摸滚动，避免与手指拖拽打架。
class YingjiSmoothWheel extends StatefulWidget {
  const YingjiSmoothWheel({
    super.key,
    required this.controller,
    required this.child,
    this.stepScale = 1.18,
    this.settlePerFrame = .78,
    this.stableGlass = false,
  });

  final ScrollController controller;
  final Widget child;

  /// 一个滚轮刻度折算成的滚动像素倍数。
  final double stepScale;

  /// 每个 60fps 帧之后仍未走完的距离比例；越小越跟手、滑行尾巴越短。
  final double settlePerFrame;

  /// 滚动列表里的玻璃保持轻量静态材质，不在起步/停稳时切换背板滤镜。
  /// 全局滚动信号仍会用于暂停流动背景，避免背景动画与列表同时合成。
  final bool stableGlass;

  @override
  State<YingjiSmoothWheel> createState() => _YingjiSmoothWheelState();
}

class _YingjiSmoothWheelState extends State<YingjiSmoothWheel> {
  /// 滚轮累加出来的落点。
  double _goal = 0;

  /// 已经写入 controller 的位置。
  double _shown = 0;

  /// 上一次由本组件写入的像素值，用来识别外部滚动介入。
  double _written = double.nan;

  Duration _lastFrame = Duration.zero;

  /// 排队中的帧回调；非 null 表示滑行还没结束。这里逐帧调度而不是用 Ticker，
  /// 是为了让 keep-alive 的页面在销毁时不会留下仍被引用的 ticker。
  int? _frame;

  @override
  void initState() {
    super.initState();
    // 只在 `MOVA_TRACE_FRAMES` 诊断开启时登记；否则是个空操作。
    FrameTrace.attachScrollController(widget.controller);
  }

  @override
  void dispose() {
    FrameTrace.detachScrollController(widget.controller);
    _settle();
    super.dispose();
  }

  /// 结束滑行：撤掉排队中的帧，并让下一次滚轮重新对齐到真实位置。
  void _settle() {
    final pending = _frame;
    if (pending != null) {
      WidgetsBinding.instance.cancelFrameCallbackWithId(pending);
      _frame = null;
    }
    _lastFrame = Duration.zero;
    _written = double.nan;
    yingjiScrollInProgress.value = false;
  }

  void _scheduleFrame() {
    _frame = WidgetsBinding.instance.scheduleFrameCallback(_onFrame);
  }

  ScrollPosition? get _position =>
      widget.controller.hasClients ? widget.controller.position : null;

  void _handleWheel(PointerScrollEvent event) {
    // 移动端不接管：内层 Scrollable 会照常处理，这里再动一次就重复滚了。
    if (!WindowHost.isDesktop) return;
    final position = _position;
    if (position == null) return;
    // 横向占优（触控板横滑 / Shift+滚轮）交给内层的横向列表。
    if (event.scrollDelta.dy.abs() <= event.scrollDelta.dx.abs()) return;

    final pixels = position.pixels;
    if (_frame == null || (pixels - _written).abs() > 1) {
      // 上一段滑行已经停稳，或外部（拖拽、程序化定位）动过位置：重新对齐再起步。
      _shown = pixels;
      _goal = pixels;
    }
    _goal = (_goal + event.scrollDelta.dy * widget.stepScale).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    yingjiScrollInProgress.value = true;
    if (_frame == null) {
      _lastFrame = Duration.zero;
      _scheduleFrame();
    }
    // 同一次事件若还嵌着别的可滚动视图，别让它再消费一遍。
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {});
  }

  void _onFrame(Duration elapsed) {
    // 这一帧已经兑现，重新排队前先清空标记。
    _frame = null;
    if (!mounted) return;
    final position = _position;
    if (position == null) {
      _settle();
      return;
    }
    // 拖拽或程序化滚动正在进行：让路，并把落点对齐到真实位置，下一帧再看。
    if ((position.pixels - _written).abs() > 1) {
      _shown = position.pixels;
      _goal = position.pixels;
      _written = position.pixels;
      _lastFrame = elapsed;
      _scheduleFrame();
      return;
    }

    final seconds = _lastFrame == Duration.zero
        ? 1 / 60
        : (elapsed - _lastFrame).inMicroseconds / 1e6;
    _lastFrame = elapsed;
    // 掉帧时钳住步长，避免一帧跨过太远。
    final step = seconds.clamp(1 / 240, 1 / 24);
    // 与帧率无关的指数收敛：60fps 下每帧保留 settlePerFrame。
    final keep = math.pow(widget.settlePerFrame, step * 60).toDouble();
    _shown += (_goal - _shown) * (1 - keep);

    // 剩余距离够小就直接落到位，省掉肉眼看不到的尾巴。
    if ((_goal - _shown).abs() < .35) {
      _commit(position, _goal);
      _settle();
      return;
    }
    _commit(position, _shown);
    _scheduleFrame();
  }

  void _commit(ScrollPosition position, double value) {
    _written = value;
    position.jumpTo(value);
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.stableGlass
        ? YingjiStableScrollGlass(child: widget.child)
        : widget.child;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (!WindowHost.isDesktop) {
          if (notification is ScrollStartNotification) {
            yingjiScrollInProgress.value = true;
          } else if (notification is ScrollEndNotification) {
            yingjiScrollInProgress.value = false;
          }
        }
        return false;
      },
      child: Listener(
        onPointerSignal: (signal) {
          if (signal is PointerScrollEvent) _handleWheel(signal);
        },
        child: child,
      ),
    );
  }
}

class YingjiStableScrollGlass extends InheritedWidget {
  const YingjiStableScrollGlass({super.key, required super.child});

  static bool enabled(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<YingjiStableScrollGlass>() !=
      null;

  @override
  bool updateShouldNotify(YingjiStableScrollGlass oldWidget) => false;
}

class YingjiAppearance extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.dark;
  String iconStyle = 'play';

  /// 全局磨砂玻璃的模糊半径（设备像素）。外观里唯一留给用户的调整项 —— 底色、
  /// 不透明度与色调都固定为中性磨砂，见 [YingjiGlass]。
  /// 液态玻璃默认就要「厚」一点：24 更接近磨砂，30 才看得出玻璃的透光层次。
  /// ⚠️ 这个默认值在 `main.dart` 与设置页各有一份拷贝，改动要三处同步。
  double glassBlur = 30;

  void apply({ThemeMode? themeMode, String? iconStyle, double? glassBlur}) {
    if (themeMode != null) this.themeMode = themeMode;
    if (iconStyle != null) this.iconStyle = iconStyle;
    if (glassBlur != null) this.glassBlur = glassBlur.clamp(0, 40);
    notifyListeners();
  }
}

final yingjiAppearance = YingjiAppearance();
final yingjiBackdropUrl = ValueNotifier<String?>(null);
final yingjiBackdropEffect = ValueNotifier<String>('blur-dissolve');
final yingjiSectionRequest = ValueNotifier<String?>(null);

/// 兼容旧“发现”入口：发现已合并进首页，收到请求时让首页按需挂载榜单。
final yingjiHomeDiscoverTick = ValueNotifier<int>(0);

/// 壳层当前展示的分区（'home' / 'calendar' / 'playlists' / 'sources' / ...）。
///
/// 分区页带上 keep-alive 之后，切回来不会重建，也就不会重跑 initState。片单页
/// 的数据来自本地库，详情页里「加入片单」写的正是它 —— 没有这个信号就会一直
/// 显示旧列表。页面监听它，在被切到时重读一次。
final yingjiSectionFocus = ValueNotifier<String>('home');

/// 「回到顶部」信号：壳层每响应一次左侧导航点击就 +1。
///
/// 这里必须用计数器而不是分区名 —— 重复点击当前分区时
/// [ValueNotifier] 的值没变，不会发出通知，也就无法回到顶部。
/// 分区页监听它，并只在 [yingjiSectionFocus] 与自己相符时滚动。
final yingjiSectionTopTick = ValueNotifier<int>(0);

/// Bumped by the shell every time the home tab becomes the visible page, so
/// the keep-alive home page re-syncs continue-watching with the media servers
/// (their resume rails may have changed while the user was elsewhere).
final yingjiHomeFocusTick = ValueNotifier<int>(0);

/// 首页画布内部的滚动深度：0 = 停在首屏，1 = 已滚过一屏（进入“发现”栏目）。
///
/// 首页与“发现”合并后，背景模糊不再由壳层翻页驱动（首页页码恒为 0），
/// 改由这个值驱动，以保留合并前“滚下去背景变糊”的观感。
final yingjiHomeScrollDepth = ValueNotifier<double>(0);

/// 滚动深度：0 = 停在顶部（清晰），1 = 已滚过一屏（全糊）。
///
/// 首页与详情页共用这一份 —— 「顶部清晰、下滑变糊」必须是同一套曲线，否则两页
/// 手感对不上（详情页原来干脆是无条件糊死，一进去就糊）。量化成 1/24 步进，
/// 避免滚动过程中每帧重建模糊层。
double yingjiScrollDepth(ScrollPosition position) {
  final viewport = position.viewportDimension;
  if (viewport <= 0) return 0;
  final raw = (position.pixels / viewport).clamp(0.0, 1.0);
  return (raw * 24).roundToDouble() / 24;
}

/// 贯穿全部页面的统一栅格。
///
/// 浮动导航固定在左边 16、宽 54，正文必须让开这一段；桌面和手机屏宽差得远，
/// 所以两侧内缩分成两档。**任何页面都不应该再自己算左边距**——之前详情页
/// （侧栏 88 + 内缩 34 = 122）和设置页（壳层 96 + 内缩 26 = 122）各算了一遍，
/// 结果和首页、搜索页的 96 对不齐，搜索按钮也被挤在返回键旁边。
abstract final class YingjiLayout {
  /// 浮动导航条的左边距与宽度。
  static const double railLeft = 16;
  static const double railWidth = 54;

  /// 导航侧栏图标按钮的尺寸。
  ///
  /// 首页浮动导航与详情页顶栏使用同一尺寸和图标栅格。
  static const double railButtonSize = 44;

  /// 设置页窄于这个宽度就从「左栏 + 正文」改成单栏。
  static const double twoColumnMinWidth = 900;

  /// 正文区统一内缩：所有内层页面（首页内的发现内容、搜索、服务器、片单、
  /// 追剧、设置）共用同一个值。
  static EdgeInsets get pageInset => WindowHost.isDesktop
      ? const EdgeInsets.only(left: 96, top: 96, right: 40)
      : const EdgeInsets.only(left: 78, top: 84, right: 18);

  /// 正文区左锚点。
  static double get pageLeft => WindowHost.isDesktop ? 96 : 78;

  /// 正文区右锚点。
  static double get pageRight => WindowHost.isDesktop ? 40 : 18;
}

class YingjiBackdrop extends StatefulWidget {
  const YingjiBackdrop({super.key, this.overlay});

  final Widget? overlay;

  @override
  State<YingjiBackdrop> createState() => _YingjiBackdropState();
}

class _YingjiBackdropState extends State<YingjiBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flow = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 28),
  )..repeat(reverse: true);

  late final Animation<Offset> _violetDrift = _flow.drive(
    Tween<Offset>(
      begin: const Offset(-.12, -.035),
      end: const Offset(.12, .035),
    ).chain(CurveTween(curve: Curves.easeInOutSine)),
  );
  late final Animation<Offset> _tealDrift = _flow.drive(
    Tween<Offset>(
      begin: const Offset(.1, -.03),
      end: const Offset(-.1, .03),
    ).chain(CurveTween(curve: Curves.easeInOutSine)),
  );

  @override
  void initState() {
    super.initState();
    yingjiScrollInProgress.addListener(_syncFlowWithScroll);
  }

  void _syncFlowWithScroll() {
    if (yingjiScrollInProgress.value) {
      // 两张超出视口的大渐变层持续平移时，滚动列表无法复用已经合成的背板。
      // 滚轮滑行期间冻结在当前相位；列表停稳后从同一位置继续，不会跳色。
      _flow.stop(canceled: false);
    } else if (!_flow.isAnimating) {
      _flow.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    yingjiScrollInProgress.removeListener(_syncFlowWithScroll);
    _flow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) => Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF111824)),
        Positioned(
          left: -size.maxWidth * .4,
          top: -size.maxHeight * .2,
          width: size.maxWidth * 1.8,
          height: size.maxHeight * 1.4,
          child: SlideTransition(
            position: _violetDrift,
            child: const RepaintBoundary(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment(-1, -.5),
                    end: Alignment(1, .5),
                    colors: [
                      Color(0xFF1B3448),
                      Color(0xFF292947),
                      Color(0xFF3A2B4C),
                      Color(0xFF183D46),
                      Color(0xFF263353),
                      Color(0xFF1B3448),
                    ],
                    stops: [0, .2, .4, .62, .82, 1],
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: -size.maxWidth * .4,
          top: -size.maxHeight * .2,
          width: size.maxWidth * 1.8,
          height: size.maxHeight * 1.4,
          child: SlideTransition(
            position: _tealDrift,
            child: const RepaintBoundary(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment(-1, .6),
                    end: Alignment(1, -.6),
                    colors: [
                      Color(0x00355D70),
                      Color(0x4D355D70),
                      Color(0x00355D70),
                      Color(0x405A3E68),
                      Color(0x005A3E68),
                    ],
                    stops: [0, .26, .5, .76, 1],
                  ),
                ),
              ),
            ),
          ),
        ),
        ?widget.overlay,
      ],
    ),
  );
}

abstract final class YingjiColors {
  static const canvas = Color(0xFF07090D);
  static const surface = Color(0xB81B1D22);
  static const elevated = Color(0xFF1E2026);
  static const line = Color(0x1FFFFFFF);
  static const ink = Color(0xFFF7F7FA);
  static const muted = Color(0xFFB9BBC3);
  static const quiet = Color(0xFF898C96);
  static const focus = Color(0xFFF4F4F5);
  static const success = Color(0xFF8EE49C);
  static const danger = Color(0xFFFF9FA8);
  static const warmGlass = Color(0xB3262328);
}

/// 播放器工具栏的入口声明。
///
/// 设置页排顺序 / 开关显隐，播放器页按结果渲染 —— 两边共用这一份，免得新增
/// 入口时漏改一处（之前顺序就只写在播放器页的 const 列表里）。
class YingjiPlayerTool {
  const YingjiPlayerTool(this.id, this.icon);

  /// 控制台面板的标签，同时用作工具提示、菜单文案与排序 / 显隐的键。
  final String id;
  final IconData icon;
}

abstract final class YingjiPlayerTools {
  static const all = <YingjiPlayerTool>[
    YingjiPlayerTool('声音', YingjiIcons.speaker_2_fill),
    YingjiPlayerTool('字幕', YingjiIcons.captions_bubble),
    YingjiPlayerTool('剧集', YingjiIcons.episodes),
    YingjiPlayerTool('弹幕', YingjiIcons.danmaku),
    YingjiPlayerTool('画面', YingjiIcons.film),
    YingjiPlayerTool('倍速', YingjiIcons.gauge),
    YingjiPlayerTool('章节', YingjiIcons.bookmark),
    YingjiPlayerTool('片头片尾', YingjiIcons.scissors),
    YingjiPlayerTool('资源', YingjiIcons.server),
  ];

  static bool contains(String id) {
    for (final tool in all) {
      if (tool.id == id) return true;
    }
    return false;
  }

  static IconData iconOf(String id) {
    for (final tool in all) {
      if (tool.id == id) return tool.icon;
    }
    return YingjiIcons.slider_horizontal_3;
  }
}

/// 液态玻璃（Liquid Glass）材质的唯一来源。
///
/// 玻璃直接采样并模糊它后面的内容；白色只是极低浓度的折射色，不承担遮罩职责。
abstract final class YingjiGlass {
  static const Color frost = Color(0xFFF7FAFF);

  static const Color frostDeep = Color(0xFFE8EEF8);

  /// 面板底色的不透明度。这一项不再开放给用户（设置里只剩「模糊程度」）。
  ///
  /// Apple 式玻璃的底色必须保持很薄；清晰度来自实时模糊、边缘折射与文字阴影，
  /// 不是来自一层黑板。
  static const double alpha = .10;

  /// 选中态 / 高亮态用的实心色：与玻璃同一色系的中性浅灰。
  static const Color accent = Color(0xFFF3F4F7);

  /// 背后画面透过玻璃后的饱和度提升（vibrancy）：玻璃会聚光，透出来的颜色比
  /// 直接看更浓一点 —— 这是液态玻璃「活」起来的关键。
  static const double vibrancy = 1.35;

  static Color surface({double strength = 1}) =>
      frost.withValues(alpha: (alpha * strength).clamp(.07, .18));

  /// 小面积控件需要更稳定的轮廓，因此浓度下限高于大面板。
  static Color chrome({double strength = .82}) => Color.lerp(
    frost,
    frostDeep,
    .38,
  )!.withValues(alpha: (alpha * strength).clamp(.11, .24));

  /// 分隔线 / 未选中描边：与底色浓度无关，固定按白透明度给。
  static Color line({double strength = 1}) =>
      Colors.white.withValues(alpha: (.30 * strength).clamp(.12, .52));

  /// 播放器里的浮层（HUD、暂停圆钮）直接压在视频上，需要最高的对比度基线。
  static Color hud({double strength = 1.5}) =>
      frost.withValues(alpha: (alpha * strength).clamp(.14, .30));

  static double get blur => yingjiAppearance.glassBlur;

  /// 玻璃厚度的竖向渐变：只有底部微微沉暗，用来暗示「这是一片有厚度的玻璃」。
  ///
  static const LinearGradient depth = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[
      Color(0x18FFFFFF),
      Color(0x08FFFFFF),
      Color(0x00000000),
      Color(0x00000000),
      Color(0x08000000),
    ],
    stops: <double>[0, .14, .46, .78, 1],
  );

  /// 液态玻璃的背板滤镜：模糊 + 轻微提饱和（vibrancy）。
  ///
  /// 只保留少量色彩活力，不提亮；否则浅色画面会让整块面板过曝。
  /// 用 `ImageFilter.compose` 而不是叠两层 `BackdropFilter`，省一次全屏回读。
  static ImageFilter backdrop({double? sigma}) {
    final value = sigma ?? blur;
    final s = vibrancy;
    return ImageFilter.compose(
      outer: ImageFilter.blur(sigmaX: value, sigmaY: value),
      inner: ColorFilter.matrix(<double>[
        0.213 + 0.787 * s,
        0.715 - 0.715 * s,
        0.072 - 0.072 * s,
        0,
        0,
        0.213 - 0.213 * s,
        0.715 + 0.285 * s,
        0.072 - 0.072 * s,
        0,
        0,
        0.213 - 0.213 * s,
        0.715 - 0.715 * s,
        0.072 + 0.928 * s,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
      ]),
    );
  }
}

/// 一块液态玻璃表面：模糊背板 + 半透明底 + 厚度沉底，可裁圆角矩形或正圆。
///
/// **所有浮在内容之上的东西都必须走这里** —— 卡片、圆形按钮、药丸选择器、
/// 下拉菜单、悬浮提示、播放页控件。原因只有一个：「设置 → 外观 → 模糊程度」
/// 是**一根**滑杆，它要同时驱动全部控件。任何手写 `DecoratedBox(color: 深色)`
/// 的控件都没有 `BackdropFilter`，拖滑杆时它一动不动，看着就是「只有一部分
/// 界面是玻璃，别处还是黑塑料」——这正是之前反复出现的问题。
///
/// 轮廓仅保留低对比内边和短促顶部反射，不使用刺眼的整圈白边。
class YingjiGlassSurface extends StatelessWidget {
  const YingjiGlassSurface({
    super.key,
    this.child,
    this.padding,
    this.radius = 18,
    this.circle = false,
    this.strength = 1,
    this.sigma,
    this.depth = true,
    this.shadow = false,
  });

  final Widget? child;
  final EdgeInsetsGeometry? padding;

  /// 圆角半径。`circle` 为真时忽略。
  final double radius;

  /// 正圆（圆形按钮）。
  final bool circle;

  /// 底色浓度倍率：需要压住文字的地方给 1.2 左右。
  final double strength;

  /// 省略时跟随 [YingjiGlass.blur]；整屏背景那类只糊一半的层显式传值。
  final double? sigma;

  /// 是否叠一层「玻璃厚度」的竖向沉底渐变。
  final bool depth;

  /// 玻璃下方的柔和投影：抬升「一片玻璃浮在内容上」的层次。
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final rounded = BorderRadius.circular(radius);
    final shape = circle ? BoxShape.circle : BoxShape.rectangle;
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    Widget inner = child ?? const SizedBox.shrink();
    if (padding != null) inner = Padding(padding: padding!, child: inner);
    if (depth) {
      inner = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: circle ? null : rounded,
          shape: shape,
          gradient: YingjiGlass.depth,
        ),
        child: inner,
      );
    }
    final body = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: circle ? null : rounded,
        shape: shape,
        color: YingjiGlass.surface(strength: strength),
      ),
      child: inner,
    );
    // 归因开关命中时整条跳过离屏背板模糊，而不只是把 sigma 归零 ——
    // 后者仍会插一层离屏 layer 并做一次全屏回读，量不出通道本身的代价。
    final stableFilter = YingjiStableScrollGlass.enabled(context);
    final skipFilter =
        FrameTrace.skipGlass('glass') ||
        FrameTrace.skipGlass(circle ? 'circle' : 'rect');
    final surface = skipFilter
        ? body
        : stableFilter
        ? BackdropFilter.grouped(
            filter: YingjiGlass.backdrop(sigma: sigma),
            child: body,
          )
        : ValueListenableBuilder<bool>(
            valueListenable: yingjiScrollInProgress,
            child: body,
            builder: (context, scrolling, child) => BackdropFilter.grouped(
              filter: YingjiGlass.backdrop(sigma: sigma),
              enabled: !scrolling,
              child: child,
            ),
          );
    final edged = CustomPaint(
      foregroundPainter: _YingjiGlassEdgePainter(
        radius: radius,
        circle: circle,
        devicePixelRatio: devicePixelRatio,
      ),
      child: surface,
    );
    // 圆形改用**圆角矩形**裁切，而不是椭圆裁切。
    //
    // 正方形上「半径 = 半边长」的圆角矩形与正圆是同一个形状，但两条路径的代价
    // 差一个量级：`ClipOval` 是任意路径裁切（要模板 + 抗锯齿），`ClipRRect` 是
    // 原生图元、可以解析式求交。左侧导航那几个圆形玻璃按钮上实测每帧省
    // 2.6ms（静止 80fps → 103fps），画面逐像素不变 —— 这是本轮最大的单点收益。
    //
    // 非正方形（真椭圆）仍然必须走 `ClipOval`：胶囊和椭圆不是同一个形状。
    final clipped = circle
        ? LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final height = constraints.maxHeight;
              if (!width.isFinite ||
                  !height.isFinite ||
                  (width - height).abs() > .5) {
                return ClipOval(child: edged);
              }
              return ClipRRect(
                borderRadius: BorderRadius.circular(width / 2),
                child: edged,
              );
            },
          )
        : ClipRRect(borderRadius: rounded, child: edged);
    if (!shadow) return clipped;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: circle ? null : rounded,
        shape: shape,
        boxShadow: const [
          BoxShadow(
            color: Color(0x4D000000),
            blurRadius: 26,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: clipped,
    );
  }
}

class _YingjiGlassEdgePainter extends CustomPainter {
  const _YingjiGlassEdgePainter({
    required this.radius,
    required this.circle,
    required this.devicePixelRatio,
  });

  final double radius;
  final bool circle;
  final double devicePixelRatio;

  /// 圆形描边环的角度渐变：α(θ) = .34 + .16·cos(θ − 225°)。
  ///
  /// 关键在 **sweep 而不是 linear**：`LinearGradient` 的等 α 线是**弦**，把它套在
  /// 圆环上时，同一条等 α 线在不同方位扫过的弧长不同 —— 环的可见亮度绕圈起伏
  /// （3.1.112 环宽 1.5 下于真机 5 颗圆钮实测，环峰亮度极差 2.91×），看起来就是
  /// 「锯齿感」。`SweepGradient` 按角度定值，每个方位只取一个 α，配合常量环宽就
  /// 不再有宽度调制；实测极差降到 2.10×，保留左上受光的方向感（方案 B，见
  /// `docs/specs/2026-09-23-glass-edge-ring-uniformity.md`）。
  ///
  /// 225° 是「左上」在屏幕坐标（y 向下）里的 sweep 角，也就是受光方向。
  ///
  /// 采样 48 段是精度与常量表大小的折中：SweepGradient 在段间做线性插值，48 段
  /// 对应 7.5°/段，肉眼在 46px 的圆上分辨不出分段。
  static const int _sweepSteps = 48;

  static final List<Color> _sweepEdgeColors = List<Color>.generate(
    _sweepSteps + 1,
    (int i) {
      final theta = 2 * math.pi * i / _sweepSteps;
      final alpha = (.34 + .16 * math.cos(theta - 225 * math.pi / 180)).clamp(
        0.0,
        1.0,
      );
      return Color.fromRGBO(255, 255, 255, alpha);
    },
  );

  static final List<double> _sweepEdgeStops = List<double>.generate(
    _sweepSteps + 1,
    (int i) => i / _sweepSteps,
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // 观感比对开关：**只覆盖圆形**。直边（卡片 / 面板）上的线性渐变在几何上是
    // 正确的，任何情况下都不动它。
    final plan = circle ? FrameTrace.edgePlan : null;
    if (plan == 'none') return;
    // 生产默认（开关未设置）就是方案 B：圆形环按**角度**定值。必须带 `circle`：
    // 非圆形时上面把 plan 强置成 null，只看 `plan == null` 会把直边卡片也切成
    // sweep（卡片上的线性渐变是几何正确的，不能动）。
    final sweep = circle && plan == null;
    // 环宽固定 1.5 物理像素（不随开关变化）。圆周若只占 1 个物理像素，Windows
    // 100%/125%/150% 缩放下没有足够的覆盖像素做平滑过渡，斜边会呈阶梯状。1.5 个
    // 物理像素仍然轻薄，但能让 Skia 在内外两侧留下稳定的半透明抗锯齿采样。
    //
    // 不再内缩：方案 A/B 原型曾用「环宽 2.0 + 内缩 0.5」脱开裁切边界，理由是担心
    // 外缘 AA 被裁切吃掉。真机逐像素量过——环峰亮度与「无截断」理论值吻合
    // （136.5 vs 135.9），裁切并没有削掉环，那条内缩是多余的，一并去掉。
    final strokeWidth = 1.5 / devicePixelRatio;
    final rect = (Offset.zero & size).deflate(strokeWidth / 2);
    final paint = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    if (sweep) {
      // 方案 B：按角度定值，保留左上受光的方向感。
      paint.shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi * 2,
        colors: _sweepEdgeColors,
        stops: _sweepEdgeStops,
      ).createShader(rect);
    } else if (plan == 'const') {
      // 诊断对照（方案 A）：常量白，环亮度完全不随角度变化。
      paint.color = const Color(0x57FFFFFF);
    } else {
      // 诊断对照：回到 3.1.112 的线性渐变，供观感回归比对。
      paint.shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[
          Color(0xA6FFFFFF),
          Color(0x4DFFF1CC),
          Color(0x2E9EDBFF),
          Color(0x70FFFFFF),
        ],
        stops: <double>[0, .28, .66, 1],
      ).createShader(rect);
    }
    if (circle) {
      canvas.drawOval(rect, paint);
    } else {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          rect,
          Radius.circular(
            (radius - strokeWidth / 2).clamp(0.0, radius).toDouble(),
          ),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _YingjiGlassEdgePainter oldDelegate) =>
      oldDelegate.radius != radius ||
      oldDelegate.circle != circle ||
      oldDelegate.devicePixelRatio != devicePixelRatio;
}

/// 一张液态玻璃卡片：模糊背板 + 半透明底 + 极轻微的厚度沉底。
///
/// 所有「浮在内容之上的面板」都应走这里，不要再手写一层灰底。
///
/// 边缘、阴影和圆角全部委托给 [YingjiGlassSurface]，避免各页面另起一套皮肤。
class YingjiGlassCard extends StatelessWidget {
  const YingjiGlassCard({
    super.key,
    required this.child,
    this.padding,
    this.radius = 18,
    this.strength = 1,
    this.shadow = true,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;

  /// 底色浓度倍率：需要压住文字的地方给 1.2 左右。
  final double strength;

  /// 玻璃下方的柔和投影：抬升「一片玻璃浮在内容上」的层次。
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final rounded = BorderRadius.circular(radius);
    final card = YingjiGlassSurface(
      radius: radius,
      strength: strength,
      padding: padding ?? const EdgeInsets.all(20),
      child: child,
    );
    if (!shadow) return card;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: rounded,
        boxShadow: const [
          BoxShadow(
            color: Color(0x52000000),
            blurRadius: 30,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: card,
    );
  }
}

/// Mova uses one bundled rounded font across every supported platform.
abstract final class YingjiFonts {
  static const String family = 'YingjiRound';
  static const List<String> fallback = [
    'YingjiCjkFallback',
    'Microsoft YaHei UI',
    'Segoe UI Variable',
    'sans-serif',
  ];
}

/// One semantic Iconsax vocabulary for the whole desktop client.  Names mirror
/// the old call sites so every screen can move together without mixing icon
/// families.  All choices use the rounded Iconsax linear glyphs.
abstract final class YingjiIcons {
  static const sparkles = Iconsax.magic_star;
  static const play_fill = Iconsax.play;
  static const play = Iconsax.play;
  static const pause_fill = Iconsax.pause;
  static const play_circle = Iconsax.play_circle;
  static const play_circle_fill = Iconsax.play_circle;
  static const play_rectangle = Iconsax.video_play;
  static const play_rectangle_fill = Iconsax.video_play;
  static const house = Iconsax.home;
  static const search = Iconsax.search_normal;
  static const calendar = Iconsax.calendar;
  static const calendar_badge_plus = Iconsax.calendar_add;
  static const heart = Iconsax.heart;
  static const heart_fill = Iconsax.heart;
  static const rectangle_stack = Iconsax.box;
  static const rectangle_stack_fill = Iconsax.box;
  static const rectangle_stack_badge_plus = Iconsax.box_add;
  static const square_stack_3d_up = Iconsax.box;
  static const square_grid_2x2 = Iconsax.element_4;
  static const archivebox = Iconsax.archive;
  static const archivebox_fill = Iconsax.archive;
  static const film = Iconsax.video;
  static const photo = Iconsax.gallery;
  static const cloud_fill = Iconsax.cloud;
  static const cloud = Iconsax.cloud;
  static const gear = Iconsax.setting_2;
  static const gear_alt = Iconsax.setting_2;
  static const slider_horizontal_3 = Iconsax.setting;
  static const paintbrush = Iconsax.brush;
  static const gauge = Iconsax.speedometer;
  static const wifi = Iconsax.wifi;

  /// 代理设置入口：地球图标，表示「走系统代理」这类网络级开关。
  static const global = Iconsax.global;
  static const captions_bubble = Iconsax.subtitle;
  static const danmaku = Iconsax.message_text;
  static const bookmark = Iconsax.bookmark;
  static const clock = Iconsax.clock;
  static const person = Iconsax.user;
  static const person_fill = Iconsax.user;
  static const info_circle = Iconsax.info_circle;
  static const question_circle = Iconsax.info_circle;
  static const exclamationmark_triangle = Iconsax.danger;
  static const check_mark = Iconsax.tick_square;
  static const checkmark_seal = Iconsax.tick_circle;
  static const checkmark_shield = Iconsax.shield_tick;
  static const checkmark_circle_fill = Iconsax.tick_circle;
  static const circle = Iconsax.radio;
  static const chevron_left = Iconsax.arrow_left;
  static const chevron_right = Iconsax.arrow_right;
  static const chevron_up = Iconsax.arrow_up;
  static const chevron_down = Iconsax.arrow_down;
  static const arrow_right_circle_fill = Iconsax.arrow_right;
  static const arrow_left_circle_fill = Iconsax.arrow_left;
  static const plus = Iconsax.add;
  static const minus = Iconsax.minus;
  static const xmark = Iconsax.close_circle;
  static const square = Iconsax.maximize;
  static const trash = Iconsax.trash;
  static const link = Iconsax.link;
  static const lock = Iconsax.lock;
  static const dot_radiowaves_left_right = Iconsax.wifi;
  static const ellipsis = Iconsax.more;
  static const doc_on_doc = Iconsax.document_copy;
  static const doc_on_clipboard = Iconsax.document_text;

  /// 剧集列表：一排条目，刻意与「资源」的服务器图标区分开，避免两个入口撞脸。
  static const episodes = Iconsax.document_text;
  static const refresh = Iconsax.refresh;

  /// 进入全屏（四向外的箭头）与退出全屏（四向内的箭头）成对使用。
  static const fullscreen = Iconsax.maximize_1;
  static const fullscreen_exit = Iconsax.maximize;

  /// 画面比例用取景框图标，不再借用全屏箭头。
  static const crop = Iconsax.crop;

  /// 追剧日历的「弃剧」状态。
  static const forbidden = Iconsax.forbidden;
  static const gobackward_10 = Iconsax.backward_10_seconds;
  static const goforward_10 = Iconsax.forward_10_seconds;
  static const speaker_2_fill = Iconsax.volume_high;
  static const speaker_slash = Iconsax.volume_slash;
  static const line_horizontal_3 = Iconsax.menu;
  static const scissors = Iconsax.path;
  static const server = Iconsax.data;
  static const rankFirst = Iconsax.crown;
  static const rankSecond = Iconsax.medal_star;
  static const rankThird = Iconsax.award;
}

/// Shared press physics for prominent navigation and chrome controls. The
/// geometry is fixed: only scale, tint, and elevation animate, so icons never
/// jump when a page changes.
class YingjiMotionIconButton extends StatefulWidget {
  const YingjiMotionIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.selected = false,
    this.size = 46,
    this.flipHorizontal = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;
  final bool selected;
  final double size;
  final bool flipHorizontal;

  @override
  State<YingjiMotionIconButton> createState() => _YingjiMotionIconButtonState();
}

/// 全站唯一的悬浮提示：一模液态玻璃面板，背后真的模糊。
///
/// 之前只有「简介」那一处用了玻璃色底，别处（剧集行、评分、人物卡、片单、
/// 控件条按钮）还是 Material 默认的深灰圆角方块 —— 同一个页面里两种悬浮提示
/// 并存，用户看到的就是「鼠标悬浮的简介文字没有统一」。现在所有悬浮提示一律
/// 走这里，尺寸、圆角、字号、内边距、材质完全同源。
///
/// 实现用 [RawTooltip] 而不是 [Tooltip]：`Tooltip` 只允许换一个
/// [Decoration]（画不出 `BackdropFilter`），而 `RawTooltip` 把整个浮层交给
/// `tooltipBuilder` —— 于是玻璃面板能真正过滤它下面压着的画面，也就自然跟着
/// 「设置 → 外观 → 模糊程度」一起变。悬停延迟、长按触发、定位、无障碍提示
/// 仍是 Flutter 自己那套，没有重写。
class YingjiGlassTooltip extends StatelessWidget {
  const YingjiGlassTooltip({
    super.key,
    required this.message,
    required this.child,
    this.maxWidth = 520,
    this.waitDuration = const Duration(milliseconds: 280),
    this.showDuration = const Duration(seconds: 12),
    this.verticalOffset = 14,
    this.preferBelow = true,
  });

  final String message;
  final Widget child;
  final double maxWidth;
  final Duration waitDuration;
  final Duration showDuration;
  final double verticalOffset;
  final bool preferBelow;

  @override
  Widget build(BuildContext context) {
    // 空消息不建浮层，直接把子节点透传（与 Tooltip 行为一致）。
    if (message.isEmpty) return child;
    return RawTooltip(
      semanticsTooltip: message,
      hoverDelay: waitDuration,
      touchDelay: showDuration,
      ignorePointer: true,
      positionDelegate: (context) => positionDependentBox(
        size: context.overlaySize,
        childSize: context.tooltipSize,
        target: context.target,
        verticalOffset: verticalOffset,
        preferBelow: preferBelow,
      ),
      tooltipBuilder: (context, animation) => FadeTransition(
        opacity: animation,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: YingjiGlassSurface(
            radius: 16,
            strength: 1.16,
            shadow: true,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Text(
              message,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                height: 1.55,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
      child: child,
    );
  }
}

/// One application-owned choice menu. It replaces stock DropdownButton menus
/// so playback and settings selectors inherit the same glass material.
class YingjiGlassChoiceButton<T> extends StatelessWidget {
  const YingjiGlassChoiceButton({
    super.key,
    required this.value,
    required this.items,
    required this.labelBuilder,
    required this.onChanged,
    this.icon = YingjiIcons.chevron_down,
  });
  final T value;
  final List<T> items;
  final String Function(T value) labelBuilder;
  final ValueChanged<T> onChanged;
  final IconData icon;

  @override
  Widget build(BuildContext context) => YingjiGlassMenu(
    entries: items
        .map(
          (item) => MenuItemButton(
            onPressed: () => onChanged(item),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    labelBuilder(item),
                    style: TextStyle(
                      fontWeight: item == value
                          ? FontWeight.w800
                          : FontWeight.w600,
                    ),
                  ),
                ),
                if (item == value)
                  const Icon(YingjiIcons.checkmark_circle_fill, size: 16),
              ],
            ),
          ),
        )
        .toList(growable: false),
    child: YingjiGlassSurface(
      radius: 13,
      strength: .95,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            labelBuilder(value),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 6),
          Icon(icon, size: 15, color: Colors.white70),
        ],
      ),
    ),
  );
}

/// One clipped backdrop for the whole menu, including scrolling menus.
/// MenuAnchor retains native keyboard traversal, Escape and edge placement.
class YingjiGlassMenu extends StatelessWidget {
  const YingjiGlassMenu({
    super.key,
    required this.entries,
    required this.child,
    this.secondaryOnly = false,
    this.onOpen,
    this.onClose,
    this.borderRadius = 13,
  });
  final List<Widget> entries;
  final Widget child;
  final bool secondaryOnly;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;
  final double borderRadius;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    onOpen: onOpen,
    onClose: onClose,
    style: const MenuStyle(
      backgroundColor: WidgetStatePropertyAll(Colors.transparent),
      surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
      elevation: WidgetStatePropertyAll(0),
      padding: WidgetStatePropertyAll(EdgeInsets.zero),
    ),
    menuChildren: [
      ListenableBuilder(
        listenable: yingjiAppearance,
        builder: (context, _) => GlassPanel(
          padding: const EdgeInsets.all(6),
          radius: 16,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: 200,
              maxWidth: 360,
              maxHeight: MediaQuery.sizeOf(context).height * .65,
            ),
            child: SingleChildScrollView(
              primary: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: entries,
              ),
            ),
          ),
        ),
      ),
    ],
    builder: (context, controller, _) => YingjiMotionSurface(
      borderRadius: borderRadius,
      selected: controller.isOpen,
      child: InkWell(
        borderRadius: BorderRadius.circular(borderRadius),
        onSecondaryTapUp: secondaryOnly
            ? (details) => controller.open(position: details.localPosition)
            : null,
        onTap: secondaryOnly
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
        child: child,
      ),
    ),
  );
}

/// Shared pointer and focus feedback for clickable surfaces that are not icon
/// buttons. It never changes layout: only scale, outline and elevation animate.
class YingjiMotionSurface extends StatefulWidget {
  const YingjiMotionSurface({
    super.key,
    required this.child,
    this.selected = false,
    this.borderRadius = 16,
  });

  final Widget child;
  final bool selected;
  final double borderRadius;

  @override
  State<YingjiMotionSurface> createState() => _YingjiMotionSurfaceState();
}

class _YingjiMotionSurfaceState extends State<YingjiMotionSurface> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected || _hovered || _focused;
    return Focus(
      onFocusChange: (value) => setState(() => _focused = value),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: Listener(
          onPointerDown: (_) => setState(() => _pressed = true),
          onPointerUp: (_) => setState(() => _pressed = false),
          onPointerCancel: (_) => setState(() => _pressed = false),
          child: AnimatedScale(
            scale: _pressed ? .975 : (active ? 1.012 : 1),
            duration: MovaMotion.tapDown,
            curve: MovaMotion.standardEase,
            child: AnimatedContainer(
              duration: MovaMotion.quick,
              curve: MovaMotion.standardEase,
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.borderRadius),
                border: Border.all(
                  color: active
                      ? Colors.white.withValues(alpha: .92)
                      : Colors.transparent,
                  width: 1.6,
                ),
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.borderRadius),
                boxShadow: active
                    ? const [
                        BoxShadow(
                          color: Color(0x5C000000),
                          blurRadius: 22,
                          offset: Offset(0, 9),
                        ),
                      ]
                    : null,
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Adapter for legacy form selectors; all options use the shared glass menu.
class YingjiGlassDropdownField<T> extends StatelessWidget {
  const YingjiGlassDropdownField({
    super.key,
    required this.initialValue,
    required this.decoration,
    required this.items,
    required this.onChanged,
  });
  final T initialValue;
  final InputDecoration decoration;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        decoration.labelText ?? '',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      if (decoration.helperText != null)
        Text(
          decoration.helperText!,
          style: const TextStyle(fontSize: 12, color: YingjiColors.muted),
        ),
      const SizedBox(height: 9),
      YingjiGlassMenu(
        entries: [
          for (final item in items)
            MenuItemButton(
              onPressed: item.enabled ? () => onChanged(item.value) : null,
              trailingIcon: item.value == initialValue
                  ? const Icon(YingjiIcons.checkmark_circle_fill, size: 16)
                  : null,
              child: item.child,
            ),
        ],
        child: YingjiGlassSurface(
          radius: 13,
          strength: .88,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              items
                  .firstWhere(
                    (item) => item.value == initialValue,
                    orElse: () => items.first,
                  )
                  .child,
              const SizedBox(width: 12),
              const Icon(YingjiIcons.chevron_down, size: 16),
            ],
          ),
        ),
      ),
    ],
  );
}

/// Labeled form variant used by Settings. Keeping the label outside the popup
/// prevents the old platform dropdown menu from appearing over the glass card.
class YingjiGlassChoiceField<T> extends StatelessWidget {
  const YingjiGlassChoiceField({
    super.key,
    required this.label,
    this.helper,
    required this.value,
    required this.items,
    required this.labelBuilder,
    required this.onChanged,
  });
  final String label;
  final String? helper;
  final T value;
  final List<T> items;
  final String Function(T value) labelBuilder;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
      if (helper != null) ...[
        const SizedBox(height: 4),
        Text(
          helper!,
          style: const TextStyle(fontSize: 12, color: Colors.white60),
        ),
      ],
      const SizedBox(height: 9),
      YingjiGlassChoiceButton<T>(
        value: value,
        items: items,
        labelBuilder: labelBuilder,
        onChanged: onChanged,
      ),
    ],
  );
}

class _YingjiMotionIconButtonState extends State<YingjiMotionIconButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected || _hovered;
    return YingjiGlassTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) {
            MovaMotion.tap();
            setState(() => _pressed = true);
          },
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onPressed,
          child: Semantics(
            button: true,
            label: widget.tooltip,
            selected: widget.selected,
            child: AnimatedScale(
              // Keep the circular glass edge pixel-aligned while hovering.
              // Material and shadow already provide hover feedback; scaling
              // the cached glass layer causes visible stair-stepping on DPI
              // scales such as 125% and 150%.
              scale: _pressed ? MovaMotion.pressScaleIcon : 1,
              duration: _pressed ? MovaMotion.tapDown : MovaMotion.tapUp,
              curve: _pressed ? MovaMotion.press : MovaMotion.spring,
              child: SizedBox(
                width: widget.size,
                height: widget.size,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 液态玻璃圆片：静止时也在。这里以前是 `YingjiGlass.chrome()`
                    // 的一层半透明色 —— 没有 BackdropFilter，拖「模糊程度」时它
                    // 一动不动，看着就是一块黑塑料圆片。
                    YingjiGlassSurface(
                      circle: true,
                      // 小圆片若沿用 30px 的面板模糊，背后颜色会被抹成一块
                      // 均匀色，看起来像实心按钮。仍跟随同一滑杆，但保留更多
                      // 实时画面细节，让移动背景能从图标下方流过。
                      sigma: YingjiGlass.blur * .55,
                      strength: widget.selected ? 1.3 : (active ? 1.05 : .78),
                      shadow: active,
                      child: widget.selected
                          ? const Stack(
                              fit: StackFit.expand,
                              children: [
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        Color(0x66FFFFFF),
                                        Color(0x48F4F7FB),
                                        Color(0x36D5DEE9),
                                        Color(0x55F8FAFC),
                                      ],
                                      stops: [0, .34, .76, 1],
                                    ),
                                  ),
                                ),
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: RadialGradient(
                                      center: Alignment(-.48, -.72),
                                      radius: .78,
                                      colors: [
                                        Color(0x6EFFFFFF),
                                        Color(0x34FFFFFF),
                                        Color(0x00FFFFFF),
                                      ],
                                      stops: [0, .34, 1],
                                    ),
                                  ),
                                ),
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Color(0x00FFFFFF),
                                        Color(0x00111A28),
                                        Color(0x24111A28),
                                      ],
                                      stops: [0, .62, 1],
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : null,
                    ),
                    Center(
                      child: Transform.flip(
                        flipX: widget.flipHorizontal,
                        child: Icon(
                          widget.icon,
                          size: widget.size * .43,
                          color: widget.selected
                              ? const Color(0xFF111824)
                              : Colors.white,
                          shadows: widget.selected
                              ? const [
                                  Shadow(
                                    color: Color(0x52000000),
                                    blurRadius: 1.5,
                                    offset: Offset(0, .7),
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One navigation control for every horizontally scrollable rail. Both
/// directions use the same glyph and material; the previous direction is
/// mirrored instead of switching to a visually unrelated icon.
class YingjiDirectionalArrow extends StatelessWidget {
  const YingjiDirectionalArrow({
    super.key,
    required this.previous,
    required this.tooltip,
    required this.onPressed,
    this.size = 34,
    this.enabled = true,
  });

  final bool previous;
  final String tooltip;
  final VoidCallback onPressed;
  final double size;
  final bool enabled;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !enabled,
    child: AnimatedOpacity(
      opacity: enabled ? 1 : .34,
      duration: const Duration(milliseconds: 160),
      child: YingjiMotionIconButton(
        icon: YingjiIcons.chevron_right,
        tooltip: tooltip,
        size: size,
        flipHorizontal: previous,
        onPressed: onPressed,
      ),
    ),
  );
}

class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding,
    this.radius = 18,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;

  @override
  Widget build(BuildContext context) =>
      YingjiGlassCard(padding: padding, radius: radius, child: child);
}

/// Shared modal shell for forms and lists whose content can overflow.
/// Header and actions stay visible while only the middle region scrolls.
class YingjiPinnedDialog extends StatelessWidget {
  const YingjiPinnedDialog({
    super.key,
    required this.header,
    required this.body,
    this.actions,
    this.maxWidth = 720,
    this.maxHeight = 760,
    this.insetPadding = const EdgeInsets.all(28),
  });

  final Widget header;
  final Widget body;
  final Widget? actions;
  final double maxWidth;
  final double maxHeight;
  final EdgeInsets insetPadding;

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Colors.transparent,
    insetPadding: insetPadding,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
      child: GlassPanel(
        radius: 22,
        padding: EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
              child: header,
            ),
            Divider(height: 1, color: YingjiGlass.line(strength: .85)),
            Flexible(
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context)
                    .copyWith(scrollbars: false),
                child: SingleChildScrollView(
                  primary: false,
                  padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
                  child: body,
                ),
              ),
            ),
            if (actions != null) ...[
              Divider(height: 1, color: YingjiGlass.line(strength: .85)),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 14, 22, 18),
                child: actions!,
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class YingjiMark extends StatelessWidget {
  const YingjiMark({super.key, this.size = 26, this.style});
  final double size;
  final String? style;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: Image.asset(
      'app/assets/mova-logo.png',
      width: size,
      height: size,
      filterQuality: FilterQuality.high,
    ),
  );
}

/// Fixed desktop chrome for pages pushed outside the main navigation shell.
/// The middle region remains draggable while actions and caption buttons keep
/// their native Windows behavior.
class YingjiPageChrome extends StatelessWidget {
  const YingjiPageChrome({
    super.key,
    this.onBack,
    this.title,
    this.actions = const [],
  });

  final VoidCallback? onBack;
  final String? title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 76,
    child: Row(
      children: [
        const SizedBox(width: 22),
        if (onBack != null) ...[
          IconButton.filled(
            tooltip: '返回',
            onPressed: onBack,
            icon: const Icon(YingjiIcons.chevron_left, size: 18),
            style: IconButton.styleFrom(
              fixedSize: const Size.square(46),
              backgroundColor: YingjiGlass.chrome(),
              side: BorderSide(color: YingjiGlass.line()),
            ),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: WindowHost.dragArea(
            child: Align(
              alignment: Alignment.centerLeft,
              child: title == null
                  ? const SizedBox.expand()
                  : Text(
                      title!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.2,
                      ),
                    ),
            ),
          ),
        ),
        ...actions,
        const Padding(
          padding: EdgeInsets.only(left: 14, right: 22),
          child: YingjiWindowControls(),
        ),
      ],
    ),
  );
}

/// App-owned Windows controls use the same glass, icon family and press
/// physics as the rest of Yingji instead of mixing native caption glyphs with
/// application controls.
class YingjiWindowControls extends StatefulWidget {
  const YingjiWindowControls({
    super.key,
    this.onClose,
    this.fullscreen = false,
    this.size = 46,
  });

  final VoidCallback? onClose;
  final bool fullscreen;
  final double size;

  @override
  State<YingjiWindowControls> createState() => _YingjiWindowControlsState();
}

class _YingjiWindowControlsState extends State<YingjiWindowControls>
    with WidgetsBindingObserver {
  bool _maximized = false;
  bool _fullScreen = false;
  bool _syncing = false;
  bool _syncPending = false;

  /// 重新读一遍真实的窗口状态。
  ///
  /// 只记住「我点过什么」是不够的：按 Esc 退出全屏、双击标题栏、
  /// 系统快捷键、把窗口拖到屏幕边缘，都会改变窗口状态但不经过这个按钮。
  /// 尺寸变化一定会触发 [didChangeMetrics]，在这里补一次同步最稳。
  Future<void> _sync() async {
    if (!mounted || !WindowHost.isDesktop) return;
    if (_syncing) {
      _syncPending = true;
      return;
    }
    _syncing = true;
    try {
      final maximized = await WindowHost.isMaximized();
      final fullScreen = await WindowHost.isFullScreen();
      if (!mounted) return;
      if (maximized == _maximized && fullScreen == _fullScreen) return;
      setState(() {
        _maximized = maximized;
        _fullScreen = fullScreen;
      });
    } finally {
      _syncing = false;
      if (_syncPending && mounted) {
        _syncPending = false;
        WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _sync();
  }

  Future<void> _toggleMaximize() async {
    if (widget.fullscreen) {
      await WindowHost.toggleFullScreen();
    } else {
      await WindowHost.toggleMaximize();
    }
    await _sync();
  }

  @override
  Widget build(BuildContext context) {
    // 移动端没有窗口控制概念，整组按钮不渲染
    if (!WindowHost.isDesktop) return const SizedBox.shrink();
    // 全屏模式下这个按钮管的是全屏，普通模式管的是最大化。
    final active = widget.fullscreen ? _fullScreen : _maximized;
    // 全屏用与移动端一致的四向箭头；标题栏的最大化 / 还原仍是方框。
    final icon = widget.fullscreen
        ? (active ? YingjiIcons.fullscreen_exit : YingjiIcons.fullscreen)
        : (active ? YingjiIcons.rectangle_stack : YingjiIcons.square);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        YingjiMotionIconButton(
          icon: YingjiIcons.minus,
          tooltip: '最小化',
          size: widget.size,
          onPressed: WindowHost.minimize,
        ),
        const SizedBox(width: 7),
        YingjiMotionIconButton(
          icon: icon,
          tooltip: widget.fullscreen
              ? (active ? '退出全屏' : '全屏')
              : (active ? '还原' : '最大化'),
          size: widget.size,
          onPressed: _toggleMaximize,
        ),
        const SizedBox(width: 7),
        YingjiMotionIconButton(
          icon: YingjiIcons.xmark,
          tooltip: '关闭',
          size: widget.size,
          onPressed: widget.onClose ?? WindowHost.close,
        ),
      ],
    );
  }
}
