// Mova 动效规范 —— 全软件唯一的动画 / 按压 / 提示来源。
//
// 设计基调：Apple。所有交互只做三件事 —— 起步快、收尾稳、按下有回弹，
// 并且「数值跟着手指走，位移跟着曲线走」。业务代码不要再手写 Duration /
// Curve，一律引用这里的常量。

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 时长与曲线的单一真源。
abstract final class MovaMotion {
  // ── 时长 ────────────────────────────────────────────────────────────
  /// 数值跟随：音量条、进度这类每帧都在变的量。
  static const Duration instant = Duration(milliseconds: 90);

  /// 轻量状态切换：胶囊底色、图标换色。
  static const Duration quick = Duration(milliseconds: 150);

  /// 按下的瞬间（要快，慢了就「粘手」）。
  static const Duration tapDown = Duration(milliseconds: 110);

  /// 抬手回弹（比按下慢，才会有「弹回来」的手感）。
  static const Duration tapUp = Duration(milliseconds: 240);

  /// 通用出现 / 位移。
  static const Duration standard = Duration(milliseconds: 300);

  /// 强调动作：弹窗、页面级转场。
  static const Duration emphasis = Duration(milliseconds: 380);

  /// 页面转场。
  static const Duration page = Duration(milliseconds: 420);

  /// HUD 出现 / 消失。
  static const Duration hudIn = Duration(milliseconds: 250);
  static const Duration hudOut = Duration(milliseconds: 180);

  // ── 曲线 ────────────────────────────────────────────────────────────
  /// 通用：起步快、尾巴长，位移和透明度都用它。
  static const Curve standardEase = Curves.easeOutCubic;

  /// 进入：比 standardEase 更「先冲后稳」，用于浮层出现。
  static const Curve enter = Cubic(0.20, 0.90, 0.28, 1.0);

  /// 退出：收得干净，不拖泥带水。
  static const Curve exit = Curves.easeInCubic;

  /// 回弹：抬手时轻微过冲一下（Apple 的「柔韧」感），过冲量很小，
  /// 只够让控件看起来有质量，不会晃。
  static const Curve spring = Cubic(0.24, 1.20, 0.42, 1.0);

  /// 按下：立刻减速，手指一碰就有反应。
  static const Curve press = Curves.decelerate;

  // ── 按压量 ──────────────────────────────────────────────────────────
  /// 按下时缩到多少（通用控件）。
  static const double pressScale = 0.955;

  /// 图标按钮这类小目标，缩得更多一点才看得出来。
  static const double pressScaleIcon = 0.94;

  /// 大面积卡片（海报等）缩一点点就够。
  static const double pressScaleCard = 0.975;

  /// 指针悬停时放大（仅桌面）。
  static const double hoverScale = 1.018;

  // ── 触感 ────────────────────────────────────────────────────────────
  /// 按下反馈：轻一下，和 iOS 系统控件一致。
  static void tap() => HapticFeedback.selectionClick();

  /// 生效反馈：跳过片头、确认这类「事情办成了」的动作。
  static void impact() => HapticFeedback.lightImpact();
}

/// 统一的按压反馈外壳。
///
/// 任何可点区域都套一层它：按下缩小 + 轻微变淡 + 触感，抬手带一点点回弹。
/// 它不改变布局，也不抢子控件的事件（translucent），所以可以直接包住
/// 现成的按钮；也可以自己接 [onTap] 顶替内部按钮。
class MovaPress extends StatefulWidget {
  const MovaPress({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.haptics = true,
    this.visualOnly = false,
    this.scale = MovaMotion.pressScale,
    this.hoverScale = MovaMotion.hoverScale,
    this.pressedOpacity = .74,
    this.behavior = HitTestBehavior.translucent,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool enabled;

  /// 是否在按下的瞬间给一下触感（桌面端是空操作）。
  final bool haptics;

  /// 只借用按压动效，真正的点击交给内部已有控件（比如内部的 TextButton）。
  /// 开着它时 MovaPress 不会注册 onTap，避免一次点击触发两遍。
  final bool visualOnly;

  final double scale;
  final double hoverScale;
  final double pressedOpacity;
  final HitTestBehavior behavior;
  final String? semanticLabel;

  @override
  State<MovaPress> createState() => _MovaPressState();
}

class _MovaPressState extends State<MovaPress> {
  bool _pressed = false;
  bool _hovered = false;

  void _down(TapDownDetails details) {
    if (!widget.enabled || !mounted) return;
    if (widget.haptics) MovaMotion.tap();
    setState(() => _pressed = true);
  }

  void _release() {
    if (mounted && _pressed) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final interactive =
        enabled &&
        (widget.onTap != null ||
            widget.onLongPress != null ||
            widget.visualOnly);
    final target = !interactive
        ? 1.0
        : (_pressed ? widget.scale : (_hovered ? widget.hoverScale : 1.0));
    final opacity = !interactive
        ? 1.0
        : (_pressed ? widget.pressedOpacity : 1.0);
    return Semantics(
      button: widget.onTap != null,
      label: widget.semanticLabel,
      enabled: enabled,
      child: MouseRegion(
        cursor: interactive ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) {
          if (interactive && mounted) setState(() => _hovered = true);
        },
        onExit: (_) {
          if (!mounted) return;
          setState(() {
            _hovered = false;
            _pressed = false;
          });
        },
        child: GestureDetector(
          behavior: widget.behavior,
          onTapDown: _down,
          onTapUp: (_) => _release(),
          onTapCancel: _release,
          onTap: widget.onTap == null ? null : () => widget.onTap?.call(),
          onLongPress: enabled ? widget.onLongPress : null,
          child: AnimatedScale(
            scale: target,
            duration: _pressed ? MovaMotion.tapDown : MovaMotion.tapUp,
            curve: _pressed ? MovaMotion.press : MovaMotion.spring,
            child: AnimatedOpacity(
              opacity: opacity,
              duration: MovaMotion.tapDown,
              curve: MovaMotion.standardEase,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 统一的出现 / 消失动画。
///
/// [animateOnMount] 为 true 时，Widget 第一帧不画，等下一帧再放出来，
/// 于是「刚出现」也有动画（HUD、暂停按钮这类中途才插进来的东西需要）。
class MovaAppear extends StatefulWidget {
  const MovaAppear({
    super.key,
    required this.child,
    this.visible = true,
    this.animateOnMount = true,
    this.beginScale = .92,
    this.slide = 0,
    this.duration = MovaMotion.hudIn,
    this.curve = MovaMotion.enter,
  });

  final Widget child;
  final bool visible;
  final bool animateOnMount;

  /// 起始缩放；1 是终点。
  final double beginScale;

  /// 起始纵向位移，单位是自身高度的比例（0.08 = 从下方 8% 处滑上来）。
  final double slide;
  final Duration duration;
  final Curve curve;

  @override
  State<MovaAppear> createState() => _MovaAppearState();
}

class _MovaAppearState extends State<MovaAppear> {
  bool _mounted = false;

  @override
  void initState() {
    super.initState();
    _mounted = !widget.animateOnMount;
    if (widget.animateOnMount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _mounted = true);
      });
    }
  }

  @override
  void didUpdateWidget(covariant MovaAppear oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible && mounted) {
      setState(() => _mounted = widget.visible);
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = _mounted && widget.visible;
    return AnimatedOpacity(
      opacity: on ? 1 : 0,
      duration: on ? widget.duration : MovaMotion.hudOut,
      curve: on ? widget.curve : MovaMotion.exit,
      child: AnimatedScale(
        scale: on ? 1 : widget.beginScale,
        duration: on ? widget.duration : MovaMotion.hudOut,
        curve: on ? widget.curve : MovaMotion.exit,
        child: AnimatedSlide(
          offset: on ? Offset.zero : Offset(0, widget.slide),
          duration: widget.duration,
          curve: widget.curve,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Apple 风格的横条 HUD（亮度 / 音量 / 快进快退）。
///
/// 统一躺成一条 38 高的胶囊：图标 + 进度条 + 数值，横向摆在画面靠上的位置。
/// 之前是竖条，手机上正好压在人物脸上；横条既薄又靠上，不挡画面也不挡字幕。
///
/// 底色由调用方传 [background]（通常是 `YingjiGlass.hud()`），这样外观设置里
/// 的玻璃色调 / 不透明度 / 模糊会直接作用到它上面。
class MovaHud extends StatelessWidget {
  const MovaHud({
    super.key,
    required this.icon,
    required this.label,
    this.value,
    this.caption,
    this.trackWidth = 96,
    this.width,
    this.background = const Color(0xA6121216),
    this.borderColor = const Color(0x24FFFFFF),
  });

  final IconData icon;

  /// 主数值文案（百分比或时间点）。
  final String label;

  /// 0..1 的进度；为 null 时不画进度条。
  final double? value;

  /// 右侧的次要说明（快进快退的偏移量）。
  final String? caption;

  /// 宽度自适应时的进度条长度；给定 [width] 时进度条改为撑满剩余空间。
  final double trackWidth;

  /// 给定后整条 HUD 固定宽度，进度条撑满。
  final double? width;
  final Color background;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    const radius = 19.0;
    final value = this.value;
    Widget track = const SizedBox.shrink();
    if (value != null) {
      track = width == null
          ? _MovaHudTrack(value: value.clamp(0.0, 1.0), width: trackWidth)
          : Expanded(child: _MovaHudTrack(value: value.clamp(0.0, 1.0)));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: borderColor, width: .8),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 26,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: SizedBox(
            width: width,
            height: 38,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13),
              child: Row(
                mainAxisSize: width == null
                    ? MainAxisSize.min
                    : MainAxisSize.max,
                children: [
                  Icon(
                    icon,
                    size: 16,
                    color: Colors.white.withValues(alpha: .92),
                  ),
                  const SizedBox(width: 10),
                  track,
                  if (value != null) const SizedBox(width: 11),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      height: 1,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (caption != null) ...[
                    const SizedBox(width: 7),
                    Text(
                      caption!,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: .62),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MovaHudTrack extends StatelessWidget {
  const _MovaHudTrack({required this.value, this.width});
  final double value;
  final double? width;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(999),
    child: SizedBox(
      width: width,
      height: 5,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            ColoredBox(color: Colors.white.withValues(alpha: .2)),
            Align(
              alignment: Alignment.centerLeft,
              child: AnimatedContainer(
                duration: MovaMotion.instant,
                curve: MovaMotion.standardEase,
                width: constraints.maxWidth * value,
                height: 5,
                color: Colors.white.withValues(alpha: .95),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Apple 风格的横条提示（快进 / 快退这类「一个数值 + 一个图标」的场合）。
///
/// 和 [MovaHud] 同一套材质，只是躺下来：一条 34 高的胶囊。
class MovaHudPill extends StatelessWidget {
  const MovaHudPill({
    super.key,
    required this.icon,
    required this.label,
    this.caption,
    this.background = const Color(0xA6121216),
    this.borderColor = const Color(0x24FFFFFF),
  });

  final IconData icon;
  final String label;
  final String? caption;
  final Color background;
  final Color borderColor;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(17),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(17),
          border: Border.all(color: borderColor, width: .8),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 26,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: Colors.white.withValues(alpha: .82)),
              const SizedBox(width: 9),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  height: 1,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              if (caption != null) ...[
                const SizedBox(width: 8),
                Text(
                  caption!,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: .62),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    height: 1,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// 统一的轻提示。
///
/// 仍然走 SnackBar 的通道（这样不会钻到页面叠层底下、多条也会自动排队），
/// 但外观、时长、圆角由这里定：底部浮起的深色胶囊，可选一个引导图标。
abstract final class MovaToast {
  MovaToast._();

  static void show(
    BuildContext context, {
    required String message,
    IconData? icon,
    Duration duration = const Duration(milliseconds: 2200),
    SnackBarAction? action,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 17, color: Colors.white.withValues(alpha: .9)),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        duration: duration,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: const Color(0xF21A1C22),
        action: action,
      ),
    );
  }
}

/// 统一的页面转场：新页面从右侧滑入并淡入，底下的页面跟着往左让一点。
/// 全平台一致（桌面也走这一套），取代 Material 默认的缩放淡入。
class MovaPageTransitionsBuilder extends PageTransitionsBuilder {
  const MovaPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final forward = CurvedAnimation(
      parent: animation,
      curve: MovaMotion.enter,
      reverseCurve: MovaMotion.exit,
    );
    final outgoing = CurvedAnimation(
      parent: secondaryAnimation,
      curve: MovaMotion.enter,
      reverseCurve: MovaMotion.exit,
    );
    return SlideTransition(
      position:
          Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(forward),
      child: FadeTransition(
        opacity: forward,
        child: SlideTransition(
          position:
              Tween<Offset>(
                begin: Offset.zero,
                end: const Offset(-.28, 0),
              ).animate(outgoing),
          child: child,
        ),
      ),
    );
  }
}
