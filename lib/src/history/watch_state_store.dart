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
  );
}

class WatchStateStore {
  WatchStateStore(this._prefs);
  final SharedPreferences _prefs;
  static const key = 'yingji.watch-states';
  static Future<WatchStateStore> create() async =>
      WatchStateStore(await SharedPreferences.getInstance());

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
}

/// Sorts watch states by most recent watch time first. Entries that carry an
/// [WatchState.updatedAt] are ordered newest first; entries without one are
/// appended after them, preserving their previous relative order, so legacy
/// rows never leap over genuinely fresh ones.
List<WatchState> sortWatchStatesByRecency(Iterable<WatchState> source) {
  final rows = source.toList(growable: false);
  final dated = <WatchState>[];
  final undated = <WatchState>[];
  for (final row in rows) {
    (row.updatedAt == null ? undated : dated).add(row);
  }
  dated.sort((a, b) => b.updatedAt!.compareTo(a.updatedAt!));
  return [...dated, ...undated];
}
