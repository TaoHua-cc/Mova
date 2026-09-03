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

  Future<void> toggle(TmdbItem item) async {
    final rows = load().where((value) => value.id != item.id).toList();
    if (!load().any((value) => value.id == item.id)) rows.insert(0, item);
    await _prefs.setStringList(
      _key,
      rows.map((value) => jsonEncode(value.toJson())).toList(),
    );
  }
}
