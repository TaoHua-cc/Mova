import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/window_host.dart';
import '../platform/native_video_host.dart';
import 'playback_progress.dart';
import 'playback_segments.dart';

import '../brand.dart';
import '../motion.dart';
import '../history/watch_state_store.dart';
import '../network/proxy_routing.dart';
import 'danmaku_client.dart';
import 'dolby_vision_color.dart';
import 'native_dolby_vision.dart';
import 'subtitle_preference.dart';
import '../sources/emby_client.dart';
import '../sources/media_source.dart';
import '../sources/server_mark.dart';
import '../sources/source_store.dart';
import '../cache/danmaku_cache.dart';
import '../cache/video_cache.dart';
import '../tracking/trakt_client.dart';

const _defaultShortcuts = <String, String>{
  'playPause': 'Space',
  'seekBack': 'Arrow Left',
  'seekForward': 'Arrow Right',
  'volumeUp': 'Arrow Up',
  'volumeDown': 'Arrow Down',
  'mute': 'M',
  'fullscreen': 'F',
  'exit': 'Escape',
};

LogicalKeyboardKey _shortcutKey(String value) {
  if (value.contains('|')) {
    final keyId = int.tryParse(value.split('|').first);
    if (keyId != null) return LogicalKeyboardKey(keyId);
  }
  return switch (value) {
    'Arrow Left' => LogicalKeyboardKey.arrowLeft,
    'Arrow Right' => LogicalKeyboardKey.arrowRight,
    'Arrow Up' => LogicalKeyboardKey.arrowUp,
    'Arrow Down' => LogicalKeyboardKey.arrowDown,
    'Enter' => LogicalKeyboardKey.enter,
    'Escape' => LogicalKeyboardKey.escape,
    'Backspace' => LogicalKeyboardKey.backspace,
    'J' => LogicalKeyboardKey.keyJ,
    'K' => LogicalKeyboardKey.keyK,
    'L' => LogicalKeyboardKey.keyL,
    'A' => LogicalKeyboardKey.keyA,
    'D' => LogicalKeyboardKey.keyD,
    'W' => LogicalKeyboardKey.keyW,
    'S' => LogicalKeyboardKey.keyS,
    'M' => LogicalKeyboardKey.keyM,
    'F' => LogicalKeyboardKey.keyF,
    _ => LogicalKeyboardKey.space,
  };
}

class PlayerResourceOption {
  const PlayerResourceOption({
    required this.url,
    required this.label,
    this.headers = const {},
    this.sourceId,
    this.serverItemId,
    this.source,
    this.videoRange,
  });

  final String url;
  final String label;
  final Map<String, String> headers;
  final String? sourceId;
  final String? serverItemId;
  final MediaSource? source;
  final String? videoRange;
}

class PlayerEpisode {
  const PlayerEpisode({
    required this.url,
    this.title = '正在播放',
    this.headers = const {},
    this.initialPosition = Duration.zero,
    this.imageUrl,
    this.seriesLogoUrl,
    this.episodeTitle,
    this.resourceInfo,
    this.videoRange,
    this.sourceId,
    this.serverItemId,
    this.tmdbId,
    this.seasonNumber,
    this.episodeNumber,
    this.chapters = const [],
    this.initialAudioTrack,
    this.initialSubtitleTrack,
    this.resources = const [],
  });

  final String url;
  final String title;
  final Map<String, String> headers;
  final Duration initialPosition;
  final String? imageUrl;
  final String? seriesLogoUrl;
  final String? episodeTitle;
  final String? resourceInfo;
  final String? videoRange;
  final String? sourceId;
  final String? serverItemId;
  final int? tmdbId;
  final int? seasonNumber;
  final int? episodeNumber;
  final List<MediaChapter> chapters;
  final int? initialAudioTrack;
  final int? initialSubtitleTrack;
  final List<PlayerResourceOption> resources;

  PlayerEpisode withResource(PlayerResourceOption resource) => PlayerEpisode(
    url: resource.url,
    title: title,
    headers: resource.headers,
    initialPosition: initialPosition,
    imageUrl: imageUrl,
    seriesLogoUrl: seriesLogoUrl,
    episodeTitle: episodeTitle,
    resourceInfo: resource.label,
    videoRange: resource.videoRange,
    sourceId: resource.sourceId,
    serverItemId: resource.serverItemId,
    tmdbId: tmdbId,
    seasonNumber: seasonNumber,
    episodeNumber: episodeNumber,
    chapters: chapters,
    initialAudioTrack: initialAudioTrack,
    initialSubtitleTrack: initialSubtitleTrack,
    resources: resources,
  );

  PlayerEpisode withInitialPosition(Duration position) => PlayerEpisode(
    url: url,
    title: title,
    headers: headers,
    initialPosition: position,
    imageUrl: imageUrl,
    seriesLogoUrl: seriesLogoUrl,
    episodeTitle: episodeTitle,
    resourceInfo: resourceInfo,
    videoRange: videoRange,
    sourceId: sourceId,
    serverItemId: serverItemId,
    tmdbId: tmdbId,
    seasonNumber: seasonNumber,
    episodeNumber: episodeNumber,
    chapters: chapters,
    initialAudioTrack: initialAudioTrack,
    initialSubtitleTrack: initialSubtitleTrack,
    resources: resources,
  );
}

/// 播放器正在处理的手势类型。
enum _GestureKind {
  /// 水平滑动：快进 / 快退。
  seek,

  /// 左半屏纵向滑动：调屏幕亮度。
  brightness,

  /// 右半屏纵向滑动：调音量。
  volume,
}

/// 右侧工具按钮的声明式描述。
///
/// 声明放在 `brand.dart`（[YingjiPlayerTools]），因为设置页要拿同一份列表做
/// 排序和显隐；这里只保留别名，避免两处各写一份导致新增入口时漏改。
typedef _PlayerTool = YingjiPlayerTool;

/// 控制台工具入口，顺序即平铺顺序（实际顺序以设置页保存的为准）。
const _playerTools = YingjiPlayerTools.all;

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.url,
    this.title = '正在播放',
    this.headers = const {},
    this.initialPosition = Duration.zero,
    this.imageUrl,
    this.seriesLogoUrl,
    this.episodeTitle,
    this.resourceInfo,
    this.videoRange,
    this.sourceId,
    this.serverItemId,
    this.seasonNumber,
    this.episodeNumber,
    this.chapters = const [],
    this.initialAudioTrack,
    this.initialSubtitleTrack,
    this.episodes = const [],
  });
  final String url;
  final String title;
  final Map<String, String> headers;
  final Duration initialPosition;
  final String? imageUrl;
  final String? seriesLogoUrl;
  final String? episodeTitle;
  final String? resourceInfo;
  final String? videoRange;
  final String? sourceId;
  final String? serverItemId;
  final int? seasonNumber;
  final int? episodeNumber;
  final List<MediaChapter> chapters;
  final int? initialAudioTrack;
  final int? initialSubtitleTrack;
  final List<PlayerEpisode> episodes;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final Player _player;
  late final VideoController? _controller;
  late final FocusNode _focusNode;
  late int _activeEpisodeIndex;
  bool _showControls = true;

  /// 是否真正播过（用来决定暂停时是否显示中央播放钮）。
  bool _hasPlayed = false;
  double _volume = 100;
  double _lastAudibleVolume = 100;
  bool _muted = false;
  String? _error;
  WatchStateStore? _watchStore;
  bool _settingsOpen = false;
  bool _exitStarted = false;
  bool _switchingEpisode = false;

  /// The Emby item whose playback session has been announced to the server
  /// (PlaybackStart). Progress reports keep flowing for this item until it
  /// changes or playback ends; switching media first closes the old session
  /// (PlaybackStopped) so the server stamps a truthful LastPlayedDate on it.
  String? _reportedSessionItemId;

  /// PlaySessionId minted per announced item. Emby 400s `Sessions/Playing`
  /// and `Sessions/Playing/Progress` bodies without it ("Value cannot be
  /// null. (Parameter 'key')"), so start/progress/stop of one session must
  /// reuse the same id. The entry lives until the session is closed (or the
  /// start failed), keyed by serverItemId.
  final Map<String, String> _sessionPlayIds = {};

  /// MediaSourceId of the source actually streamed, captured from the playback
  /// URL when the session starts. Not mandatory (the server falls back to the
  /// item's default source) but sent for parity with official clients.
  final Map<String, String> _sessionMediaSourceIds = {};
  String _consoleTab = '声音';
  bool _hardware = true;
  bool _hdr = true;
  bool _downmix = false;
  bool _night = false;
  bool _voiceEnhance = false;
  bool _danmakuEnabled = false;
  String _danmakuUrl = '';
  String _activeDanmakuApi = '';
  String _matchedDanmakuEpisode = '';
  int _danmakuRequest = 0;
  bool _preferChineseSubtitle = true;
  String _subtitleLanguage = 'zh';
  bool _preferAudioTrack = false;
  String _audioLanguage = 'zh';
  bool _quickMenuOpen = false;
  bool _subtitleChosen = false;
  bool _audioChosen = false;
  StreamSubscription<Tracks>? _subtitleSubscription;
  List<String> _danmakuApis = const [];
  double _danmakuOpacity = .82;
  double _danmakuArea = .65;
  double _danmakuDensity = .55;
  double _danmakuFontSize = 18;
  double _danmakuSpeed = 1;
  bool _danmakuScroll = true, _danmakuTop = true, _danmakuBottom = true;
  List<DanmakuComment> _danmakuComments = const [];
  String? _danmakuError;
  bool _danmakuLoading = false;
  DanmakuClient? _danmakuClient;

  /// 视频缓存与弹幕缓存。拿不到目录时保持 null，播放器按「没有缓存」正常播，
  /// 只是少一层加速，不会因此打不开。
  VideoCacheStore? _videoCache;
  DanmakuCache? _danmakuCache;

  /// 正在进行的后台视频缓存任务。切集或退出必须打断：否则它既继续占带宽，
  /// 又会把下一集的地址写进同一个分片文件。
  VideoCacheDownload? _videoDownload;
  VideoCacheDownload? _nextEpisodePreload;
  StreamSubscription<VideoCacheProgress>? _videoCacheProgressSubscription;
  bool _playingCachedFile = false;
  double _persistentCacheFraction = 0;
  String? _videoCacheStatus;
  double _speed = 1;
  double _audioDelay = 0;
  double _subtitleDelay = 0;
  double _cacheSeconds = 30;
  String _aspect = '自动';
  Timer? _progressTimer;
  Timer? _controlsTimer;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Duration>? _bufferSubscription;
  Duration _lastBufferSample = Duration.zero;
  DateTime? _lastBufferSampleAt;
  double _bufferRate = 0;
  double _networkBytesPerSecond = 0;
  PlayerEpisode? _resourceOverride;
  Duration? _introEnd;
  Duration? _outroStart;
  bool _manualIntro = false;
  bool _manualOutro = false;
  List<PlaybackSegment> _segments = const [];
  String? _segmentMessage;
  bool _autoSkipSegments = true;
  double _autoSkipDelaySeconds = 5;
  bool _segmentServerSource = true;
  bool _segmentIntroDbSource = true;
  bool _segmentTheIntroDbSource = true;
  bool _segmentAniSkipSource = true;
  bool _segmentChaptersDbSource = true;
  double _seekSeconds = 10;
  double _volumeStep = 5;
  Map<String, String> _shortcuts = Map.of(_defaultShortcuts);
  bool _preloadNextEpisode = true;
  double _preloadLeadMinutes = 5;
  String? _preloadedUrl;
  Timer? _segmentTimer;
  bool _segmentActionPending = false;

  // ── 触摸手势状态（仅移动端注册拖动，见 build）────────────────────
  /// 进行中的手势类型；null 表示当前没有手势。
  _GestureKind? _gestureKind;

  /// 画面中央手势指示器的主文案（时间点 / 百分比）。
  String _gestureLabel = '';

  /// 手势指示器的图标。
  IconData _gestureIcon = Icons.brightness_6;

  /// 手势指示器的进度，0..1。
  double _gestureProgress = 0;

  /// 手势指示器的副文案（快进快退的偏移量）；为空时不显示。
  String _gestureCaption = '';

  /// 指示器当前该不该显示。手势结束只置 false 让它按统一规范淡出，
  /// 数值保留到淡出结束，免得最后一帧跳回默认值。
  bool _gestureVisible = false;

  /// 水平拖动的累计位移，用来换算快进快退的秒数。
  double _seekDragPixels = 0;

  /// 水平拖动开始时的播放位置。
  Duration _seekDragAnchor = Duration.zero;

  /// 水平拖动过程中的预览落点，松手时 seek 到它。
  Duration? _seekPreview;

  /// 垂直拖动开始时的基准值（亮度或音量的百分比）。
  double _valueDragAnchor = 0;

  /// 垂直拖动的累计位移。
  double _valueDragPixels = 0;

  /// 屏幕亮度 0..1，由宿主窗口提供。
  double _brightness = .5;

  /// 是否已从宿主读到过真实亮度，读到之前不写回宿主。
  bool _brightnessKnown = false;

  /// 移动端当前是否全屏。桌面端没有这个按钮（走窗口控制按钮），恒为 false。
  bool _mobileFullScreen = false;

  /// 上一次单击的时间，用于自实现的双击判定。
  DateTime? _lastTapAt;

  // ── 右下角工具按钮的顺序与显隐（设置页保存）────────────────────
  /// 用户排好的顺序；缺省是 [YingjiPlayerTools.all] 的声明顺序。
  List<String> _toolOrder = YingjiPlayerTools.all
      .map((tool) => tool.id)
      .toList(growable: true);

  /// 被关掉的入口 id。
  List<String> _toolHidden = <String>[];

  /// 按设置页的顺序和开关过滤后的工具列表。
  List<_PlayerTool> get _activeTools => _toolOrder
      .where((id) => !_toolHidden.contains(id))
      .map(
        (id) => _playerTools.firstWhere(
          (tool) => tool.id == id,
          orElse: () => const YingjiPlayerTool('', YingjiIcons.gear_alt),
        ),
      )
      .where((tool) => tool.id.isNotEmpty)
      .toList(growable: false);

  PlayerEpisode get _baseEpisode => widget.episodes.isEmpty
      ? PlayerEpisode(
          url: widget.url,
          title: widget.title,
          headers: widget.headers,
          initialPosition: widget.initialPosition,
          imageUrl: widget.imageUrl,
          seriesLogoUrl: widget.seriesLogoUrl,
          episodeTitle: widget.episodeTitle,
          resourceInfo: widget.resourceInfo,
          videoRange: widget.videoRange,
          sourceId: widget.sourceId,
          serverItemId: widget.serverItemId,
          seasonNumber: widget.seasonNumber,
          episodeNumber: widget.episodeNumber,
          chapters: widget.chapters,
          initialAudioTrack: widget.initialAudioTrack,
          initialSubtitleTrack: widget.initialSubtitleTrack,
        )
      : widget.episodes[_activeEpisodeIndex];

  PlayerEpisode get _activeEpisode => _resourceOverride ?? _baseEpisode;

  @override
  void initState() {
    super.initState();
    // 移动端：保持常亮 + 沉浸式 + 允许横屏（桌面端无操作）
    unawaited(WindowHost.enterMediaSession());
    // 移动端进播放器就是沉浸式全屏，右上角按钮初始画「退出全屏」。
    _mobileFullScreen = !WindowHost.isDesktop;
    // 预读一次亮度，这样左半屏第一次上下滑动是从真实基准开始，不会跳变。
    unawaited(_loadScreenBrightness());
    unawaited(_loadToolbarPreferences());
    _activeEpisodeIndex = widget.episodes.indexWhere(
      (episode) => episode.url == widget.url,
    );
    if (_activeEpisodeIndex < 0) _activeEpisodeIndex = 0;
    _player = Player(
      configuration: PlayerConfiguration(
        vo: 'gpu-next',
        osc: WindowHost.isDesktop,
        title: 'Mova',
        libass: true,
      ),
    );
    _focusNode = FocusNode(debugLabel: 'Mova 播放器快捷键');
    // The Windows native child window keeps `vo=gpu-next`. Creating a
    // VideoController would change that same Player to Flutter's `vo=libmpv`.
    _controller = WindowHost.isDesktop ? null : VideoController(_player);
    _subtitleSubscription = _player.stream.tracks.listen((tracks) {
      if (_preferAudioTrack &&
          !_audioChosen &&
          _activeEpisode.initialAudioTrack == null) {
        final audio = preferredAudioTrack(tracks.audio, _audioLanguage);
        if (audio != null) {
          _audioChosen = true;
          unawaited(_player.setAudioTrack(audio));
        }
      }
      if (!_preferChineseSubtitle ||
          _subtitleChosen ||
          _activeEpisode.initialSubtitleTrack != null)
        return;
      final track = preferredSubtitle(tracks.subtitle, _subtitleLanguage);
      if (track != null) {
        _subtitleChosen = true;
        unawaited(_player.setSubtitleTrack(track));
      }
    });
    _initializePlayer();
    _progressTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_switchingEpisode) return;
      unawaited(_syncProgress());
      unawaited(_saveWatchState());
    });
    _segmentTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      unawaited(_applySegmentSkip());
      unawaited(_preloadNextIfNeeded());
    });
    _player.stream.error.listen((value) {
      if (mounted && value.isNotEmpty) setState(() => _error = value);
    });
    _playingSubscription = _player.stream.playing.listen((playing) {
      if (!mounted || _switchingEpisode) return;
      if (playing) {
        // 至少真正播过一次，之后暂停才在画面中央显示「继续播放」；
        // 否则开片缓冲阶段也会顶着一个大播放键。
        _hasPlayed = true;
        // Playback actually started (or resumed): announce the session to the
        // server right away instead of waiting for the 30s progress timer, so
        // the row gets a truthful LastPlayedDate even for short sessions.
        unawaited(_syncProgress());
        _scheduleControlsHide();
      } else {
        _revealControls();
      }
    });
    _bufferSubscription = _player.stream.buffer.listen((buffer) async {
      final now = DateTime.now();
      final previousAt = _lastBufferSampleAt;
      if (previousAt != null) {
        final elapsed = now.difference(previousAt).inMilliseconds;
        final delta = buffer.inMilliseconds - _lastBufferSample.inMilliseconds;
        if (elapsed > 100 && delta > 0 && mounted) {
          _bufferRate = (delta / elapsed).clamp(0, 20);
          // 缓冲速率只在信息可见时才重建播放页；字段照常更新，
          // 控制条重新出现时读到的是最新值。
          if (_showControls || _settingsOpen) setState(() {});
        }
      }
      _lastBufferSample = buffer;
      _lastBufferSampleAt = now;
      await _updateNetworkSpeed();
    });
  }

  void _revealControls() {
    if (!mounted) return;
    if (!_showControls) setState(() => _showControls = true);
    _controlsTimer?.cancel();
    if (!_settingsOpen) _scheduleControlsHide();
  }

  void _scheduleControlsHide({
    Duration delay = const Duration(milliseconds: 1100),
  }) {
    _controlsTimer?.cancel();
    if (_settingsOpen || _quickMenuOpen) return;
    _controlsTimer = Timer(delay, () {
      if (mounted && !_settingsOpen && !_quickMenuOpen) {
        setState(() => _showControls = false);
      }
    });
  }

  /// 读取宿主窗口亮度；读不到就保持默认值，不写回宿主。
  Future<void> _loadScreenBrightness() async {
    final value = await WindowHost.screenBrightness;
    if (!mounted || value == null) return;
    setState(() {
      _brightness = value;
      _brightnessKnown = true;
    });
  }

  // ── 单击 / 双击 ───────────────────────────────────────────────────
  //
  // 单击呼出或收起控件，双击播放 / 暂停。
  //
  // 这里刻意不注册 GestureDetector.onDoubleTap：只要存在双击识别器，Flutter
  // 就会把单击回调推迟到双击超时（约 300ms）之后才派发，单击呼出控件会明显
  // 发滞。改为自己维护 280ms 的双击窗口，单击零延迟响应。
  void _handleTap() {
    final now = DateTime.now();
    final previous = _lastTapAt;
    final isDoubleTap =
        previous != null &&
        now.difference(previous) < const Duration(milliseconds: 280);
    _lastTapAt = isDoubleTap ? null : now;
    if (isDoubleTap) {
      unawaited(_togglePlayback());
    } else {
      _toggleControls();
    }
  }

  /// 单击：控件可见就收起，不可见就呼出；控制台面板开着时先收面板。
  void _toggleControls() {
    if (!mounted) return;
    if (_settingsOpen) {
      setState(() => _settingsOpen = false);
      return;
    }
    if (_showControls) {
      _controlsTimer?.cancel();
      setState(() => _showControls = false);
    } else {
      _revealControls();
    }
  }

  // ── 水平滑动：快进 / 快退 ─────────────────────────────────────────

  void _onSeekDragStart(DragStartDetails details) {
    _gestureKind = _GestureKind.seek;
    _gestureIcon = Icons.fast_forward;
    _seekDragPixels = 0;
    _seekDragAnchor = _player.state.position;
    _seekPreview = _seekDragAnchor;
    _gestureLabel = _time(_seekDragAnchor);
    _gestureCaption = '';
    _gestureProgress = _progressFor(_seekDragAnchor);
    _gestureVisible = true;
    // 拖动期间不要自动隐藏控件，否则指示器会跟着一起消失。
    _controlsTimer?.cancel();
    setState(() {});
  }

  void _onSeekDragUpdate(DragUpdateDetails details) {
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    _seekDragPixels += details.delta.dx;
    // 横向划过整屏 ≈ 90 秒；超过片长会被 clamp 到结尾。
    final span = _player.state.duration;
    final target = _clampPosition(
      _seekDragAnchor +
          Duration(milliseconds: (_seekDragPixels / width * 90000).round()),
      span,
    );
    _seekPreview = target;
    // 指示器箭头跟着方向走，向左拖就是快退。
    _gestureIcon = _seekDragPixels >= 0
        ? Icons.fast_forward
        : Icons.fast_rewind;
    _gestureLabel = _time(target);
    _gestureCaption = _offsetLabel(target - _seekDragAnchor);
    _gestureProgress = _progressFor(target, span);
    setState(() {});
  }

  void _onSeekDragEnd(DragEndDetails details) {
    final target = _seekPreview;
    _endGesture();
    if (target != null) unawaited(_player.seek(target));
    _revealControls();
  }

  // ── 垂直滑动：左半屏调亮度，右半屏调音量 ──────────────────────────

  void _onValueDragStart(DragStartDetails details) {
    final width = context.size?.width ?? MediaQuery.sizeOf(context).width;
    // 以按下的位置决定调节对象，和主流移动播放器一致。
    final isLeft = width <= 0 || details.localPosition.dx < width / 2;
    _gestureKind = isLeft ? _GestureKind.brightness : _GestureKind.volume;
    _gestureIcon = isLeft
        ? Icons.brightness_6
        : (_muted ? YingjiIcons.speaker_slash : Icons.volume_up);
    _valueDragPixels = 0;
    // 亮度在 initState 里读过一次；若那次失败（宿主通道未就绪等），
    // 这里补一次，避免基准值停在默认的 50%。
    if (isLeft && !_brightnessKnown) unawaited(_loadScreenBrightness());
    _valueDragAnchor = isLeft ? _brightness * 100 : _volume;
    _gestureLabel = '${_valueDragAnchor.round()}%';
    _gestureCaption = '';
    _gestureProgress = (_valueDragAnchor / 100).clamp(0.0, 1.0);
    _gestureVisible = true;
    _controlsTimer?.cancel();
    setState(() {});
  }

  void _onValueDragUpdate(DragUpdateDetails details) {
    final height = context.size?.height ?? 0;
    final kind = _gestureKind;
    if (height <= 0 ||
        (kind != _GestureKind.brightness && kind != _GestureKind.volume)) {
      return;
    }
    _valueDragPixels += details.delta.dy;
    // 向上滑（dy 为负）是调大；纵向滑满一屏约等于 100%。
    final next = (_valueDragAnchor - _valueDragPixels / height * 100).clamp(
      0.0,
      100.0,
    );
    if (kind == _GestureKind.brightness) {
      _brightness = next / 100;
      _brightnessKnown = true;
      unawaited(WindowHost.setScreenBrightness(_brightness));
    } else {
      // 拖动过程中直接改播放器音量并刷新界面，不落盘：一次滑动会触发几十次
      // 回调，逐次写 SharedPreferences 没有必要，松手时再存一次即可。
      _volume = next;
      _muted = next <= 0;
      if (next > 0) _lastAudibleVolume = next;
      unawaited(_player.setVolume(next));
      _gestureIcon = next <= 0 ? YingjiIcons.speaker_slash : Icons.volume_up;
    }
    _gestureLabel = '${next.round()}%';
    _gestureProgress = next / 100;
    setState(() {});
  }

  void _onValueDragEnd(DragEndDetails details) {
    if (_gestureKind == _GestureKind.volume) unawaited(_persistVolume());
    _endGesture();
    _revealControls();
  }

  /// 读入设置页保存的工具栏顺序与显隐。
  ///
  /// 顺序里可能夹着旧版本留下的、现在已经不存在的入口，先按 [YingjiPlayerTools]
  /// 过滤一遍，再把新加入口补到末尾 —— 这样升级后不会丢按钮，也不会渲染出空槽。
  Future<void> _loadToolbarPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final savedOrder = prefs.getStringList('yingji.player.tool-order');
    final savedHidden = prefs.getStringList('yingji.player.tool-hidden');
    if (!mounted) return;
    setState(() {
      final order = <String>[];
      for (final id in savedOrder ?? const <String>[]) {
        if (YingjiPlayerTools.contains(id) && !order.contains(id)) {
          order.add(id);
        }
      }
      for (final tool in YingjiPlayerTools.all) {
        if (!order.contains(tool.id)) order.add(tool.id);
      }
      _toolOrder = order;
      _toolHidden = (savedHidden ?? const <String>[])
          .where(YingjiPlayerTools.contains)
          .toList(growable: true);
    });
  }

  /// 移动端右上角的全屏开关。桌面端不渲染这个按钮。
  Future<void> _toggleFullScreen() async {
    final active = await WindowHost.toggleFullScreen();
    if (mounted) setState(() => _mobileFullScreen = active);
  }

  /// 手势结束后把音量落盘，下次进入播放器沿用。
  Future<void> _persistVolume() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('yingji.player.volume', _volume);
  }

  void _endGesture() {
    if (!mounted) return;
    setState(() {
      // 保留 _gestureKind 和数值：指示器要按统一规范淡出，直接清空会让它
      // 在消失的那一帧突然变成默认文案。
      _gestureVisible = false;
      _seekPreview = null;
      _seekDragPixels = 0;
      _valueDragPixels = 0;
    });
  }

  /// 把位置限制在 [0, span] 内；span 未知（直播或时长未就绪）时只挡负数。
  Duration _clampPosition(Duration value, Duration span) {
    if (value < Duration.zero) return Duration.zero;
    if (span > Duration.zero && value > span) return span;
    return value;
  }

  /// 位置在总时长里的占比；时长未知时返回中点。
  double _progressFor(Duration value, [Duration? span]) {
    final total = (span ?? _player.state.duration).inMilliseconds;
    if (total <= 0) return .5;
    return (value.inMilliseconds / total).clamp(0.0, 1.0);
  }

  /// 「+0:30」形式的相对偏移文案。
  String _offsetLabel(Duration delta) {
    final sign = delta.isNegative ? '-' : '+';
    final seconds = delta.inSeconds.abs();
    final minutes = seconds ~/ 60;
    final rest = (seconds % 60).toString().padLeft(2, '0');
    return minutes > 0 ? '$sign$minutes:$rest' : '$sign${seconds}s';
  }

  void _toggleSettings() {
    setState(() {
      _settingsOpen = !_settingsOpen;
      _showControls = true;
    });
    if (_settingsOpen) {
      _controlsTimer?.cancel();
    } else {
      _scheduleControlsHide();
    }
  }

  void _openConsoleTab(String tab) {
    setState(() {
      if (_settingsOpen && _consoleTab == tab) {
        _settingsOpen = false;
      } else {
        _consoleTab = tab;
        _settingsOpen = true;
      }
      _showControls = true;
    });
    if (_settingsOpen) {
      _controlsTimer?.cancel();
    } else {
      _scheduleControlsHide();
    }
  }

  Future<void> _updateNetworkSpeed() async {
    try {
      final raw = await (_player.platform as dynamic).getProperty(
        'cache-speed',
      );
      final bytes = double.tryParse('$raw') ?? 0;
      if (mounted && bytes >= 0) {
        _networkBytesPerSecond = bytes;
        if (_showControls || _settingsOpen) setState(() {});
      }
    } catch (_) {
      final match = RegExp(
        r'(\d+(?:\.\d+)?)\s*Mbps',
        caseSensitive: false,
      ).firstMatch(_activeEpisode.resourceInfo ?? '');
      final bitrate = double.tryParse(match?.group(1) ?? '') ?? 0;
      if (mounted && bitrate > 0 && _bufferRate > 0) {
        _networkBytesPerSecond = bitrate * _bufferRate * 1000000 / 8;
        if (_showControls || _settingsOpen) setState(() {});
      }
    }
  }

  Future<void> _initializePlayer() async {
    _watchStore = await WatchStateStore.create();
    _videoCache = await VideoCacheStore.tryCreate();
    _danmakuCache = await DanmakuCache.tryCreate();
    final prefs = await SharedPreferences.getInstance();
    _hardware = prefs.getBool('yingji.player.hardware') ?? true;
    _hdr = prefs.getBool('yingji.player.hdr') ?? true;
    _downmix = prefs.getBool('yingji.player.downmix') ?? false;
    _night = prefs.getBool('yingji.player.night') ?? false;
    _voiceEnhance = prefs.getBool('yingji.player.voice-enhance') ?? false;
    _speed = prefs.getDouble('yingji.player.speed') ?? 1;
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
    _audioLanguage = prefs.getString('yingji.player.audio-language') ?? 'zh';
    _cacheSeconds = prefs.getDouble('yingji.player.cache-seconds') ?? 30;
    _preloadNextEpisode = prefs.getBool('yingji.player.preload-next') ?? true;
    _preloadLeadMinutes =
        prefs.getDouble('yingji.player.preload-lead-minutes') ?? 5;
    _seekSeconds = prefs.getDouble('yingji.player.seek-seconds') ?? 10;
    _volumeStep = prefs.getDouble('yingji.player.volume-step') ?? 5;
    final shortcutJson = prefs.getString('yingji.player.shortcuts');
    final shortcutData = shortcutJson == null ? null : jsonDecode(shortcutJson);
    if (shortcutData is Map) {
      _shortcuts = {
        ..._defaultShortcuts,
        ...shortcutData.map((k, v) => MapEntry('$k', '$v')),
      };
    }
    _aspect = prefs.getString('yingji.player.aspect') ?? '自动';
    _volume = (prefs.getDouble('yingji.player.volume') ?? 100).clamp(0, 100);
    _muted = _volume <= 0;
    if (!_muted) _lastAudibleVolume = _volume;
    _danmakuEnabled = prefs.getBool('yingji.danmaku.enabled') ?? false;
    _danmakuUrl = prefs.getString('yingji.danmaku.url') ?? '';
    _danmakuApis = prefs.getStringList('yingji.danmaku.apis') ?? [_danmakuUrl];
    _danmakuApis = _danmakuApis
        .where((value) => value.trim().isNotEmpty)
        .toList(growable: false);
    _danmakuOpacity = prefs.getDouble('yingji.danmaku.opacity') ?? .82;
    _danmakuArea = prefs.getDouble('yingji.danmaku.area') ?? .65;
    _danmakuDensity = prefs.getDouble('yingji.danmaku.density') ?? .55;
    _danmakuFontSize = prefs.getDouble('yingji.danmaku.font-size') ?? 18;
    _danmakuSpeed = prefs.getDouble('yingji.danmaku.speed') ?? 1;
    _danmakuScroll = prefs.getBool('yingji.danmaku.scroll') ?? true;
    _danmakuTop = prefs.getBool('yingji.danmaku.top') ?? true;
    _danmakuBottom = prefs.getBool('yingji.danmaku.bottom') ?? true;
    await _loadSegmentPreferences(prefs);
    if (_danmakuEnabled && _danmakuApis.isNotEmpty) {
      unawaited(_loadDanmaku(prefs.getString('yingji.danmaku.token') ?? ''));
    }
    if (!await _attachNativeVideoHost()) return;
    await _applyMpvPreferences();
    await _openCurrentMedia();
    unawaited(_loadSegmentData());
    if (mounted) setState(() {});
  }

  Future<void> _openCurrentMedia() async {
    final episode = _activeEpisode;
    await _applyVideoPipeline(episode);
    _subtitleChosen = false;
    _audioChosen = false;
    _skipDismissed.clear();
    _skipKind = null;
    _skipTicks = 0;
    _videoDownload?.cancel();
    _videoDownload = null;
    await _videoCacheProgressSubscription?.cancel();
    _videoCacheProgressSubscription = null;
    final cached = await _videoCache?.cachedFile(episode.url);
    _playingCachedFile = cached != null;
    _persistentCacheFraction = cached == null ? 0 : 1;
    _videoCacheStatus = cached == null ? null : '已完整缓存';
    if (cached != null) {
      // 命中本机缓存：直接开本地文件。本地文件用不上鉴权头，带了反而可能
      // 让 mpv 走一次无谓的 HTTP 请求流程。这里传的是**原始绝对路径**而不是
      // `file://` URI —— 用户目录里可能有中文，`Uri.file` 会转成百分号编码，
      // mpv 在 Windows 上未必能解回正确的路径。
      await _player.open(Media(cached.path));
    } else {
      final playbackUrl = await _videoCache?.playbackUrl(
        episode.url,
        headers: episode.headers,
      );
      await _player.open(
        Media(
          playbackUrl ?? episode.url,
          httpHeaders: playbackUrl == null ? episode.headers : const {},
        ),
      );
      unawaited(_cacheCurrentEpisode(episode));
    }
    if (WindowHost.isDesktop) {
      await (_player.platform as dynamic).command(<String>[
        'script-message-to',
        'osc',
        'osc-visibility',
        'auto',
      ]);
      await (_player.platform as dynamic).command(<String>[
        'script-message-to',
        'osc',
        'osc-show',
      ]);
    }
    if (episode.initialAudioTrack != null) {
      await _setMpvProperty('aid', '${episode.initialAudioTrack! + 1}');
    }
    if (episode.initialSubtitleTrack != null) {
      await _setMpvProperty(
        'sid',
        episode.initialSubtitleTrack == -1
            ? 'no'
            : '${episode.initialSubtitleTrack! + 1}',
      );
    }
    final resume = episode.initialPosition;
    if (resume > Duration.zero) {
      // media_kit's open() resolves before mpv finishes demuxing. A seek
      // issued at that instant is silently dropped for network streams, so
      // playback would restart from 0 even though the position was persisted.
      // Wait until a real duration is reported, then restore the position.
      final target = await _awaitSeekableTarget(resume);
      if (target != null) {
        await _player.seek(target);
      }
    }
    await _player.setVolume(_volume);
  }

  Future<bool> _attachNativeVideoHost() async {
    if (!WindowHost.isDesktop) return true;
    try {
      final handle = await NativeVideoHost.create();
      if (handle == null || handle == 0) {
        throw StateError('Windows 原生视频宿主创建失败');
      }
      // Bind this existing media_kit Player before opening media. The native
      // gpu-next VO then presents straight into the Win32 child HWND. mpv's
      // Win32 contract takes the HWND as an unsigned 32-bit value even in a
      // 64-bit process; passing the sign-extended/pointer-sized representation
      // can leave audio running while the video VO never attaches.
      final mpvWindowId = handle & 0xffffffff;
      await _setRequiredMpvProperty('wid', '$mpvWindowId');
      await _setRequiredMpvProperty('vo', 'gpu-next');
      // Do not let gpu-next auto-select Vulkan/ANGLE for an embedded HWND.
      // D3D11 is mpv's native Windows presentation path and is also the path
      // used by D3D11VA hardware decoding.
      await _setRequiredMpvProperty('gpu-api', 'd3d11');
      await _setRequiredMpvProperty('gpu-context', 'd3d11');
      // media_kit initializes every Player with `vid=no` and normally changes
      // it to `auto` from VideoController. Windows deliberately has no
      // VideoController because gpu-next renders into the native HWND, so the
      // video track must be enabled here or playback is audio-only.
      await _setRequiredMpvProperty('vid', 'auto');
      // Raw HWND embedding cannot be composited with Flutter widgets. Let mpv
      // draw the playback controls in the same native surface instead.
      await _setRequiredMpvProperty('osc', 'yes');
      await _setRequiredMpvProperty('osd-level', '1');
      await _setRequiredMpvProperty('input-default-bindings', 'yes');
      await _setRequiredMpvProperty('input-vo-keyboard', 'yes');
      await _setMpvProperty(
        'script-opts',
        'osc-layout=floating,osc-floatingtitle=no,osc-floatingwidth=920,'
            'osc-floatingalpha=125,osc-windowcontrols=no,'
            'osc-tracknumberswidth=0,osc-seekbarstyle=bar,'
            'osc-seekrangestyle=bar,osc-timetotal=yes,'
            'osc-icon_style=fluent,osc-hidetimeout=1800,'
            'osc-fadeduration=180,osc-fadein=yes,osc-deadzonesize=0.82',
      );
      return true;
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Windows 原生视频输出不可用：$error');
      }
      return false;
    }
  }

  /// 后台把这一集整份存到本机，下次打开直接播本地文件。
  ///
  /// 上限为 0（比如移动数据下默认不缓存）时什么都不做；已经在缓存里的，
  /// [VideoCacheStore.download] 会立刻返回，不会重复下载一遍。
  Future<void> _cacheCurrentEpisode(PlayerEpisode episode) async {
    final store = _videoCache;
    if (store == null) return;
    final limit = await VideoCachePolicy.current();
    if (limit <= 0) return;
    final job = store.download(
      url: episode.url,
      limitBytes: limit,
      headers: episode.headers,
      title: episode.title,
    );
    _videoDownload = job;
    void update(VideoCacheProgress progress) {
      final fraction = progress.fraction;
      if (fraction != null) _persistentCacheFraction = fraction;
      _videoCacheStatus = switch (progress.status) {
        VideoCacheStatus.downloading =>
          fraction == null ? '正在缓存' : '缓存 ${(fraction * 100).round()}%',
        VideoCacheStatus.buffered => '已预读 ${VideoCachePolicy.label(limit)}',
        VideoCacheStatus.complete => '已完整缓存',
        VideoCacheStatus.unavailable => '缓存暂不可用',
        VideoCacheStatus.idle => null,
      };
      if (mounted && (_showControls || _settingsOpen)) setState(() {});
    }

    update(job.state);
    _videoCacheProgressSubscription = job.progress.listen(update);
    await job.done;
  }

  /// Waits for the media to become seekable and returns [target] clamped into
  /// the playable range. Returns null when no restore should happen, or the
  /// raw target when a stream never exposes its duration (e.g. live feeds).
  Future<Duration?> _awaitSeekableTarget(Duration target) async {
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (DateTime.now().isBefore(deadline)) {
      final duration = _player.state.duration;
      if (duration > Duration.zero) {
        final upper = duration - const Duration(seconds: 1);
        if (upper <= Duration.zero) return Duration.zero;
        return target > upper ? upper : target;
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return target;
  }

  /// Closes the player only after the final position has been persisted and
  /// reported to the media server. Pages beneath the player (episode rails,
  /// the home continue-watching shelf) refresh from those sources as soon as
  /// this route pops, so the write must complete before [Navigator.pop] —
  /// otherwise a short session would leave stale (or missing) progress.
  Future<void> _exitPlayer(BuildContext context) async {
    // Exit is async (save + server sync can take up to ~4s before the pop).
    // ESC key auto-repeat or a double-click on the back button would otherwise
    // start a second exit and pop the route *below* the player.
    if (_exitStarted) return;
    _exitStarted = true;
    await _saveWatchState();
    try {
      await _syncProgress().timeout(const Duration(seconds: 4));
    } catch (_) {
      // Best-effort server sync: the local store is already authoritative.
    }
    if (!context.mounted) return;
    Navigator.pop(context);
  }

  Future<void> _setVolume(double value) async {
    final next = value.clamp(0.0, 100.0);
    setState(() {
      _volume = next;
      _muted = next <= 0;
      if (next > 0) _lastAudibleVolume = next;
    });
    await _player.setVolume(next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('yingji.player.volume', next);
  }

  Future<void> _toggleMute() async {
    if (_muted || _volume <= 0) {
      await _setVolume(_lastAudibleVolume <= 0 ? 100 : _lastAudibleVolume);
    } else {
      _lastAudibleVolume = _volume;
      await _setVolume(0);
    }
  }

  Future<void> _adjustVolume(double delta) => _setVolume(_volume + delta);

  Future<void> _togglePlayback() async {
    _focusNode.requestFocus();
    _revealControls();
    await _player.playOrPause();
  }

  Future<void> _seekBy(Duration delta) async {
    _revealControls();
    final target = _player.state.position + delta;
    final duration = _player.state.duration;
    await _player.seek(
      target < Duration.zero
          ? Duration.zero
          : (duration > Duration.zero && target > duration ? duration : target),
    );
  }

  Future<void> _switchEpisode(
    int index, {
    bool markCurrentPlayed = false,
  }) async {
    if (_switchingEpisode ||
        index < 0 ||
        index >= widget.episodes.length ||
        index == _activeEpisodeIndex) {
      return;
    }
    _switchingEpisode = true;
    try {
      await _player.pause();
      await _saveWatchState(isPlayed: markCurrentPlayed);
      try {
        await _syncProgress(
          ending: true,
          positionOverride: markCurrentPlayed ? _player.state.duration : null,
        ).timeout(const Duration(seconds: 4));
      } catch (_) {
        // Local history is authoritative; a server timeout must not block
        // switching.
      }
      _nextEpisodePreload?.cancel();
      _nextEpisodePreload = null;
      final target = widget.episodes[index];
      final resume = await _episodeResumePosition(target);
      if (!mounted || _exitStarted) return;
      setState(() {
        _activeEpisodeIndex = index;
        _resourceOverride = target.withInitialPosition(resume);
        _error = null;
        _danmakuComments = const [];
        _danmakuError = null;
      });
      _preloadedUrl = null;
      await _loadSegmentPreferences(await SharedPreferences.getInstance());
      await _openCurrentMedia();
      unawaited(_loadSegmentData());
      if (_danmakuEnabled && _danmakuApis.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        unawaited(_loadDanmaku(prefs.getString('yingji.danmaku.token') ?? ''));
      }
      _revealControls();
    } finally {
      _switchingEpisode = false;
    }
  }

  Future<void> _preloadNextIfNeeded() async {
    if (!_preloadNextEpisode ||
        _switchingEpisode ||
        widget.episodes.isEmpty ||
        _activeEpisodeIndex >= widget.episodes.length - 1) {
      return;
    }
    final duration = _player.state.duration;
    final position = _player.state.position;
    if (duration <= Duration.zero ||
        duration - position > Duration(minutes: _preloadLeadMinutes.round())) {
      return;
    }
    final next = widget.episodes[_activeEpisodeIndex + 1];
    if (_preloadedUrl == next.url) return;
    _preloadedUrl = next.url;
    final uri = Uri.tryParse(next.url);
    if (uri == null || !['http', 'https'].contains(uri.scheme)) return;
    final store = _videoCache;
    if (store == null) return;
    final limit = await VideoCachePolicy.current();
    if (limit <= 0) return;
    final job = store.download(
      url: next.url,
      limitBytes: limit,
      targetBytes: VideoCachePolicy.nextEpisodePreheatBytes,
      headers: next.headers,
      title: next.title,
    );
    _nextEpisodePreload = job;
    await job.done;
    if (job.state.status == VideoCacheStatus.unavailable) {
      _preloadedUrl = null;
    }
  }

  Future<Duration> _episodeResumePosition(PlayerEpisode episode) async {
    final store = _watchStore ?? await WatchStateStore.create();
    final local = store
        .load()
        .where(
          (row) =>
              row.mediaId == episode.url ||
              (episode.sourceId != null &&
                  episode.serverItemId != null &&
                  row.sourceId == episode.sourceId &&
                  row.serverItemId == episode.serverItemId) ||
              (episode.tmdbId != null &&
                  episode.tmdbId! > 0 &&
                  episode.seasonNumber != null &&
                  episode.episodeNumber != null &&
                  row.tmdbId == episode.tmdbId &&
                  row.seasonNumber == episode.seasonNumber &&
                  row.episodeNumber == episode.episodeNumber),
        )
        .firstOrNull;
    var position = local?.position ?? episode.initialPosition;
    if (episode.sourceId == null || episode.serverItemId == null)
      return position;
    EmbyClient? client;
    try {
      final sources = await SourceStore.create();
      final source = sources
          .load()
          .where((s) => s.id == episode.sourceId)
          .firstOrNull;
      if (source == null || source.kind == SourceKind.webdav) return position;
      final token = sources.tokenFor(source);
      if (token == null || token.isEmpty) return position;
      client = EmbyClient(proxy: ProxyRouting.serverUsesProxy(source.id));
      final remote = await client
          .itemById(
            EmbySession(source: source, token: token),
            episode.serverItemId!,
          )
          .timeout(const Duration(seconds: 3));
      if (remote.playbackPosition != null &&
          (local == null ||
              (remote.lastPlayedAt != null &&
                  (local.updatedAt == null ||
                      remote.lastPlayedAt!.isAfter(local.updatedAt!))))) {
        position = remote.playbackPosition!;
      }
    } catch (_) {
      // Offline switching still resumes the latest saved local position.
    } finally {
      client?.dispose();
    }
    return position;
  }

  String get _segmentKey {
    final episode = _baseEpisode;
    return '${episode.title}.${episode.seasonNumber ?? 1}';
  }

  PlaybackSegmentQuery get _activeSegmentQuery => PlaybackSegmentQuery(
    tmdbId: _activeEpisode.tmdbId,
    seasonNumber: _activeEpisode.seasonNumber,
    episodeNumber: _activeEpisode.episodeNumber,
    sourceId: _activeEpisode.sourceId,
    serverItemId: _activeEpisode.serverItemId,
  );

  Future<void> _loadSegmentPreferences(SharedPreferences prefs) async {
    final prefix = playbackSegmentPreferencePrefix(_activeSegmentQuery);
    final manualIntro = prefix == null ? null : prefs.getInt('$prefix.intro');
    final manualOutro = prefix == null ? null : prefs.getInt('$prefix.outro');
    final intro =
        manualIntro ?? prefs.getInt('yingji.segment.$_segmentKey.intro');
    final outro =
        manualOutro ?? prefs.getInt('yingji.segment.$_segmentKey.outro');
    if (!mounted) return;
    setState(() {
      _introEnd = intro == null ? null : Duration(milliseconds: intro);
      _outroStart = outro == null ? null : Duration(milliseconds: outro);
      _manualIntro = manualIntro != null;
      _manualOutro = manualOutro != null;
      _autoSkipSegments =
          prefs.getBool('yingji.segment.$_segmentKey.enabled') ??
          prefs.getBool('yingji.segment.auto-skip') ??
          true;
      _autoSkipDelaySeconds =
          prefs.getDouble('yingji.segment.skip-delay-seconds') ?? 5;
      _segmentServerSource =
          prefs.getBool('yingji.segment.source-server') ?? true;
      _segmentIntroDbSource =
          prefs.getBool('yingji.segment.source-introdb') ?? true;
      _segmentTheIntroDbSource =
          prefs.getBool('yingji.segment.source-theintrodb') ?? true;
      _segmentAniSkipSource =
          prefs.getBool('yingji.segment.source-aniskip') ?? true;
      _segmentChaptersDbSource =
          prefs.getBool('yingji.segment.source-chaptersdb') ?? true;
    });
  }

  Future<void> _loadSegmentData() async {
    final episode = _activeEpisode;
    // 片头片尾的取数逻辑与 Windows 原生播放器共用一份（playback_segments.dart）：
    // 两条链路读同一批来源开关，设置里关掉哪个来源就都不会去查。
    final result = await loadPlaybackSegments(
      PlaybackSegmentQuery(
        tmdbId: episode.tmdbId,
        seasonNumber: episode.seasonNumber,
        episodeNumber: episode.episodeNumber,
        sourceId: episode.sourceId,
        serverItemId: episode.serverItemId,
        duration: _player.state.duration,
        chapters: episode.chapters,
        sources: SegmentSourceSettings(
          server: _segmentServerSource,
          introDb: _segmentIntroDbSource,
          theIntroDb: _segmentTheIntroDbSource,
          aniSkip: _segmentAniSkipSource,
          chaptersDb: _segmentChaptersDbSource,
        ),
      ),
    );
    if (!mounted) return;
    final segments = result.segments;
    final intro = segments
        .where((item) => item.type == PlaybackSegmentType.intro)
        .firstOrNull;
    final credits = segments
        .where((item) => item.type == PlaybackSegmentType.credits)
        .firstOrNull;
    setState(() {
      _segments = segments;
      _segmentMessage = result.message;
      _introEnd ??= intro?.end;
      _outroStart ??= credits?.start;
    });
  }

  Future<void> _setSegment({required bool intro}) async {
    // A manual mark intentionally overrides any provider data for this title.
    final value = _player.state.position;
    final prefs = await SharedPreferences.getInstance();
    final prefix = playbackSegmentPreferencePrefix(_activeSegmentQuery);
    if (prefix == null) return;
    await prefs.setInt(
      '$prefix.${intro ? 'intro' : 'outro'}',
      value.inMilliseconds,
    );
    if (!mounted) return;
    setState(() {
      if (intro) {
        _introEnd = value;
        _manualIntro = true;
      } else {
        _outroStart = value;
        _manualOutro = true;
      }
    });
  }

  Future<void> _clearSegment({required bool intro}) async {
    final prefix = playbackSegmentPreferencePrefix(_activeSegmentQuery);
    if (prefix == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$prefix.${intro ? 'intro' : 'outro'}');
    if (!mounted) return;
    setState(() {
      if (intro) {
        _introEnd = null;
        _manualIntro = false;
      } else {
        _outroStart = null;
        _manualOutro = false;
      }
    });
    await _loadSegmentData();
  }

  String? _skipKind;
  int _skipTicks = 0;
  final Set<String> _skipDismissed = {};

  String? get _currentSkipKind {
    final position = _player.state.position;
    if (_introEnd != null &&
        position > Duration.zero &&
        position < _introEnd!) {
      final starts = _segments.where(
        (s) => s.type == PlaybackSegmentType.intro,
      );
      if (starts.isEmpty || position >= starts.first.start) return 'intro';
    }
    if (_outroStart != null &&
        position >= _outroStart! &&
        _player.state.duration > position)
      return 'outro';
    return null;
  }

  Future<void> _applySegmentSkip() async {
    if (!mounted || _switchingEpisode || _segmentActionPending) return;
    final kind = _currentSkipKind;
    if (kind != _skipKind) {
      setState(() {
        _skipKind = kind;
        _skipTicks = 0;
      });
    }
    if (kind == null ||
        _skipDismissed.contains(kind) ||
        !_autoSkipSegments ||
        !_player.state.playing ||
        _player.state.buffering)
      return;
    setState(() => _skipTicks++);
    if (_skipTicks >= (_autoSkipDelaySeconds * 2).round()) {
      await _performSegmentSkip();
    }
  }

  Future<void> _performSegmentSkip() async {
    final kind = _currentSkipKind;
    if (kind == null || _segmentActionPending) return;
    _segmentActionPending = true;
    _skipDismissed.add(kind);
    try {
      if (kind == 'intro') {
        await _player.seek(_introEnd!);
      } else if (widget.episodes.isNotEmpty &&
          _activeEpisodeIndex < widget.episodes.length - 1) {
        await _switchEpisode(_activeEpisodeIndex + 1, markCurrentPlayed: true);
      } else {
        await _player.seek(_player.state.duration);
      }
    } finally {
      _segmentActionPending = false;
      if (mounted) setState(() => _skipKind = null);
    }
  }

  Widget _segmentPrompt() => AnimatedPositioned(
    right: 28,
    bottom: _showControls ? 170 : 32,
    duration: MovaMotion.standard,
    curve: MovaMotion.standardEase,
    child: MovaAppear(
      beginScale: .94,
      slide: .06,
      duration: MovaMotion.standard,
      child: GlassPanel(
        radius: 16,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _skipKind == 'intro'
                  ? '片头 · 跳转至 ${_time(_introEnd!)}'
                  : '片尾 · ${_activeEpisodeIndex < widget.episodes.length - 1 ? '播放下一集' : '跳转至结尾'}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (_autoSkipSegments) ...[
              const SizedBox(height: 6),
              Text(
                '${((10 - _skipTicks) / 2).ceil().clamp(0, 5)} 秒后自动跳过',
                style: const TextStyle(fontSize: 12, color: YingjiColors.muted),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: 224,
                child: LinearProgressIndicator(
                  value: (_skipTicks / 10).clamp(0, 1),
                ),
              ),
            ],
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                MovaPress(
                  scale: .94,
                  visualOnly: true,
                  child: TextButton.icon(
                    onPressed: _performSegmentSkip,
                    icon: const Icon(YingjiIcons.chevron_right, size: 16),
                    label: const Text('立即跳过'),
                  ),
                ),
                MovaPress(
                  scale: .94,
                  visualOnly: true,
                  child: TextButton(
                    onPressed: () => setState(() {
                      if (_skipKind != null) _skipDismissed.add(_skipKind!);
                    }),
                    child: const Text('本次不跳过'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _switchResource(PlayerResourceOption resource) async {
    if (resource.url == _activeEpisode.url) return;
    final position = _player.state.position;
    await _saveWatchState();
    setState(() {
      _resourceOverride = _baseEpisode
          .withResource(resource)
          .withInitialPosition(position);
      _error = null;
    });
    await _openCurrentMedia();
  }

  Future<void> _showEpisodeList() async {
    if (widget.episodes.isEmpty) return;
    _openConsoleTab('全集');
  }

  /// 读取弹幕：先用本机缓存铺上，再按需要后台刷新。
  ///
  /// 弹幕接口每次播放都要跑一次匹配（有的还要先 match 再取评论），同一集看
  /// 第二遍时这一步纯属浪费。缓存命中就立刻显示，只有超过
  /// [DanmakuCache.refreshAfter] 才走网络；网络失败而手里有缓存时继续用缓存
  /// 且不报错 —— 用户看到的是「弹幕稍旧」，不是「弹幕加载失败」。
  Future<void> _loadDanmaku(String token, {bool forceRefresh = false}) async {
    final request = ++_danmakuRequest;
    _activeDanmakuApi = '';
    _danmakuClient?.dispose();
    if (mounted) {
      setState(() {
        _danmakuLoading = true;
        _danmakuError = null;
      });
    }
    final apis = _danmakuApis.isEmpty ? [_danmakuUrl] : _danmakuApis;
    final cache = _danmakuCache;
    final cacheKey = DanmakuCache.keyFor(
      apis: apis,
      title: _activeEpisode.title,
      season: _activeEpisode.seasonNumber,
      episode: _activeEpisode.episodeNumber,
    );
    final cached = cache == null ? null : await cache.read(cacheKey);
    if (cached != null && cached.comments.isNotEmpty) {
      if (!mounted || request != _danmakuRequest) return;
      setState(() {
        _danmakuComments = cached.comments;
        _matchedDanmakuEpisode =
            '${cached.matchedEpisode ?? '接口未提供匹配名称'} · 本机缓存';
        _danmakuError = null;
      });
      if (!cached.isStale && !forceRefresh) {
        if (mounted && request == _danmakuRequest) {
          setState(() => _danmakuLoading = false);
        }
        return;
      }
    }
    final clients = <DanmakuClient>[];
    final clientsByApi = <String, DanmakuClient>{};
    try {
      final futures = apis
          .map((api) {
            final client = DanmakuClient();
            clientsByApi[api] = client;
            clients.add(client);
            return client
                .fetch(
                  template: api,
                  title: _activeEpisode.title,
                  season: _activeEpisode.seasonNumber,
                  episode: _activeEpisode.episodeNumber,
                  mediaUrl: _activeEpisode.url,
                  token: token,
                )
                .then((comments) => (api, comments));
          })
          .toList(growable: false);
      final comments = await _firstDanmakuResult(futures);
      if (comments.$2.isEmpty) {
        throw StateError('没有找到匹配的弹幕');
      }
      final source = clientsByApi[comments.$1];
      if (mounted && request == _danmakuRequest) {
        setState(() {
          _activeDanmakuApi =
              source?.commentEndpoint?.toString() ?? comments.$1;
          _matchedDanmakuEpisode = source?.matchedEpisode ?? '接口未提供匹配名称';
          _danmakuComments = comments.$2;
          _danmakuError = null;
        });
      }
      await cache?.write(
        cacheKey,
        comments.$2,
        matchedEpisode: source?.matchedEpisode,
      );
    } catch (error) {
      if (cached != null && cached.comments.isNotEmpty && !forceRefresh) return;
      if (mounted && request == _danmakuRequest) {
        setState(
          () =>
              _danmakuError = error.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      for (final client in clients) client.dispose();
      if (mounted && request == _danmakuRequest) {
        setState(() => _danmakuLoading = false);
      }
    }
  }

  String get _displayDanmakuApi {
    final uri = Uri.tryParse(_activeDanmakuApi);
    if (uri == null) return '地址格式无效';
    return uri.replace(userInfo: '', query: '', fragment: '').toString();
  }

  Future<(String, List<DanmakuComment>)> _firstDanmakuResult(
    List<Future<(String, List<DanmakuComment>)>> futures,
  ) async {
    if (futures.isEmpty) return ('', const <DanmakuComment>[]);
    final completer = Completer<(String, List<DanmakuComment>)>();
    var remaining = futures.length;
    Object? lastError;
    var sawEmptyResult = false;
    for (final future in futures) {
      future
          .then((value) {
            remaining--;
            // A fast but empty endpoint must not hide a slower endpoint that
            // actually has comments for this episode.
            if (value.$2.isNotEmpty && !completer.isCompleted) {
              completer.complete(value);
            } else {
              sawEmptyResult = true;
              if (remaining == 0 && !completer.isCompleted) {
                completer.complete(('', const <DanmakuComment>[]));
              }
            }
          })
          .catchError((Object error) {
            lastError = error;
            remaining--;
            if (remaining == 0 && !completer.isCompleted) {
              if (sawEmptyResult) {
                completer.complete(('', const <DanmakuComment>[]));
              } else {
                completer.completeError(lastError!);
              }
            }
          });
    }
    return completer.future;
  }

  Future<void> _applyMpvPreferences() async {
    await _applyVideoPipeline(_activeEpisode);
    await _setMpvProperty('audio-channels', _downmix ? 'stereo' : 'auto');
    await _applyAudioFilters();
    await _setMpvProperty('audio-delay', _audioDelay.toString());
    await _setMpvProperty('sub-delay', _subtitleDelay.toString());
    await _setMpvProperty('demuxer-readahead-secs', _cacheSeconds.toString());
    await _setMpvProperty('video-aspect-override', switch (_aspect) {
      '16:9' => '1.7777778',
      '4:3' => '1.3333333',
      '21:9' => '2.3333333',
      _ => '0',
    });
    await _player.setRate(_speed);
  }

  Future<void> _applyColorPipeline(bool enabled) async {
    // gpu-next/libplacebo parses Dolby Vision RPU metadata and reshapes
    // Profile 5/7/8 to the actual HDR10 or SDR display target.
    for (final property in playerColorProperties(hdrEnabled: enabled).entries) {
      await _setMpvProperty(property.key, property.value);
    }
  }

  Future<void> _applyVideoPipeline(PlayerEpisode episode) async {
    final dolbyVision = NativeDolbyVisionPlayer.isDolbyVision(
      episode.videoRange,
    );
    await _setMpvProperty(
      'hwdec',
      playerHwdecValue(enabled: _hardware, dolbyVision: dolbyVision),
    );
    await _applyColorPipeline(_hdr || dolbyVision);
  }

  Future<void> _setMpvProperty(String name, String value) async {
    try {
      await (_player.platform as dynamic).setProperty(name, value);
    } catch (_) {
      // Keep playback available on libmpv builds without an optional property.
    }
  }

  Future<void> _setRequiredMpvProperty(String name, String value) async {
    await (_player.platform as dynamic).setProperty(name, value);
  }

  Future<void> _setAudioPreference({bool? downmix, bool? night}) async {
    final prefs = await SharedPreferences.getInstance();
    if (downmix != null) {
      _downmix = downmix;
      await prefs.setBool('yingji.player.downmix', downmix);
      await _setMpvProperty('audio-channels', downmix ? 'stereo' : 'auto');
    }
    if (night != null) {
      _night = night;
      await prefs.setBool('yingji.player.night', night);
    }
    await _applyAudioFilters();
    if (mounted) setState(() {});
  }

  Future<void> _setVoiceEnhance(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    _voiceEnhance = value;
    await prefs.setBool('yingji.player.voice-enhance', value);
    await _applyAudioFilters();
    if (mounted) setState(() {});
  }

  Future<void> _applyAudioFilters() {
    final filters = <String>[];
    if (_voiceEnhance) filters.add('equalizer=f=1800:t=q:w=1.2:g=4');
    if (_night) filters.add('dynaudnorm');
    return _setMpvProperty(
      'af',
      filters.isEmpty ? '' : 'lavfi=[${filters.join(',')}]',
    );
  }

  Future<void> _setPlaybackSpeed(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await _player.setRate(value);
    await prefs.setDouble('yingji.player.speed', value);
    if (mounted) setState(() => _speed = value);
  }

  Future<void> _setDelay({double? audio, double? subtitle}) async {
    final prefs = await SharedPreferences.getInstance();
    if (audio != null) {
      await _setMpvProperty('audio-delay', audio.toString());
      await prefs.setDouble('yingji.player.audio-delay', audio);
      _audioDelay = audio;
    }
    if (subtitle != null) {
      await _setMpvProperty('sub-delay', subtitle.toString());
      await prefs.setDouble('yingji.player.subtitle-delay', subtitle);
      _subtitleDelay = subtitle;
    }
    if (mounted) setState(() {});
  }

  Future<void> _setCacheSeconds(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await _setMpvProperty('demuxer-readahead-secs', value.toString());
    await prefs.setDouble('yingji.player.cache-seconds', value);
    if (mounted) setState(() => _cacheSeconds = value);
  }

  Future<void> _setVideoPreference({bool? hardware, bool? hdr}) async {
    final prefs = await SharedPreferences.getInstance();
    if (hardware != null) {
      await _setMpvProperty(
        'hwdec',
        playerHwdecValue(
          enabled: hardware,
          dolbyVision: NativeDolbyVisionPlayer.isDolbyVision(
            _activeEpisode.videoRange,
          ),
        ),
      );
      await prefs.setBool('yingji.player.hardware', hardware);
      _hardware = hardware;
    }
    if (hdr != null) {
      await _applyColorPipeline(hdr);
      await prefs.setBool('yingji.player.hdr', hdr);
      _hdr = hdr;
    }
    if (mounted) setState(() {});
  }

  Future<void> _setAspect(String value) async {
    const aspectValues = <String, String>{
      '自动': '0',
      '16:9': '1.7777778',
      '4:3': '1.3333333',
      '21:9': '2.3333333',
    };
    await _setMpvProperty('video-aspect-override', aspectValues[value] ?? '0');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('yingji.player.aspect', value);
    if (mounted) setState(() => _aspect = value);
  }

  Future<void> _copyDiagnostics() async {
    final diagnostics = <String>[
      'Mova 播放诊断',
      '标题: ${_activeEpisode.title}',
      '内核: libmpv / gpu-next',
      '硬件解码: ${_hardware ? (WindowHost.isDesktop ? 'D3D11VA' : 'MediaCodec') : '关闭'}',
      'HDR: ${_hdr ? '自动' : '关闭'}',
      '播放速度: ${_speed.toStringAsFixed(2)}x',
      '状态: ${_error ?? '正常'}',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: diagnostics));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('播放诊断已复制到剪贴板')));
    }
  }

  @override
  void dispose() {
    // 移动端：关闭常亮、恢复系统栏与竖屏（桌面端无操作）
    unawaited(WindowHost.exitMediaSession());
    _subtitleSubscription?.cancel();
    _videoDownload?.cancel();
    _videoDownload = null;
    _nextEpisodePreload?.cancel();
    _nextEpisodePreload = null;
    _videoCacheProgressSubscription?.cancel();
    _danmakuRequest++;
    unawaited(_syncProgress(syncTrakt: true, ending: true));
    unawaited(_saveWatchState());
    _progressTimer?.cancel();
    _segmentTimer?.cancel();
    _controlsTimer?.cancel();
    _playingSubscription?.cancel();
    _bufferSubscription?.cancel();
    _focusNode.dispose();
    _danmakuClient?.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _saveWatchState({bool isPlayed = false}) async {
    final store = _watchStore;
    if (store == null) return;
    final state = _player.state;
    if (state.duration <= Duration.zero) return;
    await store.save(
      // 与原生播放器的保存循环同一套清洗：集名与剧名同名/通用集名时清空，
      // 避免副标题出现「S1E2 · 叛逆的女仆」这类自我重复。
      normalizeWatchState(
        WatchState(
          mediaId: _activeEpisode.url,
          title: _activeEpisode.title,
          position: state.position,
          duration: state.duration,
          imageUrl: _activeEpisode.imageUrl,
          sourceId: _activeEpisode.sourceId,
          serverItemId: _activeEpisode.serverItemId,
          tmdbId: _activeEpisode.tmdbId,
          episodeTitle: _activeEpisode.episodeTitle,
          seasonNumber: _activeEpisode.seasonNumber,
          episodeNumber: _activeEpisode.episodeNumber,
          isPlayed: isPlayed,
        ),
      ),
    );
  }

  /// Mints a fresh UUIDv4 for a playback session (RFC 4122 layout). Emby keys
  /// `Sessions/Playing` reports by this id: verified against a real server
  /// that start/progress bodies without it return 400.
  String _newPlaySessionId() {
    final rng = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
    String hex(int value) => value.toRadixString(16).padLeft(2, '0');
    final h = bytes.map(hex).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  /// The media source actually being streamed is embedded in the playback URL
  /// (`Videos/<id>/stream?…&MediaSourceId=<source>…`), which is exactly the
  /// source the server must associate this playback session with.
  String? _mediaSourceIdOf(PlayerEpisode episode) {
    final value = Uri.tryParse(episode.url)?.queryParameters['MediaSourceId'];
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Reports the current playback position to the media server. Besides the
  /// periodic progress ping it drives the Emby session lifecycle:
  ///  - first sighting of an item -> PlaybackStart (and closes the previous
  ///    item's session, so an in-page episode switch still ends the old row);
  ///  - [ending] (exit/switch)    -> PlaybackStopped with the final position.
  /// Emby only stamps `LastPlayedDate` from those start/stop reports, so
  /// without them every resume row stays undated and the server's
  /// "continue watching" order degrades to an arbitrary one. Each session
  /// carries a stable PlaySessionId; the server 400s reports that omit it.
  Future<void> _syncProgress({
    bool syncTrakt = false,
    bool ending = false,
    Duration? positionOverride,
  }) async {
    // 「观看记录只保存在本机」时不向媒体服务器与 Trakt 上报任何进度。
    // 本机记录由 _saveWatchState 照常写入，服务器资源也照常播放；读取
    // （服务器继续观看、Trakt 已看）同样不受影响 —— 这里只停回写。
    if (await WatchStateStore.localOnly()) return;
    // Capture the episode and position up-front: the async hops below (source
    // lookup, HTTP) can race an in-page episode switch, and the stop for the
    // *old* item must never target the *new* one.
    final episode = _activeEpisode;
    final position = positionOverride ?? _player.state.position;
    final duration = _player.state.duration;
    if (duration <= Duration.zero) return;
    final sourceId = episode.sourceId;
    final itemId = episode.serverItemId;
    if (sourceId != null &&
        sourceId.isNotEmpty &&
        itemId != null &&
        itemId.isNotEmpty) {
      try {
        final store = await SourceStore.create();
        final matches = store
            .load()
            .where((value) => value.id == sourceId)
            .toList();
        if (matches.isNotEmpty) {
          final source = matches.first;
          if (source.kind != SourceKind.webdav) {
            final token = store.tokenFor(source);
            if (token != null && token.isNotEmpty) {
              final client = EmbyClient(
                proxy: ProxyRouting.serverUsesProxy(source.id),
              );
              try {
                final session = EmbySession(source: source, token: token);
                if (ending) {
                  // Leaving this item (page exit or episode switch): close the
                  // session so the server records the true last-played time.
                  if (_reportedSessionItemId == itemId) {
                    _reportedSessionItemId = null;
                    await client.stopSession(
                      session: session,
                      itemId: itemId,
                      position: position,
                      duration: duration,
                      playSessionId: _sessionPlayIds.remove(itemId),
                      mediaSourceId: _sessionMediaSourceIds.remove(itemId),
                    );
                  }
                } else {
                  // A session must be announced (PlaybackStart) before any
                  // progress ping, and every report needs the session id. The
                  // marker is claimed before the network hops so two
                  // overlapping calls cannot both announce the same item.
                  final needsStart =
                      _reportedSessionItemId != itemId ||
                      !_sessionPlayIds.containsKey(itemId);
                  if (needsStart) {
                    final previous = _reportedSessionItemId;
                    _reportedSessionItemId = itemId;
                    final playSessionId = _newPlaySessionId();
                    final mediaSourceId = _mediaSourceIdOf(episode);
                    _sessionPlayIds[itemId] = playSessionId;
                    if (mediaSourceId != null) {
                      _sessionMediaSourceIds[itemId] = mediaSourceId;
                    }
                    if (previous != null) {
                      try {
                        await client.stopSession(
                          session: session,
                          itemId: previous,
                          position: position,
                          duration: duration,
                          playSessionId: _sessionPlayIds.remove(previous),
                          mediaSourceId: _sessionMediaSourceIds.remove(
                            previous,
                          ),
                        );
                      } catch (_) {
                        // The previous item may belong to another source.
                      }
                    }
                    try {
                      await client.startSession(
                        session: session,
                        itemId: itemId,
                        position: position,
                        duration: duration,
                        isPaused: !_player.state.playing,
                        playSessionId: playSessionId,
                        mediaSourceId: mediaSourceId,
                      );
                    } catch (_) {
                      // A failed start must not leave a session id behind that
                      // a later report would send to a session that never
                      // began (the marker stays, so the next ping retries).
                      _sessionPlayIds.remove(itemId);
                      _sessionMediaSourceIds.remove(itemId);
                      rethrow;
                    }
                  } else {
                    await client.reportProgress(
                      session: session,
                      itemId: itemId,
                      position: position,
                      duration: duration,
                      isPaused: !_player.state.playing,
                      playSessionId: _sessionPlayIds[itemId],
                      mediaSourceId: _mediaSourceIdOf(episode),
                    );
                  }
                }
              } finally {
                client.dispose();
              }
            }
          }
        }
      } catch (_) {
        // Server sync must never interrupt local playback or shutdown.
      }
    }
    if (!syncTrakt ||
        episode.tmdbId == null ||
        episode.seasonNumber == null ||
        episode.episodeNumber == null) {
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final clientId = prefs.getString('yingji.trakt.client-id') ?? '';
      final token = prefs.getString('yingji.trakt.access-token') ?? '';
      if (clientId.isEmpty || token.isEmpty) return;
      final trakt = TraktClient();
      try {
        await trakt.scrobbleProgress(
          clientId: clientId,
          accessToken: token,
          tmdbId: episode.tmdbId!,
          season: episode.seasonNumber!,
          episode: episode.episodeNumber!,
          position: position,
          duration: duration,
          paused: false,
        );
      } finally {
        trakt.dispose();
      }
    } catch (_) {
      // Trakt is optional; local and server progress remain authoritative.
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      SingleActivator(_shortcutKey(_shortcuts['exit']!)): () async {
        if (_settingsOpen) {
          setState(() => _settingsOpen = false);
          return;
        }
        // 桌面端全屏时，Esc 先退回窗口、不退出播放，再按一次才关掉播放。
        // 否则全屏看片时手一抖按到 Esc，整段播放就直接结束了。
        if (WindowHost.isDesktop && await WindowHost.isFullScreen()) {
          await WindowHost.setFullScreen(false);
          return;
        }
        await _exitPlayer(context);
      },
      SingleActivator(_shortcutKey(_shortcuts['playPause']!)): _togglePlayback,
      SingleActivator(_shortcutKey(_shortcuts['seekBack']!)): () =>
          _seekBy(Duration(seconds: -_seekSeconds.round())),
      SingleActivator(_shortcutKey(_shortcuts['seekForward']!)): () =>
          _seekBy(Duration(seconds: _seekSeconds.round())),
      SingleActivator(_shortcutKey(_shortcuts['volumeUp']!)): () =>
          _adjustVolume(_volumeStep),
      SingleActivator(_shortcutKey(_shortcuts['volumeDown']!)): () =>
          _adjustVolume(-_volumeStep),
      SingleActivator(_shortcutKey(_shortcuts['mute']!)): _toggleMute,
      SingleActivator(_shortcutKey(_shortcuts['fullscreen']!)): () async {
        await WindowHost.toggleFullScreen();
      },
    },
    child: Focus(
      focusNode: _focusNode,
      autofocus: true,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: MouseRegion(
          onEnter: (_) => _revealControls(),
          onHover: (_) => _revealControls(),
          onExit: (_) =>
              _scheduleControlsHide(delay: const Duration(milliseconds: 250)),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            // 单击呼出控件、双击播放 / 暂停，见 _handleTap。
            onTap: _handleTap,
            // 拖动调参只在移动端注册：桌面端用鼠标拖拽会误触亮度和音量，
            // 而桌面本来就有方向键、滚轮和控件按钮可用。
            onHorizontalDragStart: WindowHost.isDesktop
                ? null
                : _onSeekDragStart,
            onHorizontalDragUpdate: WindowHost.isDesktop
                ? null
                : _onSeekDragUpdate,
            onHorizontalDragEnd: WindowHost.isDesktop ? null : _onSeekDragEnd,
            onVerticalDragStart: WindowHost.isDesktop
                ? null
                : _onValueDragStart,
            onVerticalDragUpdate: WindowHost.isDesktop
                ? null
                : _onValueDragUpdate,
            onVerticalDragEnd: WindowHost.isDesktop ? null : _onValueDragEnd,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 视频层不再自带手势：整屏手势（单击、双击、左右滑动快进
                // 快退、左半屏调亮度、右半屏调音量）统一由外层
                // GestureDetector 处理。内层再挂一个 TapGestureRecognizer
                // 会先赢得手势竞技场，把外层的手势全部吃掉。
                //
                // media_kit 自带的原生控制条也必须关掉，否则折叠模式下
                // 会多出一条原生控制栏。
                if (WindowHost.isDesktop)
                  NativeVideoSurface(
                    visible:
                        !_settingsOpen &&
                        _error == null &&
                        _skipKind == null &&
                        !_gestureVisible,
                  )
                else
                  Video(
                    controller: _controller!,
                    fit: BoxFit.contain,
                    controls: NoVideoControls,
                  ),
                if (_danmakuComments.isNotEmpty)
                  Positioned.fill(
                    child: _DanmakuOverlay(
                      positionStream: _player.stream.position,
                      comments: _danmakuComments,
                      opacity: _danmakuOpacity,
                      area: _danmakuArea,
                      density: _danmakuDensity,
                      fontSize: _danmakuFontSize,
                      speed: _danmakuSpeed,
                      showScroll: _danmakuScroll,
                      showTop: _danmakuTop,
                      showBottom: _danmakuBottom,
                    ),
                  ),
                if (_error != null)
                  Center(
                    child: GlassPanel(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            YingjiIcons.exclamationmark_triangle,
                            color: Color(0xffff9b9b),
                            size: 30,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            '播放失败',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 480),
                            child: Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                          const SizedBox(height: 14),
                          FilledButton(
                            onPressed: () {
                              setState(() => _error = null);
                              _openCurrentMedia();
                            },
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  ),
                IgnorePointer(
                  ignoring: !_showControls && !_settingsOpen,
                  child: AnimatedOpacity(
                    opacity: _showControls || _settingsOpen ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    child: _overlay(context),
                  ),
                ),
                if (_skipKind != null &&
                    !_skipDismissed.contains(_skipKind) &&
                    !_settingsOpen)
                  _segmentPrompt(),
                if (_settingsOpen) _consolePanel(context),
                _gestureIndicator(),
                _pauseResumePrompt(),
                // Keep a dedicated caption strip above the custom overlay so
                // controls cannot swallow window-drag gestures. It avoids
                // the left title/back button and right window buttons.
                Positioned(
                  left: 210,
                  right: 210,
                  top: 0,
                  height: 64,
                  child: WindowHost.dragArea(child: SizedBox.expand()),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _overlay(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.black54, Colors.transparent, Colors.black87],
        stops: [0, .45, 1],
      ),
    ),
    child: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 14, 12, 0),
            child: Row(
              children: [
                YingjiMotionIconButton(
                  tooltip: '返回',
                  onPressed: () => _exitPlayer(context),
                  icon: YingjiIcons.chevron_left,
                  size: 48,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_activeEpisode.seriesLogoUrl?.isNotEmpty == true)
                        SizedBox(
                          height: 42,
                          width: 260,
                          child: Image.network(
                            _activeEpisode.seriesLogoUrl!,
                            alignment: Alignment.centerLeft,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => Text(
                              _activeEpisode.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        )
                      else
                        Text(
                          _activeEpisode.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -.5,
                          ),
                        ),
                      if (_activeEpisode.seasonNumber != null ||
                          _activeEpisode.episodeNumber != null)
                        Text(
                          'S${(_activeEpisode.seasonNumber ?? 1).toString().padLeft(2, '0')}E${(_activeEpisode.episodeNumber ?? 1).toString().padLeft(2, '0')}${_activeEpisode.episodeTitle?.isNotEmpty == true ? ' · ${_activeEpisode.episodeTitle}' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
                _StateChip(
                  label: _networkSpeedLabel(),
                  ok: !_player.state.buffering,
                ),
                if (_videoCacheStatus != null) ...[
                  const SizedBox(width: 8),
                  _StateChip(
                    label: _videoCacheStatus!,
                    ok:
                        !_videoCacheStatus!.contains('超过') &&
                        !_videoCacheStatus!.contains('不可用'),
                  ),
                ],
                if (!WindowHost.isDesktop) ...[
                  const SizedBox(width: 10),
                  YingjiMotionIconButton(
                    icon: _mobileFullScreen
                        ? YingjiIcons.fullscreen_exit
                        : YingjiIcons.fullscreen,
                    tooltip: _mobileFullScreen ? '退出全屏' : '全屏',
                    size: 46,
                    onPressed: _toggleFullScreen,
                  ),
                ],
                if (WindowHost.isDesktop) ...[
                  const SizedBox(width: 10),
                  YingjiMotionIconButton(
                    icon: YingjiIcons.gear_alt,
                    tooltip: '播放设置',
                    selected: _settingsOpen,
                    size: 46,
                    onPressed: _toggleSettings,
                  ),
                ],
                // 窗口按钮在移动端整组不渲染，这里也别留空档，
                // 否则右上角会多出一截无效间距。
                if (WindowHost.isDesktop) const SizedBox(width: 12),
                YingjiWindowControls(
                  fullscreen: true,
                  onClose: () => _exitPlayer(context),
                ),
              ],
            ),
          ),
          const Spacer(),
          StreamBuilder<Duration>(
            stream: _player.stream.position,
            builder: (_, snap) {
              final position = snap.data ?? Duration.zero;
              final duration = _player.state.duration;
              return Padding(
                padding: const EdgeInsets.fromLTRB(28, 0, 28, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_activeEpisode.resourceInfo?.isNotEmpty == true) ...[
                      const SizedBox(height: 8),
                      Text(
                        _activeEpisode.resourceInfo!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    StreamBuilder<Duration>(
                      stream: _player.stream.buffer,
                      builder: (_, bufferSnap) {
                        final max = duration.inMilliseconds == 0
                            ? 1.0
                            : duration.inMilliseconds.toDouble();
                        final buffered = normalizedBufferedPosition(
                          position: position,
                          buffer: bufferSnap.data ?? _player.state.buffer,
                          duration: duration,
                          fullyCached: _playingCachedFile,
                          persistentCacheFraction: _persistentCacheFraction,
                        ).inMilliseconds.toDouble();
                        final current = duration.inMilliseconds == 0
                            ? 0.0
                            : position.inMilliseconds
                                  .clamp(0, duration.inMilliseconds)
                                  .toDouble();
                        return SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 4,
                            activeTrackColor: Colors.white,
                            secondaryActiveTrackColor: const Color(0x8AFFFFFF),
                            inactiveTrackColor: const Color(0x30FFFFFF),
                            overlayColor: const Color(0x24FFFFFF),
                          ),
                          child: Slider(
                            value: current,
                            secondaryTrackValue: buffered,
                            max: max,
                            semanticFormatterCallback: (value) =>
                                '${_time(Duration(milliseconds: value.round()))}，'
                                '已缓存至 ${_time(Duration(milliseconds: buffered.round()))}',
                            onChanged: (v) =>
                                _player.seek(Duration(milliseconds: v.round())),
                          ),
                        );
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: [
                          Text(
                            _time(position),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white70,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            _time(duration),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        GlassPanel(
                          radius: 28,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (widget.episodes.length > 1)
                                YingjiDirectionalArrow(
                                  previous: true,
                                  tooltip: '上一集',
                                  size: 40,
                                  enabled: _activeEpisodeIndex > 0,
                                  onPressed: () =>
                                      _switchEpisode(_activeEpisodeIndex - 1),
                                ),
                              YingjiMotionIconButton(
                                tooltip: '后退 10 秒',
                                onPressed: () => _player.seek(
                                  position - const Duration(seconds: 10),
                                ),
                                icon: YingjiIcons.gobackward_10,
                                size: 40,
                              ),
                              StreamBuilder<bool>(
                                stream: _player.stream.playing,
                                builder: (_, playing) => YingjiMotionIconButton(
                                  tooltip: playing.data == true ? '暂停' : '播放',
                                  onPressed: () {
                                    _revealControls();
                                    _player.playOrPause();
                                  },
                                  selected: playing.data == true,
                                  size: 40,
                                  icon: playing.data == true
                                      ? YingjiIcons.pause_fill
                                      : YingjiIcons.play_fill,
                                ),
                              ),
                              YingjiMotionIconButton(
                                tooltip: '前进 10 秒',
                                onPressed: () => _player.seek(
                                  position + const Duration(seconds: 10),
                                ),
                                icon: YingjiIcons.goforward_10,
                                size: 40,
                              ),
                              if (widget.episodes.length > 1)
                                YingjiDirectionalArrow(
                                  previous: false,
                                  tooltip: '下一集',
                                  size: 40,
                                  enabled:
                                      _activeEpisodeIndex <
                                      widget.episodes.length - 1,
                                  onPressed: () =>
                                      _switchEpisode(_activeEpisodeIndex + 1),
                                ),
                              const SizedBox(width: 8),
                              Text(
                                '${_time(position)} / ${_time(duration)}',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: _rightControlsBar(),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    ),
  );

  /// 手势回显：亮度 / 音量用 Apple 那种竖条 HUD，快进快退用横条胶囊。
  ///
  /// 手机上这层不能压在画面正中：调音量/亮度时会正好挡住人物和字幕，所以
  /// 抬到画面上方（水平仍居中）。
  ///
  /// 整层 IgnorePointer，避免它自己抢走后续的拖动事件。
  ///
  /// 出现 / 消失走 [MovaAppear]，和全软件其它浮层同一套时长与曲线。
  Widget _gestureIndicator() => LayoutBuilder(
    builder: (context, constraints) {
      // 之前固定在 Alignment(0, -.42)，手机上正好压在人物脸上。现在按屏高的
      // 13% 定位（并给顶部标题栏留出至少 76px），横条又薄，基本不挡画面。
      final height = constraints.maxHeight;
      final top = (height * .13).clamp(76.0, 200.0);
      final y = (2 * (top + 19) / (height <= 0 ? 1 : height) - 1).clamp(
        -1.0,
        1.0,
      );
      final background = YingjiGlass.hud();
      // 液态玻璃无描边：HUD 的边界靠「背后模糊、浮层不模糊」的反差自己显现。
      final border = Colors.transparent;
      return IgnorePointer(
        child: MovaAppear(
          visible: _gestureVisible,
          animateOnMount: false,
          beginScale: .92,
          duration: MovaMotion.hudIn,
          child: Align(
            alignment: Alignment(0, y),
            child: _gestureKind == _GestureKind.seek
                ? MovaHud(
                    icon: _gestureIcon,
                    label: _gestureLabel,
                    caption: _gestureCaption.isEmpty ? null : _gestureCaption,
                    value: _gestureProgress,
                    width: 292,
                    background: background,
                    borderColor: border,
                    blur: YingjiGlass.blur,
                  )
                : MovaHud(
                    icon: _gestureIcon,
                    label: _gestureLabel,
                    value: _gestureProgress,
                    trackWidth: 104,
                    background: background,
                    borderColor: border,
                    blur: YingjiGlass.blur,
                  ),
          ),
        ),
      );
    },
  );

  /// 暂停时在画面正中放一个「继续播放」圆钮。
  ///
  /// 手机上控件条一秒后就自动隐藏，暂停后画面上什么都不剩，看着像卡死。
  /// 这里单独浮一个圆钮，点它直接续播（它是叶子节点，会赢过外层的
  /// 单击手势，不会退化成“切换控件显示”）。
  Widget _pauseResumePrompt() => StreamBuilder<bool>(
    stream: _player.stream.playing,
    builder: (context, snapshot) {
      if (!_hasPlayed ||
          snapshot.data != false ||
          _error != null ||
          _settingsOpen) {
        return const SizedBox.shrink();
      }
      return Center(
        child: MovaAppear(
          beginScale: .8,
          duration: MovaMotion.emphasis,
          child: MovaPress(
            onTap: () {
              _revealControls();
              unawaited(_player.play());
            },
            behavior: HitTestBehavior.opaque,
            scale: MovaMotion.pressScaleIcon,
            hoverScale: 1.06,
            pressedOpacity: .82,
            semanticLabel: '继续播放',
            child: Container(
              width: 78,
              height: 78,
              decoration: BoxDecoration(
                color: YingjiGlass.hud(strength: 1.7),
                shape: BoxShape.circle,
                border: Border.all(
                  color: YingjiGlass.line(strength: 2.6),
                  width: 1.4,
                ),
              ),
              child: const Icon(
                YingjiIcons.play_fill,
                color: Colors.white,
                size: 34,
              ),
            ),
          ),
        ),
      );
    },
  );

  String _time(Duration value) =>
      '${value.inHours > 0 ? '${value.inHours}:' : ''}${(value.inMinutes % 60).toString().padLeft(2, '0')}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

  String _networkSpeedLabel() {
    final bytes = _networkBytesPerSecond;
    if (bytes <= 0) return _player.state.buffering ? '读取中' : '—';
    if (bytes >= 1048576) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB/s';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB/s';
  }

  Widget _consolePanel(BuildContext context) => Positioned(
    right: 26,
    bottom: 102,
    width: 440,
    height: (MediaQuery.sizeOf(context).height - 188).clamp(320, 560),
    child: GlassPanel(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                _consoleTab,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              YingjiMotionIconButton(
                tooltip: '关闭面板',
                onPressed: _toggleSettings,
                icon: YingjiIcons.xmark,
                size: 36,
              ),
            ],
          ),
          const Text(
            '音轨、音量与音频处理会即时下发给 libmpv。',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 16),
          Expanded(child: ListView(children: _consoleContent())),
        ],
      ),
    ),
  );

  List<Widget> _consoleContent() {
    switch (_consoleTab) {
      case '声音':
        return [
          _consoleGroup('音轨', [
            '音频轨道  ${_player.state.tracks.audio.length} 条',
            '音量  ${_volume.round()}%',
          ]),
          _trackSelector(audio: true),
          _consoleGroup('同步', ['音频延迟  ${(_audioDelay * 1000).round()} ms']),
        ];
      case '字幕':
        return [
          _consoleGroup('字幕', [
            '字幕轨道  ${_player.state.tracks.subtitle.length} 条',
            '首选语言  ${_preferChineseSubtitle ? (subtitleLanguages[_subtitleLanguage] ?? '中文') : '跟随媒体默认'}',
            '字幕延迟  ${(_subtitleDelay * 1000).round()} ms',
          ]),
          _trackSelector(audio: false),
        ];
      case '弹幕':
        return [
          _consoleGroup('弹幕', [
            '服务  ${_danmakuEnabled ? '自动选择最快 API' : '未启用'}',
            'API 地址  ${_activeDanmakuApi.isEmpty ? '尚无成功返回的来源' : _displayDanmakuApi}',
            if (_activeDanmakuApi.isNotEmpty) '匹配结果  $_matchedDanmakuEpisode',
            '请求剧集  ${_activeEpisode.title} · 第 ${_activeEpisode.seasonNumber ?? 1} 季 · 第 ${_activeEpisode.episodeNumber ?? 1} 集 · ${_activeEpisode.episodeTitle ?? '未提供集名'}',
            _danmakuEnabled && _danmakuApis.isNotEmpty
                ? (_danmakuError == null
                      ? '已读取 ${_danmakuComments.length} 条弹幕'
                      : '读取失败：$_danmakuError')
                : '请先在设置 > 弹幕服务中填写 API 地址',
          ]),
          _danmakuControls(),
        ];
      case '画面':
        return [
          _consoleGroup('画面', ['画面比例  $_aspect']),
        ];
      case '倍速':
        return [
          _consoleGroup('倍速', ['播放速度  ${_speed.toStringAsFixed(2)}x']),
        ];
      case '章节':
        return [
          if (_activeEpisode.chapters.isEmpty)
            _consoleGroup('章节', ['当前媒体未提供章节信息'])
          else
            _chapterGroup(),
        ];
      case '片头片尾':
        return [_segmentPanel()];
      case '资源':
        return [_resourcePanel()];
      case '全集':
        return [_episodePanel()];
      default:
        return const [];
    }
  }

  Future<void> _saveDanmakuSetting(String key, Object value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is bool) await prefs.setBool('yingji.danmaku.$key', value);
    if (value is double) await prefs.setDouble('yingji.danmaku.$key', value);
  }

  Widget _danmakuControls() => GlassPanel(
    radius: 16,
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed: !_danmakuEnabled || _danmakuLoading
                ? null
                : () async {
                    final preferences = await SharedPreferences.getInstance();
                    await _loadDanmaku(
                      preferences.getString('yingji.danmaku.token') ?? '',
                      forceRefresh: true,
                    );
                  },
            icon: _danmakuLoading
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh, size: 18),
            label: Text(_danmakuLoading ? '正在重新获取' : '重新获取弹幕'),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          '显示方式',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _danmakuToggle('滚动', _danmakuScroll, (v) {
              setState(() => _danmakuScroll = v);
              _saveDanmakuSetting('scroll', v);
            }),
            _danmakuToggle('顶部固定', _danmakuTop, (v) {
              setState(() => _danmakuTop = v);
              _saveDanmakuSetting('top', v);
            }),
            _danmakuToggle('底部固定', _danmakuBottom, (v) {
              setState(() => _danmakuBottom = v);
              _saveDanmakuSetting('bottom', v);
            }),
          ],
        ),
        const SizedBox(height: 12),
        _danmakuSlider('透明度', _danmakuOpacity, .15, 1, (v) {
          setState(() => _danmakuOpacity = v);
          _saveDanmakuSetting('opacity', v);
        }),
        _danmakuSlider('显示区域', _danmakuArea, .2, 1, (v) {
          setState(() => _danmakuArea = v);
          _saveDanmakuSetting('area', v);
        }),
        _danmakuSlider('密度', _danmakuDensity, .2, 1, (v) {
          setState(() => _danmakuDensity = v);
          _saveDanmakuSetting('density', v);
        }),
        _danmakuSlider('字体大小', _danmakuFontSize, 12, 30, (v) {
          setState(() => _danmakuFontSize = v);
          _saveDanmakuSetting('font-size', v);
        }),
        _danmakuSlider('滚动速度', _danmakuSpeed, .5, 2, (v) {
          setState(() => _danmakuSpeed = v);
          _saveDanmakuSetting('speed', v);
        }),
      ],
    ),
  );

  Widget _danmakuToggle(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) => FilterChip(
    label: Text(label),
    selected: value,
    onSelected: onChanged,
    selectedColor: YingjiGlass.surface(strength: 1.15),
    backgroundColor: YingjiGlass.surface(),
    checkmarkColor: Colors.white,
    labelStyle: const TextStyle(
      color: Colors.white,
      fontWeight: FontWeight.w600,
    ),
    side: BorderSide(color: value ? Colors.white : YingjiGlass.line()),
  );

  Widget _danmakuSlider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) => Row(
    children: [
      SizedBox(
        width: 72,
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ),
      SizedBox(
        width: 38,
        child: Text(
          label == '字体大小'
              ? value.round().toString()
              : label == '滚动速度'
              ? '${value.toStringAsFixed(1)}x'
              : '${(value * 100).round()}%',
          textAlign: TextAlign.end,
          style: const TextStyle(fontSize: 11, color: Colors.white60),
        ),
      ),
    ],
  );

  Widget _segmentPanel() => GlassPanel(
    radius: 18,
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '片头片尾',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          _segments.isEmpty
              ? '标记会按当前影片与季保存，之后播放自动沿用。'
              : '已从 ${_segments.map((item) => item.provider).toSet().join('、')} 读取 ${_segments.length} 段数据。',
          style: const TextStyle(color: Colors.white60, fontSize: 12),
        ),
        if (_segmentMessage != null) ...[
          const SizedBox(height: 5),
          Text(
            _segmentMessage!,
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ],
        if (_segments.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final segment in _segments)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Icon(YingjiIcons.scissors, size: 14, color: Colors.white70),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '${segment.label} · ${_time(segment.start)}${segment.end == null ? '' : ' — ${_time(segment.end!)}'}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  Text(
                    segment.provider,
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                ],
              ),
            ),
        ],
        const SizedBox(height: 12),
        _consoleAction(
          YingjiIcons.scissors,
          _introEnd == null ? '将当前位置设为片头结束' : '片头结束 · ${_time(_introEnd!)}',
          () => _setSegment(intro: true),
        ),
        if (_manualIntro)
          _consoleAction(
            YingjiIcons.xmark,
            '清除手动片头结束',
            () => _clearSegment(intro: true),
          ),
        _consoleAction(
          YingjiIcons.bookmark,
          _outroStart == null ? '将当前位置设为片尾开始' : '片尾开始 · ${_time(_outroStart!)}',
          () => _setSegment(intro: false),
        ),
        if (_manualOutro)
          _consoleAction(
            YingjiIcons.xmark,
            '清除手动片尾开始',
            () => _clearSegment(intro: false),
          ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('自动跳过片头片尾'),
          value: _autoSkipSegments,
          onChanged: (value) async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('yingji.segment.$_segmentKey.enabled', value);
            if (mounted) setState(() => _autoSkipSegments = value);
          },
        ),
      ],
    ),
  );

  Widget _resourcePanel() {
    final resources = _activeEpisode.resources;
    if (resources.isEmpty) return _consoleGroup('切换资源', ['当前剧集仅聚合到一个可播放资源']);
    return Column(
      children: [
        for (var index = 0; index < resources.length; index++) ...[
          _resourceTile(resources[index], index),
          if (index != resources.length - 1) const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _resourceTile(PlayerResourceOption resource, int index) {
    final selected = resource.url == _activeEpisode.url;
    final icon = index == 0
        ? YingjiIcons.rankFirst
        : index == 1
        ? YingjiIcons.rankSecond
        : index == 2
        ? YingjiIcons.rankThird
        : YingjiIcons.server;
    final color = index == 0
        ? const Color(0xFFFFD76A)
        : index == 1
        ? const Color(0xFFDCE5EE)
        : index == 2
        ? const Color(0xFFD99A68)
        : Colors.white60;
    return GlassPanel(
      radius: 16,
      padding: EdgeInsets.zero,
      child: ListTile(
        selected: selected,
        leading: SizedBox(
          width: 48,
          height: 36,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (resource.source != null)
                ServerMark(
                  source: resource.source!,
                  token: resource.headers['X-Emby-Token'],
                  size: 34,
                )
              else
                Positioned.fill(child: Icon(icon, color: color, size: 20)),
              if (resource.source != null && index < 3)
                Positioned(
                  right: 0,
                  bottom: -1,
                  child: Container(
                    width: 21,
                    height: 21,
                    decoration: BoxDecoration(
                      color: const Color(0xFF20242C),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Icon(icon, color: color, size: 12),
                  ),
                ),
            ],
          ),
        ),
        title: Text(
          resource.label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(index < 3 ? '智能筛选优先资源' : '备用播放资源'),
        trailing: selected
            ? const Icon(YingjiIcons.checkmark_circle_fill)
            : null,
        onTap: () => unawaited(_switchResource(resource)),
      ),
    );
  }

  Widget _episodePanel() => Column(
    children: [
      for (var index = 0; index < widget.episodes.length; index++) ...[
        YingjiMotionSurface(
          selected: index == _activeEpisodeIndex,
          borderRadius: 16,
          child: GlassPanel(
            radius: 16,
            padding: EdgeInsets.zero,
            child: ListTile(
              selected: index == _activeEpisodeIndex,
              leading: SizedBox(
                width: 86,
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: widget.episodes[index].imageUrl?.isNotEmpty == true
                        ? Image.network(
                            widget.episodes[index].imageUrl!,
                            fit: BoxFit.cover,
                          )
                        : const ColoredBox(
                            color: Colors.white10,
                            child: Icon(YingjiIcons.film),
                          ),
                  ),
                ),
              ),
              title: Text(
                '第 ${widget.episodes[index].episodeNumber ?? index + 1} 集 · ${widget.episodes[index].episodeTitle ?? '未命名'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                widget.episodes[index].resourceInfo ?? '点击切换播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: index == _activeEpisodeIndex
                  ? const Icon(YingjiIcons.checkmark_circle_fill)
                  : null,
              onTap: () => unawaited(_switchEpisode(index)),
            ),
          ),
        ),
        if (index != widget.episodes.length - 1) const SizedBox(height: 8),
      ],
    ],
  );

  Widget _consoleAction(IconData icon, String label, VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: GlassPanel(
          radius: 14,
          padding: EdgeInsets.zero,
          child: ListTile(
            dense: true,
            leading: Icon(icon, color: YingjiColors.focus),
            title: Text(label),
            trailing: const Icon(YingjiIcons.chevron_right, size: 17),
            onTap: onTap,
          ),
        ),
      );

  Widget _chapterGroup() => GlassPanel(
    radius: 16,
    padding: EdgeInsets.zero,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.all(14),
          child: Text(
            '章节',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
        ..._activeEpisode.chapters.map(
          (chapter) => ListTile(
            dense: true,
            leading: const Icon(YingjiIcons.bookmark, size: 16),
            title: Text(chapter.title),
            trailing: Text(
              _time(chapter.start),
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
            onTap: () => _player.seek(chapter.start),
          ),
        ),
      ],
    ),
  );

  /// 右下角控件条。
  ///
  /// 横向空间不够时把工具按钮依次折叠进末尾的「更多」菜单：先尽量平铺，
  /// 位置不足时把最后一个位置让给「更多」，其余入口收进菜单。桌面端窗口
  /// 通常够宽会全部平铺，手机横屏才会折叠——否则 Row 会直接溢出。
  Widget _rightControlsBar() => LayoutBuilder(
    builder: (context, constraints) {
      const double gap = 4;
      const double button = 40;
      final available = constraints.maxWidth;
      final hasEpisodes = widget.episodes.isNotEmpty;
      final tools = _activeTools;
      // 窄屏收窄音量滑条，把空间让给工具按钮。
      final sliderWidth = available < 420
          ? 56.0
          : available < 560
          ? 80.0
          : 116.0;
      final fixed =
          28 + // 面板左右 padding
          (button + gap) + // 静音
          (sliderWidth + gap) + // 音量滑条
          (hasEpisodes ? button + gap : 0); // 全集列表
      // 不折叠时能平铺下的工具按钮个数：n 个按钮占 n*(button+gap) - gap。
      final fit = ((available - fixed + gap) / (button + gap)).floor();
      final overflowing = fit < tools.length;
      // 折叠时末尾要让出一个「更多」按钮的位置。
      final visible = overflowing ? math.max(0, fit - 1) : tools.length;
      final hidden = tools.sublist(visible);
      return GlassPanel(
        radius: 28,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            YingjiMotionIconButton(
              tooltip: _muted ? '恢复声音' : '静音',
              onPressed: _toggleMute,
              icon: _muted
                  ? YingjiIcons.speaker_slash
                  : YingjiIcons.speaker_2_fill,
              selected: _muted,
              size: 40,
            ),
            const SizedBox(width: gap),
            SizedBox(
              width: sliderWidth,
              height: button,
              child: Slider(
                value: _volume,
                min: 0,
                max: 100,
                onChanged: _setVolume,
              ),
            ),
            const SizedBox(width: gap),
            for (final tool in tools.take(visible)) ...[
              _playerToolControl(tool),
              const SizedBox(width: gap),
            ],
            if (hasEpisodes) ...[
              YingjiMotionIconButton(
                icon: YingjiIcons.rectangle_stack,
                tooltip: '全集列表',
                selected: _settingsOpen && _consoleTab == '全集',
                size: 40,
                onPressed: _showEpisodeList,
              ),
              const SizedBox(width: gap),
            ],
            if (hidden.isNotEmpty) _overflowToolsMenu(hidden),
          ],
        ),
      );
    },
  );

  /// 把工具描述渲染成控件。带取值的两个入口（播放速度、画面比例）平铺时是
  /// 下拉快选，其余是打开控制台对应标签的图标按钮。
  Widget _playerToolControl(_PlayerTool tool) => switch (tool.id) {
    // 倍速不画图标：直接把当前值写在按钮上，一眼能看见，也省一个槽位。
    '倍速' => _quickChoice<double>(
      icon: YingjiIcons.gauge,
      label: '播放速度',
      value: _speed,
      values: const [.5, .75, 1, 1.25, 1.5, 2],
      labelBuilder: _speedText,
      onChanged: _setPlaybackSpeed,
      display: _speedBadge(),
    ),
    '画面' => _quickChoice<String>(
      icon: YingjiIcons.crop,
      label: '画面比例',
      value: _aspect,
      values: const ['自动', '16:9', '4:3', '21:9'],
      labelBuilder: (v) => v,
      onChanged: _setAspect,
    ),
    _ => YingjiMotionIconButton(
      icon: tool.icon,
      tooltip: tool.id,
      selected: _settingsOpen && _consoleTab == tool.id,
      size: 40,
      onPressed: () => _openConsoleTab(tool.id),
    ),
  };

  /// 倍速按钮的外观：和其余工具按钮同规格的 40×40 玻璃圆钮，值写在圆里。
  ///
  /// 旧实现是一颗圆角小胶囊：混在一排圆钮里形状、描边粗细都不一致，而且
  /// 比工具栏常量 button（40）宽，会把 [_rightControlsBar] 能平铺的数量算多，
  /// 窄屏就溢出。
  Widget _speedBadge() => Container(
    width: 40,
    height: 40,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: YingjiGlass.chrome(),
      shape: BoxShape.circle,
      border: Border.all(color: YingjiGlass.line(strength: .75)),
    ),
    child: Text(
      _speedText(_speed),
      maxLines: 1,
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w800,
        height: 1,
        letterSpacing: -.3,
        color: Colors.white,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    ),
  );

  /// 倍速文案：整数省掉多余的「.0」，40px 的圆钮里才放得下「1.25x」。
  static String _speedText(double value) =>
      '${value == value.roundToDouble() ? value.toStringAsFixed(0) : value}x';

  /// 放不下的工具入口折叠成一个「更多」按钮，点开列在菜单里。
  Widget _overflowToolsMenu(List<_PlayerTool> hidden) => YingjiGlassMenu(
    borderRadius: 999,
    onOpen: () {
      _quickMenuOpen = true;
      _controlsTimer?.cancel();
    },
    onClose: () {
      _quickMenuOpen = false;
      _scheduleControlsHide();
    },
    entries: [
      for (final tool in hidden)
        MenuItemButton(
          leadingIcon: Icon(tool.icon, size: 16),
          onPressed: () => _openConsoleTab(tool.id),
          child: Text(tool.id),
        ),
    ],
    child: Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: YingjiGlass.chrome(),
        shape: BoxShape.circle,
      ),
      child: const Icon(YingjiIcons.ellipsis, size: 18),
    ),
  );

  Widget _quickChoice<T>({
    required IconData icon,
    required String label,
    required T value,
    required List<T> values,
    required String Function(T) labelBuilder,
    required ValueChanged<T> onChanged,
    Widget? display,
  }) => YingjiGlassTooltip(
    message: '$label · ${labelBuilder(value)}',
    child: YingjiGlassMenu(
      borderRadius: 999,
      onOpen: () {
        _quickMenuOpen = true;
        _controlsTimer?.cancel();
      },
      onClose: () {
        _quickMenuOpen = false;
        _scheduleControlsHide();
      },
      entries: [
        for (final item in values)
          MenuItemButton(
            onPressed: () => onChanged(item),
            trailingIcon: item == value
                ? const Icon(YingjiIcons.checkmark_circle_fill, size: 16)
                : null,
            child: Text(labelBuilder(item)),
          ),
      ],
      child:
          display ??
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: YingjiGlass.chrome(strength: 1.1),
              shape: BoxShape.circle,
              border: Border.all(color: YingjiGlass.line(strength: 1.3)),
            ),
            child: Icon(icon, size: 18),
          ),
    ),
  );

  Widget _consoleGroup(String title, List<String> rows) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: GlassPanel(
      radius: 16,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
          ...rows.map(
            (row) => Material(
              color: Colors.transparent,
              child: ListTile(
                dense: true,
                leading: const Icon(
                  YingjiIcons.slider_horizontal_3,
                  size: 16,
                  color: YingjiColors.focus,
                ),
                title: Text(row, style: const TextStyle(fontSize: 13)),
                trailing: row.startsWith('音量')
                    ? SizedBox(
                        width: 130,
                        child: Slider(
                          value: _volume,
                          min: 0,
                          max: 100,
                          onChanged: _setVolume,
                        ),
                      )
                    : row.startsWith('立体声下混')
                    ? Switch(
                        value: _downmix,
                        onChanged: (value) =>
                            _setAudioPreference(downmix: value),
                      )
                    : row.startsWith('夜间模式')
                    ? Switch(
                        value: _night,
                        onChanged: (value) => _setAudioPreference(night: value),
                      )
                    : row.startsWith('人声增强')
                    ? Switch(value: _voiceEnhance, onChanged: _setVoiceEnhance)
                    : row.startsWith('硬件解码')
                    ? Switch(
                        value: _hardware,
                        onChanged: (value) =>
                            _setVideoPreference(hardware: value),
                      )
                    : row.startsWith('HDR 输出')
                    ? Switch(
                        value: _hdr,
                        onChanged: (value) => _setVideoPreference(hdr: value),
                      )
                    : row.startsWith('播放速度')
                    ? YingjiGlassChoiceButton<double>(
                        value: _speed,
                        items: const [0.5, 0.75, 1, 1.25, 1.5, 2],
                        labelBuilder: (value) => '${value}x',
                        onChanged: _setPlaybackSpeed,
                      )
                    : row.startsWith('音频延迟')
                    ? _delayPicker(
                        value: _audioDelay,
                        onChanged: (value) => _setDelay(audio: value),
                      )
                    : row.startsWith('字幕延迟')
                    ? _delayPicker(
                        value: _subtitleDelay,
                        onChanged: (value) => _setDelay(subtitle: value),
                      )
                    : row.startsWith('预读缓存')
                    ? YingjiGlassChoiceButton<double>(
                        value: _cacheSeconds,
                        items: const [10, 30, 60, 120],
                        labelBuilder: (value) => '${value.round()} 秒',
                        onChanged: _setCacheSeconds,
                      )
                    : row.startsWith('画面比例')
                    ? YingjiGlassChoiceButton<String>(
                        value: _aspect,
                        items: const ['自动', '16:9', '4:3', '21:9'],
                        labelBuilder: (value) => value,
                        onChanged: _setAspect,
                      )
                    : row.startsWith('复制诊断信息')
                    ? YingjiMotionIconButton(
                        tooltip: '复制诊断信息',
                        onPressed: _copyDiagnostics,
                        icon: YingjiIcons.doc_on_clipboard,
                        size: 36,
                      )
                    : null,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _delayPicker({
    required double value,
    required ValueChanged<double> onChanged,
  }) => YingjiGlassChoiceButton<double>(
    value: value,
    items: const [-.5, -.25, 0, .25, .5],
    labelBuilder: (value) => '${(value * 1000).round()} ms',
    onChanged: onChanged,
  );

  Widget _trackSelector({required bool audio}) => StreamBuilder<Tracks>(
    stream: _player.stream.tracks,
    initialData: _player.state.tracks,
    builder: (_, snapshot) {
      final tracks = audio
          ? snapshot.data?.audio ?? const <AudioTrack>[]
          : snapshot.data?.subtitle ?? const <SubtitleTrack>[];
      if (tracks.isEmpty) return const SizedBox.shrink();
      final current = audio
          ? _player.state.track.audio
          : _player.state.track.subtitle;
      final choices = tracks
          .map((track) => _TrackChoice.fromTrack(track, audio))
          .toList(growable: false);
      final currentChoice = _TrackChoice.fromTrack(current, audio);
      final selected = choices.contains(currentChoice)
          ? currentChoice
          : choices.first;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: GlassPanel(
          radius: 16,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  audio ? '音频轨道' : '字幕轨道',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              YingjiGlassChoiceButton<_TrackChoice>(
                value: selected,
                items: choices,
                labelBuilder: (choice) {
                  final track = audio ? choice.audio : choice.subtitle;
                  return '${track?.title ?? track?.id}${track?.language == null ? '' : ' · ${track!.language}'}';
                },
                onChanged: (choice) {
                  if (audio && choice.audio != null) {
                    _player.setAudioTrack(choice.audio!);
                  }
                  if (!audio && choice.subtitle != null) {
                    _subtitleChosen = true;
                    _player.setSubtitleTrack(choice.subtitle!);
                  }
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _TrackChoice {
  const _TrackChoice({this.audio, this.subtitle});
  final AudioTrack? audio;
  final SubtitleTrack? subtitle;
  factory _TrackChoice.fromTrack(Object track, bool audio) => audio
      ? _TrackChoice(audio: track as AudioTrack)
      : _TrackChoice(subtitle: track as SubtitleTrack);
  @override
  bool operator ==(Object other) =>
      other is _TrackChoice &&
      audio == other.audio &&
      subtitle == other.subtitle;
  @override
  int get hashCode => Object.hash(audio, subtitle);
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.label, required this.ok});
  final String label;
  final bool ok;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: YingjiGlass.chrome(strength: .92),
      borderRadius: BorderRadius.circular(999),
      boxShadow: [
        BoxShadow(
          color: YingjiGlass.chrome(strength: 1.05),
          blurRadius: 16,
          offset: Offset(0, 8),
        ),
      ],
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            YingjiIcons.wifi,
            size: 14,
            color: ok ? Colors.white70 : Colors.white60,
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: ok ? Colors.white : Colors.white60,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Danmaku is drawn on a single canvas instead of a widget tree.
///
/// The old overlay rebuilt the whole comment stack (filter over every comment
/// plus one Text subtree per visible line — build, layout and paint) on every
/// position sample from the player. During playback mpv can emit dozens of
/// samples per second, so that rebuild cost is what made danmaku look low
/// frame-rate and stuttery. Here the position stream only writes a plain
/// field, a vsync [Ticker] interpolates between samples for display-rate
/// smoothness, and a single [CustomPainter] repaints the active lines with
/// cached [TextPainter]s, keeping per-frame work to pure canvas drawing.
class _DanmakuOverlay extends StatefulWidget {
  const _DanmakuOverlay({
    required this.positionStream,
    required this.comments,
    required this.opacity,
    required this.area,
    required this.density,
    required this.fontSize,
    required this.speed,
    required this.showScroll,
    required this.showTop,
    required this.showBottom,
  });

  final Stream<Duration> positionStream;
  final List<DanmakuComment> comments;
  final double opacity, area, density, fontSize, speed;
  final bool showScroll, showTop, showBottom;

  @override
  State<_DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<_DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  StreamSubscription<Duration>? _positionSub;

  /// Cached paragraph per danmaku line (keyed by content/color/size) so that
  /// layout happens once and every frame afterwards only paints the canvas.
  final Map<int, TextPainter> _glyphs = <int, TextPainter>{};
  static const _maxGlyphs = 512;

  /// Playhead (ms) at which each scrolling comment first started travelling,
  /// keyed by its lane hash. A comment that becomes visible only after the
  /// list finished loading (or after a seek) has an elapsed time already in
  /// the middle of its lifetime; anchoring it at first sight makes it enter
  /// from the right edge instead of popping in mid-screen.
  final Map<int, double> _spawnMs = <int, double>{};

  /// A comment seen this far into its lifetime is treated as a late catch-up
  /// (danmaku arrived after playback had begun) and re-anchored to the right
  /// edge; anything younger is a normal entry and keeps its own time base.
  static const _catchUpGraceMs = 480.0;

  /// Effective playhead handed to the painter each frame.
  Duration _position = Duration.zero;
  Duration? _lastPainted;

  /// Interpolation anchors between raw position samples: [Duration.zero] until
  /// the stream delivers its first event.
  Duration _samplePos = Duration.zero;
  Duration? _sampleAt;
  Duration _tickAt = Duration.zero;
  double _mediaRate = 0;

  @override
  void initState() {
    super.initState();
    _positionSub = widget.positionStream.listen((value) {
      final now = _tickAt;
      final at = _sampleAt;
      if (at != null && now > at) {
        final gapMs = now.inMilliseconds - at.inMilliseconds;
        final deltaMs = value.inMilliseconds - _samplePos.inMilliseconds;
        final jumped = deltaMs.abs() > 3000;
        if (!jumped && gapMs > 0 && gapMs < 2000) {
          _mediaRate = deltaMs / gapMs;
        } else {
          // A seek or a pause/resume boundary: anchor without extrapolating.
          _mediaRate = 0;
        }
      }
      if ((value - _samplePos).inMilliseconds.abs() > 3000) {
        _spawnMs.clear();
        _position = value;
      }
      _samplePos = value;
      _sampleAt = now;
    });
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    _tickAt = elapsed;
    var effective = _samplePos;
    final at = _sampleAt;
    if (at != null && _mediaRate > 0) {
      final since = elapsed - at;
      if (since > Duration.zero) {
        effective += Duration(
          milliseconds: (_mediaRate * math.min(since.inMilliseconds, 250))
              .round(),
        );
      }
    }
    if (effective == _lastPainted) return;
    // Small interpolation corrections are not seeks. Keep motion monotonic;
    // real seeks reset the anchor in the position listener above.
    if (effective < _position) effective = _position;
    _lastPainted = effective;
    _position = effective;
    // A ValueNotifier bump only repaints this overlay's layer; nothing else in
    // the player page rebuilds.
    _frame.value++;
  }

  @override
  void didUpdateWidget(covariant _DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.comments != widget.comments ||
        oldWidget.fontSize != widget.fontSize) {
      _clearGlyphs();
      // New timeline (another episode) or different metrics: old spawn anchors
      // no longer apply, so every line enters fresh from the right edge.
      _spawnMs.clear();
    }
  }

  void _clearGlyphs() {
    for (final painter in _glyphs.values) {
      painter.dispose();
    }
    _glyphs.clear();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _positionSub?.cancel();
    _clearGlyphs();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        painter: _DanmakuPainter(repaint: _frame, state: this),
        size: Size.infinite,
      ),
    ),
  );
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({required this.repaint, required this.state})
    : super(repaint: repaint);

  final Listenable repaint;
  final _DanmakuOverlayState state;
  static const _paddingH = 10.0;
  static const _paddingV = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    final overlay = state.widget;
    if (size.isEmpty) return;
    final positionMs = state._position.inMilliseconds.toDouble();
    final speed = overlay.speed;
    if (speed <= 0) return;
    final lifetimeMs = 8000.0 / speed;
    final fontSize = overlay.fontSize;
    final laneHeight = fontSize + 12;
    final laneCount = math.max(
      1,
      (size.height * overlay.area / laneHeight).floor(),
    );
    final cap = (3 + overlay.density * 10).round();
    final glyphs = state._glyphs;
    final background = Paint()
      ..color = Colors.black.withValues(alpha: .42 * overlay.opacity);
    var shown = 0;
    for (final comment in overlay.comments) {
      final mode = comment.mode;
      final enabled = mode == DanmakuMode.scroll
          ? overlay.showScroll
          : mode == DanmakuMode.top
          ? overlay.showTop
          : overlay.showBottom;
      if (!enabled) continue;
      final elapsedMs = positionMs - comment.time.inMilliseconds;
      if (elapsedMs < 0) continue; // not due yet
      final lane = Object.hash(comment.content, comment.time.inMilliseconds);
      // A line's effective age is measured from when it started travelling.
      // A scrolling comment seen for the first time with most of its life
      // already spent (the danmaku list finished loading seconds into
      // playback, or the user seeked into the middle) is anchored at the
      // current playhead so it enters from the right edge instead of popping
      // in mid-screen. Fixed comments always gate on their media time.
      double ageMs;
      if (mode == DanmakuMode.scroll) {
        final anchored = state._spawnMs[lane];
        if (anchored == null) {
          if (elapsedMs > lifetimeMs) continue; // expired before first sight
          if (elapsedMs > _DanmakuOverlayState._catchUpGraceMs) {
            state._spawnMs[lane] = positionMs;
            ageMs = 0;
          } else {
            state._spawnMs[lane] = comment.time.inMilliseconds.toDouble();
            ageMs = elapsedMs;
          }
        } else {
          ageMs = positionMs - anchored;
          if (ageMs > lifetimeMs) {
            state._spawnMs.remove(lane);
            continue;
          }
          if (ageMs < 0) ageMs = 0;
        }
      } else {
        if (elapsedMs > lifetimeMs) continue;
        ageMs = elapsedMs;
      }
      if (shown >= cap) break;
      shown++;
      final color = comment.color == null
          ? Colors.white
          : Color(0xff000000 | (comment.color! & 0xffffff));
      final key = Object.hash(comment.content, comment.color, fontSize);
      var glyph = glyphs[key];
      if (glyph == null) {
        if (glyphs.length >= _DanmakuOverlayState._maxGlyphs) {
          for (final stale in glyphs.values) {
            stale.dispose();
          }
          glyphs.clear();
        }
        glyph = TextPainter(
          text: TextSpan(
            text: comment.content,
            style: TextStyle(
              color: color,
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              shadows: const [Shadow(color: Colors.black, blurRadius: 3)],
            ),
          ),
          maxLines: 1,
          ellipsis: '…',
          textDirection: TextDirection.ltr,
        )..layout();
        glyphs[key] = glyph;
      }
      final boxWidth = glyph.width + _paddingH * 2;
      final boxHeight = glyph.height + _paddingV * 2;
      double left;
      double top;
      if (mode == DanmakuMode.scroll) {
        final progress = (ageMs / lifetimeMs).clamp(0.0, 1.0);
        left = size.width - progress * (size.width + boxWidth);
        top = 82 + (lane % laneCount) * laneHeight;
      } else {
        left = (size.width - boxWidth) / 2;
        top = mode == DanmakuMode.top
            ? 82 + (lane % 3) * laneHeight
            : size.height - 150 - (lane % 3) * laneHeight;
      }
      final box = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, boxWidth, boxHeight),
        const Radius.circular(8),
      );
      canvas.drawRRect(box, background);
      glyph.paint(canvas, Offset(left + _paddingH, top + _paddingV));
    }
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) => false;
}
