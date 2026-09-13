import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../player/danmaku_client.dart';

/// 一次弹幕缓存的内容。
class DanmakuCacheEntry {
  DanmakuCacheEntry({
    required this.comments,
    required this.savedAt,
    this.matchedEpisode,
  });

  final List<DanmakuComment> comments;
  final DateTime savedAt;
  final String? matchedEpisode;

  /// 超过这个时长就值得再拉一次（弹幕会被后来的观众补充）。
  bool get isStale => DateTime.now().difference(savedAt) > DanmakuCache.refreshAfter;
}

/// 弹幕缓存：把匹配结果按「API 列表 + 标题 + 季 + 集」存成本机 JSON。
///
/// 弹幕接口每次播放都要跑一次匹配（有的还要先 `/api/v2/match` 再取评论），
/// 同一集看第二遍时这一步纯属浪费。缓存后播放器先用本地的把弹幕铺上，
/// 超过 [DanmakuCache.refreshAfter] 才在后台补拉一次。
class DanmakuCache {
  DanmakuCache._(this._root);

  static const String _folder = 'mova-danmaku-cache';

  /// 缓存多久之后算「旧」，需要后台刷新。
  static const Duration refreshAfter = Duration(hours: 24);

  /// 缓存多久没用过就删掉，避免长期堆积。
  static const Duration maxAge = Duration(days: 60);

  /// 最多缓存多少集。
  static const int maxEntries = 400;

  final Directory _root;

  static Future<DanmakuCache?> tryCreate() async {
    try {
      final base = await getApplicationSupportDirectory();
      final root = Directory('${base.path}${Platform.pathSeparator}$_folder');
      if (!await root.exists()) {
        await root.create(recursive: true);
      }
      return DanmakuCache._(root);
    } catch (_) {
      return null;
    }
  }

  /// 缓存键。
  ///
  /// API 列表一起进键：换了个弹幕源，取回的应该是新源的弹幕，而不是旧源
  /// 的旧缓存。标题与季 / 集决定匹配的是哪一集。
  static String keyFor({
    required List<String> apis,
    String? title,
    int? season,
    int? episode,
  }) {
    final seed = <String>[
      ...apis,
      title?.trim().toLowerCase() ?? '',
      '${season ?? 0}',
      '${episode ?? 0}',
    ].join('');
    var hash = 0x811c9dc5;
    for (final unit in seed.codeUnits) {
      hash = (hash ^ unit) & 0xFFFFFFFF;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _path(String key) =>
      '${_root.path}${Platform.pathSeparator}$key.json';

  Future<DanmakuCacheEntry?> read(String key) async {
    final file = File(_path(key));
    if (!await file.exists()) return null;
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return null;
      final raw = data['comments'];
      if (raw is! List) return null;
      final comments = raw
          .map(_decodeComment)
          .whereType<DanmakuComment>()
          .toList(growable: false);
      final saved =
          data['savedAt'] is int
              ? DateTime.fromMillisecondsSinceEpoch(data['savedAt'] as int)
              : DateTime.now();
      final matched = data['matched'];
      return DanmakuCacheEntry(
        comments: comments,
        savedAt: saved,
        matchedEpisode: matched is String ? matched : null,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> write(
    String key,
    List<DanmakuComment> comments, {
    String? matchedEpisode,
  }) async {
    if (comments.isEmpty) return;
    try {
      await File(_path(key)).writeAsString(
        jsonEncode(<String, dynamic>{
          'savedAt': DateTime.now().millisecondsSinceEpoch,
          'matched': matchedEpisode,
          'comments': comments.map(_encodeComment).toList(growable: false),
        }),
      );
      unawaited(_evictIfNeeded());
    } catch (_) {}
  }

  Future<int> clear() async {
    var removed = 0;
    await for (final entity in _root.list(followLinks: false)) {
      if (entity is! File) continue;
      removed++;
      try {
        await entity.delete();
      } catch (_) {}
    }
    return removed;
  }

  Future<int> count() async {
    var total = 0;
    await for (final entity in _root.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.json')) total++;
    }
    return total;
  }

  Future<int> usageBytes() async {
    var total = 0;
    await for (final entity in _root.list(followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {}
      }
    }
    return total;
  }

  /// 超出份数或过期太久的缓存删掉。写缓存后顺手跑一次，不做成定时任务 ——
  /// 弹幕缓存很小，堆到几百份也才几 MB，没必要额外维护。
  Future<void> _evictIfNeeded() async {
    final files = <_EntryFile>[];
    await for (final entity in _root.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      files.add(_EntryFile(entity, await _savedAt(entity)));
    }
    final cutoff = DateTime.now().subtract(maxAge);
    for (final entry in files) {
      if (entry.savedAt.isBefore(cutoff)) {
        try {
          await entry.file.delete();
        } catch (_) {}
      }
    }
    if (files.length <= maxEntries) return;
    files.sort((a, b) => a.savedAt.compareTo(b.savedAt));
    for (final entry in files.take(files.length - maxEntries)) {
      try {
        await entry.file.delete();
      } catch (_) {}
    }
  }

  Future<DateTime> _savedAt(File file) async {
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is Map && data['savedAt'] is int) {
        return DateTime.fromMillisecondsSinceEpoch(data['savedAt'] as int);
      }
    } catch (_) {}
    try {
      return await file.lastModified();
    } catch (_) {
      return DateTime.now();
    }
  }

  static List<dynamic> _encodeComment(DanmakuComment comment) => <dynamic>[
    comment.time.inMilliseconds,
    comment.content,
    comment.color,
    comment.mode.index,
  ];

  static DanmakuComment? _decodeComment(dynamic value) {
    if (value is! List || value.length < 2) return null;
    final content = '${value[1]}'.trim();
    if (content.isEmpty) return null;
    final ms = value[0] is int ? value[0] as int : int.tryParse('${value[0]}');
    if (ms == null) return null;
    final color = value.length > 2 && value[2] is int ? value[2] as int : null;
    final modeIndex = value.length > 3 && value[3] is int ? value[3] as int : 0;
    return DanmakuComment(
      time: Duration(milliseconds: ms < 0 ? 0 : ms),
      content: content,
      color: color,
      mode: DanmakuMode.values[modeIndex.clamp(0, DanmakuMode.values.length - 1)],
    );
  }
}

class _EntryFile {
  _EntryFile(this.file, this.savedAt);
  final File file;
  final DateTime savedAt;
}
