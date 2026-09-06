// ignore_for_file: constant_identifier_names

import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import 'package:window_manager/window_manager.dart';

/// Turns discrete Windows wheel ticks into one interruptible, eased movement.
/// The controller remains authoritative, so scrollbars and programmatic
/// centering stay synchronized.
class YingjiSmoothWheel extends StatelessWidget {
  const YingjiSmoothWheel({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: (signal) {
      if (signal is! PointerScrollEvent || !controller.hasClients) return;
      GestureBinding.instance.pointerSignalResolver.register(signal, (event) {
        final wheel = event as PointerScrollEvent;
        final position = controller.position;
        final target = (controller.offset + wheel.scrollDelta.dy * 1.18).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        controller.animateTo(
          target,
          duration: const Duration(milliseconds: 190),
          curve: Curves.easeOutCubic,
        );
      });
    },
    child: child,
  );
}

class YingjiAppearance extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.dark;
  String iconStyle = 'play';
  String fontStyle = 'round';
  double glassOpacity = .58;
  double glassBlur = 24;

  /// 0 is a brighter frosted card; 1 is the deepest graphite card.
  double cardDepth = .62;

  void apply({
    ThemeMode? themeMode,
    String? iconStyle,
    String? fontStyle,
    double? glassOpacity,
    double? glassBlur,
    double? cardDepth,
  }) {
    if (themeMode != null) this.themeMode = themeMode;
    if (iconStyle != null) this.iconStyle = iconStyle;
    if (fontStyle != null) this.fontStyle = fontStyle;
    if (glassOpacity != null) this.glassOpacity = glassOpacity.clamp(0, 1);
    if (glassBlur != null) this.glassBlur = glassBlur.clamp(0, 40);
    if (cardDepth != null) this.cardDepth = cardDepth.clamp(0, 1);
    notifyListeners();
  }
}

final yingjiAppearance = YingjiAppearance();
final yingjiBackdropUrl = ValueNotifier<String?>(null);
final yingjiBackdropEffect = ValueNotifier<String>('blur-dissolve');
final yingjiSectionRequest = ValueNotifier<String?>(null);

/// Bumped by the shell every time the home tab becomes the visible page, so
/// the keep-alive home page re-syncs continue-watching with the media servers
/// (their resume rails may have changed while the user was elsewhere).
final yingjiHomeFocusTick = ValueNotifier<int>(0);

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

/// Centralized glass material.  All floating controls derive their tint,
/// translucency and blur from the same appearance setting rather than baking
/// in opaque black fills per page.
abstract final class YingjiGlass {
  static Color _tinted(Color light, Color deep) =>
      Color.lerp(light, deep, yingjiAppearance.cardDepth)!;

  static Color surface({double strength = 1}) {
    final tint = _tinted(const Color(0xFF596270), const Color(0xFF151A22));
    return tint.withValues(
      alpha: (yingjiAppearance.glassOpacity * strength).clamp(0, 1),
    );
  }

  static Color chrome({double strength = .82}) {
    final tint = _tinted(const Color(0xFF424B58), const Color(0xFF0E131A));
    return tint.withValues(
      alpha: (yingjiAppearance.glassOpacity * strength).clamp(0, 1),
    );
  }

  static Color line({double strength = 1}) => Colors.white.withValues(
    alpha: (yingjiAppearance.glassOpacity * .21 * strength).clamp(0, .28),
  );

  static double get blur => yingjiAppearance.glassBlur;
}

/// Font choices exposed in Appearance. The first two are bundled with the
/// app; Windows families remain optional familiar local alternatives.
abstract final class YingjiFonts {
  static String get family => switch (yingjiAppearance.fontStyle) {
    'wenkai' => 'YingjiWenKai',
    'dengxian' => 'DengXian',
    'yahei' => 'Microsoft YaHei UI',
    _ => 'YingjiRound',
  };

  static List<String> get fallback => switch (yingjiAppearance.fontStyle) {
    'wenkai' => const ['YingjiRound', 'DengXian', 'Microsoft YaHei UI'],
    'dengxian' => const ['YingjiRound', 'Microsoft YaHei UI'],
    'yahei' => const ['YingjiRound', 'DengXian'],
    _ => const ['DengXian', 'Microsoft YaHei UI', 'Segoe UI Variable'],
  };
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
  static const cloud_fill = Iconsax.cloud;
  static const cloud = Iconsax.cloud;
  static const gear = Iconsax.setting_2;
  static const gear_alt = Iconsax.setting_2;
  static const slider_horizontal_3 = Iconsax.setting;
  static const paintbrush = Iconsax.brush;
  static const gauge = Iconsax.speedometer;
  static const wifi = Iconsax.wifi;
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
  static const fullscreen = Iconsax.maximize;
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
        border: Border.all(color: YingjiGlass.line()),
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
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
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
        child: Padding(
          padding: const EdgeInsets.all(12),
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
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onPressed,
          child: Semantics(
            button: true,
            label: widget.tooltip,
            selected: widget.selected,
            child: AnimatedScale(
              scale: _pressed ? .94 : (active ? 1.018 : 1),
              duration: const Duration(milliseconds: 110),
              curve: Curves.easeOutCubic,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
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
          child: DragToMoveArea(
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
        const SizedBox(
          width: 164,
          height: 76,
          child: WindowCaption(
            brightness: Brightness.dark,
            backgroundColor: Colors.transparent,
          ),
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
  });

  final VoidCallback? onClose;
  final bool fullscreen;

  @override
  State<YingjiWindowControls> createState() => _YingjiWindowControlsState();
}

class _YingjiWindowControlsState extends State<YingjiWindowControls> {
  bool _maximized = false;

  Future<void> _toggleMaximize() async {
    if (widget.fullscreen) {
      final active = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!active);
      if (mounted) setState(() => _maximized = !active);
      return;
    }
    final maximized = await windowManager.isMaximized();
    if (maximized) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
    if (mounted) setState(() => _maximized = !maximized);
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      YingjiMotionIconButton(
        icon: YingjiIcons.minus,
        tooltip: '最小化',
        size: 38,
        onPressed: windowManager.minimize,
      ),
      const SizedBox(width: 7),
      YingjiMotionIconButton(
        icon: _maximized ? YingjiIcons.rectangle_stack : YingjiIcons.square,
        tooltip: widget.fullscreen
            ? (_maximized ? '退出全屏' : '全屏')
            : (_maximized ? '还原' : '最大化'),
        size: 38,
        onPressed: _toggleMaximize,
      ),
      const SizedBox(width: 7),
      YingjiMotionIconButton(
        icon: YingjiIcons.xmark,
        tooltip: '关闭',
        size: 38,
        onPressed: widget.onClose ?? windowManager.close,
      ),
    ],
  );
}
