import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../cache/video_cache.dart';
import '../history/watch_state_store.dart';
import 'danmaku_client.dart';
import 'dolby_vision_color.dart';
import 'native_dolby_vision.dart';
import 'playback_segments.dart';

/// 可切换的资源版本。原生播放器只拿到显示用的服务器名、规格摘要与一张**本地
/// 图标文件**的路径 —— 地址、请求头与视频范围都留在应用侧，因为换资源要靠应用
/// 重建播放，原生既不该也不需要持有它们。
class WindowsNativeResourceOption {
  const WindowsNativeResourceOption({
    required this.source,
    required this.detail,
    this.iconPath,
    this.mark = 0,
    this.rank = 0,
  });

  /// 服务器显示名，面板里的标题。
  final String source;

  /// 规格摘要（分辨率 · 编码 · 容器 · 码率），面板里的副标题。
  final String detail;

  /// 服务器图标在本地磁盘上的路径，由调用方按详情页 `ServerMark` 的规则取好。
  /// 为 null 时原生按 [mark] 画兜底标记。
  final String? iconPath;

  /// 没有图标文件时的兜底标记：1 Emby、2 Jellyfin、3 WebDAV，0 表示不画。
  final int mark;

  /// 名次（1..3），原生给图标描一圈金 / 银 / 铜，和详情页的排名标记一致。
  final int rank;
}

/// 原生播放器结束后的结果。目前只有一种情况需要应用接手：用户在原生窗口里
/// 选了另一个资源版本 —— 原生的播放列表、请求头与 hwdec 选择都绑在起播时的
/// 那个服务器上，它自己换不了地址，只能把选择交回来。
class WindowsNativePlayResult {
  const WindowsNativePlayResult({this.resourceIndex, this.resourcePosition});

  /// 用户选中的资源版本下标；用户没换资源时为 null。
  final int? resourceIndex;

  /// 换资源那一刻的播放位置，用作新资源的起播点。
  final Duration? resourcePosition;
}

class WindowsNativePlaybackRequest {
  const WindowsNativePlaybackRequest({
    required this.url,
    required this.title,
    this.headers = const {},
    this.initialPosition = Duration.zero,
    this.imageUrl,
    this.seriesLogoUrl,
    this.sourceId,
    this.serverItemId,
    this.tmdbId,
    this.episodeTitle,
    this.seasonNumber,
    this.episodeNumber,
    this.videoRange,
    this.initialAudioTrack,
    this.initialSubtitleTrack,
    this.playlist = const [],
    this.playlistIndex = 0,
    this.resources = const [],
    this.resourceIndex = 0,
  });

  final String url;
  final String title;
  final Map<String, String> headers;
  final Duration initialPosition;
  final String? imageUrl;
  final String? seriesLogoUrl;
  final String? sourceId;
  final String? serverItemId;
  final int? tmdbId;
  final String? episodeTitle;
  final int? seasonNumber;
  final int? episodeNumber;
  final String? videoRange;
  final int? initialAudioTrack;
  final int? initialSubtitleTrack;
  final List<WindowsNativePlaylistEntry> playlist;
  final int playlistIndex;

  /// 当前剧集在**全部已连接服务器**上的资源版本，供原生「资源」面板切换。
  /// 为空时原生只显示一行说明。
  final List<WindowsNativeResourceOption> resources;

  /// 当前正在播放的是其中第几个版本。
  final int resourceIndex;
}

/// 由「观看比例 + 时长」估出这一集该从第几秒起播（null = 没有记录，从头播）。
///
/// 原生换集只做一次 `loadfile`，应用侧不会再插手，所以每一集的续播点必须随播放
/// 列表一起下发。应用侧手上只有「比例」和「时长」两份数据，乘一下就是秒数。
///
/// 两条容易搞错的边界：
///
/// * **已经看完的**（比例 ≥ 95%）当作没有记录。从片尾接上会立刻触发「播完 →
///   连播下一集」，用户看到的是「切到这一集，画面闪一下就跳走了」。
/// * **刚开头几秒的**也当作没有记录：与从头播没有区别，反而多一次 seek。
double? episodeResumeSeconds({double? progress, int? duration}) {
  if (progress == null || duration == null || duration <= 0) return null;
  if (progress >= .95) return null;
  final seconds = progress * duration;
  return seconds >= 5 ? seconds : null;
}

/// 拉取到的弹幕：临时文件路径 + 播放器面板要显示的数据来源信息。
class _DanmakuPayload {
  const _DanmakuPayload({
    required this.path,
    required this.count,
    required this.source,
    required this.matched,
  });

  final String path;
  final int count;
  final String source;
  final String matched;
}

class WindowsNativePlaylistEntry {
  const WindowsNativePlaylistEntry({
    required this.url,
    required this.title,
    this.headers = const {},
    this.imageUrl,
    this.sourceId,
    this.serverItemId,
    this.tmdbId,
    this.episodeTitle,
    this.seasonNumber,
    this.episodeNumber,
    this.imagePath,
    this.progress,
    this.duration,
    this.watched = false,
    this.resumeSeconds,
    this.meta,
  });

  final String url;
  final String title;
  final Map<String, String> headers;
  final String? imageUrl;
  final String? sourceId;
  final String? serverItemId;
  final int? tmdbId;
  final String? episodeTitle;
  final int? seasonNumber;
  final int? episodeNumber;

  /// 剧照在本地磁盘上的路径，由调用方按详情页同一套规则取好
  /// （TMDB 剧照优先、退回服务器图）。原生「剧集」面板不联网，只看这张图；
  /// 为 null 时画占位字形 —— 并非每一集都有剧照，缺图是常态而非异常。
  final String? imagePath;

  /// 观看进度 0..1，null 表示没有观看记录（面板不画进度条）。
  final double? progress;

  /// 该集总时长（秒），配合 [progress] 在卡片底部画「已看 / 全长」。
  final int? duration;

  /// 已播完的集：面板画对勾、不画进度条。与 [progress] 分开传 ——
  /// 服务器标记「已播放」但没有任何播放位置的集，progress 是空的。
  final bool watched;

  /// 这一集自己该从第几秒起播（null = 没有记录，从头播）。
  ///
  /// 原生换集（上一集 / 下一集 / 自动连播 / 剧集面板选集）只做一次 `loadfile`，
  /// 应用侧不会再给新集一个起播点，所以每一集的续播位置必须随播放列表一起下发。
  /// ⚠️ 不能指望 mpv 的命令行 `--start=` 代劳：它是普通（非文件局部）选项，换
  /// 文件时不会被重置，第 1 集的续播点会被重新应用到第 2 集上。
  final double? resumeSeconds;

  /// 卡片副标题里附在季号之后的补充信息，例如「2023-05-12 · 44 分钟」。
  final String? meta;
}

/// 正在播放的原生会话。设置页在播放期间改了「弹幕显示 / 片头片尾」里的项时，
/// 靠它把新值就地推给播放器 —— 以前这些值只在起播时以命令行下发一次，播放中
/// 改设置要等下一次播放才生效，两边的显示会各说各话。
class _LiveSession {
  _LiveSession({
    required this.send,
    required this.reloadSegments,
    required this.reloadDanmaku,
    required this.danmakuEnabled,
  });

  /// 往播放器 stdin 写一行；播放器已退出时静默忽略。
  final void Function(String line) send;

  /// 片头片尾来源开关变了：按新来源重拉当前集。
  final Future<void> Function() reloadSegments;

  /// 弹幕开关 / API 变了：按当前集重新拉一份。
  final Future<void> Function() reloadDanmaku;

  /// 起播时的弹幕开关，用来分清这次是「从关到开」（要重拉数据）还是只改了
  /// 显示样式（原生侧自己就够了）。
  bool danmakuEnabled;
}

class WindowsNativePlayer {
  WindowsNativePlayer._();

  /// 正在播放的会话；没有播放时为 null（此时设置改动已经落盘，下次起播读到
  /// 的就是新值，不需要热更新）。
  static _LiveSession? _live;

  /// 启动原生播放器并等待它结束。
  ///
  /// 返回值的 `resourceIndex` 非空表示：用户在原生窗口里选了另一个资源版本，
  /// 调用方应当用那个版本重新调用本方法（并沿用 `resourcePosition` 作为起播
  /// 位置），而不是当成播放结束。
  static Future<WindowsNativePlayResult> play(
    WindowsNativePlaybackRequest request,
  ) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows 原生播放器只能在 Windows 上使用');
    }
    final executable = File(
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}MovaNativePlayer.exe',
    );
    if (!await executable.exists()) {
      throw StateError('安装目录缺少 MovaNativePlayer.exe，请重新安装 Mova');
    }

    final cache = await VideoCacheStore.tryCreate();
    final limit = await VideoCachePolicy.current();
    final preferences = await SharedPreferences.getInstance();
    final seriesLogoPath = await _cachedImagePath(request.seriesLogoUrl);
    final hardware = preferences.getBool('yingji.player.hardware') ?? true;
    final hdr = preferences.getBool('yingji.player.hdr') ?? true;
    final downmix = preferences.getBool('yingji.player.downmix') ?? false;
    final night = preferences.getBool('yingji.player.night') ?? false;
    final voiceEnhance =
        preferences.getBool('yingji.player.voice-enhance') ?? false;
    final speed = preferences.getDouble('yingji.player.speed') ?? 1;
    // 音量与亮度是「控件菜单里改过就沿用」的播放器偏好：菜单里改完会回写到这两个
    // 键（见原生 EmitPlayerPreference），起播时再按这里下发，否则每次播放都回到
    // 默认值，用户会以为改的设置没保存。
    final volume = (preferences.getDouble('yingji.player.volume') ?? 100).clamp(
      0.0,
      100.0,
    );
    final brightness = (preferences.getDouble('yingji.player.brightness') ?? 0)
        .clamp(-100.0, 100.0);
    final audioDelay = preferences.getDouble('yingji.player.audio-delay') ?? 0;
    final subtitleDelay =
        preferences.getDouble('yingji.player.subtitle-delay') ?? 0;
    final cacheSeconds =
        preferences.getDouble('yingji.player.cache-seconds') ?? 30;
    final aspect = preferences.getString('yingji.player.aspect') ?? '自动';
    final preferSubtitles =
        preferences.getBool('yingji.player.subtitle-priority-enabled') ??
        preferences.getBool('yingji.player.prefer-chinese-subtitle') ??
        true;
    final subtitleLanguage =
        preferences.getString('yingji.player.subtitle-language') ?? 'zh';
    final preferAudio =
        preferences.getBool('yingji.player.audio-priority-enabled') ?? false;
    final audioLanguage =
        preferences.getString('yingji.player.audio-language') ?? 'zh';
    final preloadNext =
        preferences.getBool('yingji.player.preload-next') ?? true;
    final preloadLead = Duration(
      minutes:
          (preferences.getDouble('yingji.player.preload-lead-minutes') ?? 5)
              .round(),
    );
    final seekSeconds =
        preferences.getDouble('yingji.player.seek-seconds') ?? 10;
    final volumeStep = preferences.getDouble('yingji.player.volume-step') ?? 5;
    // 外观 → 模糊程度：播放器的控件条 / 顶栏 / 菜单 / 提示都由它换算成玻璃浓度，
    // 这样「设置里的那根滑杆」和播放器里的观感是同一份设置（播放中改动走
    // pushLiveSettings 的 mova-glass-blur 热更新）。
    final glassBlur =
        (preferences.getDouble('yingji.appearance.glass-blur') ?? 30).clamp(
          0,
          40,
        );
    final danmakuEnabled =
        preferences.getBool('yingji.danmaku.enabled') ?? false;
    final autoSkipSegments =
        preferences.getBool('yingji.segment.auto-skip') ?? true;
    final skipDelaySeconds =
        preferences.getDouble('yingji.segment.skip-delay-seconds') ?? 5;
    // 片头片尾只在这里下发开关与延迟；来源开关与数据都在起播后现读现拉
    // （见 pushEpisodeSegments）—— 播放期间设置页改了来源也能立刻重拉。
    //
    // 桌面端播放走独立的 MovaNativePlayer.exe，Flutter 的 _DanmakuOverlay 不生效，
    // 所以弹幕必须在原生覆盖窗口里渲染。做法：应用侧用 DanmakuClient 拉取 -> 序列
    // 化到临时文本文件 -> 起播后经 stdin 把路径热加载进原生。拉取失败 / 超时都不
    // 阻塞起播，换集时按新的一集重拉，播放期间改了设置页也走同一条路重来。
    List<String> danmakuStyleArgs = const [];
    if (danmakuEnabled) {
      final danmakuOpacity =
          preferences.getDouble('yingji.danmaku.opacity') ?? 0.82;
      final danmakuArea = preferences.getDouble('yingji.danmaku.area') ?? 0.65;
      final danmakuFontSize =
          preferences.getDouble('yingji.danmaku.font-size') ?? 18.0;
      final danmakuSpeed = preferences.getDouble('yingji.danmaku.speed') ?? 1.0;
      final danmakuDensity =
          preferences.getDouble('yingji.danmaku.density') ?? 0.55;
      final danmakuScroll =
          preferences.getBool('yingji.danmaku.scroll') ?? true;
      final danmakuTop = preferences.getBool('yingji.danmaku.top') ?? true;
      final danmakuBottom =
          preferences.getBool('yingji.danmaku.bottom') ?? true;
      // 弹幕不在起播路径上等待：等它会在网络不通时把起播拖到超时。播放器先
      // 起来，数据在 _pushDanmaku 里拉到后再通过 stdin 送进去热加载。
      danmakuStyleArgs = <String>[
        '--mova-danmaku-opacity=$danmakuOpacity',
        '--mova-danmaku-area=$danmakuArea',
        '--mova-danmaku-font-size=$danmakuFontSize',
        '--mova-danmaku-speed=$danmakuSpeed',
        '--mova-danmaku-density=$danmakuDensity',
        '--mova-danmaku-scroll=${danmakuScroll ? 'yes' : 'no'}',
        '--mova-danmaku-top=${danmakuTop ? 'yes' : 'no'}',
        '--mova-danmaku-bottom=${danmakuBottom ? 'yes' : 'no'}',
      ];
    }
    final toolOrder =
        preferences.getStringList('yingji.player.tool-order') ??
        const ['声音', '字幕', '剧集', '弹幕', '画面', '倍速', '章节', '片头片尾', '资源'];
    final toolHidden =
        preferences.getStringList('yingji.player.tool-hidden') ??
        const <String>[];
    final shortcuts = <String, String>{
      'playPause': 'Space',
      'seekBack': 'Arrow Left',
      'seekForward': 'Arrow Right',
      'volumeUp': 'Arrow Up',
      'volumeDown': 'Arrow Down',
      'mute': 'M',
      'fullscreen': 'F',
      'exit': 'Escape',
    };
    final shortcutJson = preferences.getString('yingji.player.shortcuts');
    if (shortcutJson != null) {
      try {
        final saved = jsonDecode(shortcutJson);
        if (saved is Map) {
          shortcuts.addAll(
            saved.map((key, value) => MapEntry('$key', '$value')),
          );
        }
      } on FormatException {
        // Keep the working defaults if an older preference was malformed.
      }
    }
    final entries = request.playlist.isEmpty
        ? <WindowsNativePlaylistEntry>[
            WindowsNativePlaylistEntry(
              url: request.url,
              title: request.title,
              headers: request.headers,
              imageUrl: request.imageUrl,
              sourceId: request.sourceId,
              serverItemId: request.serverItemId,
              tmdbId: request.tmdbId,
              episodeTitle: request.episodeTitle,
              seasonNumber: request.seasonNumber,
              episodeNumber: request.episodeNumber,
            ),
          ]
        : request.playlist;
    final playbackUrls = <String>[];
    for (final entry in entries) {
      playbackUrls.add(
        cache == null
            ? entry.url
            : await cache.playbackUrl(entry.url, headers: entry.headers),
      );
    }
    VideoCacheDownload? download;
    if (cache != null && limit > 0) {
      download = cache.download(
        url: request.url,
        limitBytes: limit,
        headers: request.headers,
        title: request.title,
      );
    }

    final arguments = <String>[
      '--config=no',
      '--force-window=yes',
      // keep-open 必须为 no：mpv 的播放列表里现在只装当前一集（整季都塞进去
      // 的话，它在任何 end-file 之后都会自动前进，就是「播到一半跳下一集」），
      // 而 keep-open=yes 会让 mpv 播完后停在最后一帧、根本不发 END_FILE，
      // 连播就永远触发不了。改成 no 之后：播完发 EOF，由原生侧判定是否真的
      // 播到了片尾，确认后才 loadfile 下一集；出错则停在原地并给出提示。
      '--keep-open=no',
      '--stop-playback-on-init-failure=yes',
      '--vo=gpu-next',
      '--gpu-api=d3d11',
      '--gpu-context=d3d11',
      '--hwdec=${playerHwdecValue(enabled: hardware, dolbyVision: hdr && NativeDolbyVisionPlayer.isDolbyVision(request.videoRange), isDesktop: true)}',
      '--vid=auto',
      '--osc=no',
      '--input-default-bindings=yes',
      '--input-vo-keyboard=yes',
      '--osd-level=1',
      '--autofit-larger=90%x90%',
      '--force-media-title=${request.title}',
      '--speed=$speed',
      '--volume=$volume',
      '--brightness=$brightness',
      '--audio-delay=$audioDelay',
      '--sub-delay=$subtitleDelay',
      '--demuxer-readahead-secs=$cacheSeconds',
      '--video-aspect-override=${_aspectValue(aspect)}',
      '--mova-seek-seconds=$seekSeconds',
      '--mova-volume-step=$volumeStep',
      '--mova-glass-blur=$glassBlur',
      // 弹幕文件不在这里传：起播时还没拉到，由 _pushDanmaku 通过 stdin 热加载。
      '--mova-danmaku-enabled=${danmakuEnabled ? 'yes' : 'no'}',
      ...danmakuStyleArgs,
      '--mova-auto-skip-segments=${autoSkipSegments ? 'yes' : 'no'}',
      '--mova-skip-delay-seconds=$skipDelaySeconds',
      ...toolOrder.map((tool) => '--mova-tool-order=$tool'),
      ...toolHidden.map((tool) => '--mova-tool-hidden=$tool'),
      ...shortcuts.entries.map(
        (entry) =>
            '--mova-shortcut=${entry.key}|${_shortcutLabel(entry.value)}',
      ),
      '--audio-channels=${downmix ? 'stereo' : 'auto'}',
      if (preferAudio) '--alang=$audioLanguage',
      if (preferSubtitles) '--slang=$subtitleLanguage',
      if (voiceEnhance || night)
        '--af=lavfi=[${[if (voiceEnhance) 'equalizer=f=1800:t=q:w=1.2:g=4', if (night) 'dynaudnorm'].join(',')}]',
      if (seriesLogoPath != null) '--mova-series-logo=$seriesLogoPath',
      // 起播点走自定义参数、而不是 mpv 的 `--start=`：后者是普通选项，换文件时
      // 不会重置，会把这一集的续播点染到之后每一集上（用户报的「切换上下集都
      // 从上一集的进度播放」）。原生解析后在首次 loadfile 前 set 进 mpv。
      '--mova-start=${request.initialPosition.inMilliseconds / 1000}',
      if (request.initialAudioTrack != null)
        '--aid=${request.initialAudioTrack! + 1}',
      if (request.initialSubtitleTrack != null)
        '--sid=${request.initialSubtitleTrack == -1 ? 'no' : request.initialSubtitleTrack! + 1}',
      if (cache == null && request.headers.isNotEmpty)
        '--http-header-fields=${request.headers.entries.map((entry) => '${entry.key}: ${entry.value}').join(',')}',
      ...playerColorProperties(
        hdrEnabled:
            hdr || NativeDolbyVisionPlayer.isDolbyVision(request.videoRange),
      ).entries.map((entry) => '--${entry.key}=${entry.value}'),
      '--terminal=yes',
      r'--term-status-msg=MOVA_POSITION=${time-pos}|${duration}',
      '--mova-playlist-start=${request.playlistIndex.clamp(0, playbackUrls.length - 1)}',
      ...entries.map((entry) => '--mova-playlist-title=${entry.title}'),
      ...entries.map(
        (entry) => '--mova-playlist-detail=${_episodeLabel(entry)}',
      ),
      // 季 / 集 / 集名分开下发：原生「剧集」面板要按季分组、逐行写「第 X 季 ·
      // 第 Y 集」，从上面那行预拼好的字符串里反解季集号只会更脆。
      ...entries.map(
        (entry) => '--mova-playlist-season=${entry.seasonNumber ?? ''}',
      ),
      ...entries.map(
        (entry) => '--mova-playlist-episode=${entry.episodeNumber ?? ''}',
      ),
      ...entries.map(
        (entry) => '--mova-playlist-episode-title=${entry.episodeTitle ?? ''}',
      ),
      // 剧照、进度与「日期 · 时长」按同一下标并行下发。空字符串表示这一项没有
      // 数据（某一集没剧照、没看过、时长未知），原生会退回占位或干脆不画。
      ...entries.map(
        (entry) => '--mova-playlist-image=${entry.imagePath ?? ''}',
      ),
      ...entries.map((entry) => '--mova-playlist-meta=${entry.meta ?? ''}'),
      ...entries.map(
        (entry) =>
            '--mova-playlist-progress=${entry.progress == null ? '' : entry.progress!.clamp(0.0, 1.0).toStringAsFixed(4)}',
      ),
      ...entries.map(
        (entry) => '--mova-playlist-duration=${entry.duration ?? ''}',
      ),
      // 每一集自己的续播秒数：换集时原生按它设 mpv 的 start。空字符串 =
      // 这一集没有观看记录，从头播。
      ...entries.map(
        (entry) =>
            '--mova-playlist-resume=${entry.resumeSeconds == null ? '' : entry.resumeSeconds!.toStringAsFixed(3)}',
      ),
      ...entries.map(
        (entry) => '--mova-playlist-watched=${entry.watched ? 1 : 0}',
      ),
      ...request.resources.map(
        (option) => '--mova-resource-source=${option.source}',
      ),
      ...request.resources.map(
        (option) => '--mova-resource-detail=${option.detail}',
      ),
      // 服务器图标：应用按详情页 ServerMark 的规则把图落到本地缓存，只下发
      // 路径；拿不到图时下发 mark，原生按来源类型画兜底标记。rank 是版本排序
      // 里的名次（1..3），原生给图标描金 / 银 / 铜环。
      ...request.resources.map(
        (option) => '--mova-resource-icon=${option.iconPath ?? ''}',
      ),
      ...request.resources.map(
        (option) => '--mova-resource-mark=${option.mark}',
      ),
      ...request.resources.map(
        (option) => '--mova-resource-rank=${option.rank}',
      ),
      if (request.resources.isNotEmpty)
        '--mova-resource-current=${request.resourceIndex.clamp(0, request.resources.length - 1)}',
      ...playbackUrls,
    ];

    final process = await Process.start(
      executable.path,
      arguments,
      workingDirectory: executable.parent.path,
      mode: ProcessStartMode.normal,
    );
    var lastNetworkBytes = 0;
    final networkSample = Stopwatch()..start();
    void sendCacheProgress(VideoCacheProgress progress) {
      process.stdin.writeln(
        'MOVA_CACHE=${progress.receivedBytes}|${progress.mediaTotalBytes}',
      );
      final received = progress.receivedBytes;
      final elapsedMilliseconds = networkSample.elapsedMilliseconds;
      if (received < lastNetworkBytes) {
        lastNetworkBytes = received;
        networkSample
          ..reset()
          ..start();
        process.stdin.writeln('MOVA_NETWORK=0');
      } else if (elapsedMilliseconds >= 250) {
        final bytesPerSecond =
            (received - lastNetworkBytes) * 1000 / elapsedMilliseconds;
        process.stdin.writeln('MOVA_NETWORK=$bytesPerSecond');
        lastNetworkBytes = received;
        networkSample
          ..reset()
          ..start();
      }
    }

    StreamSubscription<VideoCacheProgress>? cacheProgress;
    VideoCacheDownload? nextEpisodePreload;
    final preloadedUrls = <String>{};
    final completedEpisodes = <int>{};
    var activeCacheIndex = request.playlistIndex.clamp(0, entries.length - 1);
    if (download != null) {
      sendCacheProgress(download.state);
      cacheProgress = download.progress.listen(sendCacheProgress);
      unawaited(process.stdin.done.catchError((_) {}));
    }
    // 弹幕与片头片尾都是「按集」的数据：起播后异步拉当前集，之后每次换集重新
    // 拉一遍。各自的 generation 用来丢弃过期的结果 —— 网络慢的时候上一集的
    // 数据晚到，会把当前集的弹幕和片头片尾盖掉；两边分开计数则是因为设置页在
    // 播放期间改了来源开关只需要重拉片段，不该顺带作废正在进行的弹幕拉取。
    var segmentGeneration = 0;
    var danmakuGeneration = 0;
    var extrasEpisode = request.playlistIndex.clamp(0, entries.length - 1);
    // 同一时刻只有一个弹幕临时文件在用：换集后新文件一到，旧的就删（原生把它
    // 读进内存后就不再碰这个文件了），退出时再删一次收尾。
    String? activeDanmakuFile;

    void sendLine(String line) {
      try {
        process.stdin.writeln(line);
      } catch (_) {
        // 播放器已经退出，写不进去就算了。
      }
    }

    WindowsNativePlaylistEntry? entryAt(int index) =>
        index >= 0 && index < entries.length ? entries[index] : null;

    /// 按设置里当前勾选的来源，拉当前集的片头片尾并下发。
    ///
    /// 来源开关每次现读偏好：播放期间用户可能在设置页里改了它们，用起播时的
    /// 快照就会「明明勾了来源却还是没有数据」。
    Future<void> pushEpisodeSegments(int index) async {
      final generation = ++segmentGeneration;
      final preferences = await SharedPreferences.getInstance();
      await _pushSegments(
        entry: entryAt(index),
        request: request,
        send: sendLine,
        stale: () => generation != segmentGeneration,
        sources: SegmentSourceSettings.fromPreferences(preferences),
      );
    }

    /// 拉当前集的弹幕并热加载进播放器。
    Future<void> pushEpisodeDanmaku(int index) async {
      final generation = ++danmakuGeneration;
      final preferences = await SharedPreferences.getInstance();
      if (!(preferences.getBool('yingji.danmaku.enabled') ?? false)) return;
      final config = _danmakuConfig(preferences);
      if (config.apis.isEmpty) {
        // 没填 API 时不要让面板一直显示「获取中」。
        sendLine('MOVA_DANMAKU_STATUS=error:未配置弹幕 API');
        return;
      }
      sendLine('MOVA_DANMAKU_STATUS=loading');
      final path = await _pushDanmaku(
        request: request,
        entry: entryAt(index),
        apis: config.apis,
        apiNames: config.names,
        token: config.token,
        send: sendLine,
        stale: () => generation != danmakuGeneration,
      );
      if (path == null) return;
      if (generation != danmakuGeneration) {
        await _deleteFileQuietly(path);
        return;
      }
      final previous = activeDanmakuFile;
      activeDanmakuFile = path;
      if (previous != null) await _deleteFileQuietly(previous);
    }

    Future<void> loadEpisodeExtras(int index) async {
      extrasEpisode = index;
      unawaited(pushEpisodeSegments(index));
      unawaited(pushEpisodeDanmaku(index));
    }

    // 播放期间的设置热更新入口：设置页改了弹幕 / 片头片尾设置，直接推到正在
    // 跑的播放器上（见 pushLiveSettings），不必等下一次起播。
    _live = _LiveSession(
      send: sendLine,
      reloadSegments: () => pushEpisodeSegments(extrasEpisode),
      reloadDanmaku: () => pushEpisodeDanmaku(extrasEpisode),
      danmakuEnabled: danmakuEnabled,
    );

    unawaited(loadEpisodeExtras(extrasEpisode));
    var position = request.initialPosition;
    var duration = Duration.zero;
    var playlistPosition = request.playlistIndex;
    int? requestedResource;
    Duration? requestedResourcePosition;
    final episodePositions = <int, Duration>{};
    final episodeDurations = <int, Duration>{};
    final output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((chunk) {
          // 用户在原生「资源」面板里换了版本：记下选择与当时的位置，等进程退出
          // 之后交给调用方用新资源重新起播。
          for (final match in RegExp(
            r'MOVA_RESOURCE=([0-9]+)\|([0-9.]+)',
          ).allMatches(chunk)) {
            final index = int.tryParse(match.group(1) ?? '');
            if (index != null) {
              requestedResource = index;
              requestedResourcePosition = _seconds(match.group(2));
            }
          }
          for (final match in RegExp(
            r'MOVA_POSITION=([0-9.]+)\|([0-9.]+)(?:\|([0-9]+))?',
          ).allMatches(chunk)) {
            position = _seconds(match.group(1));
            duration = _seconds(match.group(2));
            playlistPosition =
                int.tryParse(match.group(3) ?? '') ?? playlistPosition;
            episodePositions[playlistPosition] = position;
            if (duration > Duration.zero) {
              episodeDurations[playlistPosition] = duration;
            }
            if (preloadNext &&
                cache != null &&
                limit > 0 &&
                duration > Duration.zero &&
                duration - position <= preloadLead &&
                playlistPosition >= 0 &&
                playlistPosition < entries.length - 1) {
              final nextEntry = entries[playlistPosition + 1];
              if (preloadedUrls.add(nextEntry.url)) {
                nextEpisodePreload = cache.download(
                  url: nextEntry.url,
                  limitBytes: limit,
                  targetBytes: VideoCachePolicy.nextEpisodePreheatBytes,
                  headers: nextEntry.headers,
                  title: nextEntry.title,
                );
              }
            }
            final nextCacheIndex = playlistPosition.clamp(
              0,
              entries.length - 1,
            );
            if (cache != null &&
                limit > 0 &&
                nextCacheIndex != activeCacheIndex) {
              activeCacheIndex = nextCacheIndex;
              nextEpisodePreload?.cancel();
              nextEpisodePreload = null;
              download?.cancel();
              final previousProgress = cacheProgress;
              if (previousProgress != null) {
                unawaited(previousProgress.cancel());
              }
              final entry = entries[nextCacheIndex];
              download = cache.download(
                url: entry.url,
                limitBytes: limit,
                headers: entry.headers,
                title: entry.title,
              );
              sendCacheProgress(download!.state);
              cacheProgress = download!.progress.listen(sendCacheProgress);
            }
            // 换集了：弹幕与片头片尾都得按新的一集重来，否则面板里显示的还是
            // 上一集的数据、自动跳过也会对着上一集的片头时间点跳。
            if (playlistPosition != extrasEpisode) {
              unawaited(loadEpisodeExtras(playlistPosition));
            }
          }
          for (final match in RegExp(
            r'MOVA_COMPLETED=([0-9]+)',
          ).allMatches(chunk)) {
            final index = int.tryParse(match.group(1) ?? '');
            if (index != null) completedEpisodes.add(index);
          }
          // 用户在原生弹幕面板里改了显示设置：回写到应用偏好，下次起播沿用。
          for (final match in RegExp(
            r'MOVA_SETTING=([A-Za-z0-9._-]+)\|(\S+)',
          ).allMatches(chunk)) {
            unawaited(_saveNativeSetting(match.group(1)!, match.group(2)!));
          }
        });
    await process.stderr.drain<void>();
    final exitCode = await process.exitCode;
    await cacheProgress?.cancel();
    await process.stdin.close();
    await output.cancel();
    // 播放结束：设置的热更新入口随之失效，再推也没人接了。
    _live = null;
    download?.cancel();
    // 收尾：删掉最后一次下发的弹幕临时文件（换集时上一份已经在换集流程里删过）。
    final lastDanmakuFile = activeDanmakuFile;
    if (lastDanmakuFile != null) {
      await _deleteFileQuietly(lastDanmakuFile);
    }
    nextEpisodePreload?.cancel();
    if (episodeDurations.isNotEmpty) {
      final store = await WatchStateStore.create();
      for (final item in episodeDurations.entries) {
        final index = item.key.clamp(0, entries.length - 1);
        final activeEntry = entries[index];
        final activePosition = episodePositions[item.key] ?? Duration.zero;
        final activeDuration = item.value;
        await store.save(
          // title 必须是剧名（request.title）：播放列表条目的 title 是单集
          // 条目自己的名字，各来源取名不一致 —— 有的叫「第 1 集」，有的直接
          // 复用剧名，写成记录标题就会出现「同一个剧两条记录、一条把集名
          // 当剧名」的脏数据。episodeTitle 只取条目自带的集名，缺了就留空
          // （卡片回退「第 N 集」），绝不拿剧名/条目名来充数。
          normalizeWatchState(
            WatchState(
              mediaId: activeEntry.url,
              title: request.title,
              position: activePosition,
              duration: activeDuration,
              imageUrl: activeEntry.imageUrl,
              sourceId: activeEntry.sourceId,
              serverItemId: activeEntry.serverItemId,
              tmdbId: activeEntry.tmdbId,
              episodeTitle: activeEntry.episodeTitle,
              seasonNumber: activeEntry.seasonNumber,
              episodeNumber: activeEntry.episodeNumber,
              isPlayed: completedEpisodes.contains(item.key),
            ),
          ),
        );
      }
    }
    if (exitCode != 0) throw StateError('原生播放器异常退出（$exitCode）');
    return WindowsNativePlayResult(
      resourceIndex: requestedResource,
      resourcePosition: requestedResourcePosition,
    );
  }

  static String _shortcutLabel(String saved) =>
      saved.contains('|') ? saved.split('|').skip(1).join('|') : saved;

  static String _episodeLabel(WindowsNativePlaylistEntry entry) {
    final parts = <String>[];
    if (entry.seasonNumber != null) parts.add('第 ${entry.seasonNumber} 季');
    if (entry.episodeNumber != null) parts.add('第 ${entry.episodeNumber} 集');
    final episodeTitle = entry.episodeTitle?.trim();
    if (episodeTitle != null && episodeTitle.isNotEmpty) {
      parts.add(episodeTitle);
    }
    return parts.join(' · ');
  }

  static String _aspectValue(String aspect) => switch (aspect) {
    '16:9' => '1.7777778',
    '4:3' => '1.3333333',
    '21:9' => '2.3333333',
    _ => '0',
  };

  static Duration _seconds(String? value) => Duration(
    milliseconds: ((double.tryParse(value ?? '') ?? 0) * 1000).round(),
  );

  static Future<String?> _cachedImagePath(String? url) async {
    if (url == null || url.isEmpty) return null;
    try {
      return (await DefaultCacheManager().getSingleFile(url)).path;
    } catch (_) {
      return null;
    }
  }

  /// 拉取弹幕并序列化为原生侧能直接读入的临时文本文件。
  ///
  /// 行格式：`<time秒>\t<mode>\t<color>\t<base64文本>`
  /// - mode：1 滚动 / 5 顶部 / 6 底部（对齐 DanmakuClient 的枚举与原生解析）。
  /// - color：0xRRGGBB，无颜色时记 -1（原生按默认白渲染）。
  /// 文本走 base64 是为了避开中文 / 制表符与换行对行解析的干扰，原生侧自带解码。
  ///
  /// 依次尝试每个 API，命中「非空结果」即刻返回；全部失败则抛错，由调用方降级为
  /// 不起用弹幕。单个 API 内部已有 15s 超时，这里再给整体 12s 上限做二次保险。
  static Future<_DanmakuPayload> _writeDanmakuFile({
    required WindowsNativePlaybackRequest request,
    WindowsNativePlaylistEntry? entry,
    required List<String> apis,
    required List<String> apiNames,
    required String token,
  }) async {
    if (apis.isEmpty) throw StateError('未配置弹幕 API');
    List<DanmakuComment>? comments;
    String source = '';
    String matched = '';
    for (var index = 0; index < apis.length; index++) {
      final api = apis[index];
      try {
        final client = DanmakuClient();
        final result = await client
            .fetch(
              template: api,
              tmdbId: (entry?.tmdbId ?? request.tmdbId)?.toString(),
              title: request.title,
              season: entry?.seasonNumber ?? request.seasonNumber,
              episode: entry?.episodeNumber ?? request.episodeNumber,
              mediaUrl: request.url,
              token: token.isEmpty ? null : token,
            )
            .timeout(const Duration(seconds: 12));
        if (result.isEmpty) continue;
        comments = result;
        // 命中的线路名优先用用户填的名称，没填就退回地址本身。
        source = index < apiNames.length && apiNames[index].trim().isNotEmpty
            ? apiNames[index].trim()
            : api;
        matched = client.matchedEpisode ?? '';
        break;
      } catch (_) {
        // 该 API 失败，继续试下一个。
      }
    }
    if (comments == null || comments.isEmpty) {
      throw StateError('没有匹配的弹幕');
    }
    final buffer = StringBuffer();
    for (final comment in comments) {
      final mode = switch (comment.mode) {
        DanmakuMode.top => 5,
        DanmakuMode.bottom => 6,
        _ => 1,
      };
      final color = comment.color ?? -1;
      final payload = base64Encode(utf8.encode(comment.content));
      buffer.writeln(
        '${comment.time.inMilliseconds / 1000}\t$mode\t$color\t$payload',
      );
    }
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'mova_danmaku_${DateTime.now().microsecondsSinceEpoch}.txt',
    );
    await file.writeAsString(buffer.toString(), encoding: utf8);
    return _DanmakuPayload(
      path: file.path,
      count: comments.length,
      source: source,
      matched: matched,
    );
  }

  /// 播放开始后再拉弹幕，拉到就通过 stdin 交给原生播放器热加载。
  ///
  /// 放在起播前做会把起播卡住（网络不通时甚至能卡到超时），而且失败会连带
  /// 拖慢整个播放流程。现在起播不等弹幕，播放器先跑起来，数据到了再叠加。
  ///
  /// [stale] 在每次发送前检查：换集之后才回来的上一集结果一律丢弃，不能让它
  /// 把当前集的弹幕（或状态提示）盖掉。
  static Future<String?> _pushDanmaku({
    required WindowsNativePlaybackRequest request,
    WindowsNativePlaylistEntry? entry,
    required List<String> apis,
    required List<String> apiNames,
    required String token,
    required void Function(String) send,
    required bool Function() stale,
  }) async {
    try {
      final payload = await _writeDanmakuFile(
        request: request,
        entry: entry,
        apis: apis,
        apiNames: apiNames,
        token: token,
      ).timeout(const Duration(seconds: 20));
      if (stale()) {
        await _deleteFileQuietly(payload.path);
        return null;
      }
      send(
        'MOVA_DANMAKU_INFO=${payload.count}\t${payload.source}\t'
        '${payload.matched.replaceAll('\t', ' ').replaceAll('\n', ' ')}',
      );
      send('MOVA_DANMAKU=${payload.path}');
      return payload.path;
    } catch (error) {
      if (!stale()) {
        send('MOVA_DANMAKU_STATUS=error:${_reasonOf(error)}');
      }
      return null;
    }
  }

  /// 拉取当前集的片头片尾并经 stdin 下发给原生播放器。
  ///
  /// 原生不联网、也不持有服务器令牌，所以数据必须在应用侧按设置里勾选的来源
  /// 取好。整段是尽力而为：拿不到就只发一条状态，面板照实显示原因，不影响播放。
  static Future<void> _pushSegments({
    required WindowsNativePlaybackRequest request,
    required WindowsNativePlaylistEntry? entry,
    required void Function(String) send,
    required bool Function() stale,
    required SegmentSourceSettings sources,
  }) async {
    send('MOVA_SEGMENT_STATUS=loading');
    try {
      final result = await loadPlaybackSegments(
        PlaybackSegmentQuery(
          tmdbId: entry?.tmdbId ?? request.tmdbId,
          seasonNumber: entry?.seasonNumber ?? request.seasonNumber,
          episodeNumber: entry?.episodeNumber ?? request.episodeNumber,
          sourceId: entry?.sourceId ?? request.sourceId,
          serverItemId: entry?.serverItemId ?? request.serverItemId,
          sources: sources,
        ),
      ).timeout(const Duration(seconds: 20));
      if (stale()) return;
      // 行格式：<类型>|<开始秒>|<结束秒>|<来源>；结束点缺失记 -1（片尾常常只有
      // 起点），原生按当前总时长处理。
      for (final segment in result.segments) {
        send(
          'MOVA_SEGMENT=${segment.type.name}|${_secondLabel(segment.start)}|'
          '${segment.end == null ? -1 : _secondLabel(segment.end!)}|'
          '${segment.provider.replaceAll('|', ' ')}',
        );
      }
      send('MOVA_SEGMENTS_DONE=${result.segments.length}');
      final message = result.message;
      if (message != null) {
        send('MOVA_SEGMENT_STATUS=note:${message.replaceAll('\n', ' ')}');
      }
    } catch (error) {
      if (!stale()) send('MOVA_SEGMENT_STATUS=error:${_reasonOf(error)}');
    }
  }

  /// 播放期间从设置页改了弹幕 / 片头片尾设置：把新值推给正在跑的播放器。
  ///
  /// 起播时的命令行参数只是「第一次应用」，之后所有改动都走这里 —— 否则设置
  /// 页里把字号调大、播放器还按旧字号渲染，两处显示的就不是同一份设置。
  ///
  /// [keys] 是本次真正变动的偏好键（媒体中心保存设置时传进来）；为空表示全部
  /// 下发。片头片尾的来源开关影响的是数据拉取，会按新来源重拉当前集。
  static Future<void> pushLiveSettings({Iterable<String>? keys}) async {
    final session = _live;
    // 没有在播的会话：改动已经落盘，下次起播自然读到新值，不必做什么。
    if (session == null) return;
    final changed = keys?.toSet();
    bool touched(String key) => changed == null || changed.contains(key);
    final preferences = await SharedPreferences.getInstance();

    void push(String key, String name, String value) {
      if (touched(key)) session.send('MOVA_APPLY=$name|$value');
    }

    push(
      'yingji.danmaku.area',
      'mova-danmaku-area',
      (preferences.getDouble('yingji.danmaku.area') ?? 0.65).toString(),
    );
    push(
      'yingji.danmaku.opacity',
      'mova-danmaku-opacity',
      (preferences.getDouble('yingji.danmaku.opacity') ?? 0.82).toString(),
    );
    push(
      'yingji.danmaku.font-size',
      'mova-danmaku-font-size',
      (preferences.getDouble('yingji.danmaku.font-size') ?? 18.0).toString(),
    );
    push(
      'yingji.danmaku.speed',
      'mova-danmaku-speed',
      (preferences.getDouble('yingji.danmaku.speed') ?? 1.0).toString(),
    );
    push(
      'yingji.danmaku.density',
      'mova-danmaku-density',
      (preferences.getDouble('yingji.danmaku.density') ?? 0.55).toString(),
    );
    push(
      'yingji.danmaku.scroll',
      'mova-danmaku-scroll',
      (preferences.getBool('yingji.danmaku.scroll') ?? true) ? 'yes' : 'no',
    );
    push(
      'yingji.danmaku.top',
      'mova-danmaku-top',
      (preferences.getBool('yingji.danmaku.top') ?? true) ? 'yes' : 'no',
    );
    push(
      'yingji.danmaku.bottom',
      'mova-danmaku-bottom',
      (preferences.getBool('yingji.danmaku.bottom') ?? true) ? 'yes' : 'no',
    );
    push(
      'yingji.segment.auto-skip',
      'mova-auto-skip-segments',
      (preferences.getBool('yingji.segment.auto-skip') ?? true) ? 'yes' : 'no',
    );
    push(
      'yingji.segment.skip-delay-seconds',
      'mova-skip-delay-seconds',
      (preferences.getDouble('yingji.segment.skip-delay-seconds') ?? 5)
          .toString(),
    );
    // 快进步长 / 音量步长：同属播放器设置，改了立刻生效才符合直觉。
    push(
      'yingji.player.seek-seconds',
      'mova-seek-seconds',
      (preferences.getDouble('yingji.player.seek-seconds') ?? 10).toString(),
    );
    push(
      'yingji.player.volume-step',
      'mova-volume-step',
      (preferences.getDouble('yingji.player.volume-step') ?? 5).toString(),
    );
    // 外观 → 模糊程度：正在播的这一集也要跟着变。原生没有高斯背板，它把同一个
    // 数值换算成玻璃浓度（控件条、顶栏、菜单、提示一起变透/变实），详见
    // native_player/main.cpp 的 GlassLevel。
    push(
      'yingji.appearance.glass-blur',
      'mova-glass-blur',
      (preferences.getDouble('yingji.appearance.glass-blur') ?? 30).toString(),
    );
    // 播放器偏好：设置页里改了「默认播放速度 / 画面比例」要立刻作用到正在播的
    // 这一集（改亮度、音量也从这里走）。值域与起播时同源，两边不会各说各话。
    push(
      'yingji.player.speed',
      'speed',
      (preferences.getDouble('yingji.player.speed') ?? 1).toString(),
    );
    push(
      'yingji.player.volume',
      'volume',
      (preferences.getDouble('yingji.player.volume') ?? 100).toString(),
    );
    push(
      'yingji.player.brightness',
      'brightness',
      (preferences.getDouble('yingji.player.brightness') ?? 0).toString(),
    );
    push(
      'yingji.player.aspect',
      'video-aspect-override',
      _aspectValue(preferences.getString('yingji.player.aspect') ?? '自动'),
    );

    // 弹幕总开关：关掉时原生会丢掉已解析的弹幕，所以「从关到开」必须重拉一
    // 份当前集的数据；改 API / 令牌也一样要按新配置重拉。只改显示样式则不必。
    final danmakuEnabled =
        preferences.getBool('yingji.danmaku.enabled') ?? false;
    final danmakuConfigChanged =
        touched('yingji.danmaku.apis') ||
        touched('yingji.danmaku.url') ||
        touched('yingji.danmaku.token');
    if (touched('yingji.danmaku.enabled')) {
      session.send(
        'MOVA_APPLY=mova-danmaku-enabled|${danmakuEnabled ? 'yes' : 'no'}',
      );
    }
    if (!danmakuEnabled) {
      session.danmakuEnabled = false;
    } else if (danmakuEnabled != session.danmakuEnabled ||
        danmakuConfigChanged) {
      session.danmakuEnabled = true;
      unawaited(session.reloadDanmaku());
    }

    // 来源开关变了：数据必须按新来源重拉（原生不联网，只负责显示）。
    if (changed == null ||
        changed.any((key) => key.startsWith('yingji.segment.source-'))) {
      unawaited(session.reloadSegments());
    }
  }

  /// 从偏好里取弹幕 API 配置。播放期间设置页可能改过它们，所以每次现读。
  static ({List<String> apis, List<String> names, String token}) _danmakuConfig(
    SharedPreferences preferences,
  ) {
    final apis =
        (preferences.getStringList('yingji.danmaku.apis') ??
                [preferences.getString('yingji.danmaku.url') ?? ''])
            .where((value) => value.trim().isNotEmpty)
            .toList();
    return (
      apis: apis,
      names: preferences.getStringList('yingji.danmaku.api-names') ?? const [],
      token: preferences.getString('yingji.danmaku.token') ?? '',
    );
  }

  /// 原生面板里改的设置回写到应用偏好，下次起播沿用。
  ///
  /// 只接受「弹幕显示」与「自动跳过」这两组键：原生是另一个进程，回写能力必须
  /// 收窄到明确的功能，不能让它往任意偏好里写值。
  /// 原生面板能回写偏好的键：只收「弹幕显示 / 片头片尾 / 播放器偏好」这一组，
  /// 别的键一律丢弃 —— 原生是另一个进程，回写面必须收窄到明确的功能。
  static const Set<String> _nativeTextSettingKeys = {'yingji.player.aspect'};

  static const Set<String> _nativeNumberSettingKeys = {
    'yingji.player.speed',
    'yingji.player.volume',
    'yingji.player.brightness',
  };

  static Future<void> _saveNativeSetting(String key, String raw) async {
    final boolean = raw == 'true' || raw == 'false';
    final accepted =
        key.startsWith('yingji.danmaku.') ||
        key == 'yingji.segment.auto-skip' ||
        _nativeTextSettingKeys.contains(key) ||
        _nativeNumberSettingKeys.contains(key);
    if (!accepted) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      if (_nativeTextSettingKeys.contains(key)) {
        // 画面比例在设置页里是标签（自动 / 16:9 / 4:3 / 21:9），原生回传的也是
        // 同一套说法，直接存字符串。
        await preferences.setString(key, raw);
      } else if (boolean) {
        await preferences.setBool(key, raw == 'true');
      } else {
        final value = double.tryParse(raw);
        if (value != null) await preferences.setDouble(key, value);
      }
    } catch (_) {
      // 偏好写不进去只是下一次起播不会沿用，不影响本次播放。
    }
  }

  static String _secondLabel(Duration value) =>
      (value.inMilliseconds / 1000).toStringAsFixed(3);

  static String _reasonOf(Object error) =>
      error.toString().replaceFirst('StateError: ', '').replaceAll('\n', ' ');

  static Future<void> _deleteFileQuietly(String path) async {
    try {
      await File(path).delete();
    } catch (_) {
      // 临时文件删不掉也不影响播放结果。
    }
  }

  /// 把一张剧照落到本地缓存并返回文件路径，供原生「剧集」面板显示。
  ///
  /// 原生不联网、也不该持有令牌，所以图片必须由应用侧先取好 —— 复用
  /// [_cachedImagePath]，保证剧集面板和应用里的图片走同一份磁盘缓存。
  static Future<String?> cacheImageFile(String? url) => _cachedImagePath(url);

  /// 批量把剧照落到本地缓存，返回「调用方给的 key → 文件路径」。
  ///
  /// 与逐张 [cacheImageFile] 的区别在于**不拿起播去换图**：先在磁盘缓存里找
  /// （离线、瞬时），只有真的缺图的那几集才去下载，而且并发下载、整体还有一个
  /// [budget] 上限。一季几十集、其中大半没缓存时，串行下载会把起播卡住好几秒；
  /// 网络不通时更是能卡到 HTTP 超时。超预算的那几集在面板里显示占位图，下一轮
  /// 打开就已经缓存好了。
  static Future<Map<String, String?>> cacheImageFiles(
    Map<String, String?> urls, {
    Duration budget = const Duration(seconds: 3),
  }) async {
    final manager = DefaultCacheManager();
    final found = await Future.wait(
      urls.entries.map((entry) async {
        final url = entry.value;
        if (url == null || url.isEmpty) return MapEntry(entry.key, null);
        try {
          final cached = await manager.getFileFromCache(url);
          return MapEntry(entry.key, cached?.file.path);
        } catch (_) {
          return MapEntry(entry.key, null);
        }
      }),
    );
    final paths = <String, String?>{
      for (final entry in found) entry.key: entry.value,
    };
    final missing = urls.entries
        .where(
          (entry) =>
              entry.value != null &&
              entry.value!.isNotEmpty &&
              paths[entry.key] == null,
        )
        .toList(growable: false);
    if (missing.isEmpty) return paths;
    await Future.wait<void>(
      missing.map((entry) async {
        paths[entry.key] = await _cachedImagePath(entry.value);
      }),
    ).timeout(budget, onTimeout: () => <void>[]);
    return paths;
  }
}
