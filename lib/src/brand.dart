// ignore_for_file: constant_identifier_names

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import 'platform/window_host.dart';
import 'motion.dart';

/// 桌面端把滚轮交给 [YingjiSmoothWheel] 接管，移动端保留原生触摸滚动。
///
/// 这是 [YingjiSmoothWheel] 能生效的前提：内层滚动视图若保留了可滚动的
/// physics，它的 `Scrollable` 会先一步消费掉滚轮事件，平滑动画永远不会触发。
ScrollPhysics? get yingjiWheelPhysics =>
    WindowHost.isDesktop ? const NeverScrollableScrollPhysics() : null;

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
  });

  final ScrollController controller;
  final Widget child;

  /// 一个滚轮刻度折算成的滚动像素倍数。
  final double stepScale;

  /// 每个 60fps 帧之后仍未走完的距离比例；越小越跟手、滑行尾巴越短。
  final double settlePerFrame;

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
  void dispose() {
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
  Widget build(BuildContext context) => Listener(
    onPointerSignal: (signal) {
      if (signal is PointerScrollEvent) _handleWheel(signal);
    },
    child: widget.child,
  );
}

class YingjiAppearance extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.dark;
  String iconStyle = 'play';
  double glassOpacity = .58;
  double glassBlur = 24;

  /// 玻璃色调预设的 key，见 [YingjiGlassTints]。
  String glassTint = 'graphite';

  /// 0 is a brighter frosted card; 1 is the deepest graphite card.
  double cardDepth = .62;

  void apply({
    ThemeMode? themeMode,
    String? iconStyle,
    double? glassOpacity,
    double? glassBlur,
    double? cardDepth,
    String? glassTint,
  }) {
    if (themeMode != null) this.themeMode = themeMode;
    if (iconStyle != null) this.iconStyle = iconStyle;
    if (glassOpacity != null) this.glassOpacity = glassOpacity.clamp(0, 1);
    if (glassBlur != null) this.glassBlur = glassBlur.clamp(0, 40);
    if (cardDepth != null) this.cardDepth = cardDepth.clamp(0, 1);
    if (glassTint != null) this.glassTint = glassTint;
    notifyListeners();
  }
}

final yingjiAppearance = YingjiAppearance();
final yingjiBackdropUrl = ValueNotifier<String?>(null);
final yingjiBackdropEffect = ValueNotifier<String>('blur-dissolve');
final yingjiSectionRequest = ValueNotifier<String?>(null);

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

  /// 详情页左侧导航栏宽度（详情页是独立路由，自带侧栏，宽度要算进锚点里）。
  static double get detailSidebarWidth => WindowHost.isDesktop ? 88 : 64;

  /// 详情页侧栏自身的横向内边距，两种宽度下都保证按钮槽位是 44。
  static EdgeInsets get detailSidebarPadding => WindowHost.isDesktop
      ? const EdgeInsets.fromLTRB(18, 18, 14, 18)
      : const EdgeInsets.fromLTRB(10, 18, 10, 18);

  /// 详情页正文与顶部栏在侧栏之外还要补的内缩，补完正好等于 [pageLeft]。
  static double get detailLeadingInset => pageLeft - detailSidebarWidth;
}

class YingjiBackdrop extends StatelessWidget {
  const YingjiBackdrop({super.key, this.overlay, this.blur = 0});
  final Widget? overlay;
  final double blur;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
    valueListenable: yingjiBackdropUrl,
    builder: (context, imageUrl, _) => Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: YingjiColors.canvas),
        if (imageUrl != null)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: CachedNetworkImage(
              imageUrl: imageUrl,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        ?overlay,
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

/// 玻璃色调预设。
///
/// 每项给一对颜色：「背景卡片颜色」（[YingjiAppearance.cardDepth]）在浅端和
/// 深端之间插值。也就是说色调和深度是同一块材质的两个维度，合起来决定软件里
/// 每一个按钮和卡片的底色。
class YingjiGlassTint {
  const YingjiGlassTint(this.key, this.name, this.light, this.deep);

  final String key;
  final String name;

  /// 深度为 0 时的颜色（通透）。
  final Color light;

  /// 深度为 1 时的颜色（深邃）。
  final Color deep;
}

abstract final class YingjiGlassTints {
  static const all = <YingjiGlassTint>[
    YingjiGlassTint('graphite', '石墨', Color(0xFF6A7382), Color(0xFF151A22)),
    YingjiGlassTint('obsidian', '曜黑', Color(0xFF6E6E7A), Color(0xFF0B0B0E)),
    YingjiGlassTint('indigo', '靛蓝', Color(0xFF6B7FA6), Color(0xFF121B2C)),
    YingjiGlassTint('pine', '松绿', Color(0xFF6E8B76), Color(0xFF101C17)),
    YingjiGlassTint('amber', '暖砂', Color(0xFFA08A6E), Color(0xFF1E1811)),
    YingjiGlassTint('violet', '紫罗兰', Color(0xFF8B78A0), Color(0xFF1A1226)),
  ];

  static YingjiGlassTint of(String key) {
    for (final tint in all) {
      if (tint.key == key) return tint;
    }
    return all.first;
  }
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

/// Centralized glass material.  All floating controls derive their tint,
/// translucency and blur from the same appearance setting rather than baking
/// in opaque black fills per page.
abstract final class YingjiGlass {
  /// 当前色调在 [cardDepth] 处插值出的实色。
  static Color get tint {
    final preset = YingjiGlassTints.of(yingjiAppearance.glassTint);
    return Color.lerp(preset.light, preset.deep, yingjiAppearance.cardDepth)!;
  }

  /// 选中态 / 高亮态用的实心色：直接取当前色调的浅端，和悬浮卡片同一色系。
  static Color get accent => YingjiGlassTints.of(yingjiAppearance.glassTint).light;

  static Color surface({double strength = 1}) => tint.withValues(
    alpha: (yingjiAppearance.glassOpacity * strength).clamp(0, 1),
  );

  /// 比卡片再深一档，用在按钮、下拉这类小面积控件上。
  static Color chrome({double strength = .82}) => Color.lerp(
    tint,
    YingjiGlassTints.of(yingjiAppearance.glassTint).deep,
    .38,
  )!.withValues(alpha: (yingjiAppearance.glassOpacity * strength).clamp(0, 1));

  static Color line({double strength = 1}) => Colors.white.withValues(
    alpha: (yingjiAppearance.glassOpacity * .21 * strength).clamp(0, .28),
  );

  /// 播放器里的浮层（HUD、暂停圆钮）。跟随玻璃设置，但不透明度有下限：
  /// 把不透明度拉到 0 时提示也还得看得见。
  static Color hud({double strength = 1.5}) => tint.withValues(
    alpha: (yingjiAppearance.glassOpacity * strength).clamp(.55, 1),
  );

  static double get blur => yingjiAppearance.glassBlur;
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

class YingjiSynopsisTooltip extends StatelessWidget {
  const YingjiSynopsisTooltip({
    super.key,
    required this.message,
    required this.child,
  });

  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: message,
    waitDuration: const Duration(milliseconds: 280),
    showDuration: const Duration(seconds: 12),
    preferBelow: true,
    verticalOffset: 14,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
    margin: const EdgeInsets.all(20),
    constraints: const BoxConstraints(maxWidth: 520),
    decoration: BoxDecoration(
      color: YingjiGlass.surface(strength: 1.16),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white.withValues(alpha: .22)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x66000000),
          blurRadius: 28,
          offset: Offset(0, 14),
        ),
      ],
    ),
    textStyle: const TextStyle(
      color: Colors.white,
      fontSize: 13,
      height: 1.55,
      fontWeight: FontWeight.w500,
    ),
    child: child,
  );
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
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: YingjiGlass.surface(strength: .9),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: YingjiGlass.line(strength: 1.35)),
      ),
      child: Padding(
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
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: YingjiGlass.surface(strength: .82),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: YingjiGlass.line(strength: 1.35)),
          ),
          child: Padding(
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
    return Tooltip(
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
              scale: _pressed
                  ? MovaMotion.pressScaleIcon
                  : (active ? MovaMotion.hoverScale : 1),
              duration: _pressed ? MovaMotion.tapDown : MovaMotion.tapUp,
              curve: _pressed ? MovaMotion.press : MovaMotion.spring,
              child: AnimatedContainer(
                duration: MovaMotion.quick,
                curve: MovaMotion.standardEase,
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  color: widget.selected ? Colors.white : YingjiGlass.chrome(),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: YingjiGlass.line(strength: active ? 1.35 : .75),
                  ),
                  boxShadow: active
                      ? const [
                          BoxShadow(
                            color: Color(0x66000000),
                            blurRadius: 16,
                            offset: Offset(0, 7),
                          ),
                        ]
                      : null,
                ),
                child: Transform.flip(
                  flipX: widget.flipHorizontal,
                  child: Icon(
                    widget.icon,
                    size: widget.size * .43,
                    color: widget.selected ? YingjiColors.canvas : Colors.white,
                  ),
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
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: ImageFilter.blur(
        sigmaX: YingjiGlass.blur,
        sigmaY: YingjiGlass.blur,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: YingjiGlass.surface(),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: YingjiGlass.line()),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 30,
              offset: Offset(0, 14),
            ),
          ],
        ),
        child: Padding(
          padding: padding ?? const EdgeInsets.all(20),
          child: child,
        ),
      ),
    ),
  );
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

  /// 重新读一遍真实的窗口状态。
  ///
  /// 只记住「我点过什么」是不够的：按 Esc 退出全屏、双击标题栏、
  /// 系统快捷键、把窗口拖到屏幕边缘，都会改变窗口状态但不经过这个按钮。
  /// 尺寸变化一定会触发 [didChangeMetrics]，在这里补一次同步最稳。
  Future<void> _sync() async {
    if (!mounted || !WindowHost.isDesktop || _syncing) return;
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
