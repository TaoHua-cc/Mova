import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderAbstractViewport, ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:image/image.dart' as image_lib;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app_route_observer.dart';
import 'brand.dart';
import 'history/watch_state_store.dart';
import 'history/watchlist_store.dart';
import 'images/icon_background.dart';
import 'metadata/metadata_detail_page.dart';
import 'metadata/tmdb_client.dart';
import 'metadata/ratings.dart';
import 'playlists/playlist_store.dart';
import 'playlists/playlist_detail_page.dart';
import 'player/danmaku_client.dart';
import 'player/subtitle_preference.dart';
import 'player/player_page.dart';
import 'sources/emby_client.dart';
import 'sources/media_source.dart';
import 'sources/source_store.dart';
import 'sources/source_library_page.dart';
import 'sources/webdav_client.dart';
import 'tracking/trakt_client.dart';

const _defaultPlayerShortcuts = <String, String>{
  'playPause': 'Space',
  'seekBack': 'Arrow Left',
  'seekForward': 'Arrow Right',
  'volumeUp': 'Arrow Up',
  'volumeDown': 'Arrow Down',
  'mute': 'M',
  'fullscreen': 'F',
  'exit': 'Escape',
};
const _shortcutNames = <String, String>{
  'playPause': '播放 / 暂停',
  'seekBack': '快退',
  'seekForward': '快进',
  'volumeUp': '增大音量',
  'volumeDown': '减小音量',
  'mute': '静音 / 恢复',
  'fullscreen': '进入 / 退出全屏',
  'exit': '返回详情页',
};

final Map<String, Future<Map<String, String>>> _watchProviderRequests = {};
const _knownPlatformLabels = <String, String>{
  'watch:8': 'Netflix',
  'watch:119': 'Prime Video',
  'watch:337': 'Disney+',
  'watch:350': 'Apple TV+',
  'watch:1899': 'Max',
  'watch:15': 'Hulu',
  'watch:386': 'Peacock',
  'watch:531': 'Paramount+',
  'company:74457': '腾讯视频',
  'company:172414': '爱奇艺',
  'company:48460': '优酷',
  'company:139947': '芒果 TV',
  'company:123270': '哔哩哔哩',
};
const _platformLogoPaths = <String, String>{
  'watch:8': '/rK1KljqmbvO9HQa1PBFLILWah72.png',
  'watch:119': '/gMZdpavHmxFNnLpMHwVxfqeux2g.png',
  'watch:337': '/5eZ872CghnHFLB1j8grszbrx0dx.png',
  'watch:350': '/9icYBfYFcwgCbky5VdGUIKJ4C5i.png',
  'watch:1899': '/skypuy7SXuugIQeYg0IglmzoKaS.png',
  'watch:15': '/44uAnmSqvA4yBOdbPWN8YgQHjWm.png',
  'watch:386': '/a1UIdq5BrkcAxnxcUhFsNbXnxeu.png',
  'company:74457': '/mPsCbXC5k20bpKErrbOQd1fG0L7.png',
  'company:172414': '/fNxBFqWr7eWEgNeBDvvCxsSItXx.png',
  'company:48460': '/7m3BMwdstKRqw7qg5vSYW2S0HrR.png',
  'company:139947': '/yTjVB6bJfdbuuZOhKdmjkY70cxn.png',
  'company:123270': '/4KxfGr13VXMr44og11hzpdwfQDQ.png',
};
final Map<String, String> _resolvedPlatformLabels = {..._knownPlatformLabels};
final Map<String, Uri> _resolvedPlatformLogos = {
  for (final entry in _platformLogoPaths.entries)
    entry.key: Uri.parse('https://image.tmdb.org/t/p/w185${entry.value}'),
};

Future<Map<String, String>> _watchProviders(
  String type,
  String region,
) => _watchProviderRequests.putIfAbsent('$type:$region', () async {
  try {
    final uri = Uri.parse(
      '${TmdbClient.managedEndpoint}/tmdb/watch/providers/$type',
    ).replace(queryParameters: {'language': 'zh-CN', 'watch_region': region});
    final response = await http.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final decoded = jsonDecode(response.body);
      final rows = decoded is Map ? decoded['results'] : null;
      for (final row in (rows is List ? rows : const []).whereType<Map>()) {
        final id = row['provider_id'];
        final logoPath = row['logo_path'];
        final key = 'watch:$id';
        if (_knownPlatformLabels.containsKey(key) &&
            logoPath is String &&
            logoPath.isNotEmpty) {
          _resolvedPlatformLogos[key] = Uri.parse(
            'https://image.tmdb.org/t/p/w185$logoPath',
          );
        }
      }
    }
  } catch (_) {}
  final platforms = <String, String>{'all': '全部平台', ..._knownPlatformLabels};
  _resolvedPlatformLabels.addAll(platforms);
  return platforms;
});

// THESIS: Film artwork is the application surface; navigation and tasks float
// over it instead of living inside a dashboard frame.
// OWN-WORLD: Near-black cinema canvas, white circular focus states, translucent
// graphite controls, 14px cards, and large direct Chinese headings.
// STORY: Pick a destination, recognize the featured title, resume or inspect it,
// then move through shelves without leaving the cinematic field.
// FIRST VIEWPORT: Brand at top-left, caption controls top-right, a circular rail
// on the left, large title and actions above a landscape continuation shelf.
// FORM: WWPlayer desktop composition, pinned by the user.
// FINISH: unreviewed and undocumented is unfinished; this build ends with the
// finish review, the verdict, and DESIGN.md.

/// The media-center shell intentionally follows the same information
/// architecture as a desktop media hub: a cinematic canvas with functional
/// content layers, rather than page-sized opaque cards.
class MediaCenterShell extends StatefulWidget {
  const MediaCenterShell({super.key});

  @override
  State<MediaCenterShell> createState() => _MediaCenterShellState();
}

class _MediaCenterShellState extends State<MediaCenterShell> {
  _CenterSection _section = _CenterSection.home;
  final PageController _pageController = PageController();
  Timer? _wheelResetTimer;
  double _wheelDelta = 0;
  double _pageScrollHint = 0;
  DateTime _lastWheelNavigation = DateTime.fromMillisecondsSinceEpoch(0);
  static const _pageSections = <_CenterSection>[
    _CenterSection.home,
    _CenterSection.discover,
    _CenterSection.calendar,
    _CenterSection.playlists,
    _CenterSection.sources,
    _CenterSection.settings,
    _CenterSection.search,
  ];

  @override
  void initState() {
    super.initState();
    yingjiSectionRequest.addListener(_handleSectionRequest);
  }

  void _handleSectionRequest() {
    final value = yingjiSectionRequest.value;
    final target = switch (value) {
      'home' => _CenterSection.home,
      'discover' => _CenterSection.discover,
      'calendar' => _CenterSection.calendar,
      'playlists' => _CenterSection.playlists,
      'sources' => _CenterSection.sources,
      'settings' => _CenterSection.settings,
      _ => null,
    };
    if (target != null) _selectSection(target);
    yingjiSectionRequest.value = null;
  }

  Widget _pageFor(_CenterSection section) => switch (section) {
    _CenterSection.home => const _CinematicHome(),
    _CenterSection.discover => const _DiscoverPage(),
    _CenterSection.search => const _SearchPage(),
    _CenterSection.sources => const _SourceHub(),
    _CenterSection.playlists => const _PlaylistsPage(),
    _CenterSection.calendar => const _CalendarPage(),
    _CenterSection.settings => const SettingsPage(),
  };

  void _selectSection(_CenterSection value) {
    final target = _pageSections.indexOf(value);
    if (target < 0) return;
    final previous = _section;
    setState(() => _section = value);
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 420),
      curve: const Cubic(.22, 1, .36, 1),
    );
    // Re-entering the home tab should re-sync its continue-watching shelf with
    // the servers: playback on other devices may have moved the resume rail
    // while the (keep-alive) home page was off-screen.
    if (value == _CenterSection.home && previous != _CenterSection.home) {
      yingjiHomeFocusTick.value++;
    }
  }

  void _handlePointerSignal(PointerSignalEvent signal) {
    // Search owns its vertical scroll completely. Wheel input here must never
    // accumulate into shell-level page navigation.
    if (_section == _CenterSection.search) return;
    if (signal is! PointerScrollEvent ||
        signal.scrollDelta.dy.abs() <= signal.scrollDelta.dx.abs()) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(signal, (
      resolvedSignal,
    ) {
      final event = resolvedSignal as PointerScrollEvent;
      _wheelResetTimer?.cancel();
      _wheelResetTimer = Timer(const Duration(milliseconds: 420), () {
        if (mounted) {
          setState(() {
            _wheelDelta = 0;
            _pageScrollHint = 0;
          });
        }
      });
      final now = DateTime.now();
      if (now.difference(_lastWheelNavigation) <
          const Duration(milliseconds: 640)) {
        return;
      }
      _wheelDelta += event.scrollDelta.dy;
      setState(() => _pageScrollHint = (_wheelDelta / 180).clamp(-1, 1));
      // A small amount of accumulated wheel distance creates a deliberate
      // desktop detent without turning the page transition into a click-step.
      if (_wheelDelta.abs() < 42) return;
      final current = _pageSections.indexOf(_section);
      final direction = _wheelDelta.isNegative ? -1 : 1;
      // A page is a destination, not a wheel tick.  Keep regular ListViews in
      // control until the user has deliberately accumulated a longer gesture.
      if (_wheelDelta.abs() < 112) return;
      final lastScrollable = _pageSections.indexOf(_CenterSection.settings);
      final target = (current + direction).clamp(0, lastScrollable);
      _wheelDelta = 0;
      _pageScrollHint = 0;
      if (target == current) return;
      _lastWheelNavigation = now;
      _selectSection(_pageSections[target]);
    });
  }

  @override
  void dispose() {
    yingjiSectionRequest.removeListener(_handleSectionRequest);
    _wheelResetTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shellBody = Stack(
      fit: StackFit.expand,
      children: [
        _ContinuousShellBackdrop(controller: _pageController),
        PageView.builder(
          controller: _pageController,
          scrollDirection: Axis.vertical,
          allowImplicitScrolling: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _pageSections.length,
          onPageChanged: (index) =>
              setState(() => _section = _pageSections[index]),
          itemBuilder: (context, index) {
            final section = _pageSections[index];
            final page = _pageFor(section);
            if (section == _CenterSection.home) return page;
            return Padding(
              padding: const EdgeInsets.only(left: 96, top: 96, right: 40),
              child: page,
            );
          },
        ),
        const _FloatingHomeDragRegion(),
        _FloatingHomeRail(selected: _section, onChanged: _selectSection),
        _FloatingHomeTopBar(
          onSearch: () => _selectSection(_CenterSection.search),
        ),
        Positioned(
          right: 28,
          bottom: 30,
          child: _PageScrollCue(progress: _pageScrollHint),
        ),
      ],
    );
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerSignal: _handlePointerSignal,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.slash): () =>
              _selectSection(_CenterSection.search),
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (_section == _CenterSection.search) {
              _selectSection(_CenterSection.home);
            }
          },
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(backgroundColor: Colors.transparent, body: shellBody),
        ),
      ),
    );
  }
}

enum _CenterSection {
  home,
  discover,
  search,
  sources,
  playlists,
  calendar,
  settings,
}

class _ContinuousShellBackdrop extends StatelessWidget {
  const _ContinuousShellBackdrop({required this.controller});

  final PageController controller;

  Widget _transition(String effect, Widget child, Animation<double> animation) {
    final curve = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    if (effect == 'blur-dissolve') {
      return AnimatedBuilder(
        animation: curve,
        child: child,
        builder: (context, child) {
          final clarity = curve.value;
          return Opacity(
            opacity: clarity,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: (1 - clarity) * 24,
                sigmaY: (1 - clarity) * 24,
              ),
              child: child,
            ),
          );
        },
      );
    }
    return switch (effect) {
      'fade' => FadeTransition(opacity: curve, child: child),
      'zoom-fade' => FadeTransition(
        opacity: curve,
        child: ScaleTransition(
          scale: Tween<double>(begin: .94, end: 1).animate(curve),
          child: child,
        ),
      ),
      'slide-horizontal' => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(.08, 0),
          end: Offset.zero,
        ).animate(curve),
        child: FadeTransition(opacity: curve, child: child),
      ),
      'instant' => child,
      _ => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, .12),
          end: Offset.zero,
        ).animate(curve),
        child: FadeTransition(opacity: curve, child: child),
      ),
    };
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
    valueListenable: yingjiBackdropUrl,
    builder: (context, imageUrl, _) => ValueListenableBuilder<String>(
      valueListenable: yingjiBackdropEffect,
      builder: (context, effect, _) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final rawPage = controller.hasClients
              ? (controller.page ?? controller.initialPage.toDouble())
              : controller.initialPage.toDouble();
          final page = rawPage.clamp(0.0, 6.0);
          final depth = Curves.easeOutCubic.transform(page.clamp(0.0, 1.0));
          final deepening = ((page - 1) / 5).clamp(0.0, 1.0);
          final darkness = .08 + .42 * depth + .12 * deepening;
          return RepaintBoundary(
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: YingjiColors.canvas),
                if (imageUrl != null)
                  AnimatedSwitcher(
                    duration: effect == 'instant'
                        ? Duration.zero
                        : const Duration(milliseconds: 900),
                    layoutBuilder: (currentChild, previousChildren) => Stack(
                      fit: StackFit.expand,
                      children: [...previousChildren, ?currentChild],
                    ),
                    transitionBuilder: (child, animation) =>
                        _transition(effect, child, animation),
                    child: CachedNetworkImage(
                      key: ValueKey('clear-$imageUrl'),
                      imageUrl: imageUrl,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) =>
                          const ColoredBox(color: YingjiColors.canvas),
                    ),
                  ),
                if (imageUrl != null)
                  Opacity(
                    opacity: depth,
                    child: RepaintBoundary(
                      child: Transform.scale(
                        scale: 1.05,
                        child: ImageFiltered(
                          imageFilter: ImageFilter.blur(sigmaX: 34, sigmaY: 34),
                          child: CachedNetworkImage(
                            key: ValueKey('blur-$imageUrl'),
                            imageUrl: imageUrl,
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) => const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    ),
                  ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: darkness),
                    gradient: LinearGradient(
                      colors: [
                        Color.lerp(
                          const Color(0xD607090D),
                          const Color(0xE807090D),
                          depth,
                        )!,
                        Color.lerp(
                          const Color(0x2407090D),
                          const Color(0x7407090D),
                          depth,
                        )!,
                        Color.lerp(
                          const Color(0x9A07090D),
                          const Color(0xD807090D),
                          depth,
                        )!,
                      ],
                      stops: const [0, .5, 1],
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                    ),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        const Color(0x0007090D),
                        Color.lerp(
                          const Color(0x7207090D),
                          const Color(0xEE07090D),
                          depth,
                        )!,
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

class _FloatingHomeRail extends StatefulWidget {
  const _FloatingHomeRail({required this.selected, required this.onChanged});
  final _CenterSection selected;
  final ValueChanged<_CenterSection> onChanged;

  @override
  State<_FloatingHomeRail> createState() => _FloatingHomeRailState();
}

class _FloatingHomeRailState extends State<_FloatingHomeRail> {
  bool _showHomeIcon = true;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(
          () => _showHomeIcon = prefs.getBool('yingji.home.show-icon') ?? true,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => Positioned(
    left: 16,
    top: 20,
    bottom: 18,
    child: SizedBox(
      width: 54,
      child: Column(
        children: [
          const YingjiMark(size: 42),
          const SizedBox(height: 26),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_showHomeIcon)
                  _FloatingRailButton(
                    icon: YingjiIcons.house,
                    selected: widget.selected == _CenterSection.home,
                    tooltip: '首页',
                    onPressed: () => widget.onChanged(_CenterSection.home),
                  ),
                const SizedBox(height: 10),
                const _RailDot(),
                const SizedBox(height: 10),
                for (final item in const <(_CenterSection, IconData, String)>[
                  (_CenterSection.discover, YingjiIcons.square_grid_2x2, '发现'),
                  (_CenterSection.calendar, YingjiIcons.calendar, '追剧'),
                  (_CenterSection.playlists, YingjiIcons.heart, '片单'),
                ]) ...[
                  _FloatingRailButton(
                    icon: item.$2,
                    selected: widget.selected == item.$1,
                    tooltip: item.$3,
                    onPressed: () => widget.onChanged(item.$1),
                  ),
                  const SizedBox(height: 10),
                ],
                const _RailDot(),
                const SizedBox(height: 10),
                _FloatingRailButton(
                  icon: YingjiIcons.rectangle_stack,
                  selected: widget.selected == _CenterSection.sources,
                  tooltip: '服务器',
                  onPressed: () => widget.onChanged(_CenterSection.sources),
                ),
              ],
            ),
          ),
          _FloatingRailButton(
            icon: YingjiIcons.gear_alt,
            selected: widget.selected == _CenterSection.settings,
            tooltip: '设置',
            onPressed: () => widget.onChanged(_CenterSection.settings),
          ),
        ],
      ),
    ),
  );
}

class _FloatingHomeDragRegion extends StatelessWidget {
  const _FloatingHomeDragRegion();

  @override
  Widget build(BuildContext context) => const Positioned(
    top: 0,
    left: 0,
    right: 0,
    height: 72,
    child: DragToMoveArea(child: SizedBox.expand()),
  );
}

class _FloatingRailButton extends StatelessWidget {
  const _FloatingRailButton({
    required this.icon,
    required this.selected,
    required this.tooltip,
    required this.onPressed,
  });
  final IconData icon;
  final bool selected;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => YingjiMotionIconButton(
    icon: icon,
    selected: selected,
    tooltip: tooltip,
    onPressed: onPressed,
  );
}

class _RailDot extends StatelessWidget {
  const _RailDot();
  @override
  Widget build(BuildContext context) => Container(
    width: 4,
    height: 4,
    decoration: const BoxDecoration(
      color: Colors.white70,
      shape: BoxShape.circle,
    ),
  );
}

/// A quiet, continuous cue: it responds to every wheel detent before a page
/// commits, so the higher navigation threshold remains discoverable.
class _PageScrollCue extends StatelessWidget {
  const _PageScrollCue({required this.progress});
  final double progress;

  @override
  Widget build(BuildContext context) {
    final active = progress.abs();
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: active == 0 ? .34 : .96,
        duration: const Duration(milliseconds: 120),
        child: Transform.translate(
          offset: Offset(0, -progress * 12),
          child: Container(
            width: 30,
            height: 54,
            decoration: BoxDecoration(
              color: YingjiGlass.chrome(strength: .72),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: YingjiGlass.line(strength: .78)),
            ),
            child: Icon(
              progress.isNegative
                  ? YingjiIcons.chevron_up
                  : YingjiIcons.chevron_down,
              size: 16,
              color: Colors.white.withValues(alpha: .9),
            ),
          ),
        ),
      ),
    );
  }
}

class _FloatingHomeTopBar extends StatelessWidget {
  const _FloatingHomeTopBar({required this.onSearch});
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) => Positioned(
    top: 20,
    right: 14,
    child: Row(
      children: [
        _CircleAction(
          icon: YingjiIcons.search,
          tooltip: '搜索',
          onPressed: onSearch,
        ),
        const SizedBox(width: 8),
        _CircleAction(
          icon: YingjiIcons.minus,
          tooltip: '最小化',
          onPressed: windowManager.minimize,
        ),
        const SizedBox(width: 8),
        _CircleAction(
          icon: YingjiIcons.square,
          tooltip: '最大化',
          onPressed: () async {
            if (await windowManager.isMaximized()) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
          },
        ),
        const SizedBox(width: 8),
        _CircleAction(
          icon: YingjiIcons.xmark,
          tooltip: '关闭',
          onPressed: windowManager.close,
        ),
        const SizedBox(width: 4),
      ],
    ),
  );
}

class _CinematicHome extends StatefulWidget {
  const _CinematicHome();
  @override
  State<_CinematicHome> createState() => _CinematicHomeState();
}

class _CinematicHomeState extends State<_CinematicHome>
    with AutomaticKeepAliveClientMixin, RouteAware {
  final _tmdb = TmdbClient();
  late Future<List<TmdbItem>> _trending;
  List<WatchState> _history = const [];
  bool _historyLoadRunning = false;
  int _hero = 0;
  // 轮播进度由 ValueNotifier 驱动：每 100ms 只刷新圆点层，避免整页重建。
  final ValueNotifier<double> _heroProgress = ValueNotifier<double>(0);
  double _carouselSeconds = 6;
  String _carouselEffect = 'blur-dissolve';
  bool _showContinue = true, _autoCarousel = true, _showCarouselDots = true;
  Timer? _heroTimer;
  final ScrollController _historyScroll = ScrollController();
  final Map<int, TmdbItem> _heroDetails = <int, TmdbItem>{};

  @override
  void initState() {
    super.initState();
    _trending = _loadCarouselItems();
    _loadHomePreferences();
    _loadHistory();
    yingjiHomeFocusTick.addListener(_handleHomeFocus);
    _heroTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      final items = _trendingValue;
      if (items.length < 2 || !_autoCarousel) return;
      final next = _heroProgress.value + .1 / _carouselSeconds;
      if (next < 1) {
        // 仅推进进度：只触发圆点层的 ValueListenableBuilder，不重建整页。
        _heroProgress.value = next;
        return;
      }
      _heroProgress.value = 0;
      // 只有真正切换到下一张时才需要整页重建（背景/标题/简介变化）。
      setState(() {
        _hero = (_hero + 1) % items.length.clamp(1, 8);
      });
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      yingjiRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPopNext() {
    // A detail page or the player closed above the home route; both may have
    // persisted new watch progress that the continue-watching shelf must show.
    _loadHistory();
  }

  /// The shell re-shows this tab (or an external request navigated back to it):
  /// pull the server resume rails again so the shelf reflects playback that
  /// happened on other devices while this page was off-screen.
  void _handleHomeFocus() => _loadHistory();

  List<TmdbItem> _trendingValue = const [];

  Future<void> _loadHomePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _carouselSeconds = (prefs.getDouble('yingji.home.carousel-seconds') ?? 6)
          .clamp(3, 15);
      final savedEffect = prefs.getString('yingji.home.carousel-effect');
      _carouselEffect = savedEffect == null || savedEffect == 'slide-fade'
          ? 'blur-dissolve'
          : savedEffect;
      yingjiBackdropEffect.value = _carouselEffect;
      _showContinue = prefs.getBool('yingji.home.continue-watching') ?? true;
      _autoCarousel = prefs.getBool('yingji.home.auto-carousel') ?? true;
      _showCarouselDots = prefs.getBool('yingji.home.show-dots') ?? true;
    });
  }

  Future<List<TmdbItem>> _loadCarouselItems() async {
    final prefs = await SharedPreferences.getInstance();
    final source = prefs.getString('yingji.home.carousel-source') ?? 'trending';
    final items = await switch (source) {
      'popular-movies' => _tmdb.popularMovies(),
      'popular-shows' => _tmdb.popularShows(),
      'top-rated' => _tmdb.topRatedMovies(),
      _ => _tmdb.trending(),
    };
    unawaited(_prefetchHeroDetails(items.take(8).toList(growable: false)));
    return items;
  }

  Future<void> _prefetchHeroDetails(List<TmdbItem> items) async {
    await Future.wait(
      items.map((item) async {
        try {
          final detail = await _tmdb.details(item.id, kind: item.kind);
          if (!mounted) return;
          setState(() => _heroDetails[item.id] = detail);
        } catch (_) {
          // The list item remains usable when optional artwork lookup fails.
        }
      }),
    );
  }

  Future<void> _loadHistory() async {
    // Several callers (init, didPopNext, shelf callbacks) may fire while a
    // previous refresh is still fetching server resume items; the guard keeps
    // refreshes serialized so the UI never stacks duplicate network work.
    if (_historyLoadRunning) return;
    _historyLoadRunning = true;
    try {
      final store = await WatchStateStore.create();
      final local = store.load();
      // Local records are authoritative for what this device just watched, so
      // surface them immediately; the server merge below only fills gaps and
      // never overwrites fresher local progress.
      final visible = continueWatchingRows(local);
      if (mounted && !_sameWatchStates(_history, visible)) {
        setState(() => _history = visible);
      }
      final merged = await _mergeServerWatchHistory(store, local);
      if (mounted && !_sameWatchStates(_history, merged)) {
        setState(() => _history = merged);
      }
    } finally {
      _historyLoadRunning = false;
    }
  }

  /// The server merge is shared with the full "continue watching" page, so it
  /// lives as a top-level helper below this class: [_mergeServerWatchHistory]
  /// pulls every server's resume rail and reconciles it with the local store,
  /// and [_sameWatchStates] reports whether two shelf lists differ.

  @override
  void dispose() {
    yingjiHomeFocusTick.removeListener(_handleHomeFocus);
    yingjiRouteObserver.unsubscribe(this);
    _heroTimer?.cancel();
    _heroProgress.dispose();
    _historyScroll.dispose();
    _tmdb.dispose();
    super.dispose();
  }

  void _moveHistory(double delta) {
    if (!_historyScroll.hasClients) return;
    _historyScroll.animateTo(
      (_historyScroll.offset + delta).clamp(
        0,
        _historyScroll.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  void _openHeroDetails(BuildContext context, TmdbItem item) {
    if (item.id == 0) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => MetadataDetailPage(item: item)),
    );
  }

  void _moveHero(int delta, int itemCount) {
    if (itemCount < 2) return;
    setState(() {
      _hero = (_hero + delta) % itemCount;
      if (_hero < 0) _hero += itemCount;
    });
    _heroProgress.value = 0;
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<List<TmdbItem>>(
      future: _trending,
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <TmdbItem>[];
        _trendingValue = items;
        if (items.isEmpty &&
            snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final baseSelected = items.isEmpty
            ? const TmdbItem(
                id: 0,
                title: 'Mova',
                kind: '媒体中心',
                overview: '元数据服务暂时不可用，但你仍可以从继续观看中播放本地记录。',
              )
            : items[_hero.clamp(0, items.length - 1)];
        final selected = _heroDetails[baseSelected.id] ?? baseSelected;
        final heroArtwork = selected.backdropUrl ?? selected.posterUrl;
        final heroArtworkValue = heroArtwork?.toString();
        if (yingjiBackdropUrl.value != heroArtworkValue) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            yingjiBackdropUrl.value = heroArtworkValue;
          });
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxHeight < 760;
            // A continuation tile contains a 16:9 image plus two metadata
            // lines. The old shelf was shorter than that content, so its
            // metadata leaked into the cinematic canvas and appeared covered.
            final continueHeight = compact ? 244.0 : 268.0;
            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => _openHeroDetails(context, selected),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: 84,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => _moveHero(-1, items.length),
                  ),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: 84,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => _moveHero(1, items.length),
                  ),
                ),
                Positioned(
                  left: 96,
                  top: compact ? 86 : 104,
                  right: 420,
                  bottom: _showContinue ? continueHeight + 126 : 72,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (items.isEmpty) ...[
                        _HomeNetworkNotice(
                          message: _networkError(snapshot.error),
                          onRetry: () =>
                              setState(() => _trending = _loadCarouselItems()),
                        ),
                        const SizedBox(height: 16),
                      ],
                      Flexible(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 650),
                          child: SizedBox(
                            width: 650,
                            height: compact ? 104 : 132,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 360),
                              layoutBuilder: (currentChild, previousChildren) =>
                                  Stack(
                                    alignment: Alignment.centerLeft,
                                    children: [
                                      ...previousChildren,
                                      ?currentChild,
                                    ],
                                  ),
                              transitionBuilder: (child, animation) =>
                                  FadeTransition(
                                    opacity: animation,
                                    child: child,
                                  ),
                              child: Align(
                                key: ValueKey(
                                  selected.logoUrl?.toString() ??
                                      'title-${selected.id}',
                                ),
                                alignment: Alignment.centerLeft,
                                child: selected.logoUrl == null
                                    ? Text(
                                        selected.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: compact ? 56 : 72,
                                          height: .96,
                                          letterSpacing: -2.2,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      )
                                    : CachedNetworkImage(
                                        imageUrl: selected.logoUrl.toString(),
                                        width: 560,
                                        height: compact ? 104 : 132,
                                        alignment: Alignment.centerLeft,
                                        fit: BoxFit.contain,
                                        errorWidget: (_, _, _) => Text(
                                          selected.title,
                                          style: TextStyle(
                                            fontSize: compact ? 56 : 72,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _MetaLine(item: selected),
                      const SizedBox(height: 14),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 610),
                        child: YingjiSynopsisTooltip(
                          message: selected.overview?.isNotEmpty == true
                              ? selected.overview!
                              : '从你的媒体库与可信元数据服务开始，建立属于自己的观影空间。',
                          child: Text(
                            selected.overview?.isNotEmpty == true
                                ? selected.overview!
                                : '从你的媒体库与可信元数据服务开始，建立属于自己的观影空间。',
                            maxLines: compact ? 2 : 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFE6E8ED),
                              height: 1.5,
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_showCarouselDots)
                  Positioned(
                    right: 48,
                    bottom: _showContinue ? continueHeight + 136 : 44,
                    child: ValueListenableBuilder<double>(
                      valueListenable: _heroProgress,
                      builder: (context, progress, _) => _HeroProgressDots(
                        length: items.length.clamp(1, 8),
                        active: _hero,
                        progress: progress,
                        onChanged: (value) {
                          setState(() => _hero = value);
                          _heroProgress.value = 0;
                        },
                      ),
                    ),
                  ),
                if (_showContinue)
                  Positioned(
                    left: 84,
                    right: 24,
                    bottom: 42,
                    height: continueHeight + 28,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              YingjiGlass.surface(strength: .56),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_showContinue)
                  Positioned(
                    left: 96,
                    right: 40,
                    bottom: 56,
                    height: continueHeight,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SectionHeader(
                          title: '继续播放',
                          subtitle: '接着上次停下的位置',
                          action: _history.isEmpty ? null : '查看全部继续播放',
                          actionIcon: YingjiIcons.rectangle_stack,
                          onAction: _history.isEmpty
                              ? null
                              : () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const _ContinueWatchingPage(),
                                  ),
                                ).then((_) => _loadHistory()),
                          trailingActions: _history.length > 1
                              ? [
                                  YingjiDirectionalArrow(
                                    previous: true,
                                    tooltip: '向左浏览继续播放',
                                    onPressed: () => _moveHistory(-560),
                                  ),
                                  const SizedBox(width: 7),
                                  YingjiDirectionalArrow(
                                    previous: false,
                                    tooltip: '向右浏览继续播放',
                                    onPressed: () => _moveHistory(560),
                                  ),
                                ]
                              : const [],
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: _history.isEmpty
                              ? const _EmptyStrip(
                                  icon: YingjiIcons.play_circle,
                                  title: '还没有观看记录',
                                  detail: '开始播放任意媒体后，会在这里显示可续播的内容。',
                                )
                              : _HistoryStrip(
                                  history: _history,
                                  onChanged: _loadHistory,
                                  controller: _historyScroll,
                                ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Fetches the resume rail of every configured media server and folds the
/// rows into [local] without destroying fresher local progress. Rules:
///  * A record missing locally is appended (its server last-played time is
///    kept when the server provides one) and persisted.
///  * An existing record is replaced only when the server is genuinely newer:
///    either its last-played time is later than this device's save time (the
///    same title was watched again — possibly on another device), or, when the
///    server sends no timestamp, its position is >30s ahead. A server whose
///    progress report has not arrived yet carries an *older* last-played time
///    and can therefore never clobber progress this device just saved.
/// Whatever the merge adopts, the returned list is ordered for the shelf:
/// rows with a real last-watch time first (newest first), then undated rows
/// in the order the server returned them. It is not truncated here — when a
/// server is configured its entire resume rail must surface, so the shelf
/// matches the server instead of only the 60-row local cache.
Future<List<WatchState>> _mergeServerWatchHistory(
  WatchStateStore store,
  List<WatchState> local,
) async {
  final merged = <WatchState>[...local];
  final remote = <WatchState>[];
  try {
    final sources = await SourceStore.create();
    for (final source in sources.load()) {
      if (source.kind == SourceKind.webdav) continue;
      final token = sources.tokenFor(source);
      if (token == null || token.isEmpty) continue;
      final client = EmbyClient();
      try {
        final session = await client.resolveSession(
          EmbySession(source: source, token: token),
        );
        if (session.source.endpoint != source.endpoint) {
          await sources.upsert(session.source, token);
        }
        final items = await client.resumeItems(session);
        remote.addAll(
          items.map(
            (item) => WatchState(
              mediaId: item.playbackUrl?.toString() ?? item.id,
              title: item.seriesTitle?.isNotEmpty == true
                  ? item.seriesTitle!
                  : item.title,
              episodeTitle: item.seriesTitle?.isNotEmpty == true
                  ? item.title
                  : null,
              seasonNumber: item.seasonNumber,
              episodeNumber: item.episodeNumber,
              position: item.playbackPosition ?? Duration.zero,
              duration: item.runtime ?? Duration.zero,
              imageUrl: item.imageUrl?.toString(),
              sourceId: item.source.id,
              serverItemId: item.id,
              tmdbId: int.tryParse(item.providerIds['Tmdb'] ?? ''),
              updatedAt: item.lastPlayedAt,
              isPlayed: item.isPlayed,
              progressOrigin: 'server',
              progressOriginName: source.name,
            ),
          ),
        );
      } catch (_) {
        // A disconnected source must not hide local continue-watching rows.
      } finally {
        client.dispose();
      }
    }
  } catch (_) {
    // SourceStore may be unavailable on first launch; local history remains.
  }
  for (final state in remote) {
    final existingIndex = merged.indexWhere(
      (item) =>
          (state.serverItemId != null &&
              item.sourceId == state.sourceId &&
              item.serverItemId == state.serverItemId) ||
          item.mediaId == state.mediaId,
    );
    if (existingIndex == -1) {
      // No record on this device yet: the server entry is the only source.
      // Append instead of forcing it to the front; the final recency sort
      // places it where its real last-played time belongs. The server's own
      // timestamp (when present) is kept verbatim — a row without one must
      // never be stamped "now", or a title watched weeks ago would masquerade
      // as freshly watched and leap over genuinely recent records.
      merged.add(state);
      continue;
    }
    final existing = merged[existingIndex];
    final serverTime = state.updatedAt;
    final localTime = existing.updatedAt;
    // The server row supersedes the local one when it reflects a later watch
    // session (newer last-played time) — e.g. the same title was watched on
    // another device after this one finished with it. When the server sends
    // no timestamp we fall back to the position heuristic (>30s ahead) that
    // spots progress reported from another device.
    final serverNewer =
        serverTime != null &&
        (localTime == null || serverTime.isAfter(localTime));
    final serverAhead =
        serverTime == null &&
        !serverNewer &&
        state.duration > Duration.zero &&
        state.position > existing.position + const Duration(seconds: 30);
    if (!serverNewer && !serverAhead) continue; // Local is at least as fresh.
    // Adopt the server content. Its timestamp for ordering is the later of
    // the server's last-played time and this device's save time, keeping the
    // shelf and the store consistent. When neither side carries a timestamp
    // the row stays undated instead of being stamped "now", so a record from
    // another device with unknown watch time never jumps above fresh ones.
    // The record stays at its current index — the final recency sort decides
    // the visible order.
    final bestTime =
        (serverTime != null &&
            (localTime == null || serverTime.isAfter(localTime)))
        ? serverTime
        : localTime;
    final adopted = bestTime == null ? state : state.withUpdatedAt(bestTime);
    merged[existingIndex] = adopted;
  }
  try {
    final prefs = await SharedPreferences.getInstance();
    final clientId = prefs.getString('yingji.trakt.client-id') ?? '';
    final token = prefs.getString('yingji.trakt.access-token') ?? '';
    if (clientId.isNotEmpty && token.isNotEmpty) {
      final trakt = TraktClient();
      try {
        final rows = await trakt.playbackProgress(
          clientId: clientId,
          accessToken: token,
        );
        for (final row in rows) {
          final index = merged.indexWhere(
            (state) =>
                state.tmdbId == row.tmdbId &&
                state.seasonNumber == row.seasonNumber &&
                state.episodeNumber == row.episodeNumber &&
                state.duration > Duration.zero,
          );
          if (index < 0) continue;
          final current = merged[index];
          final traktNewer =
              row.pausedAt != null &&
              (current.updatedAt == null ||
                  row.pausedAt!.isAfter(current.updatedAt!));
          final position = Duration(
            milliseconds: (current.duration.inMilliseconds * row.progress / 100)
                .round(),
          );
          if (!traktNewer && position <= current.position) continue;
          merged[index] = current.withProgress(
            position: position,
            updatedAt: row.pausedAt ?? current.updatedAt,
            origin: 'trakt',
            originName: 'Trakt',
          );
        }
      } finally {
        trakt.dispose();
      }
    }
  } catch (_) {
    // Trakt is optional; playable local and server rows remain available.
  }
  _demoteFabricatedImportBursts(merged);
  final ordered = _orderForShelf(merged, remote);
  // Persist the exact order the shelf will show. Without this the stored
  // undated rows stayed in reverse rail order (each per-row import() had put
  // its row at the head of the undated block) and any render that starts from
  // the local store — e.g. the home shelf right after the full continue list
  // page pops back — flashed that wrong order until a merge had re-run.
  await store.replaceAll(ordered);
  return continueWatchingRows(ordered);
}

/// Orders the reconciled rows for the continue-watching shelf. Rows carrying
/// a real last-watch time go first, newest first. The final shared sort applies
/// the fallback priority Trakt, server, then local to every undated row.
List<WatchState> _orderForShelf(
  List<WatchState> merged,
  List<WatchState> remote,
) {
  if (merged.length <= 1) return merged;
  final ordered = <WatchState>[];
  final placed = List<bool>.filled(merged.length, false);
  void place(int i) {
    if (placed[i]) return;
    ordered.add(merged[i]);
    placed[i] = true;
  }

  // 1) Dated rows, newest first.
  final dated = <int>[];
  for (var i = 0; i < merged.length; i++) {
    if (merged[i].updatedAt != null) dated.add(i);
  }
  dated.sort((a, b) => merged[b].updatedAt!.compareTo(merged[a].updatedAt!));
  for (final i in dated) {
    place(i);
  }
  // 2) Undated rows the server returned, in the server's rail order.
  for (final serverRow in remote) {
    final id = serverRow.serverItemId;
    if (id == null || serverRow.updatedAt != null) continue;
    for (var i = 0; i < merged.length; i++) {
      if (placed[i]) continue;
      if (merged[i].serverItemId == id) {
        place(i);
        break;
      }
    }
  }
  // 3) Anything left (local-only rows) keeps its stored order.
  for (var i = 0; i < merged.length; i++) {
    place(i);
  }
  return sortWatchStatesByRecency(ordered);
}

/// Undoes the damage of an older merge bug that stamped server rows with
/// `DateTime.now()` whenever the server reported no last-played time. That
/// fabricated a "watched just now" time for every imported row, so titles
/// watched weeks ago clustered at the top of the shelf and real recency was
/// lost. Such writes always arrive in bulk: the whole server rail is imported
/// within a second or two, so many rows end up sharing the same wall-clock
/// second. A genuine device watch, by contrast, stamps exactly one row at the
/// moment playback stops — it can never cluster three rows in one second.
///
/// Rows whose timestamp sits in a same-second cluster of three or more
/// server-managed entries are demoted to undated: they keep their content and
/// fall back to server-rail order (after every genuinely dated record) instead
/// of squatting on the shelf top. Idempotent — demoted rows are undated and no
/// longer re-cluster on later refreshes. Demotion is applied to [merged] in
/// memory only; the caller persists the result once via replaceAll.
void _demoteFabricatedImportBursts(List<WatchState> merged) {
  final counts = <int, int>{};
  for (final row in merged) {
    final time = row.updatedAt;
    if (time == null || row.serverItemId == null) continue;
    final second = time.millisecondsSinceEpoch ~/ 1000;
    counts[second] = (counts[second] ?? 0) + 1;
  }
  for (var i = 0; i < merged.length; i++) {
    final row = merged[i];
    final time = row.updatedAt;
    if (time == null || row.serverItemId == null) continue;
    final second = time.millisecondsSinceEpoch ~/ 1000;
    if ((counts[second] ?? 0) < 3) continue; // Not a bulk-import burst.
    merged[i] = row.withUpdatedAt(null);
  }
}

/// True when two shelf lists would render identically (same rows in the same
/// order with the same progress), so refreshed results can skip a rebuild.
bool _sameWatchStates(List<WatchState> a, List<WatchState> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].mediaId != b[i].mediaId ||
        a[i].position != b[i].position ||
        a[i].duration != b[i].duration ||
        a[i].progressOrigin != b[i].progressOrigin ||
        a[i].progressOriginName != b[i].progressOriginName) {
      return false;
    }
  }
  return true;
}

class _DiscoverPage extends StatefulWidget {
  const _DiscoverPage();
  @override
  State<_DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<_DiscoverPage> {
  final _tmdb = TmdbClient();
  final _trakt = TraktClient();
  final _tvMaze = http.Client();
  static const _sectionsKey = 'yingji.discover.sections';
  static const _stylesKey = 'yingji.discover.card-styles';
  static const _sourcesKey = 'yingji.discover.section-sources';
  static const _hiddenKey = 'yingji.discover.hidden-sections';
  static const _styleNames = ['沉浸海报', '剧照横幅', '动态排行', '平台入口'];
  static const _defaultSections = <String>[
    '今日热门电视剧',
    '今日热门电影',
    '今日播出剧集',
    '本周播出剧集',
    '院线热映',
    '高分电影',
    '高分剧集',
    '热门国产电视剧',
    '热门国产电影',
    '热门综艺',
    '热门国产动漫',
    '热门番剧',
    '热门韩剧',
    '热门日剧',
    '热门台剧',
    '按分类',
    '按平台',
  ];
  static const _sourceLabels = <String, String>{
    '今日热门电视剧': 'TMDB · 今日热门电视剧',
    '今日热门电影': 'TMDB · 今日热门电影',
    '本周热门电视剧': 'TMDB · 本周热门电视剧',
    '本周热门电影': 'TMDB · 本周热门电影',
    '热门电视剧': 'TMDB · 热门电视剧',
    '热门电影': 'TMDB · 热门电影',
    '今日播出剧集': 'TMDB · 今日播出剧集',
    '本周播出剧集': 'TMDB · 本周播出剧集',
    '院线热映': 'TMDB · 院线热映',
    '即将上映': 'TMDB · 即将上映',
    '高分电影': 'TMDB · 高分电影',
    '高分剧集': 'TMDB · 高分剧集',
    '热门国产电视剧': 'TMDB · 国产电视剧',
    '热门国产电影': 'TMDB · 国产电影',
    '热门综艺': 'TMDB · 热门综艺',
    '热门国产动漫': 'TMDB · 国产动漫',
    '热门番剧': 'TMDB · 日本动漫',
    '热门韩剧': 'TMDB · 韩国剧集',
    '热门日剧': 'TMDB · 日本剧集',
    '热门台剧': 'TMDB · 台湾剧集',
    '动作电影': 'TMDB · 动作电影',
    '喜剧电影': 'TMDB · 喜剧电影',
    '科幻电影': 'TMDB · 科幻电影',
    '悬疑电影': 'TMDB · 悬疑电影',
    '恐怖电影': 'TMDB · 恐怖电影',
    '纪录片': 'TMDB · 纪录片',
    '家庭电影': 'TMDB · 家庭电影',
    'Netflix': 'TMDB · Netflix',
    'Disney+': 'TMDB · Disney+',
    'Prime Video': 'TMDB · Prime Video',
    'Apple TV+': 'TMDB · Apple TV+',
    '流媒体综合': 'TMDB · 流媒体综合',
    '按分类': 'TMDB · 动作分类',
    '按平台': 'TMDB · 流媒体综合',
    'trakt.movies.trending': 'Trakt · 趋势电影',
    'trakt.movies.popular': 'Trakt · 热门电影',
    'trakt.movies.anticipated': 'Trakt · 最受期待电影',
    'trakt.movies.boxoffice': 'Trakt · 周末票房',
    'trakt.movies.watched': 'Trakt · 本周观看电影',
    'trakt.movies.collected': 'Trakt · 本周收藏电影',
    'trakt.movies.played': 'Trakt · 本周播放电影',
    'trakt.shows.trending': 'Trakt · 趋势剧集',
    'trakt.shows.popular': 'Trakt · 热门剧集',
    'trakt.shows.anticipated': 'Trakt · 最受期待剧集',
    'trakt.shows.watched': 'Trakt · 本周观看剧集',
    'trakt.shows.collected': 'Trakt · 本周收藏剧集',
    'trakt.shows.played': 'Trakt · 本周播放剧集',
  };
  static const _providerLabels = <String, String>{
    'tmdb': 'TMDB',
    'trakt': 'Trakt',
    'mdblist': 'MDBList',
    'douban': '豆瓣公开榜单',
    'tvmaze': 'TVmaze',
  };
  static const _mediaLabels = <String, String>{'movie': '电影', 'tv': '剧集'};
  static const _countryLabels = <String, String>{
    'all': '全部地区',
    'CN': '中国大陆',
    'HK': '中国香港',
    'TW': '中国台湾',
    'US': '美国',
    'GB': '英国',
    'JP': '日本',
    'KR': '韩国',
    'TH': '泰国',
    'IN': '印度',
    'FR': '法国',
    'DE': '德国',
    'ES': '西班牙',
    'IT': '意大利',
    'CA': '加拿大',
    'AU': '澳大利亚',
  };

  static String _normalizedSource(String source) {
    if (_DiscoverFeedSelection.tryParse(source) != null) return source;
    if (source.startsWith('trakt.')) {
      final parts = source.split('.');
      return _DiscoverFeedSelection(
        provider: 'trakt',
        mediaType: parts.length > 1 && parts[1] == 'shows' ? 'tv' : 'movie',
        genre: 'all',
        heat: parts.last,
      ).encoded;
    }
    final selection = switch (source) {
      '今日热门电视剧' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'tv',
        genre: 'all',
        heat: 'trending',
      ),
      '今日热门电影' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'movie',
        genre: 'all',
        heat: 'trending',
      ),
      '本周热门电视剧' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'tv',
        genre: 'all',
        heat: 'trending_week',
      ),
      '本周热门电影' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'movie',
        genre: 'all',
        heat: 'trending_week',
      ),
      '热门电视剧' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'tv',
        genre: 'all',
        heat: 'popular',
      ),
      '热门电影' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'movie',
        genre: 'all',
        heat: 'popular',
      ),
      '今日播出剧集' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'tv',
        genre: 'all',
        heat: 'airing_today',
      ),
      '本周播出剧集' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'tv',
        genre: 'all',
        heat: 'on_the_air',
      ),
      '院线热映' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'movie',
        genre: 'all',
        heat: 'now_playing',
        country: 'CN',
      ),
      '即将上映' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'movie',
        genre: 'all',
        heat: 'upcoming',
        country: 'CN',
      ),
      '高分电影' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'movie',
        genre: 'all',
        heat: 'top_rated',
      ),
      '高分剧集' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'tv',
        genre: 'all',
        heat: 'top_rated',
      ),
      '热门国产电视剧' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'tv',
        genre: 'all',
        heat: 'popularity.desc',
        country: 'CN',
      ),
      '热门国产电影' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'movie',
        genre: 'all',
        heat: 'popularity.desc',
        country: 'CN',
      ),
      '热门综艺' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'tv',
        genre: 'reality',
        heat: 'popularity.desc',
      ),
      '热门国产动漫' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'tv',
        genre: 'animation',
        heat: 'popularity.desc',
        country: 'CN',
      ),
      '热门番剧' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'tv',
        genre: 'animation',
        heat: 'popularity.desc',
        country: 'JP',
      ),
      '热门韩剧' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'tv',
        genre: 'all',
        heat: 'popularity.desc',
        country: 'KR',
      ),
      '热门日剧' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'tv',
        genre: 'all',
        heat: 'popularity.desc',
        country: 'JP',
      ),
      '热门台剧' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'tv',
        genre: 'all',
        heat: 'popularity.desc',
        country: 'TW',
      ),
      '动作电影' || '按分类' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'movie',
        genre: 'action',
        heat: 'popularity.desc',
      ),
      '喜剧电影' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'movie',
        genre: 'comedy',
        heat: 'popularity.desc',
      ),
      '科幻电影' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'movie',
        genre: 'scifi',
        heat: 'popularity.desc',
      ),
      '悬疑电影' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'movie',
        genre: 'mystery',
        heat: 'popularity.desc',
      ),
      '恐怖电影' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'movie',
        genre: 'horror',
        heat: 'popularity.desc',
      ),
      '纪录片' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'movie',
        genre: 'documentary',
        heat: 'popularity.desc',
      ),
      '家庭电影' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'movie',
        genre: 'family',
        heat: 'popularity.desc',
      ),
      'Netflix' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'tv',
        genre: 'all',
        heat: 'popularity.desc',
        platform: 'watch:8',
      ),
      'Disney+' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'tv',
        genre: 'all',
        heat: 'popularity.desc',
        platform: 'watch:337',
      ),
      'Prime Video' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'tv',
        genre: 'all',
        heat: 'popularity.desc',
        platform: 'watch:119',
      ),
      'Apple TV+' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'tv',
        genre: 'all',
        heat: 'popularity.desc',
        platform: 'watch:350',
      ),
      '流媒体综合' || '按平台' => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'tv',
        genre: 'all',
        heat: 'popularity.desc',
        platform: 'watch:8',
      ),
      _ => const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'movie',
        genre: 'all',
        heat: 'popularity.desc',
      ),
    };
    return selection.encoded;
  }

  final Map<String, int> _cardStyles = {};
  final Map<String, String> _sectionSources = {};
  final Set<String> _hiddenSections = {};
  late Future<Map<String, List<TmdbItem>>> _items;
  List<String> _sections = List.of(_defaultSections);

  @override
  void initState() {
    super.initState();
    _items = _initializeSections();
  }

  @override
  void dispose() {
    _tmdb.dispose();
    _trakt.dispose();
    _tvMaze.close();
    super.dispose();
  }

  Future<Map<String, List<TmdbItem>>> _initializeSections() async {
    await _restoreLayout();
    return _loadSections();
  }

  Future<void> _restoreLayout() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_sectionsKey);
    if (saved != null) {
      _sections = saved.toSet().toList(growable: true);
    }
    final rawStyles = prefs.getString(_stylesKey);
    if (rawStyles != null) {
      try {
        final decoded = jsonDecode(rawStyles);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            if (_sections.contains(entry.key) &&
                entry.value is int &&
                entry.value >= 0 &&
                entry.value < _styleNames.length) {
              _cardStyles[entry.key as String] = entry.value as int;
            }
          }
        }
      } on FormatException {
        // Retain the normal layout when old preference data is malformed.
      }
    }
    final rawSources = prefs.getString(_sourcesKey);
    if (rawSources != null) {
      try {
        final decoded = jsonDecode(rawSources);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final section = '${entry.key}';
            final source = '${entry.value}';
            if (_sections.contains(section) &&
                (_sourceLabels.containsKey(source) ||
                    _DiscoverFeedSelection.tryParse(source) != null)) {
              _sectionSources[section] = source;
            }
          }
        }
      } on FormatException {
        // Ignore malformed preferences and retain each section's own feed.
      }
    }
    for (final section in _sections) {
      _sectionSources[section] = _normalizedSource(
        _sectionSources[section] ?? section,
      );
    }
    _hiddenSections.addAll(
      (prefs.getStringList(_hiddenKey) ?? const []).where(_sections.contains),
    );
    _groupSectionsByVisibility();
  }

  Future<void> _persistLayout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_sectionsKey, _sections);
    await prefs.setString(_stylesKey, jsonEncode(_cardStyles));
    await prefs.setString(_sourcesKey, jsonEncode(_sectionSources));
    await prefs.setStringList(_hiddenKey, _hiddenSections.toList());
  }

  void _groupSectionsByVisibility() {
    _sections = [
      ..._sections.where((section) => !_hiddenSections.contains(section)),
      ..._sections.where(_hiddenSections.contains),
    ];
  }

  String _sourceLabel(String source) {
    final custom = _DiscoverFeedSelection.tryParse(source);
    if (custom == null) return _sourceLabels[source] ?? source;
    final listLabels = custom.provider == 'tmdb'
        ? (custom.mediaType == 'tv'
              ? _DiscoverSourceEditor._tmdbTvLists
              : _DiscoverSourceEditor._tmdbMovieLists)
        : custom.provider == 'trakt'
        ? (custom.mediaType == 'tv'
              ? _DiscoverSourceEditor._traktTvLists
              : _DiscoverSourceEditor._traktMovieLists)
        : custom.provider == 'mdblist'
        ? _DiscoverSourceEditor._mdbListLists
        : custom.provider == 'douban'
        ? _DiscoverSourceEditor._doubanLists
        : _DiscoverSourceEditor._tvMazeLists;
    final details = <String>[
      _mediaLabels[custom.mediaType]!,
      if (custom.country != 'all') _countryLabels[custom.country]!,
      if (custom.platform != 'all')
        custom.platforms
            .map((value) => _resolvedPlatformLabels[value] ?? '平台 $value')
            .join('、'),
      listLabels[custom.heat] ?? custom.heat,
    ];
    return '${_providerLabels[custom.provider]} · '
        '${details.join(' · ')}';
  }

  String _filterSummary(String source) {
    final value = _DiscoverFeedSelection.tryParse(_normalizedSource(source));
    if (value == null) return _sourceLabel(source);
    final lists = value.provider == 'tmdb'
        ? (value.mediaType == 'tv'
              ? _DiscoverSourceEditor._tmdbTvLists
              : _DiscoverSourceEditor._tmdbMovieLists)
        : value.provider == 'trakt'
        ? (value.mediaType == 'tv'
              ? _DiscoverSourceEditor._traktTvLists
              : _DiscoverSourceEditor._traktMovieLists)
        : value.provider == 'mdblist'
        ? _DiscoverSourceEditor._mdbListLists
        : value.provider == 'douban'
        ? _DiscoverSourceEditor._doubanLists
        : _DiscoverSourceEditor._tvMazeLists;
    final genres = value.mediaType == 'tv'
        ? _DiscoverSourceEditor._tvGenres
        : _DiscoverSourceEditor._movieGenres;
    return <String>[
      _providerLabels[value.provider] ?? value.provider,
      _mediaLabels[value.mediaType] ?? value.mediaType,
      if (value.country != 'all')
        _countryLabels[value.country] ?? value.country,
      lists[value.heat] ?? value.heat,
      if (value.genre != 'all') genres[value.genre] ?? value.genre,
      if (value.language != 'all')
        _DiscoverSourceEditor._languageLabels[value.language] ?? value.language,
      if (value.year != 'all') '${value.year} 年',
      if (value.minimumRating != 'all') '${value.minimumRating} 分以上',
      if (value.minimumVotes != 'all') '${value.minimumVotes} 人评分以上',
      if (value.runtime != 'all')
        _DiscoverSourceEditor._runtimeLabels[value.runtime] ?? value.runtime,
      if (value.releaseWindow != 'all')
        _DiscoverSourceEditor._releaseLabels[value.releaseWindow] ??
            value.releaseWindow,
      if (value.platform != 'all')
        value.platforms
            .map((item) => _resolvedPlatformLabels[item] ?? item)
            .join('、'),
    ].join(' · ');
  }

  Future<void> _addDiscoverSection() async {
    var suffix = _sections.length + 1;
    var title = '新列表 $suffix';
    while (_sections.contains(title)) {
      suffix++;
      title = '新列表 $suffix';
    }
    final visibleCount = _sections
        .where((item) => !_hiddenSections.contains(item))
        .length;
    setState(() {
      _sections.insert(visibleCount, title);
      _sectionSources[title] = const _DiscoverFeedSelection(
        provider: 'tmdb',
        mediaType: 'movie',
        genre: 'all',
        heat: 'popularity.desc',
      ).encoded;
      _cardStyles[title] = 0;
      _items = _loadSections();
    });
    await _persistLayout();
    if (mounted) await _showSectionSettings(title);
  }

  Future<void> _showSectionSettings(String initialSection) async {
    if (!_sections.contains(initialSection)) return;
    var titleDraft = initialSection;
    var source = _normalizedSource(
      _sectionSources[initialSection] ?? initialSection,
    );
    var previewItems = _loadSection(source, 1);
    var style =
        _cardStyles[initialSection] ?? _sections.indexOf(initialSection) % 4;
    var visible = !_hiddenSections.contains(initialSection);
    String? error;
    var deleted = false;
    var changed = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) => YingjiPinnedDialog(
          maxWidth: 660,
          maxHeight: 760,
          header: Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '列表设置',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    SizedBox(height: 5),
                    Text(
                      '只调整当前列表；添加、排序与其他列表互不受影响。',
                      style: TextStyle(color: YingjiColors.muted),
                    ),
                  ],
                ),
              ),
              YingjiMotionIconButton(
                icon: YingjiIcons.trash,
                tooltip: '删除列表',
                size: 38,
                onPressed: () {
                  deleted = true;
                  changed = true;
                  Navigator.pop(dialogContext);
                },
              ),
              const SizedBox(width: 8),
              YingjiMotionIconButton(
                icon: YingjiIcons.xmark,
                tooltip: '关闭',
                size: 38,
                onPressed: () => Navigator.pop(dialogContext),
              ),
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                key: ValueKey('discover-name-$initialSection'),
                initialValue: titleDraft,
                decoration: InputDecoration(
                  labelText: '列表名称',
                  errorText: error,
                ),
                onChanged: (value) => updateDialog(() {
                  titleDraft = value;
                  error = null;
                }),
              ),
              const SizedBox(height: 14),
              _ToggleRow(
                title: '显示此列表',
                detail: visible ? '当前显示在发现页中' : '当前已隐藏，可随时重新显示',
                value: visible,
                onChanged: (value) => updateDialog(() {
                  visible = value;
                  changed = true;
                }),
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: YingjiGlass.chrome(strength: .72),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '当前筛选  ${_filterSummary(source)}',
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: YingjiColors.muted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _DiscoverSourceEditor(
                value: source,
                style: style,
                providerLabels: _providerLabels,
                mediaLabels: _mediaLabels,
                countryLabels: _countryLabels,
                onChanged: (value) => updateDialog(() {
                  source = value;
                  previewItems = _loadSection(value, 1);
                  changed = true;
                }),
              ),
              const SizedBox(height: 18),
              const Text('卡片样式', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              FutureBuilder<List<TmdbItem>>(
                future: previewItems,
                builder: (context, snapshot) => Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (var index = 0; index < _styleNames.length; index++)
                      SizedBox(
                        width: 140,
                        child: _DiscoveryStylePreview(
                          label: _styleNames[index],
                          style: index,
                          selected: style == index,
                          items: snapshot.data ?? const [],
                          source: source,
                          loading:
                              snapshot.connectionState ==
                              ConnectionState.waiting,
                          onTap: () => updateDialog(() {
                            style = index;
                            if (index == 3) {
                              final selection = _DiscoverFeedSelection.tryParse(
                                source,
                              );
                              if (selection?.provider != 'tmdb') {
                                source = const _DiscoverFeedSelection(
                                  provider: 'tmdb',
                                  mediaType: 'tv',
                                  genre: 'all',
                                  heat: 'popularity.desc',
                                ).encoded;
                                previewItems = _loadSection(source, 1);
                              }
                            }
                            changed = true;
                          }),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          actions: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  final title = titleDraft.trim();
                  if (title.isEmpty ||
                      (title != initialSection && _sections.contains(title))) {
                    updateDialog(
                      () => error = title.isEmpty ? '列表名称不能为空' : '已有同名列表',
                    );
                    return;
                  }
                  changed = true;
                  Navigator.pop(dialogContext);
                },
                child: const Text('保存当前列表'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!changed || !mounted) return;
    final title = titleDraft.trim();
    setState(() {
      if (deleted) {
        _sections.remove(initialSection);
        _sectionSources.remove(initialSection);
        _cardStyles.remove(initialSection);
        _hiddenSections.remove(initialSection);
      } else {
        if (title != initialSection) {
          final index = _sections.indexOf(initialSection);
          _sections[index] = title;
          final previousSource = _sectionSources.remove(initialSection);
          if (previousSource != null) _sectionSources[title] = previousSource;
          final previousStyle = _cardStyles.remove(initialSection);
          if (previousStyle != null) _cardStyles[title] = previousStyle;
          if (_hiddenSections.remove(initialSection)) {
            _hiddenSections.add(title);
          }
        }
        _sectionSources[title] = source;
        _cardStyles[title] = style;
        if (visible) {
          _hiddenSections.remove(title);
        } else {
          _hiddenSections.add(title);
        }
      }
      _groupSectionsByVisibility();
      _items = _loadSections();
    });
    await _persistLayout();
  }

  // ignore: unused_element
  Future<void> _showCardSettings() async {
    final previews = await _items;
    if (!mounted) return;
    _groupSectionsByVisibility();
    var changed = false;
    String? expandedSection = _sections.firstOrNull;
    final titleDrafts = <String, String>{
      for (final section in _sections) section: section,
    };
    final nameErrors = <String, String>{};

    void renameSection(String section, StateSetter updateDialog) {
      final next = (titleDrafts[section] ?? section).trim();
      if (next.isEmpty || (next != section && _sections.contains(next))) {
        updateDialog(() {
          nameErrors[section] = next.isEmpty ? '列表名称不能为空' : '已有同名列表';
        });
        return;
      }
      if (next == section) return;
      updateDialog(() {
        final index = _sections.indexOf(section);
        if (index < 0) return;
        _sections[index] = next;
        final source = _sectionSources.remove(section);
        if (source != null) _sectionSources[next] = source;
        final style = _cardStyles.remove(section);
        if (style != null) _cardStyles[next] = style;
        if (_hiddenSections.remove(section)) _hiddenSections.add(next);
        titleDrafts.remove(section);
        titleDrafts[next] = next;
        nameErrors.remove(section);
        expandedSection = next;
        changed = true;
      });
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) => Dialog(
          backgroundColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 760,
              maxHeight: MediaQuery.sizeOf(context).height * .84,
            ),
            child: GlassPanel(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '发现页栏目编排',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      YingjiMotionIconButton(
                        icon: YingjiIcons.plus,
                        tooltip: '添加列表',
                        size: 36,
                        onPressed: () => updateDialog(() {
                          var suffix = _sections.length + 1;
                          var title = '新列表 $suffix';
                          while (_sections.contains(title)) {
                            suffix++;
                            title = '新列表 $suffix';
                          }
                          final visibleCount = _sections
                              .where((item) => !_hiddenSections.contains(item))
                              .length;
                          _sections.insert(visibleCount, title);
                          _sectionSources[title] = const _DiscoverFeedSelection(
                            provider: 'tmdb',
                            mediaType: 'movie',
                            genre: 'all',
                            heat: 'popularity.desc',
                          ).encoded;
                          titleDrafts[title] = title;
                          expandedSection = title;
                          changed = true;
                        }),
                      ),
                      const SizedBox(width: 8),
                      YingjiMotionIconButton(
                        icon: YingjiIcons.xmark,
                        tooltip: '关闭',
                        size: 36,
                        onPressed: () => Navigator.pop(dialogContext),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '列表可添加、删除和排序；内容只按来源、影视类型、地区与来源榜单配置。',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  Flexible(
                    child: ReorderableListView.builder(
                      shrinkWrap: true,
                      itemCount: _sections.length,
                      buildDefaultDragHandles: false,
                      onReorderItem: (oldIndex, newIndex) {
                        updateDialog(() {
                          final section = _sections.removeAt(oldIndex);
                          _sections.insert(newIndex, section);
                          _groupSectionsByVisibility();
                        });
                        changed = true;
                      },
                      itemBuilder: (_, index) {
                        final section = _sections[index];
                        final visible = !_hiddenSections.contains(section);
                        final source = _sectionSources[section] ?? section;
                        final expanded = expandedSection == section;
                        final firstVisible =
                            visible &&
                            _sections
                                    .where(
                                      (item) => !_hiddenSections.contains(item),
                                    )
                                    .firstOrNull ==
                                section;
                        final firstHidden =
                            !visible &&
                            _sections
                                    .where(_hiddenSections.contains)
                                    .firstOrNull ==
                                section;
                        return Padding(
                          key: ValueKey('discover-setting-$section'),
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (firstVisible || firstHidden) ...[
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    2,
                                    2,
                                    2,
                                    10,
                                  ),
                                  child: Text(
                                    firstVisible ? '显示的列表' : '隐藏的列表',
                                    style: const TextStyle(
                                      color: YingjiColors.muted,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ],
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: YingjiGlass.surface(strength: .72),
                                  borderRadius: BorderRadius.circular(15),
                                  border: Border.all(color: YingjiGlass.line()),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          ReorderableDragStartListener(
                                            index: index,
                                            child: const Padding(
                                              padding: EdgeInsets.all(6),
                                              child: Icon(
                                                YingjiIcons.line_horizontal_3,
                                                size: 18,
                                                color: YingjiColors.muted,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  section,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                                const SizedBox(height: 3),
                                                Text(
                                                  _sourceLabel(source),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    color: YingjiColors.muted,
                                                    fontSize: 11,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          YingjiMotionIconButton(
                                            icon: expanded
                                                ? YingjiIcons.chevron_up
                                                : YingjiIcons.chevron_down,
                                            tooltip: expanded ? '收起编辑' : '编辑栏目',
                                            size: 34,
                                            onPressed: () => updateDialog(() {
                                              expandedSection = expanded
                                                  ? null
                                                  : section;
                                            }),
                                          ),
                                          const SizedBox(width: 6),
                                          YingjiMotionIconButton(
                                            icon: YingjiIcons.trash,
                                            tooltip: '删除列表',
                                            size: 34,
                                            onPressed: () => updateDialog(() {
                                              _sections.remove(section);
                                              _sectionSources.remove(section);
                                              _cardStyles.remove(section);
                                              _hiddenSections.remove(section);
                                              titleDrafts.remove(section);
                                              nameErrors.remove(section);
                                              if (expandedSection == section) {
                                                expandedSection = null;
                                              }
                                              changed = true;
                                            }),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            visible ? '显示' : '隐藏',
                                            style: const TextStyle(
                                              color: YingjiColors.muted,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Switch(
                                            value: visible,
                                            onChanged: (value) {
                                              updateDialog(() {
                                                if (value) {
                                                  _hiddenSections.remove(
                                                    section,
                                                  );
                                                } else {
                                                  _hiddenSections.add(section);
                                                }
                                                _groupSectionsByVisibility();
                                              });
                                              changed = true;
                                            },
                                          ),
                                        ],
                                      ),
                                      AnimatedSize(
                                        duration: const Duration(
                                          milliseconds: 220,
                                        ),
                                        curve: Curves.easeOutCubic,
                                        alignment: Alignment.topCenter,
                                        child: expanded
                                            ? Column(
                                                children: [
                                                  const SizedBox(height: 12),
                                                  TextFormField(
                                                    key: ValueKey(
                                                      'discover-name-$section',
                                                    ),
                                                    initialValue:
                                                        titleDrafts[section] ??
                                                        section,
                                                    onChanged: (value) {
                                                      titleDrafts[section] =
                                                          value;
                                                      nameErrors.remove(
                                                        section,
                                                      );
                                                    },
                                                    onFieldSubmitted: (_) =>
                                                        renameSection(
                                                          section,
                                                          updateDialog,
                                                        ),
                                                    decoration: InputDecoration(
                                                      labelText: '列表名称',
                                                      errorText:
                                                          nameErrors[section],
                                                      suffixIcon:
                                                          YingjiMotionIconButton(
                                                            icon: YingjiIcons
                                                                .checkmark_circle_fill,
                                                            tooltip: '保存列表名称',
                                                            size: 34,
                                                            onPressed: () =>
                                                                renameSection(
                                                                  section,
                                                                  updateDialog,
                                                                ),
                                                          ),
                                                    ),
                                                  ),
                                                  const SizedBox(height: 12),
                                                  _DiscoverSourceEditor(
                                                    value: source,
                                                    style:
                                                        _cardStyles[section] ??
                                                        index % 4,
                                                    providerLabels:
                                                        _providerLabels,
                                                    mediaLabels: _mediaLabels,
                                                    countryLabels:
                                                        _countryLabels,
                                                    onChanged: (value) {
                                                      updateDialog(() {
                                                        _sectionSources[section] =
                                                            value;
                                                      });
                                                      changed = true;
                                                    },
                                                  ),
                                                  const SizedBox(height: 12),
                                                  Row(
                                                    children: [
                                                      for (
                                                        var style = 0;
                                                        style < 4;
                                                        style++
                                                      )
                                                        Expanded(
                                                          child: Padding(
                                                            padding:
                                                                EdgeInsets.only(
                                                                  right:
                                                                      style == 3
                                                                      ? 0
                                                                      : 8,
                                                                ),
                                                            child: _DiscoveryStylePreview(
                                                              label:
                                                                  _styleNames[style],
                                                              style: style,
                                                              selected:
                                                                  (_cardStyles[section] ??
                                                                      index %
                                                                          3) ==
                                                                  style,
                                                              items:
                                                                  previews[section] ??
                                                                  const [],
                                                              source: source,
                                                              loading: false,
                                                              onTap: () {
                                                                updateDialog(
                                                                  () =>
                                                                      _cardStyles[section] =
                                                                          style,
                                                                );
                                                                changed = true;
                                                              },
                                                            ),
                                                          ),
                                                        ),
                                                    ],
                                                  ),
                                                ],
                                              )
                                            : const SizedBox.shrink(),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (changed && mounted) {
      await _persistLayout();
      if (!mounted) return;
      setState(() {
        _items = _loadSections();
      });
    }
  }

  Future<Map<String, List<TmdbItem>>> _loadSections() async {
    final requests = <String, Future<List<TmdbItem>> Function()>{
      for (final section in _sections)
        if (!_hiddenSections.contains(section))
          section: () => _loadSectionFor(section, 1),
    };
    final entries = await Future.wait(
      requests.entries.map((entry) async {
        try {
          return MapEntry(entry.key, await entry.value());
        } catch (_) {
          return MapEntry<String, List<TmdbItem>>(entry.key, const []);
        }
      }),
    );
    return Map<String, List<TmdbItem>>.fromEntries(entries);
  }

  Future<List<TmdbItem>> _loadSection(
    String section,
    int page,
  ) => switch (section) {
    '今日热门电视剧' => _tmdb.trendingToday('tv', page: page),
    '今日热门电影' => _tmdb.trendingToday('movie', page: page),
    '本周热门电视剧' => _tmdb.trendingThisWeek('tv', page: page),
    '本周热门电影' => _tmdb.trendingThisWeek('movie', page: page),
    '热门电视剧' => _tmdb.officialList('popular', 'tv', page: page),
    '热门电影' => _tmdb.officialList('popular', 'movie', page: page),
    '今日播出剧集' => _tmdb.officialList('airing_today', 'tv', page: page),
    '本周播出剧集' => _tmdb.officialList('on_the_air', 'tv', page: page),
    '院线热映' => _tmdb.officialList('now_playing', 'movie', page: page),
    '即将上映' => _tmdb.officialList('upcoming', 'movie', page: page),
    '高分电影' => _tmdb.officialList('top_rated', 'movie', page: page),
    '高分剧集' => _tmdb.officialList('top_rated', 'tv', page: page),
    '热门国产电视剧' => _tmdb.discover('tv', page: page, originCountry: 'CN'),
    '热门国产电影' => _tmdb.discover('movie', page: page, originCountry: 'CN'),
    '热门综艺' => _tmdb.discover('tv', page: page, genre: 10764),
    '热门国产动漫' => _tmdb.discover(
      'tv',
      page: page,
      originCountry: 'CN',
      genre: 16,
    ),
    '热门番剧' => _tmdb.discover('tv', page: page, originCountry: 'JP', genre: 16),
    '热门韩剧' => _tmdb.discover('tv', page: page, originCountry: 'KR'),
    '热门日剧' => _tmdb.discover('tv', page: page, originCountry: 'JP'),
    '热门台剧' => _tmdb.discover('tv', page: page, originCountry: 'TW'),
    '动作电影' => _tmdb.discover('movie', page: page, genre: 28),
    '喜剧电影' => _tmdb.discover('movie', page: page, genre: 35),
    '科幻电影' => _tmdb.discover('movie', page: page, genre: 878),
    '悬疑电影' => _tmdb.discover('movie', page: page, genre: 9648),
    '恐怖电影' => _tmdb.discover('movie', page: page, genre: 27),
    '纪录片' => _tmdb.discover('movie', page: page, genre: 99),
    '家庭电影' => _tmdb.discover('movie', page: page, genre: 10751),
    'Netflix' => _tmdb.discover(
      'tv',
      page: page,
      provider: '8',
      watchRegion: 'HK',
    ),
    'Disney+' => _tmdb.discover(
      'tv',
      page: page,
      provider: '337',
      watchRegion: 'HK',
    ),
    'Prime Video' => _tmdb.discover(
      'tv',
      page: page,
      provider: '119',
      watchRegion: 'HK',
    ),
    'Apple TV+' => _tmdb.discover(
      'tv',
      page: page,
      provider: '350',
      watchRegion: 'HK',
    ),
    '流媒体综合' => _tmdb.discover(
      'tv',
      page: page,
      provider: '8|119|337|350',
      watchRegion: 'HK',
    ),
    '按分类' => _tmdb.discover('movie', page: page, genre: 28),
    '按平台' => _tmdb.discover(
      'tv',
      page: page,
      provider: '8|337|350',
      watchRegion: 'HK',
    ),
    final source when source.startsWith('trakt.') => _loadTrakt(source, page),
    final source when source.startsWith('custom|') => _loadCustomSection(
      source,
      page,
    ),
    _ => _tmdb.trendingToday('movie', page: page),
  };

  Future<List<TmdbItem>> _loadCustomSection(String source, int page) {
    final selection = _DiscoverFeedSelection.tryParse(source);
    if (selection == null) return _tmdb.trendingToday('movie', page: page);
    if (selection.provider == 'trakt') {
      return _loadTrakt(
        'trakt.${selection.mediaType == 'tv' ? 'shows' : 'movies'}.${selection.heat}',
        page,
      );
    }
    if (selection.provider == 'tvmaze') {
      return _loadTvMaze(selection, page);
    }
    if (selection.provider == 'mdblist') {
      return _tmdb.mdblistOfficial(
        selection.mediaType,
        selection.heat,
        page: page,
        country: selection.country,
      );
    }
    if (selection.provider == 'douban') {
      return _tmdb.doubanPublicList(selection.heat, page: page);
    }
    if (selection.heat == 'trending_week') {
      return _tmdb.trendingThisWeek(selection.mediaType, page: page);
    }
    final hasExtraFilters =
        selection.genre != 'all' ||
        selection.language != 'all' ||
        selection.year != 'all' ||
        selection.minimumRating != 'all' ||
        selection.minimumVotes != 'all' ||
        selection.runtime != 'all' ||
        selection.platform != 'all' ||
        selection.releaseWindow != 'all';
    if (!hasExtraFilters &&
        const {
          'popular',
          'top_rated',
          'now_playing',
          'upcoming',
          'airing_today',
          'on_the_air',
        }.contains(selection.heat)) {
      return _tmdb.officialList(
        selection.heat,
        selection.mediaType,
        page: page,
      );
    }
    if (selection.heat == 'trending' &&
        selection.country == 'all' &&
        selection.platform == 'all' &&
        selection.genre == 'all' &&
        selection.language == 'all' &&
        selection.year == 'all' &&
        selection.minimumRating == 'all' &&
        selection.minimumVotes == 'all' &&
        selection.runtime == 'all' &&
        selection.releaseWindow == 'all') {
      return _tmdb.trendingToday(selection.mediaType, page: page);
    }
    final sortBy = switch (selection.heat) {
      'date.desc' ||
      'now_playing' ||
      'upcoming' ||
      'airing_today' ||
      'on_the_air' =>
        selection.mediaType == 'tv'
            ? 'first_air_date.desc'
            : 'primary_release_date.desc',
      'trending' || 'popular' => 'popularity.desc',
      'top_rated' => 'vote_average.desc',
      _ => selection.heat,
    };
    const movieGenres = <String, int>{
      'action': 28,
      'adventure': 12,
      'animation': 16,
      'comedy': 35,
      'crime': 80,
      'documentary': 99,
      'drama': 18,
      'family': 10751,
      'fantasy': 14,
      'history': 36,
      'horror': 27,
      'music': 10402,
      'mystery': 9648,
      'romance': 10749,
      'scifi': 878,
      'thriller': 53,
      'war': 10752,
      'western': 37,
    };
    const tvGenres = <String, int>{
      'action': 10759,
      'animation': 16,
      'comedy': 35,
      'crime': 80,
      'documentary': 99,
      'drama': 18,
      'family': 10751,
      'kids': 10762,
      'mystery': 9648,
      'news': 10763,
      'reality': 10764,
      'scifi': 10765,
      'soap': 10766,
      'talk': 10767,
      'war': 10768,
      'western': 37,
    };
    final today = DateTime.now();
    DateTime? dateFrom;
    DateTime? dateTo;
    switch (selection.releaseWindow) {
      case 'recent30':
        dateFrom = today.subtract(const Duration(days: 30));
      case 'recent90':
        dateFrom = today.subtract(const Duration(days: 90));
      case 'thisYear':
        dateFrom = DateTime(today.year);
        dateTo = DateTime(today.year, 12, 31);
      case 'upcoming30':
        dateFrom = today;
        dateTo = today.add(const Duration(days: 30));
    }
    if (selection.releaseWindow == 'all') {
      switch (selection.heat) {
        case 'now_playing':
          dateFrom = today.subtract(const Duration(days: 90));
          dateTo = today;
        case 'upcoming':
          dateFrom = today;
          dateTo = today.add(const Duration(days: 90));
        case 'airing_today':
          dateFrom = DateTime(today.year, today.month, today.day);
          dateTo = dateFrom;
        case 'on_the_air':
          dateFrom = today.subtract(const Duration(days: 7));
          dateTo = today.add(const Duration(days: 7));
      }
    }
    final (minimumRuntime, maximumRuntime) = switch (selection.runtime) {
      'short' => (null, selection.mediaType == 'tv' ? 25 : 60),
      'standard' => selection.mediaType == 'tv' ? (25, 70) : (60, 150),
      'long' => (selection.mediaType == 'tv' ? 70 : 150, null),
      _ => (null, null),
    };
    final watchProviders = selection.platforms
        .where((value) => value.startsWith('watch:'))
        .map((value) => value.substring(6))
        .join('|');
    final companies = selection.platforms
        .where((value) => value.startsWith('company:'))
        .map((value) => value.substring(8))
        .join('|');
    return _tmdb.discover(
      selection.mediaType,
      page: page,
      originCountry: selection.country == 'all' ? null : selection.country,
      genre: (selection.mediaType == 'tv'
          ? tvGenres
          : movieGenres)[selection.genre],
      originalLanguage: selection.language == 'all' ? null : selection.language,
      year: selection.year == 'all' ? null : int.tryParse(selection.year),
      minimumRating: selection.minimumRating == 'all'
          ? null
          : double.tryParse(selection.minimumRating),
      minimumVoteCount: selection.minimumVotes == 'all'
          ? (const {'vote_average.desc', 'top_rated'}.contains(selection.heat)
                ? 50
                : null)
          : int.tryParse(selection.minimumVotes),
      minimumRuntime: minimumRuntime,
      maximumRuntime: maximumRuntime,
      dateFrom: dateFrom,
      dateTo: dateTo,
      provider: watchProviders.isEmpty ? null : watchProviders,
      company: companies.isEmpty ? null : companies,
      watchRegion: selection.watchRegion,
      sortBy: sortBy,
    );
  }

  Future<List<TmdbItem>> _loadTvMaze(
    _DiscoverFeedSelection selection,
    int page,
  ) async {
    final today = DateTime.now();
    final date =
        '${today.year.toString().padLeft(4, '0')}-'
        '${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';
    final path = selection.heat == 'web' ? '/schedule/web' : '/schedule';
    final query = <String, String>{'date': date};
    if (selection.country != 'all') query['country'] = selection.country;
    final response = await _tvMaze
        .get(
          Uri.https('api.tvmaze.com', path, query),
          headers: const {'Accept': 'application/json', 'User-Agent': 'Mova/3'},
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('TVmaze 榜单读取失败（HTTP ${response.statusCode}）');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! List) return const [];
    final ids = <String>[];
    for (final row in decoded.whereType<Map>()) {
      final show = row['show'];
      final externals = show is Map ? show['externals'] : null;
      final imdb = externals is Map ? '${externals['imdb'] ?? ''}' : '';
      if (imdb.startsWith('tt') && !ids.contains(imdb)) ids.add(imdb);
    }
    final start = (page - 1) * 20;
    if (start >= ids.length) return const [];
    final selectedIds = ids.skip(start).take(20).toList(growable: false);
    final result = <TmdbItem>[];
    for (var offset = 0; offset < selectedIds.length; offset += 5) {
      final batch = selectedIds.skip(offset).take(5);
      final rows = await Future.wait(
        batch.map((id) async {
          try {
            return await _tmdb.findByImdbId(id);
          } catch (_) {
            return null;
          }
        }),
      );
      result.addAll(rows.whereType<TmdbItem>());
    }
    return result;
  }

  Future<List<TmdbItem>> _loadTrakt(String source, int page) async {
    final parts = source.split('.');
    if (parts.length != 3) return const [];
    final prefs = await SharedPreferences.getInstance();
    final clientId = prefs.getString('yingji.trakt.client-id') ?? '';
    final rows = await _trakt.discover(
      clientId: clientId,
      type: parts[1],
      list: parts[2],
      page: page,
    );
    final items = <TmdbItem>[];
    // Resolve Trakt's canonical TMDB IDs in small batches so cards retain the
    // same artwork, Chinese metadata and detail-page behavior as other shelves.
    for (var start = 0; start < rows.length; start += 5) {
      final end = math.min(start + 5, rows.length);
      final batch = await Future.wait(
        rows.sublist(start, end).map((row) async {
          try {
            return await _tmdb.details(row.tmdbId, kind: row.kind);
          } catch (_) {
            return null;
          }
        }),
      );
      items.addAll(batch.whereType<TmdbItem>());
    }
    return items;
  }

  Future<List<TmdbItem>> _loadSectionFor(String section, int page) =>
      _loadSection(_sectionSources[section] ?? section, page);

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<Map<String, List<TmdbItem>>>(
        future: _items,
        builder: (context, snapshot) {
          final sections = snapshot.data ?? const <String, List<TmdbItem>>{};
          final items = sections.values.expand((value) => value).toList();
          final visibleSections = _sections
              .where((section) => !_hiddenSections.contains(section))
              .toList(growable: false);
          if (items.isEmpty &&
              snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(0, 8, 4, 56),
            itemCount: visibleSections.isEmpty ? 2 : visibleSections.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  key: const ValueKey('discover-header'),
                  padding: const EdgeInsets.only(bottom: 28),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '发现',
                              style: TextStyle(
                                fontSize: 48,
                                height: 1,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -1.2,
                              ),
                            ),
                            SizedBox(height: 8),
                            Text(
                              '浏览影视榜单，自定义每个列表的数据、顺序与卡片样式。',
                              style: TextStyle(color: Color(0xFFABB1BE)),
                            ),
                          ],
                        ),
                      ),
                      YingjiMotionIconButton(
                        icon: YingjiIcons.plus,
                        tooltip: '添加列表',
                        onPressed: _addDiscoverSection,
                        size: 44,
                      ),
                    ],
                  ),
                );
              }
              if (visibleSections.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.only(top: 42),
                  child: _EmptyStrip(
                    icon: YingjiIcons.rectangle_stack,
                    title: '所有栏目均已隐藏',
                    detail: '在任意列表右侧打开设置，重新显示需要的栏目。',
                  ),
                );
              }
              final section = visibleSections[index - 1];
              final block = _DiscoverBlock(
                title: section,
                source: _sectionSources[section] ?? section,
                sourceLabel: _sourceLabel(_sectionSources[section] ?? section),
                items: sections[section] ?? const [],
                variant: _cardStyles[section] ?? _sections.indexOf(section) % 4,
                onConfigure: () => _showSectionSettings(section),
                loadPage: (page) => _loadSectionFor(section, page),
                loadSourcePage: _loadSection,
              );
              return KeyedSubtree(
                key: ValueKey(section),
                child: AnimatedOpacity(
                  opacity: 1,
                  duration: const Duration(milliseconds: 160),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 36),
                    child: block,
                  ),
                ),
              );
            },
          );
        },
      );
}

class _DiscoverFeedSelection {
  const _DiscoverFeedSelection({
    required this.provider,
    required this.mediaType,
    required this.genre,
    required this.heat,
    this.country = 'all',
    this.language = 'all',
    this.year = 'all',
    this.minimumRating = 'all',
    this.minimumVotes = 'all',
    this.runtime = 'all',
    this.platform = 'all',
    this.watchRegion = 'HK',
    this.releaseWindow = 'all',
  });

  final String provider;
  final String mediaType;
  final String genre;
  final String heat;
  final String country;
  final String language;
  final String year;
  final String minimumRating;
  final String minimumVotes;
  final String runtime;
  final String platform;
  final String watchRegion;
  final String releaseWindow;

  List<String> get platforms => platform == 'all'
      ? const []
      : platform.split(',').where((value) => value.isNotEmpty).toList();

  String get encoded => [
    'custom',
    provider,
    mediaType,
    genre,
    heat,
    country,
    language,
    year,
    minimumRating,
    minimumVotes,
    runtime,
    platform,
    watchRegion,
    releaseWindow,
  ].join('|');

  _DiscoverFeedSelection withPlatform(String value) => _DiscoverFeedSelection(
    provider: provider,
    mediaType: mediaType,
    genre: genre,
    heat: heat,
    country: country,
    language: language,
    year: year,
    minimumRating: minimumRating,
    minimumVotes: minimumVotes,
    runtime: runtime,
    platform: value,
    watchRegion: watchRegion,
    releaseWindow: releaseWindow,
  );

  static _DiscoverFeedSelection? tryParse(String value) {
    final parts = value.split('|');
    if ((parts.length != 5 && parts.length != 13 && parts.length != 14) ||
        parts.first != 'custom') {
      return null;
    }
    const providers = {'tmdb', 'trakt', 'mdblist', 'douban', 'tvmaze'};
    const mediaTypes = {'movie', 'tv'};
    const genres = {
      'all',
      'action',
      'comedy',
      'scifi',
      'mystery',
      'animation',
      'documentary',
      'adventure',
      'crime',
      'drama',
      'family',
      'fantasy',
      'history',
      'horror',
      'music',
      'romance',
      'thriller',
      'war',
      'western',
      'kids',
      'news',
      'reality',
      'soap',
      'talk',
      'variety',
    };
    const tmdbHeat = {
      'popularity.desc',
      'popularity.asc',
      'vote_average.desc',
      'vote_count.desc',
      'date.desc',
      'trending',
      'trending_week',
      'popular',
      'top_rated',
      'now_playing',
      'upcoming',
      'airing_today',
      'on_the_air',
    };
    const traktHeat = {
      'trending',
      'popular',
      'anticipated',
      'boxoffice',
      'watched',
      'collected',
      'played',
    };
    const tvMazeLists = {'schedule', 'web'};
    const mdbListLists = {
      'trending',
      'popular',
      'anticipated',
      'most-watched',
      'most-watched-week',
      'moviemeter',
      'streaming-charts',
      'justwatch-streaming-charts',
    };
    const doubanLists = {'chart', 'top250'};
    if (!providers.contains(parts[1]) ||
        !mediaTypes.contains(parts[2]) ||
        !genres.contains(parts[3]) ||
        !(parts[1] == 'trakt'
                ? traktHeat
                : parts[1] == 'tvmaze'
                ? tvMazeLists
                : parts[1] == 'mdblist'
                ? mdbListLists
                : parts[1] == 'douban'
                ? doubanLists
                : tmdbHeat)
            .contains(parts[4])) {
      return null;
    }
    if (parts.length >= 13 &&
        (!_validOption(parts[5], const {
              'all',
              'CN',
              'HK',
              'TW',
              'US',
              'GB',
              'JP',
              'KR',
              'TH',
              'IN',
              'FR',
              'DE',
              'ES',
              'IT',
              'CA',
              'AU',
            }) ||
            !_validOption(parts[6], const {
              'all',
              'zh',
              'en',
              'ja',
              'ko',
              'th',
              'fr',
              'de',
              'es',
              'it',
              'hi',
              'ru',
            }) ||
            (parts[7] != 'all' && int.tryParse(parts[7]) == null) ||
            !_validOption(parts[8], const {'all', '6', '7', '8', '9'}) ||
            !_validOption(parts[9], const {
              'all',
              '50',
              '200',
              '1000',
              '5000',
            }) ||
            !_validOption(parts[10], const {
              'all',
              'short',
              'standard',
              'long',
            }) ||
            (parts[11] != 'all' &&
                !parts[11]
                    .split(',')
                    .every(
                      (value) =>
                          RegExp(r'^(watch|company):\d+$').hasMatch(value) ||
                          int.tryParse(value) != null,
                    )) ||
            !_validOption(parts[12], const {
              'all',
              'CN',
              'HK',
              'TW',
              'US',
              'GB',
              'JP',
              'KR',
              'TH',
              'IN',
              'FR',
              'DE',
              'ES',
              'IT',
              'CA',
              'AU',
            }) ||
            (parts.length == 14 &&
                !_validOption(parts[13], const {
                  'all',
                  'recent30',
                  'recent90',
                  'thisYear',
                  'upcoming30',
                })))) {
      return null;
    }
    return _DiscoverFeedSelection(
      provider: parts[1],
      mediaType: parts[2],
      genre: parts[3],
      heat: parts[4],
      country: parts.length >= 13 ? parts[5] : 'all',
      language: parts.length >= 13 ? parts[6] : 'all',
      year: parts.length >= 13 ? parts[7] : 'all',
      minimumRating: parts.length >= 13 ? parts[8] : 'all',
      minimumVotes: parts.length >= 13 ? parts[9] : 'all',
      runtime: parts.length >= 13 ? parts[10] : 'all',
      platform: parts.length >= 13 ? parts[11] : 'all',
      watchRegion: parts.length >= 13 && parts[12] != 'all' ? parts[12] : 'HK',
      releaseWindow: parts.length == 14 ? parts[13] : 'all',
    );
  }

  static bool _validOption(String value, Set<String> options) =>
      options.contains(value);
}

class _DiscoverSourceEditor extends StatelessWidget {
  const _DiscoverSourceEditor({
    required this.value,
    required this.style,
    required this.providerLabels,
    required this.mediaLabels,
    required this.countryLabels,
    required this.onChanged,
  });

  final String value;
  final int style;
  final Map<String, String> providerLabels;
  final Map<String, String> mediaLabels;
  final Map<String, String> countryLabels;
  final ValueChanged<String> onChanged;

  static const _tmdbMovieLists = <String, String>{
    'trending': '今日趋势',
    'trending_week': '本周趋势',
    'popular': '热门电影',
    'now_playing': '院线热映',
    'upcoming': '即将上映',
    'top_rated': '高分电影',
    'popularity.desc': '当前热门',
    'vote_average.desc': '高分口碑',
    'date.desc': '最新上映',
  };
  static const _tmdbTvLists = <String, String>{
    'trending': '今日趋势',
    'trending_week': '本周趋势',
    'popular': '热门剧集',
    'airing_today': '今日播出',
    'on_the_air': '本周播出',
    'top_rated': '高分剧集',
    'popularity.desc': '当前热门',
    'vote_average.desc': '高分口碑',
    'date.desc': '最新播出',
  };
  static const _traktMovieLists = <String, String>{
    'trending': '实时趋势',
    'popular': '长期热门',
    'anticipated': '最受期待',
    'boxoffice': '周末票房',
    'watched': '本周观看',
    'collected': '本周收藏',
    'played': '本周播放',
  };
  static const _traktTvLists = <String, String>{
    'trending': '实时趋势',
    'popular': '长期热门',
    'anticipated': '最受期待',
    'watched': '本周观看',
    'collected': '本周收藏',
    'played': '本周播放',
  };
  static const _tvMazeLists = <String, String>{
    'schedule': '地区今日播出',
    'web': '流媒体今日更新',
  };
  static const _mdbListLists = <String, String>{
    'trending': '实时趋势',
    'popular': '当前热门',
    'anticipated': '最受期待',
    'most-watched': '最多观看',
    'most-watched-week': '本周最多观看',
    'moviemeter': 'IMDb 热度',
    'streaming-charts': '流媒体趋势',
    'justwatch-streaming-charts': 'JustWatch 趋势',
  };
  static const _doubanLists = <String, String>{
    'chart': '豆瓣新片榜',
    'top250': '豆瓣电影 Top 250',
  };
  static const _movieGenres = <String, String>{
    'all': '全部类型',
    'action': '动作',
    'adventure': '冒险',
    'animation': '动画',
    'comedy': '喜剧',
    'crime': '犯罪',
    'documentary': '纪录片',
    'drama': '剧情',
    'family': '家庭',
    'fantasy': '奇幻',
    'history': '历史',
    'horror': '恐怖',
    'music': '音乐',
    'mystery': '悬疑',
    'romance': '爱情',
    'scifi': '科幻',
    'thriller': '惊悚',
    'war': '战争',
    'western': '西部',
  };
  static const _tvGenres = <String, String>{
    'all': '全部类型',
    'action': '动作冒险',
    'animation': '动画',
    'comedy': '喜剧',
    'crime': '犯罪',
    'documentary': '纪录片',
    'drama': '剧情',
    'family': '家庭',
    'kids': '儿童',
    'mystery': '悬疑',
    'news': '新闻',
    'reality': '真人秀',
    'scifi': '科幻奇幻',
    'soap': '肥皂剧',
    'talk': '脱口秀',
    'war': '战争政治',
    'western': '西部',
  };
  static const _languageLabels = <String, String>{
    'all': '全部语言',
    'zh': '中文',
    'en': '英语',
    'ja': '日语',
    'ko': '韩语',
    'th': '泰语',
    'fr': '法语',
    'de': '德语',
    'es': '西班牙语',
    'it': '意大利语',
    'hi': '印地语',
    'ru': '俄语',
  };
  static const _ratingLabels = <String, String>{
    'all': '不限评分',
    '6': '6.0 分以上',
    '7': '7.0 分以上',
    '8': '8.0 分以上',
    '9': '9.0 分以上',
  };
  static const _voteLabels = <String, String>{
    'all': '不限评分人数',
    '50': '50 人以上',
    '200': '200 人以上',
    '1000': '1,000 人以上',
    '5000': '5,000 人以上',
  };
  static const _runtimeLabels = <String, String>{
    'all': '不限时长',
    'short': '短片 / 短剧',
    'standard': '标准时长',
    'long': '长片 / 长剧',
  };
  static const _releaseLabels = <String, String>{
    'all': '不限时间',
    'recent30': '最近 30 天',
    'recent90': '最近 90 天',
    'thisYear': '今年',
    'upcoming30': '未来 30 天',
  };

  @override
  Widget build(BuildContext context) {
    final parsed = _DiscoverFeedSelection.tryParse(value);
    final legacyTrakt = value.startsWith('trakt.');
    final provider = parsed?.provider ?? (legacyTrakt ? 'trakt' : 'tmdb');
    final legacyTv =
        value.contains('电视剧') ||
        value.contains('剧集') ||
        value.contains('综艺') ||
        value.contains('动漫') ||
        value.contains('番剧') ||
        value.contains('.shows.');
    final mediaType = provider == 'tvmaze'
        ? 'tv'
        : provider == 'douban'
        ? 'movie'
        : parsed?.mediaType ?? (legacyTv ? 'tv' : 'movie');
    final country = const {'trakt', 'douban'}.contains(provider)
        ? 'all'
        : parsed?.country ?? 'all';
    final watchRegion = parsed?.watchRegion ?? 'HK';
    final platform = parsed?.platform ?? 'all';
    final genre = parsed?.genre ?? 'all';
    final language = parsed?.language ?? 'all';
    final year = parsed?.year ?? 'all';
    final minimumRating = parsed?.minimumRating ?? 'all';
    final minimumVotes = parsed?.minimumVotes ?? 'all';
    final runtime = parsed?.runtime ?? 'all';
    final releaseWindow = parsed?.releaseWindow ?? 'all';
    final lists = provider == 'tmdb'
        ? (mediaType == 'tv' ? _tmdbTvLists : _tmdbMovieLists)
        : provider == 'trakt'
        ? (mediaType == 'tv' ? _traktTvLists : _traktMovieLists)
        : provider == 'mdblist'
        ? _mdbListLists
        : provider == 'douban'
        ? _doubanLists
        : _tvMazeLists;
    final legacyList = legacyTrakt ? value.split('.').last : null;
    final list = lists.containsKey(parsed?.heat)
        ? parsed!.heat
        : lists.containsKey(legacyList)
        ? legacyList!
        : lists.keys.first;
    final regionLabels = const {'trakt', 'douban'}.contains(provider)
        ? const {'all': '全球'}
        : countryLabels;

    void update({
      String? nextProvider,
      String? nextMediaType,
      String? nextCountry,
      String? nextList,
      String? nextPlatform,
      String? nextWatchRegion,
      String? nextGenre,
      String? nextLanguage,
      String? nextYear,
      String? nextMinimumRating,
      String? nextMinimumVotes,
      String? nextRuntime,
      String? nextReleaseWindow,
    }) {
      final source = nextProvider ?? provider;
      final type = source == 'tvmaze'
          ? 'tv'
          : source == 'douban'
          ? 'movie'
          : nextMediaType ?? mediaType;
      var region = const {'trakt', 'douban'}.contains(source)
          ? 'all'
          : nextCountry ?? country;
      final allowedLists = source == 'tmdb'
          ? (type == 'tv' ? _tmdbTvLists : _tmdbMovieLists)
          : source == 'trakt'
          ? (type == 'tv' ? _traktTvLists : _traktMovieLists)
          : source == 'mdblist'
          ? _mdbListLists
          : source == 'douban'
          ? _doubanLists
          : _tvMazeLists;
      final selectedList = allowedLists.containsKey(nextList)
          ? nextList!
          : allowedLists.containsKey(list)
          ? list
          : allowedLists.keys.first;
      if (source == 'tvmaze' && selectedList == 'schedule' && region == 'all') {
        region = 'US';
      }
      onChanged(
        _DiscoverFeedSelection(
          provider: source,
          mediaType: type,
          genre: nextMediaType != null ? 'all' : nextGenre ?? genre,
          heat: selectedList,
          country: region,
          language: nextLanguage ?? language,
          year: nextYear ?? year,
          minimumRating: nextMinimumRating ?? minimumRating,
          minimumVotes: nextMinimumVotes ?? minimumVotes,
          runtime: nextRuntime ?? runtime,
          platform: source == 'tmdb'
              ? (nextMediaType != null ? 'all' : nextPlatform ?? platform)
              : 'all',
          watchRegion: nextWatchRegion ?? watchRegion,
          releaseWindow: nextReleaseWindow ?? releaseWindow,
        ).encoded,
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: YingjiGlass.surface(strength: .46),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: YingjiGlass.line(strength: .8)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              style == 3 ? '平台入口筛选' : '内容筛选',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _DiscoverFilterField(
                  label: '来源',
                  value: provider,
                  labels: providerLabels,
                  onChanged: (item) => update(nextProvider: item),
                ),
                _DiscoverFilterField(
                  label: '影视类型',
                  value: mediaType,
                  labels: provider == 'tvmaze'
                      ? const {'tv': '剧集'}
                      : provider == 'douban'
                      ? const {'movie': '电影'}
                      : mediaLabels,
                  onChanged: (item) => update(nextMediaType: item),
                ),
                _DiscoverFilterField(
                  label: '地区',
                  value: country,
                  labels: regionLabels,
                  onChanged: (item) => update(nextCountry: item),
                ),
                _DiscoverFilterField(
                  label: '来源榜单',
                  value: list,
                  labels: lists,
                  onChanged: (item) => update(nextList: item),
                ),
                if (provider == 'tmdb') ...[
                  _DiscoverFilterField(
                    label: '内容类型',
                    value: genre,
                    labels: mediaType == 'tv' ? _tvGenres : _movieGenres,
                    onChanged: (item) => update(nextGenre: item),
                  ),
                  _DiscoverFilterField(
                    label: '原始语言',
                    value: language,
                    labels: _languageLabels,
                    onChanged: (item) => update(nextLanguage: item),
                  ),
                  _DiscoverFilterField(
                    label: '发行年份',
                    value: year,
                    labels: {
                      'all': '全部年份',
                      for (
                        var value = DateTime.now().year;
                        value >= DateTime.now().year - 12;
                        value--
                      )
                        '$value': '$value 年',
                    },
                    onChanged: (item) => update(nextYear: item),
                  ),
                  _DiscoverFilterField(
                    label: '发行时间',
                    value: releaseWindow,
                    labels: _releaseLabels,
                    onChanged: (item) => update(nextReleaseWindow: item),
                  ),
                  _DiscoverFilterField(
                    label: '最低评分',
                    value: minimumRating,
                    labels: _ratingLabels,
                    onChanged: (item) => update(nextMinimumRating: item),
                  ),
                  _DiscoverFilterField(
                    label: style == 2 ? '排行可信度' : '评分人数',
                    value: minimumVotes,
                    labels: _voteLabels,
                    onChanged: (item) => update(nextMinimumVotes: item),
                  ),
                  _DiscoverFilterField(
                    label: '内容时长',
                    value: runtime,
                    labels: _runtimeLabels,
                    onChanged: (item) => update(nextRuntime: item),
                  ),
                ],
              ],
            ),
            if (provider == 'tmdb') ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _DiscoverFilterField(
                    label: '平台地区',
                    value: watchRegion,
                    labels: countryLabels,
                    onChanged: (item) => update(
                      nextWatchRegion: item == 'all' ? 'HK' : item,
                      nextPlatform: 'all',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FutureBuilder<Map<String, String>>(
                      future: _watchProviders(mediaType, watchRegion),
                      builder: (context, snapshot) {
                        final labels =
                            snapshot.data ?? const {'all': '正在获取平台…'};
                        if (style == 3) {
                          final selectedPlatforms = platform == 'all'
                              ? <String>{}
                              : platform.split(',').toSet();
                          final platformEntries = labels.entries
                              .where((entry) => entry.key != 'all')
                              .toList(growable: false);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '播放平台（可多选）',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 7),
                              SizedBox(
                                height: 38,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: platformEntries.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(width: 7),
                                  itemBuilder: (context, index) {
                                    final entry = platformEntries[index];
                                    final selected = selectedPlatforms.contains(
                                      entry.key,
                                    );
                                    return FilterChip(
                                      label: Text(entry.value),
                                      selected: selected,
                                      onSelected: (_) {
                                        final next = {...selectedPlatforms};
                                        selected
                                            ? next.remove(entry.key)
                                            : next.add(entry.key);
                                        update(
                                          nextPlatform: next.isEmpty
                                              ? 'all'
                                              : next.join(','),
                                          nextWatchRegion:
                                              entry.key.startsWith('company:')
                                              ? 'CN'
                                              : watchRegion == 'CN'
                                              ? 'HK'
                                              : watchRegion,
                                        );
                                      },
                                    );
                                  },
                                ),
                              ),
                            ],
                          );
                        }
                        final selected = labels.containsKey(platform)
                            ? platform
                            : 'all';
                        return _DiscoverFilterField(
                          label: '播放平台',
                          value: selected,
                          labels: labels,
                          width: 240,
                          onChanged: (item) => update(
                            nextPlatform: item,
                            nextWatchRegion: item.startsWith('company:')
                                ? 'CN'
                                : watchRegion == 'CN'
                                ? 'HK'
                                : watchRegion,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '海外平台按 TMDB 观看目录筛选；国内平台按官方出品公司筛选。选择国内平台时会自动切换到中国大陆地区。',
                style: const TextStyle(fontSize: 11, color: YingjiColors.muted),
              ),
            ],
            if (provider == 'trakt') ...[
              const SizedBox(height: 10),
              const Text(
                'Trakt 榜单不提供地区过滤，因此地区固定为全球。',
                style: TextStyle(fontSize: 11, color: YingjiColors.muted),
              ),
            ],
            if (provider == 'douban') ...[
              const SizedBox(height: 10),
              const Text(
                '读取豆瓣公开电影榜单标题，并通过 TMDB 匹配中文海报与详情。',
                style: TextStyle(fontSize: 11, color: YingjiColors.muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DiscoverFilterField extends StatelessWidget {
  const _DiscoverFilterField({
    required this.label,
    required this.value,
    required this.labels,
    required this.onChanged,
    this.width = 148,
  });

  final String label;
  final String value;
  final Map<String, String> labels;
  final ValueChanged<String> onChanged;
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: YingjiGlassChoiceField<String>(
      label: label,
      value: value,
      items: labels.keys.toList(growable: false),
      labelBuilder: (item) => labels[item] ?? item,
      onChanged: onChanged,
    ),
  );
}

class _DiscoverBlock extends StatefulWidget {
  const _DiscoverBlock({
    required this.title,
    required this.source,
    required this.sourceLabel,
    required this.items,
    required this.variant,
    required this.loadPage,
    required this.loadSourcePage,
    required this.onConfigure,
  });
  final String title;
  final String source;
  final String sourceLabel;
  final List<TmdbItem> items;
  final int variant;
  final Future<List<TmdbItem>> Function(int page) loadPage;
  final Future<List<TmdbItem>> Function(String source, int page) loadSourcePage;
  final VoidCallback onConfigure;
  @override
  State<_DiscoverBlock> createState() => _DiscoverBlockState();
}

class _DiscoverBlockState extends State<_DiscoverBlock> {
  final _shelf = _ShelfNavigator();
  late List<TmdbItem> _items;
  int _page = 1;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _items = List.of(widget.items);
  }

  @override
  void didUpdateWidget(covariant _DiscoverBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.items, widget.items)) {
      _items = List.of(widget.items);
      _page = 1;
    }
  }

  Future<void> _moveNext() async {
    _shelf.move(560);
    if (_loadingMore) return;
    _loadingMore = true;
    try {
      final next = await widget.loadPage(_page + 1);
      if (!mounted || next.isEmpty) return;
      final ids = _items.map((item) => '${item.kind}:${item.id}').toSet();
      setState(() {
        _page++;
        _items.addAll(next.where((item) => ids.add('${item.kind}:${item.id}')));
      });
    } finally {
      _loadingMore = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title;
    final items = _items;
    final variant = widget.variant;
    final platformCount =
        _DiscoverFeedSelection.tryParse(widget.source)?.platforms.length ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: title,
          subtitle: widget.sourceLabel,
          titleAction: YingjiMotionIconButton(
            icon: YingjiIcons.slider_horizontal_3,
            tooltip: '设置$title',
            size: 30,
            onPressed: widget.onConfigure,
          ),
          trailingActions: [
            if (variant != 3 || platformCount > 1) ...[
              YingjiDirectionalArrow(
                previous: true,
                tooltip: '向左浏览',
                size: 34,
                onPressed: () => _shelf.move(-560),
              ),
              const SizedBox(width: 7),
              YingjiDirectionalArrow(
                previous: false,
                tooltip: '向右浏览',
                size: 34,
                onPressed: _moveNext,
              ),
            ],
          ],
          action: variant == 3 ? null : '打开$title完整列表',
          onAction: variant == 3
              ? null
              : () {
                  if (title == '排行榜') {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => _RankingPage(initialItems: items),
                      ),
                    );
                    return;
                  }
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => _DiscoverListPage(
                        title: title,
                        items: items,
                        source: widget.source,
                        loadSourcePage: widget.loadSourcePage,
                      ),
                    ),
                  );
                },
        ),
        const SizedBox(height: 14),
        if (variant == 1)
          _LandscapeStrip(items: items, shelf: _shelf)
        else if (variant == 2)
          _RankStrip(items: items, shelf: _shelf)
        else if (variant == 3)
          _PlatformEntryStrip(
            items: items,
            source: widget.source,
            shelf: _shelf,
            loadSourcePage: widget.loadSourcePage,
            onConfigure: widget.onConfigure,
          )
        else
          _PosterStrip(items: items, shelf: _shelf),
      ],
    );
  }
}

class _DiscoveryStylePreview extends StatelessWidget {
  const _DiscoveryStylePreview({
    required this.label,
    required this.style,
    required this.selected,
    required this.items,
    required this.source,
    required this.loading,
    required this.onTap,
  });
  final String label;
  final int style;
  final bool selected;
  final List<TmdbItem> items;
  final String source;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: label,
    child: Material(
      color: YingjiGlass.surface(),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? Colors.white : YingjiGlass.line(),
              width: 2,
            ),
          ),
          child: Column(
            children: [
              SizedBox(
                height: 128,
                child: ClipRect(
                  child: IgnorePointer(
                    child: loading
                        ? const Center(
                            child: SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : items.isEmpty
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                style == 1
                                    ? YingjiIcons.play_rectangle
                                    : YingjiIcons.film,
                              ),
                              const SizedBox(height: 8),
                              const Text('暂无预览图片'),
                            ],
                          )
                        : FittedBox(
                            fit: BoxFit.contain,
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: style == 0 ? 320 : 560,
                              child: switch (style) {
                                1 => _LandscapeStrip(
                                  items: items.take(2).toList(),
                                ),
                                2 => _RankStrip(items: items.take(2).toList()),
                                3 => _PlatformEntryCard(
                                  items: items.take(3).toList(),
                                  source: source,
                                  compact: true,
                                  onConfigure: onTap,
                                  onOpen: onTap,
                                ),
                                _ => _PosterStrip(
                                  items: items.take(2).toList(),
                                ),
                              },
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (selected)
                    const Icon(YingjiIcons.checkmark_circle_fill, size: 16),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ShelfNavigator {
  ScrollController? _controller;
  void attach(ScrollController controller) => _controller = controller;
  void detach(ScrollController controller) {
    if (identical(_controller, controller)) _controller = null;
  }

  void move(double delta) {
    final controller = _controller;
    if (controller == null || !controller.hasClients) return;
    controller.animateTo(
      (controller.offset + delta).clamp(0, controller.position.maxScrollExtent),
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
    );
  }
}

/// The discovery page remains an editorial preview. This is the dedicated,
/// scrollable ranking view for people who want to browse every returned item
/// by chart rather than opening a small dialog.
class _RankingPage extends StatefulWidget {
  const _RankingPage({required this.initialItems});
  final List<TmdbItem> initialItems;

  @override
  State<_RankingPage> createState() => _RankingPageState();
}

class _RankingPageState extends State<_RankingPage> {
  final _tmdb = TmdbClient();
  static const _labels = <String>['院线热映', '电影热度', '剧集热度', '高分电影'];
  late Future<Map<String, List<TmdbItem>>> _charts;
  String _active = _labels.first;

  @override
  void initState() {
    super.initState();
    _charts = _loadCharts();
  }

  @override
  void dispose() {
    _tmdb.dispose();
    super.dispose();
  }

  Future<Map<String, List<TmdbItem>>> _loadCharts() async {
    final requests = <String, Future<List<TmdbItem>> Function()>{
      '院线热映': _tmdb.nowPlaying,
      '电影热度': _tmdb.popularMovies,
      '剧集热度': _tmdb.popularShows,
      '高分电影': _tmdb.topRatedMovies,
    };
    final resolved = await Future.wait(
      requests.entries.map((entry) async {
        try {
          return MapEntry(entry.key, await entry.value());
        } catch (_) {
          return MapEntry<String, List<TmdbItem>>(entry.key, const []);
        }
      }),
    );
    final charts = Map<String, List<TmdbItem>>.fromEntries(resolved);
    if (charts['院线热映']?.isEmpty ?? true) {
      charts['院线热映'] = widget.initialItems;
    }
    return charts;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: YingjiBackdrop(
      blur: 22,
      overlay: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x99070A0D), Color(0xC007090D)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              YingjiPageChrome(onBack: () => Navigator.pop(context)),
              Expanded(
                child: FutureBuilder<Map<String, List<TmdbItem>>>(
                  future: _charts,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting &&
                        !snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final charts =
                        snapshot.data ?? const <String, List<TmdbItem>>{};
                    final rows = charts[_active] ?? const <TmdbItem>[];
                    if (rows.isEmpty) {
                      return _LoadFailure(
                        onRetry: () => setState(() => _charts = _loadCharts()),
                        message: '榜单暂时无法加载，请稍后重试。',
                      );
                    }
                    return CustomScrollView(
                      scrollCacheExtent: const ScrollCacheExtent.pixels(1200),
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(74, 32, 64, 24),
                          sliver: SliverToBoxAdapter(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '影视榜单',
                                  style: TextStyle(
                                    fontSize: 48,
                                    height: 1,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -1.2,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                const Text(
                                  '每个榜单显示本次数据源返回的完整列表；评分仅在来源实际提供时展示。',
                                  style: TextStyle(color: YingjiColors.muted),
                                ),
                                const SizedBox(height: 22),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: [
                                    for (final label in _labels)
                                      _RankingFilter(
                                        label: label,
                                        selected: _active == label,
                                        onTap: () =>
                                            setState(() => _active = label),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 26),
                                Row(
                                  children: [
                                    Text(
                                      _active,
                                      style: const TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      '${rows.length} 部',
                                      style: const TextStyle(
                                        color: YingjiColors.muted,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(74, 0, 64, 56),
                          sliver: SliverGrid(
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 224,
                                  mainAxisExtent: 372,
                                  mainAxisSpacing: 20,
                                  crossAxisSpacing: 16,
                                ),
                            delegate: SliverChildBuilderDelegate((
                              context,
                              index,
                            ) {
                              return _RankingPosterCard(
                                rank: index + 1,
                                item: rows[index],
                              );
                            }, childCount: rows.length),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _RankingFilter extends StatelessWidget {
  const _RankingFilter({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(22),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: selected ? Colors.white : YingjiGlass.chrome(),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: selected ? Colors.white : YingjiGlass.line()),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: selected ? YingjiColors.canvas : Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}

class _DiscoverListPage extends StatefulWidget {
  const _DiscoverListPage({
    required this.title,
    required this.items,
    required this.source,
    required this.loadSourcePage,
  });
  final String title;
  final List<TmdbItem> items;
  final String source;
  final Future<List<TmdbItem>> Function(String source, int page) loadSourcePage;

  @override
  State<_DiscoverListPage> createState() => _DiscoverListPageState();
}

class _DiscoverListPageState extends State<_DiscoverListPage> {
  static const _filterKeyPrefix = 'yingji.discover.all-list.filters.';
  static const _types = <String, String>{
    'all': '全部',
    'movie': '电影',
    'tv': '剧集',
  };
  static const _sorts = ['热度', '评分', '年份'];
  final _controller = ScrollController();
  late List<TmdbItem> _items;
  int _page = 1;
  bool _loading = false;
  bool _hasMore = true;
  int _feedRevision = 0;
  String _type = 'all';
  String _sort = '热度';
  String _platform = 'all';
  bool _filterChanged = false;

  _DiscoverFeedSelection? get _selection =>
      _DiscoverFeedSelection.tryParse(widget.source);

  String get _activeSource =>
      _selection?.withPlatform(_platform).encoded ?? widget.source;

  String get _filterKey =>
      '$_filterKeyPrefix${base64Url.encode(utf8.encode(widget.title))}';

  @override
  void initState() {
    super.initState();
    _items = List.of(widget.items);
    _platform = _selection?.platform ?? 'all';
    _controller.addListener(_onScroll);
    unawaited(_restoreFilters());
  }

  Future<void> _restoreFilters() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_filterKey);
    if (saved == null || _filterChanged) return;
    try {
      final value = jsonDecode(saved) as Map<String, dynamic>;
      final type = value['type'] as String?;
      final sort = value['sort'] as String?;
      final platform = value['platform'] as String?;
      if (!mounted || _filterChanged) return;
      final platformChanged = platform != null && platform != _platform;
      setState(() {
        final normalizedType = switch (type) {
          '电影' => 'movie',
          '剧集' => 'tv',
          '全部' => 'all',
          _ => type,
        };
        if (_types.containsKey(normalizedType)) _type = normalizedType!;
        if (_sorts.contains(sort)) _sort = sort!;
        if (platform != null) _platform = platform;
      });
      if (platformChanged) unawaited(_reloadPlatform());
    } catch (_) {
      // Ignore preferences written by an older or incomplete build.
    }
  }

  void _selectFilter({String? type, String? sort}) {
    setState(() {
      _filterChanged = true;
      if (type != null) _type = type;
      if (sort != null) _sort = sort;
    });
    unawaited(_saveFilters());
  }

  Future<void> _saveFilters() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _filterKey,
      jsonEncode({'type': _type, 'sort': _sort, 'platform': _platform}),
    );
  }

  Future<void> _selectPlatform(String platform) async {
    if (_platform == platform) return;
    setState(() {
      _filterChanged = true;
      _platform = platform;
    });
    await _saveFilters();
    await _reloadPlatform();
  }

  Future<void> _reloadPlatform() async {
    final revision = ++_feedRevision;
    setState(() {
      _loading = true;
      _hasMore = true;
      _page = 1;
    });
    try {
      final rows = await widget.loadSourcePage(_activeSource, 1);
      if (!mounted || revision != _feedRevision) return;
      setState(() {
        _items = rows;
        _hasMore = rows.isNotEmpty;
      });
    } finally {
      if (mounted && revision == _feedRevision) {
        setState(() => _loading = false);
      }
    }
  }

  void _onScroll() {
    if (_controller.position.extentAfter < 900) unawaited(_loadMore());
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    final revision = _feedRevision;
    final source = _activeSource;
    setState(() => _loading = true);
    try {
      final next = await widget.loadSourcePage(source, _page + 1);
      if (!mounted || revision != _feedRevision) return;
      final keys = _items.map((item) => '${item.kind}:${item.id}').toSet();
      setState(() {
        _page++;
        _items.addAll(
          next.where((item) => keys.add('${item.kind}:${item.id}')),
        );
        _hasMore = next.isNotEmpty;
      });
    } finally {
      if (mounted && revision == _feedRevision) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var rows = _items
        .where((item) => _type == 'all' || item.kind == _type)
        .toList();
    if (_sort == '评分') {
      rows.sort((a, b) => b.rating.compareTo(a.rating));
    } else if (_sort == '年份') {
      rows.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: YingjiBackdrop(
        blur: 22,
        overlay: SafeArea(
          child: Column(
            children: [
              YingjiPageChrome(onBack: () => Navigator.pop(context)),
              Expanded(
                child: CustomScrollView(
                  controller: _controller,
                  scrollCacheExtent: const ScrollCacheExtent.pixels(1200),
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(74, 32, 64, 24),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.title,
                              style: const TextStyle(
                                fontSize: 48,
                                height: 1,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -1.2,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              '${_hasMore ? '持续加载' : '已加载全部'} · 当前 ${rows.length} 部',
                              style: const TextStyle(color: YingjiColors.muted),
                            ),
                            const SizedBox(height: 18),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final entry in _types.entries)
                                  _RankingFilter(
                                    label: entry.value,
                                    selected: _type == entry.key,
                                    onTap: () => _selectFilter(type: entry.key),
                                  ),
                                for (final label in _sorts)
                                  _RankingFilter(
                                    label: label,
                                    selected: _sort == label,
                                    onTap: () => _selectFilter(sort: label),
                                  ),
                              ],
                            ),
                            if (_selection?.provider == 'tmdb') ...[
                              const SizedBox(height: 12),
                              FutureBuilder<Map<String, String>>(
                                future: _watchProviders(
                                  _selection!.mediaType,
                                  _selection!.watchRegion,
                                ),
                                builder: (context, snapshot) {
                                  final platforms =
                                      snapshot.data ?? const {'all': '全部平台'};
                                  final selected =
                                      platforms.containsKey(_platform)
                                      ? _platform
                                      : 'all';
                                  return SizedBox(
                                    width: 280,
                                    child: YingjiGlassChoiceField<String>(
                                      label: '播放平台',
                                      helper: '切换后重新获取该平台的影视内容',
                                      value: selected,
                                      items: platforms.keys.toList(),
                                      labelBuilder: (value) =>
                                          platforms[value] ?? value,
                                      onChanged: (value) =>
                                          unawaited(_selectPlatform(value)),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(74, 0, 64, 56),
                      sliver: SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 224,
                              mainAxisExtent: 372,
                              mainAxisSpacing: 20,
                              crossAxisSpacing: 16,
                            ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => _RankingPosterCard(
                            rank: index + 1,
                            item: rows[index],
                          ),
                          childCount: rows.length,
                        ),
                      ),
                    ),
                    if (_loading)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: 32),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RankingPosterCard extends StatelessWidget {
  const _RankingPosterCard({required this.rank, required this.item});
  final int rank;
  final TmdbItem item;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => MetadataDetailPage(item: item)),
    ),
    borderRadius: BorderRadius.circular(17),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _MediaHover(
            borderRadius: 17,
            child: Stack(
              children: [
                Positioned.fill(
                  child: item.posterUrl == null
                      ? DecoratedBox(
                          decoration: BoxDecoration(
                            color: YingjiGlass.surface(),
                          ),
                          child: const Center(child: Icon(YingjiIcons.film)),
                        )
                      : CachedNetworkImage(
                          imageUrl: item.posterUrl.toString(),
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => DecoratedBox(
                            decoration: BoxDecoration(
                              color: YingjiGlass.surface(),
                            ),
                          ),
                        ),
                ),
                Positioned(
                  left: 10,
                  top: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: YingjiGlass.chrome(strength: 1.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: YingjiGlass.line()),
                    ),
                    child: Text(
                      '#$rank',
                      style: const TextStyle(
                        fontFeatures: [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        MediaRatingRow(item: item),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                '${item.year ?? '—'} · ${item.kind}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: YingjiColors.muted, fontSize: 12),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _SearchPage extends StatefulWidget {
  const _SearchPage();
  @override
  State<_SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<_SearchPage> {
  static const _recentKey = 'yingji.search.opened';
  final _controller = TextEditingController();
  final _pageScroll = ScrollController();
  final _tmdb = TmdbClient();
  List<TmdbItem> _results = const [];
  List<TmdbItem> _recentOpened = const [];
  List<MediaItem> _serverResults = const [];
  bool _loading = false;
  String? _message;
  String _scope = 'tmdb';

  @override
  void initState() {
    super.initState();
    _loadRecentOpened();
  }

  Future<void> _loadRecentOpened() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final raw = jsonDecode(prefs.getString(_recentKey) ?? '[]') as List;
      final rows = raw
          .whereType<Map<String, dynamic>>()
          .map(TmdbItem.fromJson)
          .where((item) => item.id > 0)
          .toList();
      if (mounted) setState(() => _recentOpened = rows);
    } catch (_) {}
  }

  Future<void> _openResult(TmdbItem item) async {
    final rows = [
      item,
      ..._recentOpened.where(
        (value) => value.id != item.id || value.kind != item.kind,
      ),
    ].take(12).toList();
    setState(() => _recentOpened = rows);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _recentKey,
      jsonEncode(rows.map((value) => value.toJson()).toList()),
    );
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => MetadataDetailPage(item: item)),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _pageScroll.dispose();
    _tmdb.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final result = _scope == 'tmdb'
          ? await _tmdb.search(query)
          : const <TmdbItem>[];
      final serverResults = _scope == 'server'
          ? await _searchServers(query)
          : const <MediaItem>[];
      if (mounted) {
        setState(() {
          _results = result;
          _serverResults = serverResults;
          _loading = false;
          _message = result.isEmpty && serverResults.isEmpty
              ? '没有匹配内容'
              : _scope == 'tmdb'
              ? 'TMDB · ${result.length} 项结果'
              : '已连接服务器 · ${serverResults.length} 项结果';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _message = error.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Future<List<MediaItem>> _searchServers(String query) async {
    final store = await SourceStore.create();
    final matches = <MediaItem>[];
    for (final source in store.load()) {
      final token = store.tokenFor(source);
      if (token == null || token.isEmpty) continue;
      try {
        if (source.kind == SourceKind.webdav) {
          final parts = utf8.decode(base64Url.decode(token)).split('\u0000');
          if (parts.length >= 2) {
            final client = WebDavClient();
            try {
              matches.addAll(
                (await client.list(
                  source: source,
                  username: parts[0],
                  password: parts[1],
                )).where(
                  (item) =>
                      item.title.toLowerCase().contains(query.toLowerCase()),
                ),
              );
            } finally {
              client.dispose();
            }
          }
        } else {
          final client = EmbyClient();
          try {
            final session = await client.resolveSession(
              EmbySession(source: source, token: token),
            );
            if (session.source.endpoint != source.endpoint) {
              await store.upsert(session.source, token);
            }
            matches.addAll(await client.search(session, query));
          } finally {
            client.dispose();
          }
        }
      } catch (_) {
        // One offline server must not hide results from the remaining sources.
      }
    }
    return matches;
  }

  @override
  Widget build(BuildContext context) => YingjiSmoothWheel(
    controller: _pageScroll,
    child: ListView(
      controller: _pageScroll,
      padding: const EdgeInsets.fromLTRB(0, 8, 4, 56),
      children: [
        const Text(
          '搜索',
          style: TextStyle(
            fontSize: 48,
            height: 1,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.2,
          ),
        ),
        const SizedBox(height: 22),
        _FrostSurface(
          borderRadius: 22,
          padding: const EdgeInsets.fromLTRB(18, 4, 10, 4),
          child: Row(
            children: [
              const Icon(YingjiIcons.search, color: Color(0xFFC5CAD5)),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _controller,
                  onSubmitted: (_) => _search(),
                  autofocus: true,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: '电影、剧集、演员或关键字',
                  ),
                ),
              ),
              _loading
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      onPressed: _search,
                      icon: const Icon(
                        YingjiIcons.arrow_right_circle_fill,
                        size: 28,
                      ),
                    ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            YingjiMotionIconButton(
              icon: YingjiIcons.film,
              tooltip: '使用 TMDB 搜索',
              selected: _scope == 'tmdb',
              size: 40,
              onPressed: () {
                setState(() {
                  _scope = 'tmdb';
                  _serverResults = const [];
                  _message = null;
                });
                if (_controller.text.trim().isNotEmpty) _search();
              },
            ),
            const SizedBox(width: 8),
            YingjiMotionIconButton(
              icon: YingjiIcons.cloud,
              tooltip: '搜索已连接服务器',
              selected: _scope == 'server',
              size: 40,
              onPressed: () {
                setState(() {
                  _scope = 'server';
                  _results = const [];
                  _message = null;
                });
                if (_controller.text.trim().isNotEmpty) _search();
              },
            ),
            const SizedBox(width: 12),
            Text(
              _scope == 'tmdb' ? 'TMDB 搜索' : '服务器搜索',
              style: const TextStyle(
                color: YingjiColors.muted,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(
              _message!,
              style: const TextStyle(color: Color(0xFFC5CAD5)),
            ),
          ),
        if (_recentOpened.isNotEmpty) ...[
          const SizedBox(height: 30),
          _SectionHeader(title: '最近查看', subtitle: '已从搜索进入详情的内容'),
          const SizedBox(height: 16),
          Wrap(
            spacing: 16,
            runSpacing: 26,
            children: _recentOpened
                .map(
                  (item) =>
                      _PosterTile(item: item, onOpen: () => _openResult(item)),
                )
                .toList(),
          ),
        ],
        if (_results.isNotEmpty) ...[
          const SizedBox(height: 34),
          _SectionHeader(title: '搜索结果', subtitle: '来自 TMDB 元数据'),
          const SizedBox(height: 16),
          Wrap(
            spacing: 16,
            runSpacing: 26,
            children: _results
                .map(
                  (item) =>
                      _PosterTile(item: item, onOpen: () => _openResult(item)),
                )
                .toList(),
          ),
        ],
        if (_serverResults.isNotEmpty) ...[
          const SizedBox(height: 34),
          _SectionHeader(title: '服务器结果', subtitle: '来自已连接的媒体来源'),
          const SizedBox(height: 16),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: _serverResults
                .map((media) => _ServerSearchTile(media: media))
                .toList(),
          ),
        ],
      ],
    ),
  );
}

class _ServerSearchTile extends StatelessWidget {
  const _ServerSearchTile({required this.media});
  final MediaItem media;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 230,
    child: InkWell(
      onTap: () => _openServerSearchDetail(context, media),
      borderRadius: BorderRadius.circular(14),
      child: _FrostSurface(
        borderRadius: 14,
        child: Row(
          children: [
            Icon(
              media.type == 'Episode' ? YingjiIcons.calendar : YingjiIcons.film,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    media.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    media.source.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: YingjiColors.muted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Lower-cases and strips punctuation/whitespace so server titles can be
/// matched against TMDB results without being thrown off by separators.
String _titleKey(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[\s\W_]+', unicode: true), '');

Future<void> _openServerSearchDetail(
  BuildContext context,
  MediaItem media,
) async {
  final providerId = media.providerIds.entries
      .where((entry) => entry.key.toLowerCase() == 'tmdb')
      .map((entry) => int.tryParse(entry.value))
      .firstWhere((value) => value != null, orElse: () => null);
  final isSeries = media.type == 'Series' || media.type == 'Episode';
  final title =
      (media.seriesTitle?.trim().isNotEmpty == true
              ? media.seriesTitle!
              : media.title)
          .trim();
  final tmdb = TmdbClient();
  try {
    TmdbItem? match;
    if (providerId != null && providerId > 0) {
      match = TmdbItem(
        id: providerId,
        title: title,
        kind: isSeries ? '剧集' : '电影',
      );
    } else if (title.isNotEmpty) {
      try {
        final rows = await tmdb.search(title);
        final wantedKind = isSeries ? '剧集' : '电影';
        final sameKind = rows
            .where((item) => item.kind == wantedKind)
            .toList(growable: false);
        final key = _titleKey(title);
        // Prefer an exact-name row, then a contains match, before falling
        // back to the first same-kind row — for a title like “一人之下” the
        // first result may be a different adaptation than the one this
        // server holds.
        match =
            sameKind
                .where((item) => _titleKey(item.title) == key)
                .firstOrNull ??
            sameKind
                .where(
                  (item) =>
                      _titleKey(item.title).contains(key) ||
                      key.contains(_titleKey(item.title)),
                )
                .firstOrNull ??
            sameKind.firstOrNull ??
            rows.firstOrNull;
      } catch (_) {
        match = null; // TMDB unreachable; handled below.
      }
    }
    if (!context.mounted) return;
    if (match == null) {
      // The bare “server item” detail page (MetadataDetailPage with [media])
      // is only meaningful for playable rows (Movie/Episode). A Series is a
      // container and cannot play directly, so without a TMDB match there is
      // no correct detail page to open — tell the user instead of showing a
      // broken container page.
      final playable = media.type != 'Series' && !media.isContainer;
      if (playable) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MetadataDetailPage(
              item: TmdbItem(id: 0, title: title, kind: isSeries ? '剧集' : '电影'),
              media: media,
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('暂未找到该内容的详情，仍可从完整列表继续播放。')),
        );
      }
      return;
    }
    // `match` is assigned inside a catch above, which defeats flow-typed
    // promotion; the `== null` branch already returned, so the assertion is
    // safe.
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => MetadataDetailPage(item: match!)),
    );
  } finally {
    tmdb.dispose();
  }
}

/// Locally cached library statistics for one source, refreshed only when the
/// app probes servers (first visit per run, or a manual refresh).
class _CachedSourceStats {
  const _CachedSourceStats({
    required this.movieCount,
    required this.seriesCount,
    required this.episodeCount,
    required this.latencyMs,
    required this.checkedAt,
  });

  factory _CachedSourceStats.fromJson(Map<String, dynamic> json) =>
      _CachedSourceStats(
        movieCount: (json['movieCount'] as num?)?.toInt() ?? 0,
        seriesCount: (json['seriesCount'] as num?)?.toInt() ?? 0,
        episodeCount: (json['episodeCount'] as num?)?.toInt() ?? 0,
        latencyMs: (json['latencyMs'] as num?)?.toInt() ?? 0,
        checkedAt: DateTime.tryParse('${json['checkedAt']}') ?? DateTime.now(),
      );

  final int movieCount;
  final int seriesCount;
  final int episodeCount;
  final int latencyMs;
  final DateTime checkedAt;

  Map<String, dynamic> toJson() => {
    'movieCount': movieCount,
    'seriesCount': seriesCount,
    'episodeCount': episodeCount,
    'latencyMs': latencyMs,
    'checkedAt': checkedAt.toIso8601String(),
  };
}

class _SourceHub extends StatefulWidget {
  const _SourceHub();
  @override
  State<_SourceHub> createState() => _SourceHubState();
}

class _SourceHubState extends State<_SourceHub> {
  SourceStore? _store;
  List<MediaSource> _sources = const [];
  bool _ready = false;
  String? _error;
  String? _testing;
  bool _refreshing = false;
  DateTime? _lastChecked;
  final Map<String, _CachedSourceStats> _stats = {};
  final Set<String> _offline = {};

  /// Process-wide guard: servers are probed once per app session — the first
  /// time this page is opened after launch — and again only on a manual
  /// refresh. Re-entering the page later renders the local cache instantly.
  static DateTime? _sessionProbeAt;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Local-first: render saved sources from disk immediately, then probe the
  /// servers only on the first visit of this app session.
  Future<void> _load() async {
    try {
      final store = await SourceStore.create();
      final saved = store.load();
      final stats = <String, _CachedSourceStats>{};
      for (final source in saved) {
        final raw = store.statsFor(source.id);
        if (raw == null) continue;
        try {
          stats[source.id] = _CachedSourceStats.fromJson(
            jsonDecode(raw) as Map<String, dynamic>,
          );
        } catch (_) {
          // Ignore a malformed cache entry; it will be rewritten on probe.
        }
      }
      if (!mounted) return;
      setState(() {
        _store = store;
        _sources = saved;
        _stats
          ..clear()
          ..addAll(stats);
        _error = null;
        _ready = true;
      });
      if (_sessionProbeAt == null) {
        unawaited(_refresh(manual: false));
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _ready = true;
          _error = '$error';
        });
      }
    }
  }

  /// Refresh button / post-edit validation. With [manual] false it only runs
  /// once per app session; with [manual] true it always probes the network.
  Future<void> _refresh({required bool manual}) async {
    if (_refreshing) return;
    if (!manual && _sessionProbeAt != null) return;
    final store = _store ?? await SourceStore.create();
    if (mounted) setState(() => _refreshing = true);
    final now = DateTime.now();
    final updated = List<MediaSource>.of(_sources);
    final stats = Map<String, _CachedSourceStats>.of(_stats);
    final offline = <String>{};

    await Future.wait([
      for (var index = 0; index < updated.length; index++)
        () async {
          final source = updated[index];
          if (source.kind == SourceKind.webdav) return;
          final token = store.tokenFor(source);
          final client = EmbyClient();
          try {
            if (token == null || token.isEmpty) {
              offline.add(source.id);
              return;
            }
            var current = (await client.resolveSession(
              EmbySession(source: source, token: token),
            )).source;
            // 1) Verify reachability and refresh the server identity.
            try {
              final identity = await client.serverIdentity(
                current,
                token: token,
              );
              final endpoints = <Uri>{
                ...source.endpoints,
                ...identity.discoveredEndpoints,
              };
              if (identity.name != source.name ||
                  identity.id != (source.serverId ?? source.id) ||
                  identity.endpoint != source.endpoint ||
                  endpoints.length != source.endpoints.length) {
                current = MediaSource(
                  id: source.id,
                  name: identity.name,
                  kind: source.kind,
                  endpoint: identity.endpoint,
                  userId: source.userId,
                  serverId: identity.id,
                  alternateEndpoints: endpoints
                      .where((value) => value != identity.endpoint)
                      .toList(growable: false),
                  iconUrl: source.iconUrl,
                  customIcon: source.customIcon,
                );
                await store.upsert(current, token);
              }
            } catch (_) {
              // An authenticated media session can work when info is private.
            }
            // 2) Refresh the cached library statistics.
            try {
              final library = await client.libraryStats(
                EmbySession(source: current, token: token),
              );
              final cached = _CachedSourceStats(
                movieCount: library.movieCount,
                seriesCount: library.seriesCount,
                episodeCount: library.episodeCount,
                latencyMs: library.latency.inMilliseconds,
                checkedAt: now,
              );
              stats[current.id] = cached;
              await store.saveStats(current.id, jsonEncode(cached.toJson()));
            } catch (_) {
              // Statistics permissions do not determine connection status.
            }
            // 3) Discover a server icon once, when none is stored yet.
            try {
              updated[index] = await _discoverServerIcon(store, current, token);
            } catch (_) {
              updated[index] = current;
            }
          } catch (_) {
            offline.add(source.id);
          } finally {
            client.dispose();
          }
        }(),
    ]);

    // A transient failure must be retried when this page is revisited; only a
    // fully successful automatic pass is considered complete for the session.
    _sessionProbeAt = offline.isEmpty ? now : null;
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      _lastChecked = now;
      _sources = updated;
      _stats
        ..clear()
        ..addAll(stats);
      _offline
        ..clear()
        ..addAll(offline);
    });
  }

  Future<MediaSource> _discoverServerIcon(
    SourceStore store,
    MediaSource source,
    String? token,
  ) async {
    if (source.customIcon || source.kind == SourceKind.webdav) {
      return source;
    }
    // Legacy records did not distinguish a selected icon-pack image from a
    // detected server icon. Clear those values before probing so a stale,
    // unrelated image cannot keep masking the connected server's identity.
    final baseline = MediaSource(
      id: source.id,
      name: source.name,
      kind: source.kind,
      endpoint: source.endpoint,
      userId: source.userId,
      serverId: source.serverId,
      alternateEndpoints: source.alternateEndpoints,
    );
    final candidates = [
      source.endpoint.resolve('web/assets/img/icon-transparent.png'),
      source.endpoint.resolve('web/assets/img/icon.png'),
      source.endpoint.resolve('web/assets/img/icon-square.png'),
      source.endpoint.resolve('web/assets/img/icon-round.png'),
    ];
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      for (final candidate in candidates) {
        try {
          final request = await http.getUrl(candidate);
          if (token != null && token.isNotEmpty) {
            request.headers.set('X-Emby-Token', token);
          }
          final response = await request.close();
          final image =
              response.headers.contentType?.primaryType == 'image' ||
              RegExp(
                r'\.(?:png|jpe?g|webp|gif|ico)$',
                caseSensitive: false,
              ).hasMatch(candidate.path);
          await response.drain<void>();
          if (response.statusCode < 300 && image) {
            final updated = MediaSource(
              id: source.id,
              name: source.name,
              kind: source.kind,
              endpoint: source.endpoint,
              userId: source.userId,
              serverId: source.serverId,
              alternateEndpoints: source.alternateEndpoints,
              iconUrl: candidate.toString(),
              customIcon: false,
            );
            if (token != null && token.isNotEmpty) {
              await store.upsert(updated, token);
            }
            return updated;
          }
        } catch (_) {
          // Try the next standard server icon path.
        }
      }
    } finally {
      http.close(force: true);
    }
    if (source.iconUrl != null && token != null && token.isNotEmpty) {
      await store.upsert(baseline, token);
    }
    return baseline;
  }

  Future<void> _remove(MediaSource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除服务器？'),
        content: Text('“${source.name}”的登录凭据与本地设置会一并移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed == true && _store != null) {
      await _store!.remove(source);
      await _load();
    }
  }

  Future<void> _add() async {
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => const _AddSourceDialog(),
    );
    if (added == true) {
      await _load();
      unawaited(_refresh(manual: true));
    }
  }

  Future<void> _edit(MediaSource source) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _AddSourceDialog(existing: source),
    );
    if (changed == true) {
      await _load();
      unawaited(_refresh(manual: true));
    }
  }

  Future<void> _pickIcon(MediaSource source) async {
    final store = _store ?? await SourceStore.create();
    final token = store.tokenFor(source);
    if (token == null || token.isEmpty) return;
    if (!mounted) return;
    final icon = await showDialog<String>(
      context: context,
      builder: (_) => _ServerIconDialog(source: source, token: token),
    );
    if (icon == null) return;
    await store.upsert(
      MediaSource(
        id: source.id,
        name: source.name,
        kind: source.kind,
        endpoint: source.endpoint,
        userId: source.userId,
        serverId: source.serverId,
        alternateEndpoints: source.alternateEndpoints,
        iconUrl: icon.isEmpty ? null : icon,
        customIcon: icon.isNotEmpty,
      ),
      token,
    );
    await _load();
    if (icon.isEmpty) unawaited(_refresh(manual: true));
  }

  Future<void> _switchEndpoint(MediaSource source, Uri endpoint) async {
    final store = _store ?? await SourceStore.create();
    final token = store.tokenFor(source);
    if (token == null || token.isEmpty) return;
    await store.upsert(
      MediaSource(
        id: source.id,
        name: source.name,
        kind: source.kind,
        endpoint: endpoint,
        userId: source.userId,
        serverId: source.serverId,
        alternateEndpoints: source.endpoints
            .where((value) => value != endpoint)
            .toList(growable: false),
        iconUrl: source.iconUrl,
        customIcon: source.customIcon,
      ),
      token,
    );
    await _load();
    unawaited(_refresh(manual: true));
  }

  Future<void> _test(MediaSource source) async {
    if (_testing != null) return;
    setState(() => _testing = source.id);
    try {
      final store = _store ?? await SourceStore.create();
      final token = store.tokenFor(source);
      if (token == null || token.isEmpty) {
        throw Exception('未找到已保存的登录凭据');
      }
      int count;
      if (source.kind == SourceKind.webdav) {
        final values = utf8.decode(base64Url.decode(token)).split('\u0000');
        if (values.length < 2) throw Exception('WebDAV 凭据已损坏');
        final client = WebDavClient();
        try {
          count = (await client.list(
            source: source,
            username: values[0],
            password: values[1],
          )).length;
        } finally {
          client.dispose();
        }
      } else {
        final client = EmbyClient();
        try {
          final resolved = await client.resolveSession(
            EmbySession(source: source, token: token),
          );
          final identity = await client.serverIdentity(
            resolved.source,
            token: token,
          );
          final tested = MediaSource(
            id: source.id,
            name: identity.name,
            kind: source.kind,
            endpoint: identity.endpoint,
            userId: resolved.source.userId,
            serverId: identity.id,
            alternateEndpoints: <Uri>{
              ...source.endpoints,
              ...identity.discoveredEndpoints,
            }.where((value) => value != identity.endpoint).toList(),
            iconUrl: source.iconUrl,
            customIcon: source.customIcon,
          );
          await client.checkConnection(
            EmbySession(source: tested, token: token),
          );
          count = (await client.recentlyAdded(
            EmbySession(source: tested, token: token),
          )).length;
          await store.upsert(tested, token);
          if (mounted) {
            setState(() {
              final index = _sources.indexWhere((row) => row.id == source.id);
              if (index >= 0) {
                _sources = List.of(_sources)..[index] = tested;
              }
              _offline.remove(source.id);
            });
          }
        } finally {
          client.dispose();
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('连接成功，可读取 $count 项媒体')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString().replaceFirst('Exception: ', '')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _testing = null);
    }
  }

  String get _statusSubtitle {
    if (_refreshing) {
      return _offline.isEmpty
          ? '正在检查服务器连接…'
          : '正在检查服务器连接… ${_offline.length} 个暂不可达';
    }
    final parts = <String>['${_sources.length} 个来源参与媒体库'];
    final checked = _lastChecked;
    if (checked != null) {
      final hour = checked.hour.toString().padLeft(2, '0');
      final minute = checked.minute.toString().padLeft(2, '0');
      parts.add('上次检查 $hour:$minute');
    }
    if (_offline.isNotEmpty) parts.add('${_offline.length} 个离线');
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(0, 8, 4, 56),
    children: [
      Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '服务器',
                  style: TextStyle(
                    fontSize: 48,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.2,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  '连接、验证并管理聚合到 Mova 的媒体来源。',
                  style: TextStyle(color: Color(0xFFABB1BE)),
                ),
              ],
            ),
          ),
          if (_refreshing)
            const Padding(
              padding: EdgeInsets.all(11),
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            )
          else
            YingjiMotionIconButton(
              onPressed: () => unawaited(_refresh(manual: true)),
              icon: YingjiIcons.refresh,
              tooltip: '检查服务器连接',
              size: 46,
            ),
          const SizedBox(width: 10),
          YingjiMotionIconButton(
            onPressed: _add,
            icon: YingjiIcons.plus,
            tooltip: '添加来源',
            size: 46,
          ),
        ],
      ),
      const SizedBox(height: 30),
      if (!_ready)
        const Center(
          child: Padding(
            padding: EdgeInsets.all(50),
            child: CircularProgressIndicator(),
          ),
        )
      else if (_error != null)
        _LoadFailure(onRetry: _load, message: _error!)
      else if (_sources.isEmpty)
        const _EmptyStrip(
          icon: YingjiIcons.dot_radiowaves_left_right,
          title: '还没有媒体来源',
          detail: '添加 Emby、Jellyfin 或 WebDAV 后，可聚合浏览并播放你的媒体。',
        )
      else ...[
        _SectionHeader(title: '已连接', subtitle: _statusSubtitle),
        const SizedBox(height: 14),
        ..._sources.map(
          (source) => Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _SourceCard(
                source: source,
                stats: _stats[source.id],
                iconToken: _store?.tokenFor(source),
                onPickIcon: () => _pickIcon(source),
                offline: _offline.contains(source.id),
                onRemove: () => _remove(source),
                onEdit: () => _edit(source),
                testing: _testing == source.id,
                onTest: () => _test(source),
                onOpen: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => EmbyLibraryPage(source: source),
                  ),
                ),
                onSwitchEndpoint: (endpoint) =>
                    _switchEndpoint(source, endpoint),
              ),
            ),
          ),
        ),
      ],
      const SizedBox(height: 34),
      const _SectionHeader(title: '可接入类型', subtitle: '当前版本已实现的来源'),
      const SizedBox(height: 14),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: const [
          _CapabilityTile(
            icon: YingjiIcons.play_rectangle_fill,
            title: 'Emby',
            detail: '账户验证、媒体库与直连播放',
          ),
          _CapabilityTile(
            icon: YingjiIcons.play_rectangle_fill,
            title: 'Jellyfin',
            detail: '账户验证、媒体库与直连播放',
          ),
          _CapabilityTile(
            icon: YingjiIcons.cloud_fill,
            title: 'WebDAV',
            detail: '目录扫描与直连播放',
          ),
        ],
      ),
    ],
  );
}

class _AddSourceDialog extends StatefulWidget {
  const _AddSourceDialog({this.existing});
  final MediaSource? existing;
  @override
  State<_AddSourceDialog> createState() => _AddSourceDialogState();
}

class _AddSourceDialogState extends State<_AddSourceDialog> {
  SourceKind _kind = SourceKind.emby;
  String _scheme = 'https';
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _alternateUrlControllers = <TextEditingController>[];
  final _iconUrl = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) {
      _kind = existing.kind;
      _scheme = existing.endpoint.scheme == 'http' ? 'http' : 'https';
      _name.text = existing.name;
      _url.text = existing.endpoint.toString();
      _alternateUrlControllers.addAll(
        existing.alternateEndpoints.map(
          (value) => TextEditingController(text: value.toString()),
        ),
      );
      _iconUrl.text = existing.iconUrl ?? '';
    }
  }

  List<Uri> _parsedEndpoints() {
    final raw = [
      _url.text,
      ..._alternateUrlControllers.map((row) => row.text),
    ].join('\n');
    final matches = RegExp(r'https?://[^\s,;]+', caseSensitive: false)
        .allMatches(raw)
        .map((match) => Uri.tryParse(match.group(0)!))
        .whereType<Uri>();
    final values = <Uri>[];
    for (final value in matches) {
      if (value.host.isEmpty || !['http', 'https'].contains(value.scheme)) {
        continue;
      }
      final normalized = value.toString().endsWith('/')
          ? value
          : value.replace(path: '${value.path}/');
      if (!values.contains(normalized)) values.add(normalized);
    }
    if (values.isEmpty && _url.text.trim().isNotEmpty) {
      final value = Uri.tryParse('$_scheme://${_url.text.trim()}');
      if (value != null && value.host.isNotEmpty) values.add(value);
    }
    return values;
  }

  void _selectScheme(String scheme) {
    final value = Uri.tryParse(_url.text.trim());
    setState(() {
      _scheme = scheme;
      if (value != null && value.host.isNotEmpty) {
        _url.text = value.replace(scheme: scheme).toString();
      }
    });
  }

  void _detectScheme(String input) {
    final match = RegExp(r'https?://', caseSensitive: false).firstMatch(input);
    if (match == null) return;
    final scheme = match
        .group(0)!
        .substring(0, match.group(0)!.length - 3)
        .toLowerCase();
    if (_scheme != scheme) setState(() => _scheme = scheme);
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    for (final controller in _alternateUrlControllers) {
      controller.dispose();
    }
    _iconUrl.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final candidates = _parsedEndpoints();
    if (candidates.isEmpty) {
      setState(() => _error = '请输入完整的 http:// 或 https:// 服务器地址');
      return;
    }
    final endpoint = candidates.firstWhere(
      (value) => value.scheme == _scheme,
      orElse: () => candidates.first,
    );
    final alternates = candidates
        .where((value) => value != endpoint)
        .toList(growable: false);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final store = await SourceStore.create();
      final existing = widget.existing;
      final keepCredentials =
          existing != null &&
          _username.text.trim().isEmpty &&
          _password.text.isEmpty;
      if (_kind == SourceKind.webdav) {
        final source = MediaSource(
          id: existing?.id ?? '${endpoint.host}-${endpoint.port}-webdav',
          name: _name.text.trim().isEmpty ? endpoint.host : _name.text.trim(),
          kind: _kind,
          endpoint: endpoint,
          alternateEndpoints: alternates,
          iconUrl: _iconUrl.text.trim().isEmpty ? null : _iconUrl.text.trim(),
          customIcon: existing?.customIcon ?? false,
        );
        final token = keepCredentials
            ? store.tokenFor(existing)
            : base64UrlEncode(
                utf8.encode('${_username.text}\u0000${_password.text}'),
              );
        if (token == null || token.isEmpty) {
          throw Exception('请填写 WebDAV 用户名和密码');
        }
        await store.upsert(source, token);
      } else if (keepCredentials) {
        final token = store.tokenFor(existing);
        if (token == null || token.isEmpty) {
          throw Exception('未找到旧登录凭据，请重新填写用户名和密码');
        }
        final client = EmbyClient();
        late final ({
          String name,
          String id,
          Uri endpoint,
          List<Uri> discoveredEndpoints,
        })
        identity;
        late final EmbySession verified;
        try {
          identity = await client.serverIdentity(
            MediaSource(
              id: existing.id,
              name: existing.name,
              kind: _kind,
              endpoint: endpoint,
              alternateEndpoints: alternates,
              userId: existing.userId,
              serverId: existing.serverId,
            ),
            token: token,
          );
          final available = <Uri>{
            endpoint,
            ...alternates,
            ...identity.discoveredEndpoints,
          };
          verified = await client.resolveSession(
            EmbySession(
              source: MediaSource(
                id: existing.id,
                name: identity.name,
                kind: _kind,
                endpoint: identity.endpoint,
                alternateEndpoints: available
                    .where((value) => value != identity.endpoint)
                    .toList(growable: false),
                userId: existing.userId,
                serverId: identity.id,
              ),
              token: token,
            ),
          );
        } finally {
          client.dispose();
        }
        final allEndpoints = <Uri>{
          endpoint,
          ...alternates,
          ...identity.discoveredEndpoints,
        };
        await store.upsert(
          MediaSource(
            id: existing.id,
            name: _name.text.trim().isEmpty ? identity.name : _name.text.trim(),
            kind: _kind,
            endpoint: verified.source.endpoint,
            alternateEndpoints: allEndpoints
                .where((value) => value != verified.source.endpoint)
                .toList(growable: false),
            userId: existing.userId,
            serverId: identity.id,
            iconUrl: _iconUrl.text.trim().isEmpty ? null : _iconUrl.text.trim(),
            customIcon: existing.customIcon,
          ),
          token,
        );
      } else {
        final client = EmbyClient();
        EmbySession? session;
        Object? lastError;
        try {
          for (final candidate in [endpoint, ...alternates]) {
            try {
              session = await client.authenticate(
                endpoint: candidate,
                username: _username.text.trim(),
                password: _password.text,
                kind: _kind,
              );
              break;
            } catch (error) {
              lastError = error;
            }
          }
          if (session == null) {
            throw lastError ?? Exception('所有服务器线路均无法登录');
          }
          final identity = await client.serverIdentity(
            MediaSource(
              id: existing?.id ?? session.source.id,
              name: session.source.name,
              kind: _kind,
              endpoint: session.source.endpoint,
              alternateEndpoints: [endpoint, ...alternates]
                  .where((value) => value != session!.source.endpoint)
                  .toList(growable: false),
              userId: session.source.userId,
              serverId: session.source.serverId,
            ),
            token: session.token,
          );
          final allEndpoints = <Uri>{
            endpoint,
            ...alternates,
            ...identity.discoveredEndpoints,
          };
          final verified = await client.resolveSession(
            EmbySession(
              source: MediaSource(
                id: existing?.id ?? session.source.id,
                name: identity.name,
                kind: _kind,
                endpoint: session.source.endpoint,
                userId: session.source.userId,
                serverId: identity.id,
                alternateEndpoints: allEndpoints
                    .where((value) => value != session!.source.endpoint)
                    .toList(growable: false),
              ),
              token: session.token,
            ),
          );
          await store.upsert(
            MediaSource(
              id: existing?.id ?? session.source.id,
              name: _name.text.trim().isEmpty
                  ? identity.name
                  : _name.text.trim(),
              kind: _kind,
              endpoint: verified.source.endpoint,
              userId: session.source.userId,
              serverId: identity.id,
              alternateEndpoints: allEndpoints
                  .where((value) => value != verified.source.endpoint)
                  .toList(growable: false),
              iconUrl: _iconUrl.text.trim().isEmpty
                  ? null
                  : _iconUrl.text.trim(),
              customIcon: existing?.customIcon ?? false,
            ),
            session.token,
          );
        } finally {
          client.dispose();
        }
      }
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => YingjiPinnedDialog(
    maxWidth: 720,
    maxHeight: 680,
    header: Row(
      children: [
        if (widget.existing != null) ...[
          _ServerMark(source: widget.existing!, size: 42),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.existing == null ? '连接媒体服务器' : '修改媒体服务器',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -.5,
                ),
              ),
              SizedBox(height: 6),
              Text(
                widget.existing == null
                    ? '验证成功后自动读取服务器名称、媒体统计与播放能力。'
                    : '留空用户名和密码可保留现有凭据；修改后可在卡片上测速。',
                style: TextStyle(color: YingjiColors.muted),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          icon: const Icon(YingjiIcons.xmark),
        ),
      ],
    ),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '来源类型',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final kind in SourceKind.values) ...[
              Expanded(
                child: _SourceKindChoice(
                  kind: kind,
                  selected: _kind == kind,
                  onTap: _saving ? null : () => setState(() => _kind = kind),
                ),
              ),
              if (kind != SourceKind.values.last) const SizedBox(width: 10),
            ],
          ],
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _name,
          decoration: const InputDecoration(
            labelText: '显示名称',
            hintText: '例如：客厅 Emby',
            prefixIcon: Icon(YingjiIcons.rectangle_stack),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          '连接信息',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          onChanged: _detectScheme,
          decoration: const InputDecoration(
            labelText: '服务器线路',
            hintText: 'https://server.example.com/（可直接粘贴多条）',
            prefixIcon: Icon(YingjiIcons.link),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            for (final scheme in const ['https', 'http']) ...[
              ChoiceChip(
                label: Text(scheme.toUpperCase()),
                selected: _scheme == scheme,
                onSelected: _saving ? null : (_) => _selectScheme(scheme),
              ),
              if (scheme == 'https') const SizedBox(width: 8),
            ],
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                '优先使用选中协议；其他粘贴的地址会自动保存为可切换线路。',
                style: TextStyle(color: YingjiColors.muted, fontSize: 11),
              ),
            ),
          ],
        ),
        for (
          var index = 0;
          index < _alternateUrlControllers.length;
          index++
        ) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _alternateUrlControllers[index],
                  keyboardType: TextInputType.url,
                  onChanged: _detectScheme,
                  decoration: InputDecoration(
                    labelText: '线路 ${index + 2}',
                    hintText: 'https://mirror.example.com/',
                    prefixIcon: const Icon(YingjiIcons.link),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              YingjiMotionIconButton(
                icon: YingjiIcons.trash,
                tooltip: '删除线路 ${index + 2}',
                size: 38,
                onPressed: () => setState(() {
                  _alternateUrlControllers.removeAt(index).dispose();
                }),
              ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: YingjiMotionIconButton(
            icon: YingjiIcons.plus,
            tooltip: '添加线路',
            size: 38,
            onPressed: () => setState(
              () => _alternateUrlControllers.add(TextEditingController()),
            ),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          '每个输入框保存一条线路；验证后也会加入服务器发布的线路。',
          style: TextStyle(color: YingjiColors.muted, fontSize: 11),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _username,
          decoration: InputDecoration(
            labelText: _kind == SourceKind.webdav ? '用户名（可选）' : '用户名',
            prefixIcon: const Icon(YingjiIcons.person),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          obscureText: true,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: _kind == SourceKind.webdav ? '密码（可选）' : '密码',
            prefixIcon: const Icon(YingjiIcons.lock),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(
              _error!,
              style: const TextStyle(color: YingjiColors.danger),
            ),
          ),
      ],
    ),
    actions: Row(
      children: [
        const Expanded(
          child: Text(
            '凭据仅用于连接所填服务器，并保存在本机。',
            style: TextStyle(color: YingjiColors.muted, fontSize: 11),
          ),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: _saving ? null : _submit,
          icon: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(YingjiIcons.checkmark_shield, size: 17),
          label: Text(
            _saving
                ? '正在验证'
                : widget.existing == null
                ? '验证并添加'
                : '保存修改',
          ),
        ),
      ],
    ),
  );
}

class _SourceKindChoice extends StatelessWidget {
  const _SourceKindChoice({
    required this.kind,
    required this.selected,
    required this.onTap,
  });
  final SourceKind kind;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      height: 74,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: selected ? Colors.white : const Color(0x99101317),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? Colors.white : Colors.white.withValues(alpha: .1),
        ),
      ),
      child: Row(
        children: [
          Icon(
            kind == SourceKind.webdav
                ? YingjiIcons.cloud_fill
                : YingjiIcons.play_rectangle_fill,
            color: selected ? Colors.black : Colors.white,
            size: 20,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              kind.label,
              style: TextStyle(
                color: selected ? Colors.black : Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _PlaylistsPage extends StatefulWidget {
  const _PlaylistsPage();
  @override
  State<_PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<_PlaylistsPage> {
  List<YingjiPlaylist> _playlists = const [];
  List<TmdbItem> _watchlist = const [];
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final playlists = await PlaylistStore.create();
    final watchlist = await WatchlistStore.create();
    if (mounted) {
      setState(() {
        _playlists = playlists.load();
        _watchlist = watchlist.load();
      });
    }
  }

  Future<void> _create() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        child: SizedBox(
          width: 480,
          child: GlassPanel(
            radius: 22,
            padding: const EdgeInsets.all(26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '新建片单',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          SizedBox(height: 5),
                          Text(
                            '用一个清晰的名称收纳想看的影视内容。',
                            style: TextStyle(color: YingjiColors.muted),
                          ),
                        ],
                      ),
                    ),
                    YingjiMotionIconButton(
                      icon: YingjiIcons.xmark,
                      tooltip: '关闭',
                      size: 38,
                      onPressed: () => Navigator.pop(dialogContext),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                TextField(
                  controller: controller,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (value) {
                    if (value.trim().isNotEmpty) {
                      Navigator.pop(dialogContext, value.trim());
                    }
                  },
                  decoration: const InputDecoration(
                    labelText: '片单名称',
                    hintText: '例如：周末电影',
                    prefixIcon: Icon(YingjiIcons.rectangle_stack),
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () {
                        final value = controller.text.trim();
                        if (value.isNotEmpty) {
                          Navigator.pop(dialogContext, value);
                        }
                      },
                      icon: const Icon(YingjiIcons.plus, size: 17),
                      label: const Text('创建片单'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    controller.dispose();
    if (name?.trim().isNotEmpty == true) {
      final store = await PlaylistStore.create();
      await store.save(
        YingjiPlaylist(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: name!.trim(),
          createdAt: DateTime.now(),
        ),
      );
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(0, 8, 4, 56),
    children: [
      Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '片单',
                  style: TextStyle(
                    fontSize: 48,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.2,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  '把待看、收藏与自定义顺序保存在自己的媒体空间。',
                  style: TextStyle(color: Color(0xFFABB1BE)),
                ),
              ],
            ),
          ),
          YingjiMotionIconButton(
            onPressed: _create,
            icon: YingjiIcons.plus,
            tooltip: '新建片单',
            size: 46,
          ),
        ],
      ),
      const SizedBox(height: 32),
      _SectionHeader(title: '待看', subtitle: '${_watchlist.length} 部已收藏内容'),
      const SizedBox(height: 14),
      if (_watchlist.isEmpty)
        const _EmptyStrip(
          icon: YingjiIcons.bookmark,
          title: '待看列表为空',
          detail: '在媒体详情页点击“加入待看”，即可保存到这里。',
        )
      else
        _PosterStrip(items: _watchlist),
      const SizedBox(height: 38),
      _SectionHeader(title: '自定义片单', subtitle: '本地保存，可继续扩展为 Trakt 同步'),
      const SizedBox(height: 14),
      if (_playlists.isEmpty)
        const _EmptyStrip(
          icon: YingjiIcons.rectangle_stack,
          title: '还没有自定义片单',
          detail: '创建片单后可从详情页把内容加入其中。',
        )
      else
        Wrap(
          spacing: 14,
          runSpacing: 14,
          children: _playlists
              .map(
                (playlist) => _PlaylistTile(
                  playlist: playlist,
                  onOpen: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          PlaylistDetailPage(playlistId: playlist.id),
                    ),
                  ).then((_) => _load()),
                  onDelete: () async {
                    final store = await PlaylistStore.create();
                    await store.remove(playlist.id);
                    await _load();
                  },
                ),
              )
              .toList(),
        ),
    ],
  );
}

class _CalendarPage extends StatefulWidget {
  const _CalendarPage();
  @override
  State<_CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<_CalendarPage> {
  final _trakt = TraktClient();
  final _tmdb = TmdbClient();
  List<TraktEvent> _events = const [];
  Map<String, String> _trackingStatus = const {};
  String? _traktMessage;
  DateTime _selectedDate = DateTime.now();
  final ScrollController _calendarRail = ScrollController();

  bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _weekday(DateTime value) =>
      const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][value.weekday - 1];

  // ignore: unused_element
  String _eventTime(DateTime value) {
    final local = value.toLocal();
    return '${local.month}月${local.day}日 ${_weekday(local)}';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final watchlist = await WatchlistStore.create();
    final watchStates = await WatchStateStore.create();
    final prefs = await SharedPreferences.getInstance();
    final clientId = prefs.getString('yingji.trakt.client-id') ?? '';
    final token = prefs.getString('yingji.trakt.access-token') ?? '';
    final statusJson = prefs.getString('yingji.tracking.status');
    final cached = _readCachedEvents(prefs);
    if (mounted) {
      setState(() {
        _events = cached;
        _trackingStatus = _readTrackingStatus(statusJson);
        _traktMessage = clientId.isEmpty || token.isEmpty
            ? '未连接 Trakt；已展示本地待看的更新信息。'
            : null;
      });
    }

    List<TraktEvent> traktEvents = const [];
    String? message;
    if (clientId.isNotEmpty && token.isNotEmpty) {
      try {
        traktEvents = await _trakt.calendar(
          clientId: clientId,
          accessToken: token,
        );
      } catch (error) {
        message = error.toString().replaceFirst('Exception: ', '');
      }
    } else {
      message = '未连接 Trakt；可在设置中连接以同步观看记录。';
    }
    final tracked = <int, TmdbItem>{
      for (final state in watchStates.load())
        if ((state.tmdbId ?? 0) > 0 && state.seasonNumber != null)
          state.tmdbId!: TmdbItem(
            id: state.tmdbId!,
            title: state.title,
            kind: '剧集',
          ),
      // The saved watchlist carries the proper poster/title and therefore
      // enriches a history-only placeholder for the same TMDB series.
      for (final item in watchlist.load())
        if (item.kind == '剧集' && item.id > 0) item.id: item,
    };
    final localEvents = await _localWatchlistEvents(tracked.values.toList());
    final events = _mergeEvents([...traktEvents, ...localEvents]);
    await prefs.setString(
      'yingji.tracking.calendar-cache',
      jsonEncode(events.map((event) => event.toJson()).toList()),
    );
    if (mounted) {
      final visibleEvents = events.isEmpty ? cached : events;
      final selectedHasEvent = visibleEvents.any(
        (event) => _sameDate(event.airDate.toLocal(), _selectedDate),
      );
      final nextEvent = visibleEvents
          .where((event) => !event.airDate.toLocal().isBefore(DateTime.now()))
          .firstOrNull;
      final preferredDate =
          nextEvent?.airDate.toLocal() ??
          visibleEvents.firstOrNull?.airDate.toLocal();
      setState(() {
        _events = visibleEvents;
        _trackingStatus = _readTrackingStatus(statusJson);
        _traktMessage = message;
        if (!selectedHasEvent && preferredDate != null) {
          _selectedDate = preferredDate;
        }
      });
    }
  }

  Map<String, String> _readTrackingStatus(String? value) {
    if (value == null || value.isEmpty) return const {};
    try {
      return Map<String, String>.from(
        (jsonDecode(value) as Map).cast<String, String>(),
      );
    } catch (_) {
      return const {};
    }
  }

  List<TraktEvent> _readCachedEvents(SharedPreferences prefs) {
    final raw = prefs.getString('yingji.tracking.calendar-cache');
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(TraktEvent.fromJson)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<List<TraktEvent>> _localWatchlistEvents(
    List<TmdbItem> watchlist,
  ) async {
    final items = watchlist.where((item) => item.kind == '剧集').toList();
    final result = <TraktEvent>[];
    // Keep first refresh responsive without flooding either schedule service
    // when a user imports a large Trakt/server history at once.
    for (var start = 0; start < items.length; start += 6) {
      final end = (start + 6).clamp(0, items.length);
      final rows = await Future.wait(
        items.sublist(start, end).map((item) async {
          try {
            final episodes = await _tmdb.upcomingEpisodes(item);
            return episodes
                .map(
                  (next) => TraktEvent(
                    tmdbId: item.id,
                    seasonNumber: next.seasonNumber,
                    episodeNumber: next.episodeNumber,
                    title: item.title,
                    episode:
                        '第 ${next.seasonNumber} 季 · 第 ${next.episodeNumber} 集 · ${next.title}',
                    airDate: next.airDate,
                    posterUrl: next.stillUrl ?? item.posterUrl,
                    platform: next.network,
                    timeKnown: next.timeKnown,
                  ),
                )
                .toList(growable: false);
          } catch (_) {
            // A single metadata timeout cannot hide the other tracked shows.
            return const <TraktEvent>[];
          }
        }),
      );
      result.addAll(rows.expand((row) => row));
    }
    return result;
  }

  List<TraktEvent> _mergeEvents(List<TraktEvent> rows) {
    final distinct = <String, TraktEvent>{};
    for (final event in rows) {
      final local = event.airDate.toLocal();
      final key =
          event.tmdbId != null &&
              event.seasonNumber != null &&
              event.episodeNumber != null
          ? '${event.tmdbId}:${event.seasonNumber}:${event.episodeNumber}'
          : '${event.title}|${event.episode}|${local.year}-${local.month}-${local.day}';
      final previous = distinct[key];
      if (previous == null) {
        distinct[key] = event;
      } else {
        final precise = previous.timeKnown ? previous : event;
        distinct[key] = TraktEvent(
          title: event.title,
          episode: event.episode,
          airDate: precise.airDate,
          timeKnown: precise.timeKnown,
          posterUrl: event.posterUrl ?? previous.posterUrl,
          platform: precise.platform ?? previous.platform ?? event.platform,
          tmdbId: event.tmdbId,
          seasonNumber: event.seasonNumber,
          episodeNumber: event.episodeNumber,
        );
      }
    }
    final result = distinct.values.toList()
      ..sort((a, b) => a.airDate.compareTo(b.airDate));
    return result;
  }

  Future<void> _setTrackingStatus(String title, String status) async {
    final next = Map<String, String>.from(_trackingStatus);
    if (status == 'none') {
      next.remove(title);
    } else {
      next[title] = status;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('yingji.tracking.status', jsonEncode(next));
    if (mounted) setState(() => _trackingStatus = next);
  }

  @override
  void dispose() {
    _calendarRail.dispose();
    _trakt.dispose();
    _tmdb.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedEvents =
        _events
            .where((event) => _sameDate(event.airDate.toLocal(), _selectedDate))
            .toList()
          ..sort((a, b) => a.airDate.compareTo(b.airDate));
    final dates = _scheduleDates();
    final now = DateTime.now();
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 4, 56),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '追剧日历',
                    style: TextStyle(
                      fontSize: 44,
                      height: 1,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1.2,
                    ),
                  ),
                  SizedBox(height: 9),
                  Text(
                    '待看剧集与 Trakt 观看记录的下一次播出安排。',
                    style: TextStyle(color: Color(0xFFABB1BE)),
                  ),
                ],
              ),
            ),
            YingjiMotionIconButton(
              icon: YingjiIcons.refresh,
              tooltip: '刷新播出安排',
              onPressed: _load,
            ),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            YingjiDirectionalArrow(
              previous: true,
              tooltip: '向前浏览日期',
              onPressed: () => _moveCalendarRail(-420),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 82,
                child: ListView.separated(
                  controller: _calendarRail,
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  itemCount: dates.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 9),
                  itemBuilder: (context, index) {
                    final date = dates[index];
                    final count = _events
                        .where(
                          (event) => _sameDate(event.airDate.toLocal(), date),
                        )
                        .length;
                    return _CalendarDateRailTile(
                      date: date,
                      count: count,
                      selected: _sameDate(date, _selectedDate),
                      today: _sameDate(date, now),
                      weekday: _weekday(date),
                      onTap: () => setState(() => _selectedDate = date),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 10),
            YingjiDirectionalArrow(
              previous: false,
              tooltip: '向后浏览日期',
              onPressed: () => _moveCalendarRail(420),
            ),
          ],
        ),
        const SizedBox(height: 28),
        _SectionHeader(
          title: '${_eventTime(_selectedDate)} · ${selectedEvents.length} 项更新',
          subtitle: _events.isEmpty
              ? (_traktMessage ?? '正在读取 Trakt 日历…')
              : selectedEvents.isEmpty
              ? '当天没有待播内容，选择带圆点的日期查看安排。'
              : '时间以已连接的 Trakt 与媒体元数据为准。',
        ),
        const SizedBox(height: 12),
        if (selectedEvents.isNotEmpty)
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth >= 1000
                  ? (constraints.maxWidth - 16) / 2
                  : constraints.maxWidth;
              return Wrap(
                spacing: 16,
                runSpacing: 16,
                children: selectedEvents
                    .map(
                      (event) => SizedBox(
                        width: width,
                        child: _TrackingEventCard(
                          event: event,
                          status: _trackingStatus[event.title] ?? 'none',
                          onOpen: () => _openTrackingDetail(event),
                          onStatus: (status) =>
                              _setTrackingStatus(event.title, status),
                        ),
                      ),
                    )
                    .toList(growable: false),
              );
            },
          ),
        if (selectedEvents.isEmpty)
          _FrostSurface(
            borderRadius: 16,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 28),
            child: Row(
              children: [
                const Icon(YingjiIcons.calendar, color: YingjiColors.muted),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _events.isEmpty
                        ? (_traktMessage ?? '正在读取更新安排…')
                        : '这一天没有更新，选择带进度标记的日期查看剧集。',
                    style: const TextStyle(color: YingjiColors.muted),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  List<DateTime> _scheduleDates() {
    final today = DateTime.now();
    final values = <DateTime>{
      for (var offset = -3; offset <= 20; offset++)
        DateTime(
          today.year,
          today.month,
          today.day,
        ).add(Duration(days: offset)),
      for (final event in _events)
        DateTime(
          event.airDate.toLocal().year,
          event.airDate.toLocal().month,
          event.airDate.toLocal().day,
        ),
      DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day),
    }.toList()..sort();
    return values;
  }

  void _moveCalendarRail(double delta) {
    if (!_calendarRail.hasClients) return;
    _calendarRail.animateTo(
      (_calendarRail.offset + delta).clamp(
        0,
        _calendarRail.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _openTrackingDetail(TraktEvent event) async {
    try {
      final matches = await _tmdb.search(event.title);
      if (!mounted) return;
      final match =
          matches.where((item) => item.kind == '剧集').firstOrNull ??
          matches.firstOrNull;
      if (match == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('暂未找到该剧集的详情。')));
        return;
      }
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => MetadataDetailPage(item: match)),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('详情暂时无法加载，请稍后重试。')));
      }
    }
  }
}

class _CalendarDateRailTile extends StatelessWidget {
  const _CalendarDateRailTile({
    required this.date,
    required this.count,
    required this.selected,
    required this.today,
    required this.weekday,
    required this.onTap,
  });

  final DateTime date;
  final int count;
  final bool selected;
  final bool today;
  final String weekday;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(16),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: 64,
      decoration: BoxDecoration(
        color: selected
            ? Colors.white.withValues(alpha: .92)
            : today
            ? Colors.white.withValues(alpha: .16)
            : YingjiGlass.chrome(strength: .58),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: selected
              ? Colors.white
              : YingjiGlass.line(strength: today ? 1.7 : .8),
        ),
        boxShadow: selected
            ? const [
                BoxShadow(
                  color: Color(0x3DFFFFFF),
                  blurRadius: 15,
                  offset: Offset(0, 5),
                ),
              ]
            : today
            ? const [BoxShadow(color: Color(0x2EFFFFFF), blurRadius: 14)]
            : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            today ? '今天' : weekday,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: selected ? const Color(0xFF151820) : YingjiColors.quiet,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${date.day}',
            style: TextStyle(
              fontSize: 20,
              height: 1,
              fontWeight: FontWeight.w800,
              color: selected ? const Color(0xFF101217) : YingjiColors.ink,
            ),
          ),
          const SizedBox(height: 5),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: count > 0 ? 16 : 4,
            height: 3,
            decoration: BoxDecoration(
              color: count > 0
                  ? (selected
                        ? const Color(0xFF16191F)
                        : const Color(0xFF8EE49C))
                  : Colors.white.withValues(alpha: .18),
              borderRadius: BorderRadius.circular(99),
            ),
          ),
        ],
      ),
    ),
  );
}

class _TrackingEventCard extends StatelessWidget {
  const _TrackingEventCard({
    required this.event,
    required this.status,
    required this.onOpen,
    required this.onStatus,
  });
  final TraktEvent event;
  final String status;
  final VoidCallback onOpen;
  final ValueChanged<String> onStatus;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onOpen,
    borderRadius: BorderRadius.circular(18),
    child: _FrostSurface(
      borderRadius: 18,
      padding: const EdgeInsets.all(12),
      child: SizedBox(
        height: 104,
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 166,
                height: 104,
                child: event.posterUrl == null
                    ? const ColoredBox(
                        color: YingjiColors.elevated,
                        child: Icon(YingjiIcons.calendar),
                      )
                    : CachedNetworkImage(
                        imageUrl: event.posterUrl.toString(),
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) =>
                            const ColoredBox(color: YingjiColors.elevated),
                      ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    event.episode,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: YingjiColors.muted,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${event.timeKnown ? '${event.airDate.toLocal().hour.toString().padLeft(2, '0')}:${event.airDate.toLocal().minute.toString().padLeft(2, '0')}' : '已公布日期，时分未公布'}  ·  ${event.platform?.isNotEmpty == true ? event.platform : '播出平台待定'}',
                    style: const TextStyle(
                      color: YingjiColors.quiet,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                YingjiMotionIconButton(
                  icon: YingjiIcons.bookmark,
                  tooltip: status == 'watchlist' ? '移出待看' : '加入待看',
                  selected: status == 'watchlist',
                  size: 34,
                  onPressed: () =>
                      onStatus(status == 'watchlist' ? 'none' : 'watchlist'),
                ),
                const SizedBox(width: 6),
                YingjiMotionIconButton(
                  icon: status == 'watched'
                      ? YingjiIcons.check_mark
                      : YingjiIcons.xmark,
                  tooltip: status == 'watched' ? '取消已看' : '标记已看',
                  selected: status == 'watched',
                  size: 34,
                  onPressed: () =>
                      onStatus(status == 'watched' ? 'none' : 'watched'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _settingsScroll = ScrollController();
  final _homeKey = GlobalKey();
  final _appearanceKey = GlobalKey();
  final _playerKey = GlobalKey();
  final _behaviorKey = GlobalKey();
  final _networkKey = GlobalKey();
  final _danmakuKey = GlobalKey();
  final _systemKey = GlobalKey();
  final _maintenanceKey = GlobalKey();
  final _aboutKey = GlobalKey();
  final _activeSetting = ValueNotifier<int>(0);
  bool _hardware = true, _hdr = true, _downmix = false, _night = false;
  bool _preferChineseSubtitle = true;
  String _subtitleLanguage = 'zh';
  bool _preferAudioTrack = false;
  String _audioLanguage = 'zh';
  bool _voiceEnhance = false;
  bool _resumePrompt = true;
  bool _homeContinueWatching = true, _homeShowIcon = true;
  bool _homeAutoCarousel = true, _homeShowCarouselDots = true;
  double _homeCarouselSeconds = 6;
  String _homeCarouselSource = 'trending';
  String _homeCarouselEffect = 'blur-dissolve';
  String _appearanceTheme = 'dark', _appearanceIcon = 'play';
  String _appearanceFont = 'round';
  double _appearanceGlassOpacity = .58, _appearanceGlassBlur = 24;
  double _appearanceCardDepth = .62;
  double _defaultSpeed = 1,
      _audioDelay = 0,
      _subtitleDelay = 0,
      _cacheSeconds = 30;
  String _aspect = '自动';
  bool _autoSkipSegments = true;
  double _autoSkipDelaySeconds = 5;
  bool _segmentServerSource = true;
  bool _segmentIntroDbSource = true;
  double _seekSeconds = 10;
  double _volumeStep = 5;
  bool _preloadNextEpisode = true;
  double _preloadLeadMinutes = 5;
  bool _closeToTray = true;
  Map<String, String> _shortcuts = Map.of(_defaultPlayerShortcuts);
  int _metadataCacheCount = 0;
  int _imageCacheBytes = 0;
  final _tmdbApiKey = TextEditingController();
  bool _danmakuEnabled = false;
  final _traktClientId = TextEditingController();
  final _traktClientSecret = TextEditingController();
  final _traktToken = TextEditingController();
  final _danmakuUrl = TextEditingController();
  final _danmakuApiNameControllers = <TextEditingController>[];
  final _danmakuApiControllers = <TextEditingController>[];
  final _danmakuToken = TextEditingController();
  String? _savedMessage;
  bool _tmdbTesting = false;
  String? _tmdbMessage;
  bool _danmakuTesting = false;
  String? _danmakuMessage;
  bool _traktAuthorizing = false;
  String? _traktMessage;
  bool _jumpingToSetting = false;
  int _settingJumpGeneration = 0;

  void _changeShortcut(String action, String value) {
    String label(String raw) => raw.contains('|')
        ? raw.split('|').skip(1).join('|').toLowerCase()
        : raw.toLowerCase();
    final conflict = _shortcuts.entries
        .where(
          (entry) => entry.key != action && label(entry.value) == label(value),
        )
        .firstOrNull;
    if (conflict != null) {
      setState(
        () => _savedMessage = '$value 已用于 ${_shortcutNames[conflict.key]}',
      );
      return;
    }
    setState(() => _shortcuts[action] = value);
    _save();
  }

  @override
  void initState() {
    super.initState();
    _settingsScroll.addListener(_syncActiveSetting);
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _hardware = prefs.getBool('yingji.player.hardware') ?? true;
        _hdr = prefs.getBool('yingji.player.hdr') ?? true;
        _downmix = prefs.getBool('yingji.player.downmix') ?? false;
        _night = prefs.getBool('yingji.player.night') ?? false;
        _voiceEnhance = prefs.getBool('yingji.player.voice-enhance') ?? false;
        _resumePrompt = prefs.getBool('yingji.player.resume-prompt') ?? true;
        _homeContinueWatching =
            prefs.getBool('yingji.home.continue-watching') ?? true;
        _homeShowIcon = prefs.getBool('yingji.home.show-icon') ?? true;
        _homeAutoCarousel = prefs.getBool('yingji.home.auto-carousel') ?? true;
        _homeShowCarouselDots = prefs.getBool('yingji.home.show-dots') ?? true;
        _homeCarouselSeconds =
            (prefs.getDouble('yingji.home.carousel-seconds') ?? 6).clamp(3, 15);
        _homeCarouselSource =
            prefs.getString('yingji.home.carousel-source') ?? 'trending';
        final savedEffect = prefs.getString('yingji.home.carousel-effect');
        _homeCarouselEffect = savedEffect == null || savedEffect == 'slide-fade'
            ? 'blur-dissolve'
            : savedEffect;
        _appearanceTheme = prefs.getString('yingji.appearance.theme') ?? 'dark';
        _appearanceIcon = prefs.getString('yingji.appearance.icon') ?? 'play';
        _appearanceFont = prefs.getString('yingji.appearance.font') ?? 'round';
        _appearanceGlassOpacity =
            (prefs.getDouble('yingji.appearance.glass-opacity') ?? .58).clamp(
              0,
              1,
            );
        _appearanceGlassBlur =
            (prefs.getDouble('yingji.appearance.glass-blur') ?? 24).clamp(
              0,
              40,
            );
        _appearanceCardDepth =
            (prefs.getDouble('yingji.appearance.card-depth') ?? .62).clamp(
              0,
              1,
            );
        _defaultSpeed = prefs.getDouble('yingji.player.speed') ?? 1;
        _audioDelay = prefs.getDouble('yingji.player.audio-delay') ?? 0;
        _subtitleDelay = prefs.getDouble('yingji.player.subtitle-delay') ?? 0;
        _preferChineseSubtitle =
            prefs.getBool('yingji.player.subtitle-priority-enabled') ??
            prefs.getBool('yingji.player.prefer-chinese-subtitle') ??
            true;
        _subtitleLanguage =
            prefs.getString('yingji.player.subtitle-language') ?? 'zh';
        _preferAudioTrack =
            prefs.getBool('yingji.player.audio-priority-enabled') ?? false;
        _audioLanguage =
            prefs.getString('yingji.player.audio-language') ?? 'zh';
        _cacheSeconds = prefs.getDouble('yingji.player.cache-seconds') ?? 30;
        _aspect = prefs.getString('yingji.player.aspect') ?? '自动';
        _autoSkipSegments = prefs.getBool('yingji.segment.auto-skip') ?? true;
        _autoSkipDelaySeconds =
            prefs.getDouble('yingji.segment.skip-delay-seconds') ?? 5;
        _segmentServerSource =
            prefs.getBool('yingji.segment.source-server') ?? true;
        _segmentIntroDbSource =
            prefs.getBool('yingji.segment.source-theintrodb') ?? true;
        _seekSeconds = prefs.getDouble('yingji.player.seek-seconds') ?? 10;
        _volumeStep = prefs.getDouble('yingji.player.volume-step') ?? 5;
        _preloadNextEpisode =
            prefs.getBool('yingji.player.preload-next') ?? true;
        _preloadLeadMinutes =
            prefs.getDouble('yingji.player.preload-lead-minutes') ?? 5;
        _closeToTray = prefs.getBool('yingji.system.close-to-tray') ?? true;
        final shortcutJson = prefs.getString('yingji.player.shortcuts');
        final shortcutData = shortcutJson == null
            ? null
            : jsonDecode(shortcutJson);
        _shortcuts = shortcutData is Map
            ? {
                ..._defaultPlayerShortcuts,
                ...shortcutData.map((k, v) => MapEntry('$k', '$v')),
              }
            : Map.of(_defaultPlayerShortcuts);
        _tmdbApiKey.text = prefs.getString('yingji.tmdb.api-key') ?? '';
        _danmakuEnabled = prefs.getBool('yingji.danmaku.enabled') ?? false;
        _traktClientId.text = prefs.getString('yingji.trakt.client-id') ?? '';
        _traktClientSecret.text =
            prefs.getString('yingji.trakt.client-secret') ?? '';
        _traktToken.text = prefs.getString('yingji.trakt.access-token') ?? '';
        _danmakuUrl.text = prefs.getString('yingji.danmaku.url') ?? '';
        final savedApis =
            prefs.getStringList('yingji.danmaku.apis') ?? const [];
        for (final controller in _danmakuApiControllers) {
          controller.dispose();
        }
        for (final controller in _danmakuApiNameControllers) {
          controller.dispose();
        }
        final savedApiNames =
            prefs.getStringList('yingji.danmaku.api-names') ?? const [];
        _danmakuApiControllers
          ..clear()
          ..addAll(
            (savedApis.isEmpty ? [_danmakuUrl.text] : savedApis)
                .where((value) => value.trim().isNotEmpty)
                .map((value) => TextEditingController(text: value)),
          );
        if (_danmakuApiControllers.isEmpty) {
          _danmakuApiControllers.add(TextEditingController());
        }
        _danmakuApiNameControllers
          ..clear()
          ..addAll(
            List.generate(
              _danmakuApiControllers.length,
              (index) => TextEditingController(
                text: index < savedApiNames.length
                    ? savedApiNames[index]
                    : '弹幕 ${index + 1}',
              ),
            ),
          );
        _danmakuToken.text = prefs.getString('yingji.danmaku.token') ?? '';
      });
      _applyAppearance();
      unawaited(_refreshCacheStats());
    }
  }

  Future<void> _save({bool feedback = false}) async {
    final danmakuApis = _danmakuApiControllers
        .map((controller) => controller.text.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (_danmakuEnabled && danmakuApis.isEmpty) {
      if (mounted) setState(() => _savedMessage = '请填写弹幕 API 地址，或关闭弹幕');
      return;
    }
    for (final api in danmakuApis) {
      final candidate = api.replaceAllMapped(
        RegExp(r'\{(?:tmdbId|title|season|episode|url)\}'),
        (_) => 'test',
      );
      final uri = Uri.tryParse(candidate);
      if (uri == null || !['http', 'https'].contains(uri.scheme)) {
        if (mounted) setState(() => _savedMessage = '弹幕 API 地址无效');
        return;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('yingji.player.hardware', _hardware);
    await prefs.setBool('yingji.player.hdr', _hdr);
    await prefs.setBool('yingji.player.downmix', _downmix);
    await prefs.setBool('yingji.player.night', _night);
    await prefs.setBool('yingji.player.voice-enhance', _voiceEnhance);
    await prefs.setBool('yingji.player.resume-prompt', _resumePrompt);
    await prefs.setBool('yingji.home.continue-watching', _homeContinueWatching);
    await prefs.setBool('yingji.home.show-icon', _homeShowIcon);
    await prefs.setBool('yingji.home.auto-carousel', _homeAutoCarousel);
    await prefs.setBool('yingji.home.show-dots', _homeShowCarouselDots);
    await prefs.setDouble('yingji.home.carousel-seconds', _homeCarouselSeconds);
    await prefs.setString('yingji.home.carousel-source', _homeCarouselSource);
    await prefs.setString('yingji.home.carousel-effect', _homeCarouselEffect);
    yingjiBackdropEffect.value = _homeCarouselEffect;
    await prefs.setString('yingji.appearance.theme', _appearanceTheme);
    await prefs.setString('yingji.appearance.icon', _appearanceIcon);
    await prefs.setString('yingji.appearance.font', _appearanceFont);
    await prefs.setDouble(
      'yingji.appearance.glass-opacity',
      _appearanceGlassOpacity,
    );
    await prefs.setDouble('yingji.appearance.glass-blur', _appearanceGlassBlur);
    await prefs.setDouble('yingji.appearance.card-depth', _appearanceCardDepth);
    await prefs.setDouble('yingji.player.speed', _defaultSpeed);
    await prefs.setDouble('yingji.player.audio-delay', _audioDelay);
    await prefs.setDouble('yingji.player.subtitle-delay', _subtitleDelay);
    await prefs.setBool(
      'yingji.player.subtitle-priority-enabled',
      _preferChineseSubtitle,
    );
    await prefs.setString('yingji.player.subtitle-language', _subtitleLanguage);
    await prefs.setBool(
      'yingji.player.audio-priority-enabled',
      _preferAudioTrack,
    );
    await prefs.setString('yingji.player.audio-language', _audioLanguage);
    await prefs.setDouble('yingji.player.cache-seconds', _cacheSeconds);
    await prefs.setString('yingji.player.aspect', _aspect);
    await prefs.setBool('yingji.segment.auto-skip', _autoSkipSegments);
    await prefs.setDouble(
      'yingji.segment.skip-delay-seconds',
      _autoSkipDelaySeconds,
    );
    await prefs.setBool('yingji.segment.source-server', _segmentServerSource);
    await prefs.setBool(
      'yingji.segment.source-theintrodb',
      _segmentIntroDbSource,
    );
    await prefs.setDouble('yingji.player.seek-seconds', _seekSeconds);
    await prefs.setDouble('yingji.player.volume-step', _volumeStep);
    await prefs.setBool('yingji.player.preload-next', _preloadNextEpisode);
    await prefs.setDouble(
      'yingji.player.preload-lead-minutes',
      _preloadLeadMinutes,
    );
    await prefs.setBool('yingji.system.close-to-tray', _closeToTray);
    await prefs.setString('yingji.player.shortcuts', jsonEncode(_shortcuts));
    await prefs.setString('yingji.tmdb.api-key', _tmdbApiKey.text.trim());
    await prefs.setString('yingji.trakt.client-id', _traktClientId.text.trim());
    await prefs.setString(
      'yingji.trakt.client-secret',
      _traktClientSecret.text.trim(),
    );
    await prefs.setString('yingji.trakt.access-token', _traktToken.text.trim());
    await prefs.setBool('yingji.danmaku.enabled', _danmakuEnabled);
    await prefs.remove('yingji.danmaku.name');
    await prefs.setString('yingji.danmaku.url', danmakuApis.firstOrNull ?? '');
    await prefs.setStringList('yingji.danmaku.apis', danmakuApis);
    await prefs.setStringList(
      'yingji.danmaku.api-names',
      List.generate(
        danmakuApis.length,
        (index) => index < _danmakuApiNameControllers.length
            ? _danmakuApiNameControllers[index].text.trim()
            : '',
      ),
    );
    await prefs.setString('yingji.danmaku.token', _danmakuToken.text.trim());
    if (feedback && mounted) setState(() => _savedMessage = '已保存');
  }

  void _applyAppearance() {
    yingjiAppearance.apply(
      themeMode: switch (_appearanceTheme) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      },
      iconStyle: _appearanceIcon,
      fontStyle: _appearanceFont,
      glassOpacity: _appearanceGlassOpacity,
      glassBlur: _appearanceGlassBlur,
      cardDepth: _appearanceCardDepth,
    );
  }

  Future<void> _testDanmaku([String? target]) async {
    if (_danmakuTesting) return;
    final endpoint =
        target ??
        _danmakuApiControllers
            .map((controller) => controller.text.trim())
            .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    if (endpoint.isEmpty) {
      setState(() => _danmakuMessage = '请先填写弹幕 API 地址');
      return;
    }
    setState(() {
      _danmakuTesting = true;
      _danmakuMessage = null;
    });
    final client = DanmakuClient();
    try {
      final comments = await client.fetch(
        template: endpoint,
        tmdbId: '550',
        title: '生万物',
        season: 1,
        episode: 1,
        mediaUrl: 'https://example.com/test.mp4',
        token: _danmakuToken.text,
      );
      if (mounted) {
        setState(() => _danmakuMessage = '连接正常 · 已读取 ${comments.length} 条弹幕');
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _danmakuMessage = error.toString().replaceFirst(
            'Exception: ',
            '',
          ),
        );
      }
    } finally {
      client.dispose();
      if (mounted) setState(() => _danmakuTesting = false);
    }
  }

  Future<void> _clearTmdbCache() async {
    final client = TmdbClient();
    final count = await client.clearCache();
    client.dispose();
    if (mounted) {
      setState(
        () => _savedMessage = count == 0
            ? '没有可清理的 TMDB 缓存'
            : '已清理 $count 项 TMDB 缓存',
      );
      unawaited(_refreshCacheStats());
    }
  }

  Future<void> _refreshCacheStats() async {
    final prefs = await SharedPreferences.getInstance();
    final metadata = prefs
        .getKeys()
        .where((key) => key.startsWith('yingji.tmdb.cache.'))
        .length;
    var bytes = 0;
    try {
      final root = await getTemporaryDirectory();
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) bytes += await entity.length();
      }
    } catch (_) {}
    if (mounted)
      setState(() {
        _metadataCacheCount = metadata;
        _imageCacheBytes = bytes;
      });
  }

  Future<void> _clearImageCache() async {
    await DefaultCacheManager().emptyCache();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await _refreshCacheStats();
    if (mounted) setState(() => _savedMessage = '海报、剧照与图标图片缓存已清理');
  }

  String get _imageCacheLabel {
    final mb = _imageCacheBytes / 1024 / 1024;
    return mb < 1
        ? '${(_imageCacheBytes / 1024).round()} KB'
        : '${mb.toStringAsFixed(1)} MB';
  }

  Future<void> _clearWatchHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空观看记录？'),
        content: const Text('这会移除本机保存的继续观看进度，不会删除媒体服务器上的数据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final store = await WatchStateStore.create();
    await store.clear();
    if (mounted) setState(() => _savedMessage = '观看记录已清空');
  }

  Future<void> _authorizeTrakt() async {
    if (_traktAuthorizing) return;
    final clientId = _traktClientId.text.trim();
    final clientSecret = _traktClientSecret.text.trim();
    if (clientId.isEmpty || clientSecret.isEmpty) {
      setState(() => _traktMessage = '请先填写 Trakt Client ID 和 Client Secret');
      return;
    }
    setState(() {
      _traktAuthorizing = true;
      _traktMessage = '正在获取设备授权码…';
    });
    final client = TraktClient();
    try {
      final device = await client.requestDeviceCode(clientId);
      await Process.run('cmd', ['/c', 'start', '', device.verificationUrl]);
      if (mounted) {
        setState(() => _traktMessage = '浏览器已打开，请输入代码 ${device.userCode} 完成授权');
      }
      final token = await client.pollDeviceCode(
        clientId: clientId,
        clientSecret: clientSecret,
        device: device,
      );
      _traktToken.text = token;
      await _save();
      if (mounted) setState(() => _traktMessage = 'Trakt 已授权');
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _traktMessage = error.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      client.dispose();
      if (mounted) setState(() => _traktAuthorizing = false);
    }
  }

  Future<void> _testTmdb() async {
    if (_tmdbTesting) return;
    setState(() {
      _tmdbTesting = true;
      _tmdbMessage = null;
    });
    final client = TmdbClient();
    try {
      final items = await client.trending(apiKey: _tmdbApiKey.text.trim());
      if (mounted) {
        setState(() => _tmdbMessage = '连接正常 · 已读取 ${items.length} 项');
      }
    } catch (error) {
      if (mounted) setState(() => _tmdbMessage = _networkError(error));
    } finally {
      client.dispose();
      if (mounted) setState(() => _tmdbTesting = false);
    }
  }

  List<GlobalKey> get _settingKeys => [
    _homeKey,
    _appearanceKey,
    _playerKey,
    _behaviorKey,
    _networkKey,
    _danmakuKey,
    _systemKey,
    _maintenanceKey,
    _aboutKey,
  ];

  void _syncActiveSetting() {
    if (_jumpingToSetting || !_settingsScroll.hasClients) return;
    final position = _settingsScroll.offset + 28;
    var active = 0;
    for (var index = 0; index < _settingKeys.length; index++) {
      final target = _settingKeys[index].currentContext?.findRenderObject();
      if (target == null || !target.attached) continue;
      final offset = RenderAbstractViewport.of(target)
          .getOffsetToReveal(target, 0)
          .offset;
      if (offset <= position) active = index;
    }
    if (active != _activeSetting.value) _activeSetting.value = active;
  }

  Future<void> _jumpToSetting(int index, GlobalKey key) async {
    final target = key.currentContext?.findRenderObject();
    if (target == null || !target.attached || !_settingsScroll.hasClients) {
      return;
    }
    final generation = ++_settingJumpGeneration;
    _activeSetting.value = index;
    _jumpingToSetting = true;
    final offset = RenderAbstractViewport.of(target)
        .getOffsetToReveal(target, 0)
        .offset
        .clamp(
          _settingsScroll.position.minScrollExtent,
          _settingsScroll.position.maxScrollExtent,
        );
    try {
      await _settingsScroll.animateTo(
        offset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    } finally {
      if (generation == _settingJumpGeneration) {
        _jumpingToSetting = false;
        _syncActiveSetting();
      }
    }
  }

  @override
  void dispose() {
    _settingsScroll.dispose();
    _activeSetting.dispose();
    _tmdbApiKey.dispose();
    _traktClientId.dispose();
    _traktClientSecret.dispose();
    _traktToken.dispose();
    _danmakuUrl.dispose();
    for (final controller in _danmakuApiNameControllers) {
      controller.dispose();
    }
    for (final controller in _danmakuApiControllers) {
      controller.dispose();
    }
    _danmakuToken.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const labels = <(String, IconData)>[
      ('首页', YingjiIcons.house),
      ('外观', YingjiIcons.paintbrush),
      ('播放器', YingjiIcons.play),
      ('播放行为', YingjiIcons.gauge),
      ('网络与同步', YingjiIcons.wifi),
      ('字幕与弹幕', YingjiIcons.captions_bubble),
      ('快捷键与系统', YingjiIcons.gear_alt),
      ('缓存与数据', YingjiIcons.archivebox),
      ('关于 Mova', YingjiIcons.info_circle),
    ];
    final keys = <GlobalKey>[
      _homeKey,
      _appearanceKey,
      _playerKey,
      _behaviorKey,
      _networkKey,
      _danmakuKey,
      _systemKey,
      _maintenanceKey,
      _aboutKey,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 4, 44, 30),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: YingjiGlass.blur + 4,
            sigmaY: YingjiGlass.blur + 4,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: YingjiGlass.surface(strength: 1.08),
              border: Border.all(color: YingjiGlass.line()),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 220,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 40, 18, 24),
                    child: ValueListenableBuilder<int>(
                      valueListenable: _activeSetting,
                      builder: (context, active, _) => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < labels.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: TextButton(
                                onPressed: () => _jumpToSetting(i, keys[i]),
                                style: TextButton.styleFrom(
                                  alignment: Alignment.centerLeft,
                                  foregroundColor: active == i
                                      ? const Color(0xFF111216)
                                      : const Color(0xFFB8BDC8),
                                  backgroundColor: active == i
                                      ? const Color(0xFFF1F1F2)
                                      : Colors.transparent,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(labels[i].$2, size: 18),
                                    const SizedBox(width: 11),
                                    Text(labels[i].$1),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const VerticalDivider(width: 1, color: Color(0x22FFFFFF)),
                Expanded(
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context)
                        .copyWith(scrollbars: false),
                    child: SingleChildScrollView(
                      controller: _settingsScroll,
                      padding: const EdgeInsets.fromLTRB(40, 40, 46, 60),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            '设置',
                            style: TextStyle(
                              fontSize: 48,
                              height: 1,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -1.2,
                            ),
                          ),
                          const SizedBox(height: 28),
                          _FrostSurface(
                            key: _homeKey,
                            borderRadius: 22,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '首页',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '控制首页海报轮播、浮动导航和继续观看内容。保存后返回首页即可生效。',
                                  style: TextStyle(color: Color(0xFFABB1BE)),
                                ),
                                _ToggleRow(
                                  title: '显示继续观看',
                                  detail: '在首页海报下方显示本机播放进度',
                                  value: _homeContinueWatching,
                                  onChanged: (value) {
                                    setState(
                                      () => _homeContinueWatching = value,
                                    );
                                    _save();
                                  },
                                ),
                                _ToggleRow(
                                  title: '显示首页图标',
                                  detail: '在左侧浮动导航中保留首页按钮',
                                  value: _homeShowIcon,
                                  onChanged: (value) {
                                    setState(() => _homeShowIcon = value);
                                    _save();
                                  },
                                ),
                                _ToggleRow(
                                  title: '自动轮播海报',
                                  detail: '关闭后保留当前海报，可用轮播点手动切换',
                                  value: _homeAutoCarousel,
                                  onChanged: (value) {
                                    setState(() => _homeAutoCarousel = value);
                                    _save();
                                  },
                                ),
                                _ToggleRow(
                                  title: '显示轮播点',
                                  detail: '在海报右下方显示当前轮播进度',
                                  value: _homeShowCarouselDots,
                                  onChanged: (value) {
                                    setState(
                                      () => _homeShowCarouselDots = value,
                                    );
                                    _save();
                                  },
                                ),
                                const SizedBox(height: 8),
                                YingjiGlassChoiceField<String>(
                                  label: '首页轮播来源',
                                  helper: '决定海报轮播使用哪组真实 TMDB 数据',
                                  value: _homeCarouselSource,
                                  items: const [
                                    'trending',
                                    'popular-movies',
                                    'popular-shows',
                                    'top-rated',
                                  ],
                                  labelBuilder: (value) => switch (value) {
                                    'trending' => 'TMDB · 本周趋势',
                                    'popular-movies' => 'TMDB · 热门电影',
                                    'popular-shows' => 'TMDB · 热门剧集',
                                    _ => 'TMDB · 高分电影',
                                  },
                                  onChanged: (value) {
                                    setState(() => _homeCarouselSource = value);
                                    _save();
                                  },
                                ),
                                const SizedBox(height: 12),
                                YingjiGlassDropdownField<String>(
                                  initialValue: _homeCarouselEffect,
                                  decoration: const InputDecoration(
                                    labelText: '海报轮播效果',
                                    helperText: '切换海报时使用的过渡动画',
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'blur-dissolve',
                                      child: Text('模糊溶解（推荐）'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'slide-fade',
                                      child: Text('上浮渐变'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'fade',
                                      child: Text('淡入式'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'zoom-fade',
                                      child: Text('缩放淡入'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'slide-horizontal',
                                      child: Text('横向滑入'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'instant',
                                      child: Text('即时切换'),
                                    ),
                                  ],
                                  onChanged: (value) {
                                    if (value == null) return;
                                    setState(() => _homeCarouselEffect = value);
                                    _save();
                                  },
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  '海报停留时间  ${_homeCarouselSeconds.round()} 秒',
                                ),
                                Slider(
                                  value: _homeCarouselSeconds,
                                  min: 3,
                                  max: 15,
                                  divisions: 12,
                                  label: '${_homeCarouselSeconds.round()} 秒',
                                  onChanged: (value) => setState(
                                    () => _homeCarouselSeconds = value,
                                  ),
                                  onChangeEnd: (_) => _save(),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          _FrostSurface(
                            key: _appearanceKey,
                            borderRadius: 22,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '外观',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '调整整体明暗、圆润图标与全局玻璃材质；改动会即时应用到每个悬浮卡片。',
                                  style: TextStyle(color: Color(0xFFABB1BE)),
                                ),
                                const SizedBox(height: 8),
                                YingjiGlassDropdownField<String>(
                                  initialValue: _appearanceTheme,
                                  decoration: const InputDecoration(
                                    labelText: '颜色模式',
                                    helperText: '系统模式会跟随 Windows 的浅色/深色设置',
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'dark',
                                      child: Text('深色模式'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'light',
                                      child: Text('浅色模式'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'system',
                                      child: Text('跟随系统'),
                                    ),
                                  ],
                                  onChanged: (value) {
                                    if (value == null) return;
                                    setState(() => _appearanceTheme = value);
                                    _applyAppearance();
                                    _save();
                                  },
                                ),
                                const SizedBox(height: 14),
                                YingjiGlassDropdownField<String>(
                                  initialValue: _appearanceFont,
                                  decoration: const InputDecoration(
                                    labelText: '全局字体',
                                    helperText: '字体会即时应用到标题、正文、榜单与播放器控件',
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'round',
                                      child: Text('Mova 圆润无衬线（内置）'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'wenkai',
                                      child: Text('Mova 温润文楷（内置）'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'dengxian',
                                      child: Text('方圆 UI · 等线（Windows）'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'yahei',
                                      child: Text('微软雅黑 UI（Windows）'),
                                    ),
                                  ],
                                  onChanged: (value) {
                                    if (value == null) return;
                                    setState(() => _appearanceFont = value);
                                    _applyAppearance();
                                    _save();
                                  },
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  '玻璃不透明度  ${(_appearanceGlassOpacity * 100).round()}%',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                const Text(
                                  '左端完全透明，右端完全玻璃化；所有图标与卡片同步使用。',
                                  style: TextStyle(color: Color(0xFFABB1BE)),
                                ),
                                Slider(
                                  value: _appearanceGlassOpacity,
                                  min: 0,
                                  max: 1,
                                  divisions: 20,
                                  label:
                                      '${(_appearanceGlassOpacity * 100).round()}%',
                                  onChanged: (value) {
                                    setState(
                                      () => _appearanceGlassOpacity = value,
                                    );
                                    _applyAppearance();
                                  },
                                  onChangeEnd: (_) => _save(),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '背景模糊  ${_appearanceGlassBlur.round()} px',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                const Text(
                                  '左端完全无模糊，右端为完整毛玻璃；可单独与透明度组合。',
                                  style: TextStyle(color: Color(0xFFABB1BE)),
                                ),
                                Slider(
                                  value: _appearanceGlassBlur,
                                  min: 0,
                                  max: 40,
                                  divisions: 15,
                                  label: '${_appearanceGlassBlur.round()} px',
                                  onChanged: (value) {
                                    setState(
                                      () => _appearanceGlassBlur = value,
                                    );
                                    _applyAppearance();
                                  },
                                  onChangeEnd: (_) => _save(),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '背景卡片颜色  ${(_appearanceCardDepth * 100).round()}%',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                const Text(
                                  '左端更明亮通透，右端更深邃；不会改变海报背景本身。',
                                  style: TextStyle(color: Color(0xFFABB1BE)),
                                ),
                                Slider(
                                  value: _appearanceCardDepth,
                                  min: 0,
                                  max: 1,
                                  divisions: 20,
                                  label:
                                      '${(_appearanceCardDepth * 100).round()}%',
                                  onChanged: (value) {
                                    setState(
                                      () => _appearanceCardDepth = value,
                                    );
                                    _applyAppearance();
                                  },
                                  onChangeEnd: (_) => _save(),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          _FrostSurface(
                            key: _playerKey,
                            borderRadius: 22,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '播放器',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '内置 libmpv；这些偏好会在播放时下发给内核。',
                                  style: TextStyle(color: Color(0xFFABB1BE)),
                                ),
                                _ToggleRow(
                                  title: '硬件解码',
                                  detail: '优先 D3D11VA',
                                  value: _hardware,
                                  onChanged: (v) {
                                    setState(() => _hardware = v);
                                    _save();
                                  },
                                ),
                                _ToggleRow(
                                  title: 'HDR 输出',
                                  detail: '匹配 Windows HDR 状态',
                                  value: _hdr,
                                  onChanged: (v) {
                                    setState(() => _hdr = v);
                                    _save();
                                  },
                                ),
                                _ToggleRow(
                                  title: '立体声下混',
                                  detail: '多声道输出转换为立体声',
                                  value: _downmix,
                                  onChanged: (v) {
                                    setState(() => _downmix = v);
                                    _save();
                                  },
                                ),
                                _ToggleRow(
                                  title: '夜间模式',
                                  detail: '压缩动态范围',
                                  value: _night,
                                  onChanged: (v) {
                                    setState(() => _night = v);
                                    _save();
                                  },
                                ),
                                _ToggleRow(
                                  title: '人声增强',
                                  detail: '提升对白清晰度',
                                  value: _voiceEnhance,
                                  onChanged: (v) {
                                    setState(() => _voiceEnhance = v);
                                    _save();
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          _FrostSurface(
                            key: _behaviorKey,
                            borderRadius: 22,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '播放行为与默认值',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '这些值会作为每次打开播放器时的初始状态，也可在播放控制台临时调整。',
                                  style: TextStyle(color: Color(0xFFABB1BE)),
                                ),
                                _ToggleRow(
                                  title: '继续播放提示',
                                  detail: '打开已观看媒体时显示上次进度',
                                  value: _resumePrompt,
                                  onChanged: (v) {
                                    setState(() => _resumePrompt = v);
                                    _save();
                                  },
                                ),
                                const SizedBox(height: 6),
                                YingjiGlassDropdownField<String>(
                                  initialValue: _aspect,
                                  decoration: const InputDecoration(
                                    labelText: '默认画面比例',
                                  ),
                                  items: const ['自动', '16:9', '4:3', '21:9']
                                      .map(
                                        (value) => DropdownMenuItem(
                                          value: value,
                                          child: Text(value),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (value) {
                                    if (value == null) return;
                                    setState(() => _aspect = value);
                                    _save();
                                  },
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  '默认播放速度  ${_defaultSpeed.toStringAsFixed(2)}x',
                                ),
                                Slider(
                                  value: _defaultSpeed,
                                  min: .5,
                                  max: 2,
                                  divisions: 30,
                                  label: '${_defaultSpeed.toStringAsFixed(2)}x',
                                  onChanged: (value) =>
                                      setState(() => _defaultSpeed = value),
                                  onChangeEnd: (_) => _save(),
                                ),
                                Text('预读缓存  ${_cacheSeconds.round()} 秒'),
                                Slider(
                                  value: _cacheSeconds,
                                  min: 5,
                                  max: 120,
                                  divisions: 23,
                                  label: '${_cacheSeconds.round()} 秒',
                                  onChanged: (value) =>
                                      setState(() => _cacheSeconds = value),
                                  onChangeEnd: (_) => _save(),
                                ),
                                _ToggleRow(
                                  title: '预加载下一集',
                                  detail: '播放接近片尾时预热下一集，减少连续播放等待',
                                  value: _preloadNextEpisode,
                                  onChanged: (value) {
                                    setState(() => _preloadNextEpisode = value);
                                    _save();
                                  },
                                ),
                                if (_preloadNextEpisode) ...[
                                  Text(
                                    '距本集结束 ${_preloadLeadMinutes.round()} 分钟开始预加载',
                                  ),
                                  Slider(
                                    value: _preloadLeadMinutes,
                                    min: 1,
                                    max: 15,
                                    divisions: 14,
                                    label: '${_preloadLeadMinutes.round()} 分钟',
                                    onChanged: (value) => setState(
                                      () => _preloadLeadMinutes = value,
                                    ),
                                    onChangeEnd: (_) => _save(),
                                  ),
                                ],
                                Text('快进 / 快退  ${_seekSeconds.round()} 秒'),
                                const Text(
                                  '播放器左右方向键每次跳转的时间；长片可调大，短片建议保持 10 秒。',
                                  style: TextStyle(
                                    color: Color(0xFFABB1BE),
                                    fontSize: 12,
                                  ),
                                ),
                                Slider(
                                  value: _seekSeconds,
                                  min: 5,
                                  max: 60,
                                  divisions: 11,
                                  label: '${_seekSeconds.round()} 秒',
                                  onChanged: (value) =>
                                      setState(() => _seekSeconds = value),
                                  onChangeEnd: (_) => _save(),
                                ),
                                Text('音量按键步长  ${_volumeStep.round()}%'),
                                Slider(
                                  value: _volumeStep,
                                  min: 1,
                                  max: 20,
                                  divisions: 19,
                                  label: '${_volumeStep.round()}%',
                                  onChanged: (value) =>
                                      setState(() => _volumeStep = value),
                                  onChangeEnd: (_) => _save(),
                                ),
                                Text(
                                  '默认音频延迟  ${(_audioDelay * 1000).round()} ms',
                                ),
                                Slider(
                                  value: _audioDelay,
                                  min: -3,
                                  max: 3,
                                  divisions: 120,
                                  label: '${(_audioDelay * 1000).round()} ms',
                                  onChanged: (value) =>
                                      setState(() => _audioDelay = value),
                                  onChangeEnd: (_) => _save(),
                                ),
                                Text(
                                  '默认字幕延迟  ${(_subtitleDelay * 1000).round()} ms',
                                ),
                                Slider(
                                  value: _subtitleDelay,
                                  min: -3,
                                  max: 3,
                                  divisions: 120,
                                  label:
                                      '${(_subtitleDelay * 1000).round()} ms',
                                  onChanged: (value) =>
                                      setState(() => _subtitleDelay = value),
                                  onChangeEnd: (_) => _save(),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          _FrostSurface(
                            key: _networkKey,
                            borderRadius: 22,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '网络与同步',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'TMDB 默认通过 Mova 托管网关获取；也可以填写自己的 API Key。填写 Trakt 凭据后，追剧页会读取未来两周的播出安排。',
                                  style: TextStyle(color: Color(0xFFABB1BE)),
                                ),
                                const SizedBox(height: 14),
                                TextField(
                                  controller: _tmdbApiKey,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    labelText: 'TMDB API Key（可选）',
                                    hintText: '留空使用 Mova 托管网关',
                                  ),
                                ),
                                const SizedBox(height: 14),
                                Row(
                                  children: [
                                    FilledButton.tonalIcon(
                                      onPressed: _tmdbTesting
                                          ? null
                                          : _testTmdb,
                                      icon: _tmdbTesting
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Icon(
                                              YingjiIcons.wifi,
                                              size: 16,
                                            ),
                                      label: const Text('测试 TMDB 网络'),
                                    ),
                                    if (_tmdbMessage != null) ...[
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(
                                          _tmdbMessage!,
                                          style: const TextStyle(
                                            color: Color(0xFFABB1BE),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 14),
                                TextField(
                                  controller: _traktClientId,
                                  decoration: const InputDecoration(
                                    labelText: 'Trakt Client ID',
                                  ),
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: _traktToken,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Trakt Access Token',
                                  ),
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: _traktClientSecret,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Trakt Client Secret（设备授权需要）',
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    FilledButton.tonal(
                                      onPressed: _traktAuthorizing
                                          ? null
                                          : _authorizeTrakt,
                                      child: Text(
                                        _traktAuthorizing
                                            ? '等待授权…'
                                            : '浏览器授权 Trakt',
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    FilledButton(
                                      onPressed: _save,
                                      child: Text(_savedMessage ?? '保存设置'),
                                    ),
                                  ],
                                ),
                                if (_traktMessage != null) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    _traktMessage!,
                                    style: const TextStyle(
                                      color: Color(0xFFABB1BE),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          _FrostSurface(
                            key: _danmakuKey,
                            borderRadius: 22,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '音轨、字幕与片头片尾',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '按语言智能选择音轨和字幕，并统一管理自动跳过的数据来源。',
                                  style: TextStyle(color: Color(0xFFABB1BE)),
                                ),
                                _ToggleRow(
                                  title: '启用首选音轨',
                                  detail: '存在匹配语言时自动选择；手动选择仍然优先',
                                  value: _preferAudioTrack,
                                  onChanged: (value) {
                                    setState(() => _preferAudioTrack = value);
                                    _save();
                                  },
                                ),
                                YingjiGlassChoiceField<String>(
                                  label: '首选音轨语言',
                                  value: _audioLanguage,
                                  items: audioLanguages.keys.toList(),
                                  labelBuilder: (v) => audioLanguages[v] ?? v,
                                  onChanged: (v) {
                                    setState(() => _audioLanguage = v);
                                    _save();
                                  },
                                ),
                                const SizedBox(height: 16),
                                SwitchListTile.adaptive(
                                  contentPadding: EdgeInsets.zero,
                                  secondary: const Icon(
                                    YingjiIcons.captions_bubble,
                                  ),
                                  title: const Text('启用字幕语言优先'),
                                  subtitle: const Text(
                                    '按所选语言识别字幕；没有匹配时保留媒体默认，手动选择优先。',
                                  ),
                                  value: _preferChineseSubtitle,
                                  onChanged: (value) {
                                    setState(
                                      () => _preferChineseSubtitle = value,
                                    );
                                    _save();
                                  },
                                ),
                                const SizedBox(height: 24),
                                YingjiGlassChoiceField<String>(
                                  label: '首选字幕语言',
                                  value: _subtitleLanguage,
                                  items: subtitleLanguages.keys.toList(),
                                  labelBuilder: (v) =>
                                      subtitleLanguages[v] ?? v,
                                  onChanged: (v) {
                                    setState(() => _subtitleLanguage = v);
                                    _save();
                                  },
                                ),
                                const SizedBox(height: 24),
                                const Divider(color: Color(0x22FFFFFF)),
                                const SizedBox(height: 12),
                                const Text(
                                  '自动跳过',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                _ToggleRow(
                                  title: '自动跳过片头片尾',
                                  detail: '播放器仍会先显示跳转提示，可手动取消',
                                  value: _autoSkipSegments,
                                  onChanged: (value) {
                                    setState(() => _autoSkipSegments = value);
                                    _save();
                                  },
                                ),
                                if (_autoSkipSegments) ...[
                                  Text(
                                    '跳转提示停留  ${_autoSkipDelaySeconds.round()} 秒',
                                  ),
                                  Slider(
                                    value: _autoSkipDelaySeconds,
                                    min: 1,
                                    max: 10,
                                    divisions: 9,
                                    label: '${_autoSkipDelaySeconds.round()} 秒',
                                    onChanged: (value) => setState(
                                      () => _autoSkipDelaySeconds = value,
                                    ),
                                    onChangeEnd: (_) => _save(),
                                  ),
                                ],
                                _ToggleRow(
                                  title: '服务器章节',
                                  detail: '从 Emby / Jellyfin 媒体章节读取片头片尾',
                                  value: _segmentServerSource,
                                  onChanged: (value) {
                                    setState(
                                      () => _segmentServerSource = value,
                                    );
                                    _save();
                                  },
                                ),
                                _ToggleRow(
                                  title: 'TheIntroDB',
                                  detail: '按 TMDB、季和集匹配公共片头片尾数据',
                                  value: _segmentIntroDbSource,
                                  onChanged: (value) {
                                    setState(
                                      () => _segmentIntroDbSource = value,
                                    );
                                    _save();
                                  },
                                ),
                                const SizedBox(height: 16),
                                const Divider(color: Color(0x22FFFFFF)),
                                const SizedBox(height: 16),
                                const Text(
                                  '弹幕服务',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '播放时并行请求下方 API，自动使用最先返回有效结果的线路。',
                                  style: TextStyle(color: Color(0xFFABB1BE)),
                                ),
                                _ToggleRow(
                                  title: '启用弹幕',
                                  detail: _danmakuEnabled
                                      ? '播放时读取下方 API'
                                      : '当前关闭',
                                  value: _danmakuEnabled,
                                  onChanged: (value) {
                                    setState(() => _danmakuEnabled = value);
                                    _save();
                                  },
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '弹幕 API',
                                  style: TextStyle(fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: 4),
                                const Text(
                                  '每个地址独立保存。播放时并行测速，使用最先返回实际弹幕的服务。',
                                  style: TextStyle(
                                    color: Color(0xFFABB1BE),
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                for (
                                  var index = 0;
                                  index < _danmakuApiControllers.length;
                                  index++
                                ) ...[
                                  Row(
                                    children: [
                                      SizedBox(
                                        width: 118,
                                        child: TextField(
                                          controller:
                                              _danmakuApiNameControllers[index],
                                          decoration: InputDecoration(
                                            labelText: '名称',
                                            hintText: '弹幕 ${index + 1}',
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: TextField(
                                          controller:
                                              _danmakuApiControllers[index],
                                          keyboardType: TextInputType.url,
                                          decoration: InputDecoration(
                                            labelText: 'API ${index + 1}',
                                            hintText: 'https://example.com/api',
                                            prefixIcon: const Icon(
                                              YingjiIcons.link,
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      YingjiMotionIconButton(
                                        icon: YingjiIcons.checkmark_seal,
                                        tooltip:
                                            '测试 ${_danmakuApiNameControllers[index].text.trim().isEmpty ? '弹幕 API ${index + 1}' : _danmakuApiNameControllers[index].text.trim()}',
                                        size: 38,
                                        onPressed: _danmakuTesting
                                            ? () {}
                                            : () {
                                                unawaited(
                                                  _testDanmaku(
                                                    _danmakuApiControllers[index]
                                                        .text
                                                        .trim(),
                                                  ),
                                                );
                                              },
                                      ),
                                      if (_danmakuApiControllers.length >
                                          1) ...[
                                        const SizedBox(width: 8),
                                        YingjiMotionIconButton(
                                          icon: YingjiIcons.trash,
                                          tooltip: '移除 API ${index + 1}',
                                          size: 38,
                                          onPressed: () => setState(() {
                                            _danmakuApiControllers
                                                .removeAt(index)
                                                .dispose();
                                            _danmakuApiNameControllers
                                                .removeAt(index)
                                                .dispose();
                                          }),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                ],
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: YingjiMotionIconButton(
                                    icon: YingjiIcons.plus,
                                    tooltip: '添加弹幕 API',
                                    size: 38,
                                    onPressed: () => setState(() {
                                      _danmakuApiControllers.add(
                                        TextEditingController(),
                                      );
                                      _danmakuApiNameControllers.add(
                                        TextEditingController(
                                          text:
                                              '弹幕 ${_danmakuApiControllers.length}',
                                        ),
                                      );
                                    }),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: _danmakuToken,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    labelText: 'API Token（可选）',
                                    hintText: '以 Bearer Token 方式发送',
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    FilledButton.tonalIcon(
                                      onPressed: _danmakuTesting
                                          ? null
                                          : _testDanmaku,
                                      icon: _danmakuTesting
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Icon(
                                              YingjiIcons.checkmark_seal,
                                              size: 16,
                                            ),
                                      label: const Text('测试弹幕 API'),
                                    ),
                                    if (_danmakuMessage != null) ...[
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(
                                          _danmakuMessage!,
                                          style: const TextStyle(
                                            color: Color(0xFFABB1BE),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          _FrostSurface(
                            key: _systemKey,
                            borderRadius: 22,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '快捷键与系统',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '播放器快捷键会立即保存；同一个按键不能绑定两个操作。',
                                  style: TextStyle(color: Color(0xFFABB1BE)),
                                ),
                                _ToggleRow(
                                  title: '关闭窗口时最小化到托盘',
                                  detail: '从托盘菜单可重新显示 Mova；选择“退出”才结束进程',
                                  value: _closeToTray,
                                  onChanged: (value) {
                                    setState(() => _closeToTray = value);
                                    _save();
                                  },
                                ),
                                const SizedBox(height: 10),
                                for (final entry in _shortcutNames.entries) ...[
                                  _ShortcutRecorder(
                                    label: entry.value,
                                    value: _shortcuts[entry.key]!,
                                    onChanged: (value) =>
                                        _changeShortcut(entry.key, value),
                                  ),
                                  const SizedBox(height: 10),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          _FrostSurface(
                            key: _maintenanceKey,
                            borderRadius: 22,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '缓存与数据',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '分别管理元数据、海报剧照与观看记录；清理不会修改服务器媒体。',
                                  style: TextStyle(color: Color(0xFFABB1BE)),
                                ),
                                const SizedBox(height: 14),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 8,
                                  children: [
                                    _CacheStat(
                                      label: '元数据',
                                      value: '$_metadataCacheCount 项',
                                    ),
                                    _CacheStat(
                                      label: '照片与其他临时缓存',
                                      value: _imageCacheLabel,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 14),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: [
                                    FilledButton.tonalIcon(
                                      onPressed: _clearTmdbCache,
                                      icon: const Icon(
                                        YingjiIcons.trash,
                                        size: 16,
                                      ),
                                      label: const Text('清理 TMDB 缓存'),
                                    ),
                                    FilledButton.tonalIcon(
                                      onPressed: _clearImageCache,
                                      icon: const Icon(
                                        YingjiIcons.film,
                                        size: 16,
                                      ),
                                      label: const Text('清理照片缓存'),
                                    ),
                                    FilledButton.tonalIcon(
                                      onPressed: _clearWatchHistory,
                                      icon: const Icon(
                                        YingjiIcons.clock,
                                        size: 16,
                                      ),
                                      label: const Text('清空观看记录'),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  _savedMessage ?? '本机缓存与观看记录',
                                  style: const TextStyle(
                                    color: Color(0xFFABB1BE),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          _FrostSurface(
                            key: _aboutKey,
                            borderRadius: 22,
                            child: Row(
                              children: [
                                const YingjiMark(size: 72),
                                const SizedBox(width: 22),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Mova',
                                        style: TextStyle(
                                          fontSize: 30,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      const Text(
                                        '私人媒体中心',
                                        style: TextStyle(
                                          color: YingjiColors.muted,
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      const Text(
                                        '版本 3.1.65 · Windows · Flutter + libmpv',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: YingjiColors.muted,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      const Text('连接你的媒体，延续每一次观看。'),
                                    ],
                                  ),
                                ),
                                YingjiMotionIconButton(
                                  icon: YingjiIcons.info_circle,
                                  tooltip: '关于与许可',
                                  onPressed: () => showAboutDialog(
                                    context: context,
                                    applicationName: 'Mova',
                                    applicationIcon: const YingjiMark(size: 56),
                                    applicationVersion: '3.1.65',
                                    applicationLegalese: '私人媒体中心 · 内置 libmpv',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PosterStrip extends StatefulWidget {
  const _PosterStrip({required this.items, this.shelf});
  final List<TmdbItem> items;
  final _ShelfNavigator? shelf;

  @override
  State<_PosterStrip> createState() => _PosterStripState();
}

class _PosterStripState extends State<_PosterStrip> {
  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.shelf?.attach(_controller);
  }

  @override
  void dispose() {
    widget.shelf?.detach(_controller);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 296,
    child: ListView.separated(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      itemCount: widget.items.length,
      separatorBuilder: (_, _) => const SizedBox(width: 14),
      itemBuilder: (_, i) => _PosterTile(item: widget.items[i]),
    ),
  );
}

class _LandscapeStrip extends StatefulWidget {
  const _LandscapeStrip({required this.items, this.shelf});
  final List<TmdbItem> items;
  final _ShelfNavigator? shelf;

  @override
  State<_LandscapeStrip> createState() => _LandscapeStripState();
}

class _LandscapeStripState extends State<_LandscapeStrip> {
  final _controller = ScrollController();
  @override
  void initState() {
    super.initState();
    widget.shelf?.attach(_controller);
  }

  @override
  void dispose() {
    widget.shelf?.detach(_controller);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 184,
    child: ListView.separated(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      itemCount: widget.items.length,
      separatorBuilder: (_, _) => const SizedBox(width: 14),
      itemBuilder: (_, i) => _LandscapeTile(item: widget.items[i]),
    ),
  );
}

class _PlatformEntryStrip extends StatefulWidget {
  const _PlatformEntryStrip({
    required this.items,
    required this.source,
    required this.shelf,
    required this.loadSourcePage,
    required this.onConfigure,
  });

  final List<TmdbItem> items;
  final String source;
  final _ShelfNavigator shelf;
  final Future<List<TmdbItem>> Function(String source, int page) loadSourcePage;
  final VoidCallback onConfigure;

  @override
  State<_PlatformEntryStrip> createState() => _PlatformEntryStripState();
}

class _PlatformEntryStripState extends State<_PlatformEntryStrip> {
  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.shelf.attach(_controller);
  }

  @override
  void dispose() {
    widget.shelf.detach(_controller);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selection = _DiscoverFeedSelection.tryParse(widget.source);
    final platforms = selection?.platforms ?? const [];
    if (selection == null || platforms.isEmpty) {
      return _PlatformEntryCard(
        items: widget.items,
        source: widget.source,
        onConfigure: widget.onConfigure,
        onOpen: widget.onConfigure,
      );
    }
    return SizedBox(
      height: 258,
      child: ListView.separated(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        physics: const BouncingScrollPhysics(),
        itemCount: platforms.length,
        separatorBuilder: (_, _) => const SizedBox(width: 16),
        itemBuilder: (context, index) {
          final platformSource = selection
              .withPlatform(platforms[index])
              .encoded;
          return FutureBuilder<List<TmdbItem>>(
            future: widget.loadSourcePage(platformSource, 1),
            builder: (context, snapshot) {
              final items = snapshot.data ?? const <TmdbItem>[];
              return _PlatformEntryCard(
                items: items,
                source: platformSource,
                onConfigure: widget.onConfigure,
                onOpen: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => _DiscoverListPage(
                      title:
                          _resolvedPlatformLabels[platforms[index]] ?? '平台内容',
                      items: items,
                      source: platformSource,
                      loadSourcePage: widget.loadSourcePage,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _PlatformEntryCard extends StatefulWidget {
  const _PlatformEntryCard({
    required this.items,
    required this.source,
    required this.onConfigure,
    required this.onOpen,
    this.compact = false,
  });

  final List<TmdbItem> items;
  final String source;
  final VoidCallback onConfigure;
  final VoidCallback onOpen;
  final bool compact;

  @override
  State<_PlatformEntryCard> createState() => _PlatformEntryCardState();
}

class _PlatformEntryCardState extends State<_PlatformEntryCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selection = _DiscoverFeedSelection.tryParse(widget.source);
    final platformId = selection?.platform ?? 'all';
    final hasPlatform = platformId != 'all';
    final platformName =
        _resolvedPlatformLabels[platformId] ??
        (hasPlatform ? '平台 $platformId' : '选择播放平台');
    final platformLogo = _resolvedPlatformLogos[platformId];
    final artwork = widget.items
        .map((item) => item.backdropUrl)
        .whereType<Uri>()
        .take(3)
        .toList(growable: false);
    return SizedBox(
      height: widget.compact ? 132 : 258,
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: widget.compact ? 520 : 570,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: hasPlatform ? widget.onOpen : widget.onConfigure,
            child: MouseRegion(
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _hovered
                        ? Colors.white.withValues(alpha: .82)
                        : Colors.white.withValues(alpha: .11),
                    width: _hovered ? 2.2 : 1,
                  ),
                  boxShadow: _hovered
                      ? const [
                          BoxShadow(
                            color: Color(0xA0000000),
                            blurRadius: 28,
                            offset: Offset(0, 14),
                          ),
                        ]
                      : const [],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: LayoutBuilder(
                    builder: (context, constraints) => Stack(
                      fit: StackFit.expand,
                      children: [
                        const ColoredBox(color: Color(0xFF12151B)),
                        if (artwork.isNotEmpty)
                          _PlatformArtwork(
                            uri: artwork.first,
                            alignment: Alignment.center,
                          ),
                        if (artwork.length > 1)
                          Positioned(
                            left: constraints.maxWidth * .43,
                            top: 0,
                            bottom: 0,
                            width: constraints.maxWidth * .40,
                            child: _PlatformArtwork(
                              uri: artwork[1],
                              fadeEdges: true,
                            ),
                          ),
                        if (artwork.length > 2)
                          Positioned(
                            right: 0,
                            top: 0,
                            bottom: 0,
                            width: constraints.maxWidth * .32,
                            child: _PlatformArtwork(
                              uri: artwork[2],
                              fadeEdges: true,
                            ),
                          ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: [
                                Colors.black.withValues(alpha: .88),
                                Colors.black.withValues(alpha: .42),
                                Colors.black.withValues(alpha: .08),
                                Colors.black.withValues(alpha: .28),
                              ],
                            ),
                          ),
                        ),
                        Positioned(
                          left: widget.compact ? 18 : 28,
                          bottom: widget.compact ? 18 : 27,
                          child: SizedBox(
                            width: widget.compact ? 128 : 178,
                            height: widget.compact ? 42 : 64,
                            child: platformLogo != null
                                ? _BackgroundFreeNetworkIcon(
                                    url: platformLogo.toString(),
                                    alignment: Alignment.centerLeft,
                                    fallback: _PlatformName(
                                      name: platformName,
                                      compact: widget.compact,
                                    ),
                                  )
                                : _PlatformName(
                                    name: hasPlatform ? platformName : '+',
                                    compact: widget.compact,
                                  ),
                          ),
                        ),
                        if (!widget.compact)
                          Positioned(
                            right: 18,
                            bottom: 18,
                            child: AnimatedOpacity(
                              opacity: _hovered ? 1 : 0,
                              duration: const Duration(milliseconds: 150),
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.black.withValues(alpha: .58),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: .28),
                                  ),
                                ),
                                child: const Icon(
                                  YingjiIcons.chevron_right,
                                  size: 18,
                                ),
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
        ),
      ),
    );
  }
}

class _PlatformArtwork extends StatelessWidget {
  const _PlatformArtwork({
    required this.uri,
    this.fadeEdges = false,
    this.alignment = Alignment.center,
  });

  final Uri uri;
  final bool fadeEdges;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final image = CachedNetworkImage(
      imageUrl: uri.toString(),
      fit: BoxFit.cover,
      alignment: alignment,
      errorWidget: (_, _, _) => const SizedBox.shrink(),
    );
    if (!fadeEdges) return image;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => const LinearGradient(
        colors: [Colors.transparent, Colors.white, Colors.white],
        stops: [0, .28, 1],
      ).createShader(bounds),
      child: image,
    );
  }
}

class _PlatformName extends StatelessWidget {
  const _PlatformName({required this.name, required this.compact});

  final String name;
  final bool compact;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: compact ? 22 : 30,
        fontWeight: FontWeight.w900,
        letterSpacing: -.6,
      ),
    ),
  );
}

class _RankStrip extends StatefulWidget {
  const _RankStrip({required this.items, this.shelf});
  final List<TmdbItem> items;
  final _ShelfNavigator? shelf;

  @override
  State<_RankStrip> createState() => _RankStripState();
}

class _RankStripState extends State<_RankStrip> {
  final _controller = ScrollController();
  @override
  void initState() {
    super.initState();
    widget.shelf?.attach(_controller);
  }

  @override
  void dispose() {
    widget.shelf?.detach(_controller);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 252,
    child: ListView.separated(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      itemCount: widget.items.length,
      separatorBuilder: (_, _) => const SizedBox(width: 12),
      itemBuilder: (_, i) => _RankTile(index: i + 1, item: widget.items[i]),
    ),
  );
}

class _PosterTile extends StatelessWidget {
  const _PosterTile({required this.item, this.onOpen});
  final TmdbItem item;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 168,
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap:
          onOpen ??
          () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => MetadataDetailPage(item: item)),
          ),
      child: SizedBox(
        height: 280,
        child: _MediaHover(
          borderRadius: 16,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (item.posterUrl != null)
                CachedNetworkImage(
                  imageUrl: item.posterUrl.toString(),
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) =>
                      const ColoredBox(color: Color(0xFF1A1D25)),
                )
              else
                const ColoredBox(color: Color(0xFF1A1D25)),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [.42, .72, 1],
                    colors: [
                      Colors.transparent,
                      Color(0x99101418),
                      Color(0xF20B0D11),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 13,
                right: 13,
                bottom: 13,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(
                          YingjiIcons.sparkles,
                          size: 12,
                          color: Color(0xFFFFD76A),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          item.rating.toStringAsFixed(1),
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${item.year ?? '—'} · ${item.kind}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFFCACED7),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _LandscapeTile extends StatelessWidget {
  const _LandscapeTile({required this.item});
  final TmdbItem item;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 286,
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => MetadataDetailPage(item: item)),
      ),
      child: _MediaHover(
        borderRadius: 16,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (item.backdropUrl != null)
              CachedNetworkImage(
                imageUrl: item.backdropUrl.toString(),
                fit: BoxFit.cover,
                errorWidget: (_, _, _) =>
                    const ColoredBox(color: Color(0xFF1A1D25)),
              )
            else
              const ColoredBox(color: Color(0xFF1A1D25)),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: .9),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 14,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      _DiscoveryMetaPill(
                        icon: YingjiIcons.sparkles,
                        label: item.rating.toStringAsFixed(1),
                      ),
                      const SizedBox(width: 6),
                      _DiscoveryMetaPill(
                        label: '${item.year ?? '—'} · ${item.kind}',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _DiscoveryMetaPill extends StatelessWidget {
  const _DiscoveryMetaPill({required this.label, this.icon});
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .48),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white.withValues(alpha: .16)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 11, color: const Color(0xFFFFD76A)),
          const SizedBox(width: 4),
        ],
        Text(
          label,
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );
}

class _RankTile extends StatefulWidget {
  const _RankTile({required this.index, required this.item});
  final int index;
  final TmdbItem item;

  @override
  State<_RankTile> createState() => _RankTileState();
}

class _RankTileState extends State<_RankTile>
    with SingleTickerProviderStateMixin {
  final _link = LayerLink();
  final _cardKey = GlobalKey();
  OverlayEntry? _preview;
  bool _hovered = false;
  late final AnimationController _previewController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 190),
    reverseDuration: const Duration(milliseconds: 130),
  );

  void _showPreview() {
    if (_preview != null) {
      _previewController.forward();
      return;
    }
    final overlay = Overlay.of(context);
    final box = _cardKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final showOnRight = MediaQuery.sizeOf(context).width - rect.left >= 520;
    final reveal = CurvedAnimation(
      parent: _previewController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _preview = OverlayEntry(
      builder: (context) => IgnorePointer(
        child: CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: showOnRight ? Alignment.topLeft : Alignment.topRight,
          followerAnchor: showOnRight ? Alignment.topLeft : Alignment.topRight,
          offset: Offset(showOnRight ? 36 : 0, 0),
          child: UnconstrainedBox(
            alignment: showOnRight ? Alignment.topLeft : Alignment.topRight,
            child: AnimatedBuilder(
              animation: reveal,
              child: _RankHoverPreview(
                index: widget.index,
                item: widget.item,
                reverse: !showOnRight,
              ),
              builder: (context, child) => ClipRect(
                child: Align(
                  alignment: showOnRight
                      ? Alignment.centerLeft
                      : Alignment.centerRight,
                  widthFactor: .27 + reveal.value * .73,
                  child: Opacity(
                    opacity: .92 + reveal.value * .08,
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_preview!);
    _previewController.forward(from: 0);
  }

  Future<void> _hidePreview() async {
    if (_preview == null) return;
    await _previewController.reverse();
    _preview?.remove();
    _preview = null;
  }

  @override
  void didUpdateWidget(covariant _RankTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.item.kind != widget.item.kind) {
      _preview?.remove();
      _preview = null;
      _previewController.value = 0;
    }
  }

  @override
  void dispose() {
    _preview?.remove();
    _previewController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CompositedTransformTarget(
    link: _link,
    child: MouseRegion(
      key: _cardKey,
      onEnter: (_) {
        setState(() => _hovered = true);
        _showPreview();
      },
      onExit: (_) {
        setState(() => _hovered = false);
        unawaited(_hidePreview());
      },
      child: SizedBox(
        width: 166,
        child: InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MetadataDetailPage(item: widget.item),
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                left: 0,
                bottom: 0,
                child: Text(
                  '${widget.index}',
                  style: TextStyle(
                    fontSize: 104,
                    height: .8,
                    fontWeight: FontWeight.w900,
                    color: Colors.white.withValues(alpha: .18),
                  ),
                ),
              ),
              Positioned(
                left: 36,
                top: 0,
                bottom: 0,
                right: 0,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Colors.white.withValues(
                        alpha: _hovered ? .76 : .12,
                      ),
                      width: _hovered ? 2.2 : 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(13),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (widget.item.posterUrl != null)
                          CachedNetworkImage(
                            imageUrl: widget.item.posterUrl.toString(),
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) =>
                                const ColoredBox(color: Color(0xFF1A1D25)),
                          )
                        else
                          const ColoredBox(color: Color(0xFF1A1D25)),
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.center,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Color(0xE60B0D11)],
                            ),
                          ),
                        ),
                        Positioned(
                          left: 10,
                          right: 10,
                          bottom: 10,
                          child: Text(
                            widget.item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              height: 1.2,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _RankHoverPreview extends StatelessWidget {
  const _RankHoverPreview({
    required this.index,
    required this.item,
    required this.reverse,
  });

  final int index;
  final TmdbItem item;
  final bool reverse;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 500,
    height: 226,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: YingjiGlass.blur,
          sigmaY: YingjiGlass.blur,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: YingjiGlass.surface(strength: 1.14),
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(
                color: Color(0x80000000),
                blurRadius: 30,
                offset: Offset(0, 14),
              ),
            ],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (item.backdropUrl != null)
                Opacity(
                  opacity: .12,
                  child: CachedNetworkImage(
                    imageUrl: item.backdropUrl.toString(),
                    fit: BoxFit.cover,
                  ),
                ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: reverse
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    end: reverse ? Alignment.centerLeft : Alignment.centerRight,
                    colors: [
                      YingjiGlass.chrome(strength: 1.24),
                      YingjiGlass.surface(strength: 1.16),
                    ],
                  ),
                ),
              ),
              Row(
                textDirection: reverse ? TextDirection.rtl : TextDirection.ltr,
                children: [
                  SizedBox(
                    width: 135,
                    height: double.infinity,
                    child: item.posterUrl == null
                        ? const ColoredBox(color: Color(0xFF1A1D25))
                        : CachedNetworkImage(
                            imageUrl: item.posterUrl.toString(),
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) =>
                                const ColoredBox(color: Color(0xFF1A1D25)),
                          ),
                  ),
                  Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(vertical: 12),
                    color: Colors.white.withValues(alpha: .09),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 15, 18, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: .14),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Text(
                                  '#$index',
                                  style: const TextStyle(
                                    color: YingjiColors.ink,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                    fontSize: 11,
                                    fontWeight: FontWeight.w900,
                                    decoration: TextDecoration.none,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  [
                                    if (item.year != null) '${item.year}',
                                    item.kind,
                                    ...item.genres.take(2),
                                  ].join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: YingjiColors.muted,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    decoration: TextDecoration.none,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 9),
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              height: 1.12,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -.35,
                              decoration: TextDecoration.none,
                            ),
                          ),
                          const SizedBox(height: 9),
                          MediaRatingRow(
                            item: item,
                            expanded: true,
                            maxItems: 3,
                            emphasizeFirst: true,
                          ),
                          if ((item.overview ?? '').trim().isNotEmpty) ...[
                            const SizedBox(height: 11),
                            Expanded(
                              child: Text(
                                item.overview!.trim(),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: .82),
                                  fontSize: 12,
                                  height: 1.55,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ),
                          ] else
                            const Spacer(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .76),
                      width: 2.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// A full, persistent continuation library.  It deliberately inherits the
/// current poster through [YingjiBackdrop], softened just enough for scanable
/// text, instead of replacing the cinematic field with a blank route.
class _ContinueWatchingPage extends StatefulWidget {
  const _ContinueWatchingPage();

  @override
  State<_ContinueWatchingPage> createState() => _ContinueWatchingPageState();
}

class _ContinueWatchingPageState extends State<_ContinueWatchingPage> {
  List<WatchState> _rows = const [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Local records render immediately; the server resume rail is then pulled
  /// and folded in (the same reconciliation the home shelf uses) so this page
  /// shows the server's latest playback data even when the local cache is
  /// stale, and rows are ordered by the real last-watch time.
  Future<void> _load() async {
    if (_busy) return;
    _busy = true;
    try {
      final store = await WatchStateStore.create();
      final local = store.load();
      if (mounted) {
        setState(() {
          _rows = continueWatchingRows(local);
          _loading = false;
        });
      }
      final merged = await _mergeServerWatchHistory(store, local);
      if (mounted && !_sameWatchStates(_rows, merged)) {
        setState(() => _rows = merged);
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _remove(WatchState state) async {
    final store = await WatchStateStore.create();
    await store.remove(state.mediaId);
    if (!mounted) return;
    // Remove from the visible list only; the server remains authoritative and
    // will re-import the record the next time the shelf reconciles.
    setState(
      () => _rows = _rows
          .where((row) => row.mediaId != state.mediaId)
          .toList(growable: false),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: YingjiBackdrop(
      blur: 22,
      overlay: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x7A07090D), Color(0xE807090D)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              YingjiPageChrome(onBack: () => Navigator.pop(context)),
              Expanded(
                child: Builder(
                  builder: (context) {
                    final rows = _rows;
                    if (_loading && rows.isEmpty) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return CustomScrollView(
                      physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                      slivers: [
                        const SliverPadding(
                          padding: EdgeInsets.fromLTRB(74, 30, 64, 18),
                          sliver: SliverToBoxAdapter(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '继续播放',
                                  style: TextStyle(
                                    fontSize: 46,
                                    height: 1,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -1.1,
                                  ),
                                ),
                                SizedBox(height: 10),
                                Text(
                                  '按最后观看时间保留本机进度。',
                                  style: TextStyle(color: YingjiColors.muted),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (rows.isEmpty)
                          const SliverFillRemaining(
                            hasScrollBody: false,
                            child: _EmptyStrip(
                              icon: YingjiIcons.play_circle,
                              title: '还没有继续播放内容',
                              detail: '开始播放任意媒体后，会在这里保留进度。',
                            ),
                          )
                        else
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(74, 0, 64, 64),
                            sliver: SliverGrid(
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 336,
                                    mainAxisExtent: 252,
                                    mainAxisSpacing: 22,
                                    crossAxisSpacing: 18,
                                  ),
                              delegate: SliverChildBuilderDelegate((
                                context,
                                index,
                              ) {
                                final state = rows[index];
                                return Stack(
                                  children: [
                                    Positioned.fill(
                                      child: _ContinueTile(
                                        state: state,
                                        width: double.infinity,
                                        onChanged: _load,
                                      ),
                                    ),
                                    Positioned(
                                      right: 6,
                                      top: 6,
                                      child: YingjiMotionIconButton(
                                        icon: YingjiIcons.trash,
                                        tooltip: '移除继续播放记录',
                                        size: 32,
                                        onPressed: () => _remove(state),
                                      ),
                                    ),
                                  ],
                                );
                              }, childCount: rows.length),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _HistoryStrip extends StatelessWidget {
  const _HistoryStrip({
    required this.history,
    required this.onChanged,
    this.controller,
  });
  final List<WatchState> history;
  final VoidCallback onChanged;
  final ScrollController? controller;
  @override
  Widget build(BuildContext context) => ListView.separated(
    controller: controller,
    scrollDirection: Axis.horizontal,
    clipBehavior: Clip.none,
    padding: const EdgeInsets.only(bottom: 4),
    itemCount: history.length,
    separatorBuilder: (_, _) => const SizedBox(width: 16),
    itemBuilder: (_, index) {
      final state = history[index];
      return _ContinueTile(state: state, onChanged: onChanged);
    },
  );
}

class _ContinueTile extends StatelessWidget {
  const _ContinueTile({
    required this.state,
    required this.onChanged,
    this.width = 274,
  });
  final WatchState state;
  final VoidCallback onChanged;
  final double width;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _openWatchDetail(context, state),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: _MediaHover(
              borderRadius: 14,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  state.imageUrl == null
                      ? _ContinueArtworkFallback(title: state.title)
                      : CachedNetworkImage(
                          imageUrl: state.imageUrl!,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) =>
                              _ContinueArtworkFallback(title: state.title),
                        ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.transparent, Color(0xB3000000)],
                        begin: Alignment.center,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 10,
                    top: 10,
                    child: _WatchProgressOriginBadge(state: state),
                  ),
                  Positioned(
                    left: 10,
                    right: 10,
                    bottom: 8,
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Text(
                              _duration(state.position),
                              style: const TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              _duration(state.duration - state.position),
                              style: const TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: LinearProgressIndicator(
                            value: state.progress,
                            minHeight: 3,
                            backgroundColor: Colors.white24,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            state.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 14,
              height: 1.25,
              letterSpacing: -.15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            state.episodeTitle?.isNotEmpty == true
                ? 'S${state.seasonNumber ?? 1}E${state.episodeNumber ?? 1} · ${state.episodeTitle}'
                : state.episodeNumber != null
                ? '第 ${state.episodeNumber} 集'
                : '继续上次观看',
            style: const TextStyle(
              fontSize: 11.5,
              height: 1.25,
              fontWeight: FontWeight.w500,
              color: Color(0xFFC2C6D0),
            ),
          ),
        ],
      ),
    ),
  );
}

class _WatchProgressOriginBadge extends StatelessWidget {
  const _WatchProgressOriginBadge({required this.state});

  final WatchState state;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (state.progressOrigin) {
      'server' => (
        YingjiIcons.server,
        state.progressOriginName?.trim().isNotEmpty == true
            ? state.progressOriginName!.trim()
            : '服务器',
      ),
      'trakt' => (YingjiIcons.refresh, 'Trakt'),
      _ => (YingjiIcons.play_rectangle, '本机'),
    };
    return Container(
      constraints: const BoxConstraints(maxWidth: 132),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: YingjiGlass.chrome(strength: 1.08),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: YingjiGlass.line(strength: 1.1)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x52000000),
            blurRadius: 14,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: Colors.white),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10.5,
                height: 1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContinueArtworkFallback extends StatelessWidget {
  const _ContinueArtworkFallback({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        colors: [Color(0xFF242833), Color(0xFF101319)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: Center(
      child: Text(
        title.isEmpty ? '映' : title.characters.first,
        style: TextStyle(
          color: Colors.white.withValues(alpha: .24),
          fontSize: 42,
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
  );
}

class _MediaHover extends StatefulWidget {
  const _MediaHover({required this.borderRadius, required this.child});

  final double borderRadius;
  final Widget child;

  @override
  State<_MediaHover> createState() => _MediaHoverState();
}

class _MediaHoverState extends State<_MediaHover> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: AnimatedScale(
      scale: _hovered ? 1.018 : 1,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        transform: Matrix4.translationValues(0, _hovered ? -4 : 0, 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          border: Border.all(
            color: _hovered
                ? Colors.white.withValues(alpha: .72)
                : Colors.white.withValues(alpha: .09),
            width: _hovered ? 2.2 : 1,
          ),
          boxShadow: _hovered
              ? const [
                  BoxShadow(
                    color: Color(0x99000000),
                    blurRadius: 24,
                    offset: Offset(0, 12),
                  ),
                ]
              : const [],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius - 1),
          child: widget.child,
        ),
      ),
    ),
  );
}

String _duration(Duration value) =>
    '${value.inHours > 0 ? '${value.inHours}:' : ''}${value.inMinutes.remainder(60).toString().padLeft(2, '0')}:${value.inSeconds.remainder(60).toString().padLeft(2, '0')}';

Future<void> _openWatchDetail(BuildContext context, WatchState state) async {
  if (state.tmdbId != null && state.tmdbId! > 0) {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MetadataDetailPage(
          item: TmdbItem(
            id: state.tmdbId!,
            title: state.title.split(' · ').first.trim(),
            kind: '剧集',
          ),
        ),
      ),
    );
    return;
  }
  final sourceId = state.sourceId;
  final serverItemId = state.serverItemId;
  final seriesTitle = state.title.split(' · ').first.trim();
  if (sourceId != null &&
      sourceId.isNotEmpty &&
      serverItemId != null &&
      serverItemId.isNotEmpty) {
    try {
      final store = await SourceStore.create();
      final source = store
          .load()
          .where((item) => item.id == sourceId)
          .firstOrNull;
      final token = source == null ? null : store.tokenFor(source);
      if (source != null && token != null && token.isNotEmpty) {
        final session = EmbySession(source: source, token: token);
        final client = EmbyClient();
        try {
          // Precise path: the stored row references one server item. Fetch it
          // and, when it is an episode, roll up to its parent series — the
          // series carries the TMDB provider id that makes the detail page
          // render correctly, while the episode row itself never does. A
          // title search is deliberately the fallback: on libraries whose
          // episode file names embed the series title it returns dozens of
          // provider-less episode rows and a bare firstOrNull lands wrongly.
          MediaItem? media;
          try {
            final item = await client.itemById(session, serverItemId);
            media =
                item.type == 'Episode' && (item.seriesId?.isNotEmpty == true)
                ? await client.itemById(session, item.seriesId!)
                : item;
          } catch (_) {
            media = null; // Source offline or item removed; retry by title.
          }
          if (media == null) {
            final rows = await client.search(session, seriesTitle);
            // Prefer Series/Movie rows over episodes (see above).
            final nonEpisodes = rows
                .where((item) => item.type != 'Episode')
                .toList(growable: false);
            media =
                nonEpisodes
                    .where((item) => item.id == serverItemId)
                    .firstOrNull ??
                nonEpisodes
                    .where((item) => item.title == seriesTitle)
                    .firstOrNull ??
                nonEpisodes.firstOrNull ??
                rows.firstOrNull;
          }
          if (media != null && context.mounted) {
            await _openServerSearchDetail(context, media);
            return;
          }
        } finally {
          client.dispose();
        }
      }
    } catch (_) {
      // Fall through to TMDB title matching when the source is offline.
    }
  }
  final client = TmdbClient();
  try {
    var matches = await client.search(seriesTitle);
    if (matches.isEmpty && seriesTitle != state.title) {
      matches = await client.search(state.title);
    }
    if (!context.mounted) return;
    if (matches.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂未找到该内容的详情，仍可从完整列表继续播放。')));
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MetadataDetailPage(item: matches.first),
      ),
    );
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('详情暂时无法加载，请稍后重试。')));
    }
  } finally {
    client.dispose();
  }
}

Future<void> _resumePlayback(BuildContext context, WatchState state) async {
  var headers = const <String, String>{};
  final sourceId = state.sourceId;
  if (sourceId != null && sourceId.isNotEmpty) {
    try {
      final store = await SourceStore.create();
      final source = store
          .load()
          .where((value) => value.id == sourceId)
          .firstOrNull;
      final token = source == null ? null : store.tokenFor(source);
      if (source?.kind == SourceKind.webdav &&
          token != null &&
          token.isNotEmpty) {
        final credentials = utf8
            .decode(base64Url.decode(token))
            .split('\u0000');
        if (credentials.length >= 2) {
          headers = <String, String>{
            'Authorization':
                'Basic ${base64Encode(utf8.encode('${credentials[0]}:${credentials[1]}'))}',
          };
        }
      }
    } catch (_) {
      // The player will show a retryable stream error if a stored source changed.
    }
  }
  if (!context.mounted) return;
  var startPosition = state.position;
  final prefs = await SharedPreferences.getInstance();
  if (!context.mounted) return;
  final prompt = prefs.getBool('yingji.player.resume-prompt') ?? true;
  if (prompt && state.position > const Duration(seconds: 5)) {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('继续观看？'),
        content: Text('上次看到 ${_duration(state.position)}，要从这里继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'restart'),
            child: const Text('从头播放'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'resume'),
            child: const Text('继续播放'),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'restart') startPosition = Duration.zero;
  }
  if (!context.mounted) return;
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => PlayerPage(
        url: state.mediaId,
        title: state.title,
        headers: headers,
        initialPosition: startPosition,
        imageUrl: state.imageUrl,
        sourceId: state.sourceId,
        serverItemId: state.serverItemId,
      ),
    ),
  );
}

// ignore: unused_element
Future<void> _showDiscoverItems(
  BuildContext context,
  String title,
  List<TmdbItem> items,
) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 560,
        height: 460,
        child: ListView.separated(
          itemCount: items.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (_, index) {
            final item = items[index];
            return ListTile(
              leading: item.posterUrl == null
                  ? const Icon(YingjiIcons.film)
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: CachedNetworkImage(
                        imageUrl: item.posterUrl.toString(),
                        width: 38,
                        height: 54,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => const Icon(YingjiIcons.film),
                      ),
                    ),
              title: Text(item.title),
              subtitle: MediaRatingRow(item: item),
              onTap: () {
                Navigator.pop(dialogContext);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MetadataDetailPage(item: item),
                  ),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

// Kept as a recovery dialog for callers outside the cinematic shell.
// ignore: unused_element
Future<void> _showHistoryManager(
  BuildContext context,
  List<WatchState> history,
  VoidCallback onChanged,
) async {
  final store = await WatchStateStore.create();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      var rows = List<WatchState>.of(history);
      return StatefulBuilder(
        builder: (_, setDialogState) => AlertDialog(
          title: const Text('继续观看'),
          content: SizedBox(
            width: 560,
            height: 460,
            child: rows.isEmpty
                ? const Center(child: Text('没有观看记录'))
                : ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, index) {
                      final state = rows[index];
                      return ListTile(
                        title: Text(state.title),
                        subtitle: Text(
                          '已观看 ${_duration(state.position)} · 剩余 ${_duration(state.duration - state.position)}',
                        ),
                        trailing: IconButton(
                          tooltip: '移除记录',
                          icon: const Icon(YingjiIcons.trash, size: 18),
                          onPressed: () async {
                            await store.remove(state.mediaId);
                            setDialogState(
                              () => rows = List.of(rows)..removeAt(index),
                            );
                            onChanged();
                          },
                        ),
                        onTap: () {
                          Navigator.pop(dialogContext);
                          _resumePlayback(context, state);
                        },
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    },
  );
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.item});
  final TmdbItem item;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 6,
    children: [
      Text(
        '${item.year ?? '—'}',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      _Tag(item.kind),
      for (final genre in item.genres.take(3)) _Tag(genre),
      _PlatformRatingRow(item: item),
    ],
  );
}

class _PlatformRatingRow extends StatelessWidget {
  const _PlatformRatingRow({required this.item});
  final TmdbItem item;
  @override
  Widget build(BuildContext context) =>
      MediaRatingRow(item: item, expanded: true);
}

class _Tag extends StatelessWidget {
  const _Tag(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .14),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      label,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
    ),
  );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.subtitle,
    this.action,
    this.onAction,
    this.actionIcon,
    this.titleAction,
    this.trailingActions = const [],
  });
  final String title;
  final String subtitle;
  final String? action;
  final VoidCallback? onAction;
  final IconData? actionIcon;
  final Widget? titleAction;
  final List<Widget> trailingActions;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 25,
                      height: 1.08,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.3,
                    ),
                  ),
                ),
                if (titleAction != null) ...[
                  const SizedBox(width: 8),
                  titleAction!,
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(
                color: YingjiColors.muted,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
      ...trailingActions,
      if (trailingActions.isNotEmpty && action != null)
        const SizedBox(width: 8),
      if (action != null)
        YingjiMotionIconButton(
          onPressed: onAction ?? () {},
          icon: actionIcon ?? YingjiIcons.rectangle_stack,
          tooltip: action!,
          size: 38,
        ),
    ],
  );
}

class _HeroProgressDots extends StatelessWidget {
  const _HeroProgressDots({
    required this.length,
    required this.active,
    required this.progress,
    required this.onChanged,
  });
  final int length;
  final int active;
  final double progress;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: List.generate(
      length,
      (index) => InkWell(
        onTap: () => onChanged(index),
        borderRadius: BorderRadius.circular(99),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 12),
          child: Transform.translate(
            offset: index == active
                ? Offset(0, math.sin(progress * math.pi * 2) * 2)
                : Offset.zero,
            child: Transform.scale(
              scale: index == active
                  ? 1 + (.06 * math.sin(progress * math.pi * 2).abs())
                  : 1,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOutCubic,
                width: index == active ? 8 + (24 * progress.clamp(0, 1)) : 7,
                height: index == active ? 6 : 5,
                decoration: BoxDecoration(
                  color: index == active ? Colors.white : Colors.white54,
                  borderRadius: BorderRadius.circular(99),
                  boxShadow: index == active
                      ? const [
                          BoxShadow(
                            color: Color(0xAAFFFFFF),
                            blurRadius: 8,
                            spreadRadius: -2,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _FrostSurface extends StatefulWidget {
  const _FrostSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    required this.borderRadius,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  @override
  State<_FrostSurface> createState() => _FrostSurfaceState();
}

class _FrostSurfaceState extends State<_FrostSurface> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: AnimatedScale(
      scale: _hovered ? 1.008 : 1,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        transform: Matrix4.translationValues(0, _hovered ? -3 : 0, 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          boxShadow: _hovered
              ? const [
                  BoxShadow(
                    color: Color(0x82000000),
                    blurRadius: 32,
                    offset: Offset(0, 17),
                  ),
                ]
              : const [
                  BoxShadow(
                    color: Color(0x52000000),
                    blurRadius: 28,
                    offset: Offset(0, 14),
                  ),
                ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: YingjiGlass.blur,
              sigmaY: YingjiGlass.blur,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: YingjiGlass.surface(),
                borderRadius: BorderRadius.circular(widget.borderRadius),
                border: Border.all(
                  color: YingjiGlass.line(strength: _hovered ? 1.25 : 1),
                ),
              ),
              child: Material(
                color: Colors.transparent,
                child: Padding(padding: widget.padding, child: widget.child),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _CircleAction extends StatelessWidget {
  const _CircleAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => YingjiMotionIconButton(
    icon: icon,
    tooltip: tooltip,
    onPressed: onPressed,
    size: 52,
  );
}

class _EmptyStrip extends StatelessWidget {
  const _EmptyStrip({
    required this.icon,
    required this.title,
    required this.detail,
  });
  final IconData icon;
  final String title, detail;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: _FrostSurface(
        borderRadius: 14,
        child: Row(
          children: [
            Icon(icon, color: YingjiColors.focus, size: 30),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    style: const TextStyle(
                      color: Color(0xFFABB1BE),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure({
    required this.onRetry,
    this.message = '无法读取内容，请检查网络后重试。',
  });
  final VoidCallback onRetry;
  final String message;
  @override
  Widget build(BuildContext context) => Center(
    child: _FrostSurface(
      borderRadius: 18,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            YingjiIcons.exclamationmark_triangle,
            color: Color(0xFFFF9BA5),
          ),
          const SizedBox(height: 10),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 10),
          FilledButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    ),
  );
}

class _HomeNetworkNotice extends StatelessWidget {
  const _HomeNetworkNotice({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => _FrostSurface(
    borderRadius: 16,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(
      children: [
        const Icon(
          YingjiIcons.exclamationmark_triangle,
          color: Color(0xFFFFA1A9),
          size: 18,
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(message, style: const TextStyle(fontSize: 12))),
        TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    ),
  );
}

String _networkError(Object? error) {
  if (error == null) return '无法读取内容，请检查网络后重试。';
  final text = error.toString().replaceFirst('Exception: ', '').trim();
  if (text.contains('SocketException') || text.contains('Failed host lookup')) {
    return '无法连接 TMDB 元数据服务，请检查网络或 DNS。';
  }
  if (text.contains('HandshakeException') ||
      text.toLowerCase().contains('handshake') ||
      text.toLowerCase().contains('tls')) {
    return 'TMDB 安全连接失败，请检查 Windows 代理或系统证书。';
  }
  if (text.contains('ClientException')) {
    return 'TMDB 网络连接失败，请检查 Windows 代理或防火墙。';
  }
  if (text.contains('TimeoutException')) return 'TMDB 请求超时，请稍后重试。';
  return text.isEmpty ? '无法读取内容，请检查网络后重试。' : text;
}

class _SourceCard extends StatefulWidget {
  const _SourceCard({
    required this.source,
    required this.stats,
    required this.iconToken,
    required this.onPickIcon,
    required this.offline,
    required this.onRemove,
    required this.onEdit,
    required this.onTest,
    required this.onOpen,
    required this.testing,
    required this.onSwitchEndpoint,
  });
  final MediaSource source;

  /// Locally cached library statistics supplied by the parent hub — the card
  /// itself never performs a network request on mount.
  final _CachedSourceStats? stats;
  final String? iconToken;
  final VoidCallback onPickIcon;
  final bool offline;
  final VoidCallback onRemove;
  final VoidCallback onEdit;
  final VoidCallback onTest;
  final VoidCallback onOpen;
  final bool testing;
  final ValueChanged<Uri> onSwitchEndpoint;

  @override
  State<_SourceCard> createState() => _SourceCardState();
}

class _SourceCardState extends State<_SourceCard> {
  Future<DateTime?>? _lastWatched;

  @override
  void initState() {
    super.initState();
    _lastWatched = _loadLastWatched();
  }

  Future<DateTime?> _loadLastWatched() async {
    final states = (await WatchStateStore.create()).load();
    final values = states
        .where((state) => state.sourceId == widget.source.id)
        .map((state) => state.updatedAt)
        .whereType<DateTime>();
    if (values.isEmpty) return null;
    return values.reduce(
      (latest, value) => value.isAfter(latest) ? value : latest,
    );
  }

  Widget _statusChip() {
    if (widget.testing) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.8),
            ),
            SizedBox(width: 5),
            Text(
              '测试中…',
              style: TextStyle(color: YingjiColors.muted, fontSize: 12),
            ),
          ],
        ),
      );
    }
    final Color color;
    final String label;
    if (widget.offline) {
      color = const Color(0xFFFF7A85);
      label = '离线';
    } else if (widget.stats == null) {
      color = const Color(0xFF8A90A0);
      label = '未检查';
    } else {
      color = const Color(0xFF4CD97B);
      label = '${widget.stats!.latencyMs} ms';
    }
    return InkWell(
      onTap: widget.onTest,
      borderRadius: BorderRadius.circular(9),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(color: YingjiColors.muted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => YingjiGlassMenu(
    secondaryOnly: true,
    entries: [
      for (final endpoint in widget.source.endpoints)
        MenuItemButton(
          onPressed: () {
            if (endpoint != widget.source.endpoint) {
              widget.onSwitchEndpoint(endpoint);
            }
          },
          leadingIcon: Icon(
            endpoint == widget.source.endpoint
                ? YingjiIcons.checkmark_circle_fill
                : YingjiIcons.link,
            size: 16,
          ),
          child: Text(endpoint.host),
        ),
    ],
    child: _buildCard(context),
  );

  Widget _buildCard(BuildContext context) => InkWell(
    onTap: widget.onOpen,
    borderRadius: BorderRadius.circular(18),
    child: SizedBox(
      width: 388,
      height: 128,
      child: _FrostSurface(
        borderRadius: 18,
        padding: const EdgeInsets.fromLTRB(14, 13, 12, 12),
        child: FutureBuilder<DateTime?>(
          future: _lastWatched,
          builder: (context, watchedSnapshot) {
            final lastWatched = watchedSnapshot.data;
            final days = lastWatched == null
                ? null
                : DateTime.now().difference(lastWatched).inDays;
            final stats = widget.stats;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: widget.onPickIcon,
                  borderRadius: BorderRadius.circular(16),
                  child: _ServerMark(
                    source: widget.source,
                    token: widget.iconToken,
                    size: 54,
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.source.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '服务器设置',
                            visualDensity: VisualDensity.compact,
                            onPressed: widget.testing ? null : widget.onEdit,
                            icon: const Icon(YingjiIcons.gear, size: 17),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        days == null
                            ? '尚未有本地观看记录'
                            : days == 0
                            ? '上次观看：今天'
                            : '上次观看：$days 天前',
                        style: const TextStyle(
                          fontSize: 11,
                          color: YingjiColors.muted,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Container(
                        height: 1,
                        color: Colors.white.withValues(alpha: .16),
                      ),
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              stats == null
                                  ? '电影  --'
                                  : '电影  ${stats.movieCount}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              stats == null
                                  ? '剧集  --'
                                  : '剧集  ${stats.seriesCount}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.source.alternateEndpoints.isEmpty
                                  ? '主线路'
                                  : '主线路 · ${widget.source.alternateEndpoints.length + 1} 条',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          _statusChip(),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '移除来源',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onRemove,
                  icon: const Icon(
                    YingjiIcons.trash,
                    size: 16,
                    color: YingjiColors.danger,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

class _IconPackEntry {
  const _IconPackEntry({required this.name, required this.url});
  final String name;
  final String url;
}

class _IconPackData {
  const _IconPackData({required this.icons, required this.metadata});
  final List<_IconPackEntry> icons;
  final _IconPackMetadata metadata;
}

class _IconPackMetadata {
  const _IconPackMetadata({
    required this.url,
    required this.name,
    required this.iconCount,
    required this.updatedAt,
    this.author,
    this.version,
    this.description,
  });
  final String url, name, updatedAt;
  final int iconCount;
  final String? author, version, description;

  factory _IconPackMetadata.fromJson(String url, dynamic raw) {
    if (raw is String) {
      return _IconPackMetadata(
        url: url,
        name: Uri.tryParse(url)?.host ?? '图标包',
        iconCount:
            int.tryParse(RegExp(r'(\d+)').firstMatch(raw)?.group(1) ?? '') ?? 0,
        updatedAt: '',
        description: raw,
      );
    }
    final map = raw is Map ? raw : const {};
    return _IconPackMetadata(
      url: url,
      name: '${map['name'] ?? Uri.tryParse(url)?.host ?? '图标包'}',
      iconCount: (map['iconCount'] as num?)?.toInt() ?? 0,
      updatedAt: '${map['updatedAt'] ?? ''}',
      author: map['author']?.toString(),
      version: map['version']?.toString(),
      description: map['description']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    'name': name,
    'iconCount': iconCount,
    'updatedAt': updatedAt,
    if (author?.isNotEmpty == true) 'author': author,
    if (version?.isNotEmpty == true) 'version': version,
    if (description?.isNotEmpty == true) 'description': description,
  };
}

class _ServerIconDialog extends StatefulWidget {
  const _ServerIconDialog({required this.source, required this.token});
  final MediaSource source;
  final String token;

  @override
  State<_ServerIconDialog> createState() => _ServerIconDialogState();
}

class _ServerIconDialogState extends State<_ServerIconDialog> {
  final _packUrl = TextEditingController();
  final _query = TextEditingController();
  List<_IconPackEntry> _icons = const [];
  List<String> _packs = const [];
  Map<String, _IconPackMetadata> _packInfo = const {};
  String? _selectedPack;
  bool _loading = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _loadPacks();
    _query.addListener(() => setState(() {}));
  }

  Future<void> _loadPacks() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final packs = prefs.getStringList('yingji.server.icon-packs') ?? const [];
    final rawInfo = prefs.getString('yingji.server.icon-pack-info');
    final decoded = rawInfo == null ? null : jsonDecode(rawInfo);
    final info = decoded is Map
        ? decoded.map(
            (key, value) =>
                MapEntry('$key', _IconPackMetadata.fromJson('$key', value)),
          )
        : <String, _IconPackMetadata>{};
    final selected =
        prefs.getString('yingji.server.icon-pack-selected') ??
        (packs.isEmpty ? null : packs.last);
    setState(() {
      _packs = packs;
      _packInfo = info;
      _selectedPack = selected;
    });
    if (selected != null) unawaited(_selectPack(selected));
  }

  Future<_IconPackData> _readPack(String value) async {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !['http', 'https'].contains(uri.scheme)) {
      throw Exception('图标包链接无效');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('图标包读取失败（HTTP ${response.statusCode}）');
      }
      final raw = await utf8.decoder.bind(response).join();
      final data = jsonDecode(raw);
      final List<dynamic> rows;
      if (data is List) {
        rows = data;
      } else if (data is Map<String, dynamic>) {
        rows = data['icons'] is List
            ? List<dynamic>.from(data['icons'] as List)
            : List<dynamic>.from(data.entries);
      } else {
        rows = const [];
      }
      final result = <_IconPackEntry>[];
      for (final row in rows) {
        String? name;
        String? url;
        if (row is MapEntry) {
          name = '${row.key}';
          url = '${row.value}';
        } else if (row is Map) {
          name = '${row['name'] ?? row['title'] ?? row['slug'] ?? '未命名图标'}';
          final candidate =
              row['url'] ?? row['icon'] ?? row['logo'] ?? row['src'];
          if (candidate != null) url = '$candidate';
        }
        final iconUri = Uri.tryParse(url ?? '');
        if (name != null && iconUri != null && iconUri.hasScheme) {
          result.add(_IconPackEntry(name: name, url: iconUri.toString()));
        }
      }
      if (result.isEmpty) throw Exception('图标包中没有可用图标');
      final map = data is Map ? data : const {};
      String? text(dynamic value) =>
          value == null || '$value'.trim().isEmpty ? null : '$value';
      final metadata = _IconPackMetadata(
        url: value,
        name: text(map['name'] ?? map['title'] ?? map['packName']) ?? uri.host,
        iconCount: result.length,
        updatedAt: DateTime.now().toIso8601String(),
        author: text(map['author'] ?? map['publisher'] ?? map['maintainer']),
        version: text(map['version']),
        description: text(map['description'] ?? map['summary']),
      );
      return _IconPackData(icons: result, metadata: metadata);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _addPack() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final value = _packUrl.text.trim();
      final pack = await _readPack(value);
      final prefs = await SharedPreferences.getInstance();
      final packs = {..._packs, value}.toList(growable: false);
      final info = <String, _IconPackMetadata>{
        ..._packInfo,
        value: pack.metadata,
      };
      await prefs.setStringList('yingji.server.icon-packs', packs);
      await prefs.setString('yingji.server.icon-pack-selected', value);
      await prefs.setString(
        'yingji.server.icon-pack-info',
        jsonEncode(info.map((key, value) => MapEntry(key, value.toJson()))),
      );
      if (mounted) {
        setState(() {
          _packs = packs;
          _packInfo = info;
          _selectedPack = value;
          _icons = pack.icons;
          _message = '已更新 ${pack.metadata.name} · ${pack.icons.length} 个图标';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _selectPack(String value) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _packUrl.text = value;
      _message = null;
    });
    try {
      final pack = await _readPack(value);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('yingji.server.icon-pack-selected', value);
      final info = {..._packInfo, value: pack.metadata};
      await prefs.setString(
        'yingji.server.icon-pack-info',
        jsonEncode(info.map((key, value) => MapEntry(key, value.toJson()))),
      );
      if (mounted) {
        setState(() {
          _icons = pack.icons;
          _packInfo = info;
          _selectedPack = value;
          _message = '已更新 ${pack.metadata.name} · ${pack.icons.length} 个图标';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _packUrl.dispose();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filter = _query.text.trim().toLowerCase();
    final icons = _icons
        .where(
          (icon) => filter.isEmpty || icon.name.toLowerCase().contains(filter),
        )
        .toList(growable: false);
    return Dialog(
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 680),
        child: GlassPanel(
          radius: 22,
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _ServerMark(
                    source: widget.source,
                    token: widget.token,
                    size: 48,
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      '服务器图标',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  YingjiMotionIconButton(
                    icon: YingjiIcons.xmark,
                    tooltip: '关闭',
                    size: 38,
                    onPressed: () {
                      Navigator.pop(context);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _packUrl,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: '图标包 JSON 链接',
                        hintText: 'https://example.com/icons.json',
                        prefixIcon: Icon(YingjiIcons.link),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  YingjiMotionIconButton(
                    icon: YingjiIcons.plus,
                    tooltip: '获取图标包',
                    size: 42,
                    onPressed: _loading
                        ? () {}
                        : () {
                            unawaited(_addPack());
                          },
                  ),
                ],
              ),
              if (_packs.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final pack in _packs)
                      ChoiceChip(
                        avatar: const Icon(YingjiIcons.archivebox, size: 15),
                        label: Text(
                          '${_packInfo[pack]?.name ?? Uri.tryParse(pack)?.host ?? '图标包'} · ${_packInfo[pack]?.iconCount ?? 0}',
                        ),
                        selected: _selectedPack == pack,
                        onSelected: (_) {
                          unawaited(_selectPack(pack));
                        },
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _message ??
                          (_selectedPack == null
                              ? '可添加多条 JSON 图标包链接。'
                              : '来源：${Uri.tryParse(_selectedPack!)?.host ?? _selectedPack!}'),
                      style: const TextStyle(
                        color: YingjiColors.muted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, ''),
                    child: const Text('使用自动图标'),
                  ),
                ],
              ),
              if (_selectedPack != null &&
                  _packInfo[_selectedPack!] != null) ...[
                const SizedBox(height: 8),
                Builder(
                  builder: (context) {
                    final info = _packInfo[_selectedPack!]!;
                    final updated = DateTime.tryParse(info.updatedAt)
                        ?.toLocal();
                    final stamp = updated == null
                        ? '尚未记录'
                        : '${updated.year}-${updated.month.toString().padLeft(2, '0')}-${updated.day.toString().padLeft(2, '0')} ${updated.hour.toString().padLeft(2, '0')}:${updated.minute.toString().padLeft(2, '0')}';
                    return _FrostSurface(
                      borderRadius: 14,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  info.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  [
                                    if (info.author?.isNotEmpty == true)
                                      '作者 ${info.author}',
                                    if (info.version?.isNotEmpty == true)
                                      '版本 ${info.version}',
                                    '${info.iconCount} 个图标',
                                    '更新 $stamp',
                                  ].join('  ·  '),
                                  style: const TextStyle(
                                    color: YingjiColors.muted,
                                    fontSize: 11,
                                  ),
                                ),
                                if (info.description?.isNotEmpty == true) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    info.description!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: YingjiColors.muted,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
              const SizedBox(height: 10),
              TextField(
                controller: _query,
                decoration: const InputDecoration(
                  labelText: '搜索图标',
                  prefixIcon: Icon(YingjiIcons.search),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : icons.isEmpty
                    ? const Center(child: Text('添加图标包后，可在这里搜索并替换服务器图标。'))
                    : GridView.builder(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 118,
                              mainAxisSpacing: 10,
                              crossAxisSpacing: 10,
                              childAspectRatio: .88,
                            ),
                        itemCount: icons.length,
                        itemBuilder: (context, index) {
                          final icon = icons[index];
                          return InkWell(
                            onTap: () => Navigator.pop(context, icon.url),
                            borderRadius: BorderRadius.circular(14),
                            child: _FrostSurface(
                              borderRadius: 14,
                              padding: const EdgeInsets.all(9),
                              child: Column(
                                children: [
                                  Expanded(
                                    child: Image.network(
                                      icon.url,
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    icon.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServerMark extends StatelessWidget {
  const _ServerMark({required this.source, this.token, this.size = 42});
  final MediaSource source;
  final String? token;
  final double size;

  @override
  Widget build(BuildContext context) {
    final webdav = source.kind == SourceKind.webdav;
    final jellyfin = source.kind == SourceKind.jellyfin;
    final colors = webdav
        ? const [Color(0xFF4B88C7), Color(0xFF23456B)]
        : jellyfin
        ? const [Color(0xFF9B5DE5), Color(0xFF3157C8)]
        : const [Color(0xFF58D568), Color(0xFF18853A)];
    final customIcon = Uri.tryParse(source.iconUrl ?? '');
    final hasImage = customIcon != null && customIcon.hasScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: hasImage
            ? null
            : LinearGradient(
                colors: colors,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
        borderRadius: BorderRadius.circular(size * .29),
        boxShadow: hasImage
            ? null
            : const [
                BoxShadow(
                  color: Color(0x4D000000),
                  blurRadius: 16,
                  offset: Offset(0, 8),
                ),
              ],
      ),
      child: hasImage
          ? ClipRRect(
              borderRadius: BorderRadius.circular(size * .29),
              child: source.customIcon
                  ? _BackgroundFreeNetworkIcon(
                      url: customIcon.toString(),
                      fallback: _defaultMark(webdav, colors),
                    )
                  : Image.network(
                      customIcon.toString(),
                      headers:
                          customIcon.host == source.endpoint.host &&
                              token != null &&
                              token!.isNotEmpty
                          ? {'X-Emby-Token': token!}
                          : null,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => _defaultMark(webdav, colors),
                    ),
            )
          : _defaultMark(webdav, colors),
    );
  }

  Widget _defaultMark(bool webdav, List<Color> colors) => webdav
      ? Icon(YingjiIcons.cloud_fill, color: Colors.white, size: size * .46)
      : Center(
          child: Transform.rotate(
            angle: math.pi / 4,
            child: Container(
              width: size * .44,
              height: size * .44,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .94),
                borderRadius: BorderRadius.circular(size * .08),
              ),
              child: Transform.rotate(
                angle: -math.pi / 4,
                child: Icon(
                  YingjiIcons.play_fill,
                  color: colors.last,
                  size: size * .24,
                ),
              ),
            ),
          ),
        );
}

final Map<String, Future<Uint8List?>> _backgroundFreeIconCache = {};

class _BackgroundFreeNetworkIcon extends StatelessWidget {
  const _BackgroundFreeNetworkIcon({
    required this.url,
    required this.fallback,
    this.alignment = Alignment.center,
  });

  final String url;
  final Widget fallback;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _backgroundFreeIconCache.putIfAbsent(
      url,
      () => _loadBackgroundFreeIcon(url),
    ),
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      if (bytes == null) {
        return snapshot.connectionState == ConnectionState.done
            ? fallback
            : const SizedBox.shrink();
      }
      return Image.memory(
        bytes,
        fit: BoxFit.contain,
        alignment: alignment,
        gaplessPlayback: true,
      );
    },
  );
}

Future<Uint8List?> _loadBackgroundFreeIcon(String value) async {
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme) return null;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final response = await (await client.getUrl(uri)).close();
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final output = BytesBuilder(copy: false);
    await for (final chunk in response) {
      output.add(chunk);
    }
    final decoded = image_lib.decodeImage(output.takeBytes());
    if (decoded == null) return null;
    final rgba = decoded.numChannels == 4
        ? decoded
        : decoded.convert(numChannels: 4);
    removeFlatIconBackground(rgba);
    return Uint8List.fromList(image_lib.encodePng(rgba));
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

class _CapabilityTile extends StatelessWidget {
  const _CapabilityTile({
    required this.icon,
    required this.title,
    required this.detail,
  });
  final IconData icon;
  final String title, detail;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 240,
    child: _FrostSurface(
      borderRadius: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: YingjiColors.focus),
          const SizedBox(height: 16),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 5),
          Text(
            detail,
            style: const TextStyle(color: Color(0xFFABB1BE), fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({
    required this.playlist,
    required this.onDelete,
    required this.onOpen,
  });
  final YingjiPlaylist playlist;
  final VoidCallback onDelete;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 236,
    child: InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(17),
      child: _FrostSurface(
        borderRadius: 17,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              YingjiIcons.rectangle_stack_fill,
              color: YingjiColors.focus,
            ),
            const SizedBox(height: 38),
            Text(
              playlist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
            ),
            const SizedBox(height: 4),
            Text(
              '${playlist.items.length} 部内容',
              style: const TextStyle(color: Color(0xFFABB1BE), fontSize: 12),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: '删除片单',
                onPressed: onDelete,
                icon: const Icon(
                  YingjiIcons.trash,
                  size: 17,
                  color: Color(0xFFFFA1A9),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ShortcutRecorder extends StatefulWidget {
  const _ShortcutRecorder({
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label, value;
  final ValueChanged<String> onChanged;

  @override
  State<_ShortcutRecorder> createState() => _ShortcutRecorderState();
}

class _ShortcutRecorderState extends State<_ShortcutRecorder> {
  final _focusNode = FocusNode();
  bool _recording = false;

  String get _displayValue => widget.value.contains('|')
      ? widget.value.split('|').skip(1).join('|')
      : widget.value;

  String _keyName(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.space) return 'Space';
    if (key == LogicalKeyboardKey.arrowLeft) return 'Arrow Left';
    if (key == LogicalKeyboardKey.arrowRight) return 'Arrow Right';
    if (key == LogicalKeyboardKey.arrowUp) return 'Arrow Up';
    if (key == LogicalKeyboardKey.arrowDown) return 'Arrow Down';
    return key.keyLabel.isEmpty ? key.debugName ?? '未知按键' : key.keyLabel;
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focusNode,
    onKeyEvent: (_, event) {
      if (!_recording || event is! KeyDownEvent) return KeyEventResult.ignored;
      final name = _keyName(event.logicalKey);
      widget.onChanged('${event.logicalKey.keyId}|$name');
      setState(() => _recording = false);
      return KeyEventResult.handled;
    },
    child: Semantics(
      button: true,
      label: '${widget.label}快捷键',
      child: YingjiMotionSurface(
        selected: _recording,
        borderRadius: 13,
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          onTap: () {
            setState(() => _recording = true);
            _focusNode.requestFocus();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: YingjiGlass.surface(strength: .72),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: YingjiGlass.line(strength: 1.35)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.label,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  _recording ? '请按下键盘按键…' : _displayValue,
                  style: TextStyle(
                    color: _recording ? Colors.white : YingjiColors.muted,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _CacheStat extends StatelessWidget {
  const _CacheStat({required this.label, required this.value});
  final String label, value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    decoration: BoxDecoration(
      color: YingjiGlass.surface(strength: .72),
      borderRadius: BorderRadius.circular(13),
      border: Border.all(color: YingjiGlass.line(strength: 1.35)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(color: YingjiColors.muted, fontSize: 12),
        ),
        const SizedBox(width: 10),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
      ],
    ),
  );
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.title,
    required this.detail,
    required this.value,
    required this.onChanged,
  });
  final String title, detail;
  final bool value;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: YingjiColors.line)),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: const TextStyle(
                    color: YingjiColors.muted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 18),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    ),
  );
}

extension on SourceKind {
  String get label => switch (this) {
    SourceKind.emby => 'Emby',
    SourceKind.jellyfin => 'Jellyfin',
    SourceKind.webdav => 'WebDAV',
  };
}
