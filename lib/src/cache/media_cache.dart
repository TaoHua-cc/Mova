import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../metadata/tmdb_client.dart';
import '../sources/emby_client.dart';
import '../sources/media_source.dart';

/// 详情页「资源卡片」的本地快照。
///
/// 打开一部剧时，页面本来要挨个服务器找剧、再拉季与剧集，最后聚合出资源卡片，
/// 这一趟要几秒，期间只能转圈。这里把上次聚合好的结果缓存下来：下次打开先用
/// 缓存把全部卡片渲染出来，再在后台按 [MediaDetailCache.scanCooldown] 的间隔
/// 重新聚合一次并替换 —— 也就是「先展示已缓存内容，再更新」。
class MediaDetailSnapshot {
  const MediaDetailSnapshot({
    required this.rows,
    required this.seasonPosters,
    required this.savedAt,
  });

  /// 已经过滤、可直接渲染的资源行。
  final List<MediaItem> rows;

  /// 服务器给出的季封面（季号 → 图片地址）。
  final Map<int, Uri> seasonPosters;

  final DateTime savedAt;
}

abstract final class MediaDetailCache {
  /// 同一部剧的重新聚合间隔：这段时间内反复开关详情页都只用缓存。
  static const Duration scanCooldown = Duration(minutes: 10);

  /// 单部剧最多缓存多少行，避免长篇剧把偏好文件撑得过大。
  static const int _maxRows = 800;

  static const String _rowsPrefix = 'yingji.detail.res.v1.';
  static const String _scanPrefix = 'yingji.detail.scan.v1.';

  static String _key(String prefix, TmdbItem item) =>
      '$prefix${item.kind == '剧集' ? 'tv' : 'movie'}.${item.id}';

  static Future<MediaDetailSnapshot?> load(TmdbItem item) async {
    if (item.id <= 0) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(_rowsPrefix, item));
      if (raw == null || raw.isEmpty) return null;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final rows = (data['rows'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(_mediaItemFromJson)
          .whereType<MediaItem>()
          .toList(growable: false);
      if (rows.isEmpty) return null;
      final posters = <int, Uri>{};
      final saved = data['posters'] as Map<String, dynamic>?;
      if (saved != null) {
        for (final entry in saved.entries) {
          final number = int.tryParse(entry.key);
          final url = Uri.tryParse('${entry.value}');
          if (number != null && url != null) posters[number] = url;
        }
      }
      return MediaDetailSnapshot(
        rows: rows,
        seasonPosters: posters,
        savedAt:
            DateTime.tryParse('${data['savedAt']}') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
    } catch (_) {
      // 损坏的快照按「没有缓存」处理，走正常聚合路径覆盖它。
      return null;
    }
  }

  static Future<void> save(
    TmdbItem item, {
    required List<MediaItem> rows,
    required Map<int, Uri> seasonPosters,
  }) async {
    if (item.id <= 0 || rows.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final capped = rows.length > _maxRows
          ? rows.take(_maxRows).toList(growable: false)
          : rows;
      await prefs.setString(
        _key(_rowsPrefix, item),
        jsonEncode({
          'savedAt': DateTime.now().toIso8601String(),
          'rows': capped.map(_mediaItemToJson).toList(growable: false),
          'posters': {
            for (final entry in seasonPosters.entries)
              '${entry.key}': entry.value.toString(),
          },
        }),
      );
    } catch (_) {
      // 缓存写不进去只是少了加速，不影响本次渲染。
    }
  }

  /// 上次聚合是否还在冷却期内。
  static Future<bool> recentlyScanned(TmdbItem item) async {
    if (item.id <= 0) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stamp = prefs.getInt(_key(_scanPrefix, item));
      if (stamp == null) return false;
      return DateTime.now()
              .difference(DateTime.fromMillisecondsSinceEpoch(stamp)) <
          scanCooldown;
    } catch (_) {
      return false;
    }
  }

  static Future<void> markScanned(TmdbItem item) async {
    if (item.id <= 0) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _key(_scanPrefix, item),
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {
      // 记不上时间戳只会让下次多聚合一遍，可以接受。
    }
  }

  /// 「清理元数据缓存」时连同详情快照一起清掉。
  static Future<int> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs
          .getKeys()
          .where(
            (key) =>
                key.startsWith(_rowsPrefix) || key.startsWith(_scanPrefix),
          )
          .toList(growable: false);
      var count = 0;
      for (final key in keys) {
        if (await prefs.remove(key)) count++;
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  /// 缓存里一共有多少部作品（用于设置页的缓存统计）。
  static Future<int> count() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs
          .getKeys()
          .where((key) => key.startsWith(_rowsPrefix))
          .length;
    } catch (_) {
      return 0;
    }
  }
}

/// `MediaItem` 的 JSON 编解码。
///
/// 服务器返回的字段很多都要在详情页离线重放（播放地址、请求头、轨道、章节、
/// 观看进度），所以这里逐字段保全，而不是只存渲染卡片要用的那一小部分。
Map<String, dynamic> _mediaItemToJson(MediaItem item) => {
  'id': item.id,
  'title': item.title,
  'type': item.type,
  'source': item.source.toJson(),
  'overview': item.overview,
  'imageUrl': item.imageUrl?.toString(),
  'playbackUrl': item.playbackUrl?.toString(),
  'year': item.year,
  'premiereDate': item.premiereDate?.toIso8601String(),
  'runtime': item.runtime?.inMilliseconds,
  'headers': item.headers,
  'providerIds': item.providerIds,
  'parentId': item.parentId,
  'seriesId': item.seriesId,
  'seriesTitle': item.seriesTitle,
  'seasonNumber': item.seasonNumber,
  'episodeNumber': item.episodeNumber,
  'isContainer': item.isContainer,
  'chapters': [
    for (final chapter in item.chapters)
      {
        'title': chapter.title,
        'start': chapter.start.inMilliseconds,
        'end': chapter.end?.inMilliseconds,
      },
  ],
  'container': item.container,
  'size': item.size,
  'bitrate': item.bitrate,
  'width': item.width,
  'height': item.height,
  'videoCodec': item.videoCodec,
  'videoRange': item.videoRange,
  'bitDepth': item.bitDepth,
  'frameRate': item.frameRate,
  'audioTracks': [
    for (final track in item.audioTracks) _trackToJson(track),
  ],
  'subtitleTracks': [
    for (final track in item.subtitleTracks) _trackToJson(track),
  ],
  'playbackPosition': item.playbackPosition?.inMilliseconds,
  'isPlayed': item.isPlayed,
  'lastPlayedAt': item.lastPlayedAt?.toIso8601String(),
};

Map<String, dynamic> _trackToJson(MediaTrack track) => {
  'index': track.index,
  'title': track.title,
  'codec': track.codec,
  'language': track.language,
  'channels': track.channels,
  'sampleRate': track.sampleRate,
  'bitrate': track.bitrate,
  'isDefault': track.isDefault,
};

MediaItem? _mediaItemFromJson(Map<String, dynamic> json) {
  try {
    final id = '${json['id'] ?? ''}';
    final source = json['source'];
    if (id.isEmpty || source is! Map) return null;
    return MediaItem(
      id: id,
      title: '${json['title'] ?? ''}',
      type: '${json['type'] ?? ''}',
      source: MediaSource.fromJson(Map<String, dynamic>.from(source)),
      overview: json['overview'] as String?,
      imageUrl: _uri(json['imageUrl']),
      playbackUrl: _uri(json['playbackUrl']),
      year: (json['year'] as num?)?.toInt(),
      premiereDate: _date(json['premiereDate']),
      runtime: _duration(json['runtime']),
      headers: _stringMap(json['headers']),
      providerIds: _stringMap(json['providerIds']),
      parentId: json['parentId'] as String?,
      seriesId: json['seriesId'] as String?,
      seriesTitle: json['seriesTitle'] as String?,
      seasonNumber: (json['seasonNumber'] as num?)?.toInt(),
      episodeNumber: (json['episodeNumber'] as num?)?.toInt(),
      isContainer: json['isContainer'] == true,
      chapters: (json['chapters'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(
            (row) => MediaChapter(
              title: '${row['title'] ?? ''}',
              start: _duration(row['start']) ?? Duration.zero,
              end: _duration(row['end']),
            ),
          )
          .toList(growable: false),
      container: json['container'] as String?,
      size: (json['size'] as num?)?.toInt(),
      bitrate: (json['bitrate'] as num?)?.toInt(),
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
      videoCodec: json['videoCodec'] as String?,
      videoRange: json['videoRange'] as String?,
      bitDepth: (json['bitDepth'] as num?)?.toInt(),
      frameRate: (json['frameRate'] as num?)?.toDouble(),
      audioTracks: _tracks(json['audioTracks']),
      subtitleTracks: _tracks(json['subtitleTracks']),
      playbackPosition: _duration(json['playbackPosition']),
      isPlayed: json['isPlayed'] == true,
      lastPlayedAt: _date(json['lastPlayedAt']),
    );
  } catch (_) {
    return null;
  }
}

List<MediaTrack> _tracks(dynamic value) =>
    (value as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(
          (row) => MediaTrack(
            index: (row['index'] as num?)?.toInt() ?? 0,
            title: '${row['title'] ?? ''}',
            codec: '${row['codec'] ?? ''}',
            language: row['language'] as String?,
            channels: (row['channels'] as num?)?.toInt(),
            sampleRate: (row['sampleRate'] as num?)?.toInt(),
            bitrate: (row['bitrate'] as num?)?.toInt(),
            isDefault: row['isDefault'] == true,
          ),
        )
        .toList(growable: false);

Map<String, String> _stringMap(dynamic value) {
  if (value is! Map) return const {};
  return {
    for (final entry in value.entries) '${entry.key}': '${entry.value}',
  };
}

Uri? _uri(dynamic value) {
  if (value is! String || value.isEmpty) return null;
  return Uri.tryParse(value);
}

DateTime? _date(dynamic value) =>
    value is String ? DateTime.tryParse(value) : null;

Duration? _duration(dynamic value) => value is num
    ? Duration(milliseconds: value.toInt())
    : null;
