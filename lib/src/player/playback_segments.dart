import 'package:shared_preferences/shared_preferences.dart';

import '../network/proxy_routing.dart';
import '../sources/emby_client.dart';
import '../sources/media_source.dart';
import '../sources/source_store.dart';
import 'segment_client.dart';

// 片头片尾的统一入口：调用方只需要认识这一个文件，片段类型与数据结构由它
// 转出（PlaybackSegment / PlaybackSegmentType 都在 segment_client.dart 里）。
export 'segment_client.dart';

/// 设置页「自动跳过」分组里的五个来源开关。
///
/// 应用内播放器与 Windows 原生播放器读的是同一批键，所以在设置里关掉某个
/// 来源，两条链路都不会再去查它 —— 之前原生链路根本没有片头片尾数据，设置
/// 里的开关对它等于不存在。
class SegmentSourceSettings {
  const SegmentSourceSettings({
    this.server = true,
    this.introDb = true,
    this.theIntroDb = true,
    this.aniSkip = true,
    this.chaptersDb = true,
  });

  final bool server;
  final bool introDb;
  final bool theIntroDb;
  final bool aniSkip;
  final bool chaptersDb;

  bool get anyEnabled =>
      server || introDb || theIntroDb || aniSkip || chaptersDb;

  factory SegmentSourceSettings.fromPreferences(SharedPreferences prefs) =>
      SegmentSourceSettings(
        server: prefs.getBool('yingji.segment.source-server') ?? true,
        introDb: prefs.getBool('yingji.segment.source-introdb') ?? true,
        theIntroDb: prefs.getBool('yingji.segment.source-theintrodb') ?? true,
        aniSkip: prefs.getBool('yingji.segment.source-aniskip') ?? true,
        chaptersDb: prefs.getBool('yingji.segment.source-chaptersdb') ?? true,
      );
}

/// 一次片头片尾查询所需的全部上下文。
///
/// 只带标识（TMDB / 服务器 item id / 季 / 集），不带标题：标题匹配一旦命中
/// 同名作品就会跳过真实内容，SegmentClient 那边也刻意不认标题。
class PlaybackSegmentQuery {
  const PlaybackSegmentQuery({
    this.tmdbId,
    this.seasonNumber,
    this.episodeNumber,
    this.sourceId,
    this.serverItemId,
    this.duration,
    this.chapters = const [],
    this.sources = const SegmentSourceSettings(),
  });

  final int? tmdbId;
  final int? seasonNumber;
  final int? episodeNumber;

  /// 当前片源所属服务器，用来取令牌读服务器原生分段（WebDAV 没有这个能力）。
  final String? sourceId;
  final String? serverItemId;

  /// 当前媒体的总时长。TheIntroDB / AniSkip 会用它做匹配，未知时传 null。
  final Duration? duration;

  /// 媒体自带的章节。服务器把片头片尾做成章节时，这一路不需要联网。
  final List<MediaChapter> chapters;

  final SegmentSourceSettings sources;

  bool get movie => seasonNumber == null;
}

class PlaybackSegmentResult {
  const PlaybackSegmentResult({this.segments = const [], this.message});

  final List<PlaybackSegment> segments;

  /// 给界面的一句话说明：全部来源都不可用时给出原因，部分不可用时说明
  /// 「已使用可用来源」，完全正常时为 null。
  final String? message;
}

/// 按设置里勾选的来源拉取片头片尾，去重后返回。
///
/// 顺序即优先级：服务器自己的数据（原生分段 / 章节）最可信，公共库只作补充。
/// 任何一路失败都不影响其它路，也不抛给调用方 —— 播放器要的是「有多少算多少」。
Future<PlaybackSegmentResult> loadPlaybackSegments(
  PlaybackSegmentQuery query,
) async {
  final sources = query.sources;
  if (!sources.anyEnabled) {
    return const PlaybackSegmentResult(message: '已在设置中关闭全部片头片尾来源');
  }
  var local = sources.server
      ? segmentsFromChapters(query.chapters)
      : const <PlaybackSegment>[];
  final fetched = <PlaybackSegment>[];
  final failures = <String>[];

  if (sources.server && query.serverItemId != null) {
    try {
      final store = await SourceStore.create();
      final source = store
          .load()
          .where((value) => value.id == query.sourceId)
          .firstOrNull;
      final token = source == null ? null : store.tokenFor(source);
      if (source != null &&
          source.kind != SourceKind.webdav &&
          token != null &&
          token.isNotEmpty) {
        final server = EmbyClient(
          proxy: ProxyRouting.serverUsesProxy(source.id),
        );
        try {
          final native = await server.mediaSegments(
            EmbySession(source: source, token: token),
            query.serverItemId!,
          );
          if (native.isNotEmpty) {
            local = [
              ...segmentsFromChapters(native, provider: '服务器原生分段'),
              ...local,
            ];
          }
        } finally {
          server.dispose();
        }
      }
    } catch (_) {
      failures.add('服务器分段');
    }
  }

  final client = SegmentClient();
  try {
    final tmdbId = query.tmdbId;
    if (tmdbId != null) {
      SegmentIdentifiers? ids;
      if (sources.introDb || sources.aniSkip || sources.chaptersDb) {
        try {
          ids = await client.identifiers(tmdbId: tmdbId, movie: query.movie);
        } catch (_) {
          failures.add('外部标识');
        }
      }
      final requests = <Future<List<PlaybackSegment>>>[
        if (sources.introDb &&
            ids?.imdbId != null &&
            query.seasonNumber != null &&
            query.episodeNumber != null)
          client.introDb(
            imdbId: ids!.imdbId!,
            season: query.seasonNumber!,
            episode: query.episodeNumber!,
          ),
        if (sources.theIntroDb)
          client.theIntroDb(
            tmdbId: tmdbId,
            season: query.seasonNumber,
            episode: query.episodeNumber,
            duration: query.duration,
          ),
        if (sources.aniSkip &&
            ids?.malId != null &&
            query.episodeNumber != null)
          client.aniSkip(
            malId: ids!.malId!,
            episode: query.episodeNumber!,
            duration: query.duration,
          ),
        if (sources.chaptersDb && (ids?.imdbId != null || ids?.tvdbId != null))
          client.chaptersDb(
            imdbId: ids?.imdbId,
            season: query.seasonNumber,
            episode: query.episodeNumber,
          ),
      ];
      final results = await Future.wait(
        requests.map((request) async {
          try {
            return await request;
          } catch (_) {
            failures.add('公共来源');
            return const <PlaybackSegment>[];
          }
        }),
      );
      for (final result in results) {
        fetched.addAll(result);
      }
    }
  } finally {
    client.dispose();
  }

  final segments = dedupeSegments([...local, ...fetched]);
  return PlaybackSegmentResult(
    segments: segments,
    message: segments.isEmpty
        ? failures.isEmpty
              ? '当前数据源未提供片头片尾信息'
              : '部分来源暂时不可用，且未找到片头片尾信息'
        : failures.isEmpty
        ? null
        : '已使用可用来源，部分来源暂时不可用',
  );
}

/// 同一类型、起点相差 2 秒内的重复片段只留先到的那条。
///
/// 几个公共库经常给出同一段片头（尤其是动画的 OP），不去重的话面板里会出现
/// 一行行几乎一样的「片头 00:30 – 01:30」，自动跳过也会被反复触发。
List<PlaybackSegment> dedupeSegments(List<PlaybackSegment> values) {
  final result = <PlaybackSegment>[];
  for (final value in values) {
    final duplicate = result.any(
      (existing) =>
          existing.type == value.type &&
          (existing.start - value.start).abs() < const Duration(seconds: 2),
    );
    if (!duplicate) result.add(value);
  }
  return result;
}

/// 把服务器章节里那些明显是片头 / 前情 / 预告 / 片尾的条目挑出来。
///
/// 结束点用下一章的起点补：Emby / Jellyfin 的章节只有起点，单看起点没法知道
/// 这段有多长。
List<PlaybackSegment> segmentsFromChapters(
  List<MediaChapter> chapters, {
  String provider = '服务器章节',
}) {
  final results = <PlaybackSegment>[];
  for (var index = 0; index < chapters.length; index++) {
    final chapter = chapters[index];
    final name = chapter.title.toLowerCase();
    final next =
        chapter.end ??
        (index + 1 < chapters.length ? chapters[index + 1].start : null);
    if (name.contains('intro') || name.contains('片头')) {
      results.add(
        PlaybackSegment(
          type: PlaybackSegmentType.intro,
          start: chapter.start,
          end: next,
          provider: provider,
        ),
      );
    } else if (name.contains('recap') || name.contains('前情')) {
      results.add(
        PlaybackSegment(
          type: PlaybackSegmentType.recap,
          start: chapter.start,
          end: next,
          provider: provider,
        ),
      );
    } else if (name.contains('preview') || name.contains('预告')) {
      results.add(
        PlaybackSegment(
          type: PlaybackSegmentType.preview,
          start: chapter.start,
          end: next,
          provider: provider,
        ),
      );
    } else if (name.contains('credit') ||
        name.contains('outro') ||
        name.contains('片尾')) {
      results.add(
        PlaybackSegment(
          type: PlaybackSegmentType.credits,
          start: chapter.start,
          end: next,
          provider: provider,
        ),
      );
    }
  }
  return results;
}
