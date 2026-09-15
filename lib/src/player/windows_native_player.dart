import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../cache/video_cache.dart';
import '../history/watch_state_store.dart';
import 'dolby_vision_color.dart';
import 'native_dolby_vision.dart';

class WindowsNativePlaybackRequest {
  const WindowsNativePlaybackRequest({
    required this.url,
    required this.title,
    this.headers = const {},
    this.initialPosition = Duration.zero,
    this.imageUrl,
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
  });

  final String url;
  final String title;
  final Map<String, String> headers;
  final Duration initialPosition;
  final String? imageUrl;
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
}

class WindowsNativePlayer {
  WindowsNativePlayer._();

  static Future<void> play(WindowsNativePlaybackRequest request) async {
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
      '--hwdec=${playerHwdecValue(enabled: true, dolbyVision: NativeDolbyVisionPlayer.isDolbyVision(request.videoRange), isDesktop: true)}',
      '--vid=auto',
      '--osc=no',
      '--input-default-bindings=yes',
      '--input-vo-keyboard=yes',
      '--osd-level=1',
      '--autofit-larger=90%x90%',
      '--force-media-title=${request.title}',
      if (request.initialPosition > Duration.zero)
        '--start=${request.initialPosition.inMilliseconds / 1000}',
      if (request.initialAudioTrack != null)
        '--aid=${request.initialAudioTrack! + 1}',
      if (request.initialSubtitleTrack != null)
        '--sid=${request.initialSubtitleTrack == -1 ? 'no' : request.initialSubtitleTrack! + 1}',
      if (cache == null && request.headers.isNotEmpty)
        '--http-header-fields=${request.headers.entries.map((entry) => '${entry.key}: ${entry.value}').join(',')}',
      ...playerColorProperties(
        hdrEnabled: NativeDolbyVisionPlayer.isDolbyVision(request.videoRange),
      ).entries.map((entry) => '--${entry.key}=${entry.value}'),
      '--terminal=yes',
      r'--term-status-msg=MOVA_POSITION=${time-pos}|${duration}',
      '--mova-playlist-start=${request.playlistIndex.clamp(0, playbackUrls.length - 1)}',
      ...entries.map((entry) => '--mova-playlist-title=${entry.title}'),
      ...playbackUrls,
    ];

    final process = await Process.start(
      executable.path,
      arguments,
      workingDirectory: executable.parent.path,
      mode: ProcessStartMode.normal,
    );
    void sendCacheProgress(VideoCacheProgress progress) {
      process.stdin.writeln(
        'MOVA_CACHE=${progress.receivedBytes}|${progress.mediaTotalBytes}',
      );
    }

    StreamSubscription<VideoCacheProgress>? cacheProgress;
    var activeCacheIndex = request.playlistIndex.clamp(0, entries.length - 1);
    if (download != null) {
      sendCacheProgress(download.state);
      cacheProgress = download.progress.listen(sendCacheProgress);
      unawaited(process.stdin.done.catchError((_) {}));
    }
    var position = request.initialPosition;
    var duration = Duration.zero;
    var playlistPosition = request.playlistIndex;
    final episodePositions = <int, Duration>{};
    final episodeDurations = <int, Duration>{};
    final output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((chunk) {
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
            final nextCacheIndex = playlistPosition.clamp(
              0,
              entries.length - 1,
            );
            if (cache != null &&
                limit > 0 &&
                nextCacheIndex != activeCacheIndex) {
              activeCacheIndex = nextCacheIndex;
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
        });
    await process.stderr.drain<void>();
    final exitCode = await process.exitCode;
    await cacheProgress?.cancel();
    await process.stdin.close();
    await output.cancel();
    download?.cancel();
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
          ),
        );
      }
    }
    if (exitCode != 0) throw StateError('原生播放器异常退出（$exitCode）');
  }

  static Duration _seconds(String? value) => Duration(
    milliseconds: ((double.tryParse(value ?? '') ?? 0) * 1000).round(),
  );
}
