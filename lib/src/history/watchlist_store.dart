import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../metadata/tmdb_client.dart';

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
  }

  /// 移出待看。
  Future<void> remove(int id) async {
    await _save(load().where((value) => value.id != id).toList());
  }

  Future<void> toggle(TmdbItem item) async {
    if (contains(item.id)) {
      await remove(item.id);
    } else {
      await add(item);
    }
  }

  Future<void> _save(List<TmdbItem> rows) async {
    await _prefs.setStringList(
      _key,
      rows.map((value) => jsonEncode(value.toJson())).toList(),
    );
  }
}
