import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// How many watch-state rows the local store retains. Emby resume rails can
/// return up to 50 rows (server-side `Limit=50`), so the cache must be able
/// to hold a full rail; the visible shelf is no longer truncated to this size
/// when a server is reachable (the merge folds the whole rail in memory).
const int watchStateStoreCap = 60;

class WatchState {
  const WatchState({
    required this.mediaId,
    required this.title,
    required this.position,
    required this.duration,
    this.imageUrl,
    this.sourceId,
    this.serverItemId,
    this.tmdbId,
    this.episodeTitle,
    this.seasonNumber,
    this.episodeNumber,
    this.updatedAt,
    this.isPlayed = false,
    this.progressOrigin = 'local',
    this.progressOriginName,
  });
  final String mediaId;
  final String title;
  final Duration position;
  final Duration duration;
  final String? imageUrl;
  final String? sourceId;
  final String? serverItemId;
  final int? tmdbId;
  final String? episodeTitle;
  final int? seasonNumber;
  final int? episodeNumber;
  final DateTime? updatedAt;
  final bool isPlayed;

  /// Where the latest progress value was read from: local, server, or trakt.
  final String progressOrigin;
  final String? progressOriginName;
  bool get isCompleted =>
      isPlayed || (duration > Duration.zero && progress >= .92);
  double get progress => duration.inMilliseconds == 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0, 1);
  Map<String, dynamic> toJson() => {
    'mediaId': mediaId,
    'title': title,
    'position': position.inMilliseconds,
    'duration': duration.inMilliseconds,
    'imageUrl': imageUrl,
    'sourceId': sourceId,
    'serverItemId': serverItemId,
    'tmdbId': tmdbId,
    'episodeTitle': episodeTitle,
    'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
    'updatedAt': updatedAt?.toIso8601String(),
    'isPlayed': isPlayed,
    'progressOrigin': progressOrigin,
    'progressOriginName': progressOriginName,
  };
  factory WatchState.fromJson(Map<String, dynamic> value) => WatchState(
    mediaId: '${value['mediaId']}',
    title: '${value['title'] ?? '正在观看'}',
    position: Duration(milliseconds: (value['position'] as num?)?.toInt() ?? 0),
    duration: Duration(milliseconds: (value['duration'] as num?)?.toInt() ?? 0),
    imageUrl: value['imageUrl'] as String?,
    sourceId: value['sourceId'] as String?,
    serverItemId: value['serverItemId'] as String?,
    tmdbId: (value['tmdbId'] as num?)?.toInt(),
    episodeTitle: value['episodeTitle'] as String?,
    seasonNumber: (value['seasonNumber'] as num?)?.toInt(),
    episodeNumber: (value['episodeNumber'] as num?)?.toInt(),
    updatedAt: DateTime.tryParse('${value['updatedAt'] ?? ''}'),
    isPlayed: value['isPlayed'] == true,
    progressOrigin: '${value['progressOrigin'] ?? 'local'}',
    progressOriginName: value['progressOriginName'] as String?,
  );

  WatchState withUpdatedAt(DateTime? value) => WatchState(
    mediaId: mediaId,
    title: title,
    position: position,
    duration: duration,
    imageUrl: imageUrl,
    sourceId: sourceId,
    serverItemId: serverItemId,
    tmdbId: tmdbId,
    episodeTitle: episodeTitle,
    seasonNumber: seasonNumber,
    episodeNumber: episodeNumber,
    updatedAt: value,
    isPlayed: isPlayed,
    progressOrigin: progressOrigin,
    progressOriginName: progressOriginName,
  );

  WatchState withEpisodeMetadata({
    String? title,
    String? episodeTitle,
    int? tmdbId,
  }) => WatchState(
    mediaId: mediaId,
    title: title ?? this.title,
    position: position,
    duration: duration,
    imageUrl: imageUrl,
    sourceId: sourceId,
    serverItemId: serverItemId,
    tmdbId: tmdbId ?? this.tmdbId,
    episodeTitle: episodeTitle ?? this.episodeTitle,
    seasonNumber: seasonNumber,
    episodeNumber: episodeNumber,
    updatedAt: updatedAt,
    isPlayed: isPlayed,
    progressOrigin: progressOrigin,
    progressOriginName: progressOriginName,
  );

  WatchState withProgress({
    required Duration position,
    required DateTime? updatedAt,
    required String origin,
    String? originName,
  }) => WatchState(
    mediaId: mediaId,
    title: title,
    position: position,
    duration: duration,
    imageUrl: imageUrl,
    sourceId: sourceId,
    serverItemId: serverItemId,
    tmdbId: tmdbId,
    episodeTitle: episodeTitle,
    seasonNumber: seasonNumber,
    episodeNumber: episodeNumber,
    updatedAt: updatedAt,
    isPlayed: isPlayed,
    progressOrigin: origin,
    progressOriginName: originName,
  );

  /// Replace only the artwork pointer. Used by the one-shot resolution pass
  /// that upgrades broken/suspect cover URLs to a stable TMDB-backed image.
  WatchState withImage(String? value) => WatchState(
    mediaId: mediaId,
    title: title,
    position: position,
    duration: duration,
    imageUrl: value,
    sourceId: sourceId,
    serverItemId: serverItemId,
    tmdbId: tmdbId,
    episodeTitle: episodeTitle,
    seasonNumber: seasonNumber,
    episodeNumber: episodeNumber,
    updatedAt: updatedAt,
    isPlayed: isPlayed,
    progressOrigin: progressOrigin,
    progressOriginName: progressOriginName,
  );
}

class WatchStateStore {
  WatchStateStore(this._prefs);
  final SharedPreferences _prefs;
  static const key = 'yingji.watch-states';
  static Future<WatchStateStore> create() async =>
      WatchStateStore(await SharedPreferences.getInstance());

  /// 「观看记录只保存在本机」开关的存储键。默认关闭时与以前行为一致：把
  /// 进度同步到媒体服务器与 Trakt；打开后只写本机 —— 服务器资源照常播放，
  /// 服务器 / Trakt 上已有的记录也照常读取（只停回写，不停读取）。
  static const localOnlyKey = 'yingji.history.local-only';

  static Future<bool> localOnly() async =>
      (await SharedPreferences.getInstance()).getBool(localOnlyKey) ?? false;

  /// mediaIds that have already been through [_resolveArtworkForRows] — whether
  /// the resolution succeeded or failed. Persisted so the one-shot artwork
  /// upgrade does not re-hit TMDB on every app launch for rows that can never
  /// resolve (e.g. no tmdbId and the title search returned nothing). That
  /// re-resolution loop made the continue-watching shelf feel like it re-fetched
  /// covers on each open even though the image bytes themselves were cached.
  static const _resolvedArtworkKey = 'yingji.watch-artwork-resolved';

  Future<Set<String>> loadResolvedArtwork() async =>
      (_prefs.getStringList(_resolvedArtworkKey) ?? const <String>[]).toSet();

  /// Records that [mediaIds] have each been resolved exactly once. Called after
  /// a resolution pass so subsequent launches skip them; only genuinely new
  /// records (not yet in this set) ever trigger a TMDB lookup.
  Future<void> markArtworkResolved(Set<String> mediaIds) async {
    if (mediaIds.isEmpty) return;
    final next =
        (_prefs.getStringList(_resolvedArtworkKey) ?? const <String>[]).toSet()
          ..addAll(mediaIds);
    await _prefs.setStringList(_resolvedArtworkKey, next.toList());
  }

  /// Returns every stored record ordered by most recent watch time first.
  /// Records without a timestamp (written by very old builds) stay at the end
  /// in their stored order instead of arbitrarily jumping above dated ones.
  List<WatchState> load() {
    final rows = (_prefs.getStringList(key) ?? const [])
        .map((v) => WatchState.fromJson(jsonDecode(v) as Map<String, dynamic>))
        .toList();
    return sortWatchStatesByRecency(rows);
  }

  /// Saves [state] so it becomes the most recently watched record. When
  /// [updatedAt] is omitted the current time is used, which is right for this
  /// device's own playback; callers folding server history in can pass the
  /// server's real last-played time so remote records do not masquerade as
  /// freshly watched here.
  Future<void> save(WatchState state, {DateTime? updatedAt}) async {
    final rows = load().where((item) => item.mediaId != state.mediaId).toList()
      ..insert(0, state.withUpdatedAt(updatedAt ?? DateTime.now()));
    await _prefs.setStringList(
      key,
      sortWatchStatesByRecency(rows)
          .take(watchStateStoreCap)
          .map((item) => jsonEncode(item.toJson()))
          .toList(),
    );
  }

  Future<void> remove(String mediaId) async => _prefs.setStringList(
    key,
    load()
        .where((item) => item.mediaId != mediaId)
        .map((item) => jsonEncode(item.toJson()))
        .toList(),
  );

  /// Upserts [state] exactly as given without fabricating a timestamp: rows
  /// folded in from a media server keep their real last-played time, or stay
  /// undated (null) when the server reports none. Undated rows sort after all
  /// dated ones, so a server row without a known watch time never masquerades
  /// as freshly watched on this device and never leaps over genuinely recent
  /// local records.
  Future<void> import(WatchState state) async {
    final rows = load().where((item) => item.mediaId != state.mediaId).toList()
      ..insert(0, state);
    await _prefs.setStringList(
      key,
      sortWatchStatesByRecency(rows)
          .take(watchStateStoreCap)
          .map((item) => jsonEncode(item.toJson()))
          .toList(),
    );
  }

  /// Replaces the whole store with [states] in the given order. Called after a
  /// successful server merge so the persisted order always equals the order
  /// the shelf displays. Before this existed the merge only reordered rows in
  /// memory while per-row [import] writes kept inserting undated server rows
  /// at the head of the undated block — the stored order ended up the reverse
  /// of the server's rail, and every render that started from the local store
  /// (home shelf, full list page) flashed that wrong order until the next
  /// network merge finished.
  Future<void> replaceAll(Iterable<WatchState> states) async {
    await _prefs.setStringList(
      key,
      sortWatchStatesByRecency(states)
          .take(watchStateStoreCap)
          .map((item) => jsonEncode(item.toJson()))
          .toList(),
    );
  }

  Future<void> clear() => _prefs.remove(key);

  /// Writes resolved cover URLs back onto their records without touching the
  /// recency order or timestamps — so the artwork upgrade pass never reorders
  /// the shelf or stamps "now" on old rows. Keys are [WatchState.mediaId].
  Future<void> persistImages(Map<String, String> imageByMediaId) async {
    if (imageByMediaId.isEmpty) return;
    final rows = load().map((item) {
      final url = imageByMediaId[item.mediaId];
      return url != null ? item.withImage(url) : item;
    }).toList();
    await replaceAll(rows);
  }
}

/// Sorts continue-watching states by their real playback time. Dated entries
/// always come first and are newest-first. When a provider cannot supply a
/// timestamp, its rows follow in provider priority: Trakt, server, then local.
List<WatchState> sortWatchStatesByRecency(Iterable<WatchState> source) {
  int originPriority(WatchState row) => switch (row.progressOrigin) {
    'trakt' => 0,
    'server' => 1,
    _ => 2,
  };

  final indexed = source.toList(growable: false).indexed.toList();
  indexed.sort((a, b) {
    final aTime = a.$2.updatedAt;
    final bTime = b.$2.updatedAt;
    if (aTime != null && bTime != null) {
      final byTime = bTime.compareTo(aTime);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    }
    if (aTime != null) return -1;
    if (bTime != null) return 1;
    final byOrigin = originPriority(a.$2).compareTo(originPriority(b.$2));
    return byOrigin != 0 ? byOrigin : a.$1.compareTo(b.$1);
  });
  return indexed.map((entry) => entry.$2).toList(growable: false);
}

/// 「第 1 集」「Episode 2」这类只有序号的通用集名 —— 作为副标题毫无信息量。
final RegExp _genericEpisodeLabel = RegExp(
  r'^(?:第\s*\d+\s*[集话話]|EP?\s*\d+|Episode\s*\d+)$',
  caseSensitive: false,
);

/// 清洗写入路径可能产生的两类脏数据，返回可直接入库/上架的副本：
///
/// 1. 副标题与剧名同名 —— 部分服务器的单集条目会直接以剧名命名（如
///    「叛逆的女仆」的 E2 条目标题也叫「叛逆的女仆」），副标题就变成
///    「S1E2 · 叛逆的女仆」。清空后卡片回退显示「第 N 集」。
/// 2. 副标题是通用集名（「第 2 集」）—— 与卡片缺省回退重复，清掉一致化。
///
/// 剧名本身不动：旧版本把单集名写进 title 的存量行只能在合并时用服务器的
/// 权威命名自愈（见 [_mergeServerWatchHistory]），这里没有可靠依据改名。
WatchState normalizeWatchState(WatchState state) {
  final episodic = state.seasonNumber != null || state.episodeNumber != null;
  var episodeTitle = state.episodeTitle;
  if (episodic && episodeTitle != null) {
    final trimmed = episodeTitle.trim();
    if (trimmed.isEmpty ||
        trimmed == state.title.trim() ||
        _genericEpisodeLabel.hasMatch(trimmed)) {
      episodeTitle = null;
    }
  }
  if (episodeTitle == state.episodeTitle) return state;
  return WatchState(
    mediaId: state.mediaId,
    title: state.title,
    position: state.position,
    duration: state.duration,
    imageUrl: state.imageUrl,
    sourceId: state.sourceId,
    serverItemId: state.serverItemId,
    tmdbId: state.tmdbId,
    episodeTitle: null,
    seasonNumber: state.seasonNumber,
    episodeNumber: state.episodeNumber,
    updatedAt: state.updatedAt,
    isPlayed: state.isPlayed,
    progressOrigin: state.progressOrigin,
    progressOriginName: state.progressOriginName,
  );
}

/// A display projection only: episode history stays intact for resume/rewatch.
List<WatchState> continueWatchingRows(Iterable<WatchState> history) {
  final seen = <String>{};
  final seenItems = <String>{};
  final result = <WatchState>[];
  for (final row in sortWatchStatesByRecency(history)) {
    final episodic = row.episodeNumber != null || row.seasonNumber != null;
    final name = row.title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final aliases = <String>[
      if (row.tmdbId != null && row.tmdbId! > 0)
        '${episodic ? 'tv' : 'movie'}:${row.tmdbId}',
      if (episodic && name.isNotEmpty) 'series:$name',
      if (!episodic) 'item:${row.sourceId}:${row.serverItemId ?? row.mediaId}',
      if (episodic && name.isEmpty)
        'item:${row.sourceId}:${row.serverItemId ?? row.mediaId}',
    ];
    // Resolve the latest state per episode before grouping resumable shows.
    // Marking one episode watched must not hide another episode's progress.
    final itemAliases = <String>[
      'item:${row.sourceId}:${row.serverItemId ?? row.mediaId}',
      if (episodic && row.episodeNumber != null)
        for (final alias in aliases)
          '$alias:season:${row.seasonNumber}:episode:${row.episodeNumber}',
      if (!episodic) ...aliases,
    ];
    final alreadySeen = itemAliases.any(seenItems.contains);
    seenItems.addAll(itemAliases);
    if (alreadySeen || row.isCompleted || row.position <= Duration.zero) {
      continue;
    }
    if (aliases.any(seen.contains)) {
      seen.addAll(aliases);
      continue;
    }
    seen.addAll(aliases);
    result.add(row);
  }
  return result;
}
