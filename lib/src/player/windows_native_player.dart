import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../cache/video_cache.dart';
import '../history/watch_state_store.dart';
import 'dolby_vision_color.dart';
import 'native_dolby_vision.dart';

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

  /// 卡片副标题里附在季号之后的补充信息，例如「2023-05-12 · 44 分钟」。
  final String? meta;
}

class WindowsNativePlayer {
  WindowsNativePlayer._();

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
    final danmakuEnabled =
        preferences.getBool('yingji.danmaku.enabled') ?? false;
    final autoSkipSegments =
        preferences.getBool('yingji.segment.auto-skip') ?? true;
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
      '--keep-open=no',
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
      '--audio-delay=$audioDelay',
      '--sub-delay=$subtitleDelay',
      '--demuxer-readahead-secs=$cacheSeconds',
      '--video-aspect-override=${_aspectValue(aspect)}',
      '--mova-seek-seconds=$seekSeconds',
      '--mova-volume-step=$volumeStep',
      '--mova-danmaku-enabled=${danmakuEnabled ? 'yes' : 'no'}',
      '--mova-auto-skip-segments=${autoSkipSegments ? 'yes' : 'no'}',
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
      if (request.initialPosition > Duration.zero)
        '--start=${request.initialPosition.inMilliseconds / 1000}',
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
          }
          for (final match in RegExp(
            r'MOVA_COMPLETED=([0-9]+)',
          ).allMatches(chunk)) {
            final index = int.tryParse(match.group(1) ?? '');
            if (index != null) completedEpisodes.add(index);
          }
        });
    await process.stderr.drain<void>();
    final exitCode = await process.exitCode;
    await cacheProgress?.cancel();
    await process.stdin.close();
    await output.cancel();
    download?.cancel();
    nextEpisodePreload?.cancel();
    if (episodeDurations.isNotEmpty) {
      final store = await WatchStateStore.create();
      for (final item in episodeDurations.entries) {
        final index = item.key.clamp(0, entries.length - 1);
        final activeEntry = entries[index];
        final activePosition = episodePositions[item.key] ?? Duration.zero;
        final activeDuration = item.value;
        await store.save(
          WatchState(
            mediaId: activeEntry.url,
            title: activeEntry.title,
            position: activePosition,
            duration: activeDuration,
            imageUrl: activeEntry.imageUrl,
            sourceId: activeEntry.sourceId,
            serverItemId: activeEntry.serverItemId,
            tmdbId: activeEntry.tmdbId,
            episodeTitle: activeEntry.episodeTitle ?? activeEntry.title,
            seasonNumber: activeEntry.seasonNumber,
            episodeNumber: activeEntry.episodeNumber,
            isPlayed: completedEpisodes.contains(item.key),
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
