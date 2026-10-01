import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

import '../metadata/tmdb_client.dart';
import '../tracking/tracking_status_store.dart';

class WatchlistStore {
  WatchlistStore(this._prefs);
  final SharedPreferences _prefs;
  static const _key = 'yingji.watchlist';
  static Future<WatchlistStore> create() async =>
      WatchlistStore(await SharedPreferences.getInstance());

  List<TmdbItem> load() => (_prefs.getStringList(_key) ?? const [])
      .map(
        (value) => TmdbItem.fromJson(jsonDecode(value) as Map<String, dynamic>),
      )
      .toList(growable: false);

  bool contains(int id) => load().any((value) => value.id == id);

  /// 加入待看。同 id 的旧条目先移除，列表里不会出现重复项。
  Future<void> add(TmdbItem item) async {
    final rows = load().where((value) => value.id != item.id).toList();
    rows.insert(0, item);
    await _save(rows);
    if (item.kind == '剧集') {
      await TrackingStatusStore.resume(_prefs, item.title, item.id);
    }
  }

  /// 移出待看。
  Future<void> remove(int id) async {
    await _save(load().where((value) => value.id != id).toList());
  }

  /// Apply a Trakt reconciliation atomically while preserving existing Mova
  /// metadata for entries that are already in the local watchlist.
  Future<void> reconcile({
    Iterable<TmdbItem> add = const [],
    Set<int> removeIds = const {},
  }) async {
    final rows = load().where((item) => !removeIds.contains(item.id)).toList();
    final ids = rows.map((item) => item.id).toSet();
    rows.insertAll(0, add.where((item) => item.id > 0 && ids.add(item.id)));
    await _save(rows);
  }

  Future<void> toggle(TmdbItem item) async {
    if (contains(item.id)) {
      await remove(item.id);
    } else {
      await add(item);
    }
  }

  Future<void> _save(List<TmdbItem> rows) async {
    final next = rows.map((value) => jsonEncode(value.toJson())).toList();
    if (listEquals(_prefs.getStringList(_key) ?? const <String>[], next)) {
      return;
    }
    await _prefs.setStringList(_key, next);
    TrackingStatusStore.revision.value++;
  }
}
