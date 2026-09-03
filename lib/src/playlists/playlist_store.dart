import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../metadata/tmdb_client.dart';

class YingjiPlaylist {
  const YingjiPlaylist({
    required this.id,
    required this.name,
    required this.createdAt,
    this.items = const [],
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final List<TmdbItem> items;

  YingjiPlaylist copyWith({String? name, List<TmdbItem>? items}) =>
      YingjiPlaylist(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        items: items ?? this.items,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'items': items.map((item) => item.toJson()).toList(),
  };

  factory YingjiPlaylist.fromJson(Map<String, dynamic> json) => YingjiPlaylist(
    id: '${json['id']}',
    name: '${json['name'] ?? '未命名片单'}',
    createdAt: DateTime.tryParse('${json['createdAt']}') ?? DateTime.now(),
    items: (json['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(TmdbItem.fromJson)
        .toList(growable: false),
  );
}

class PlaylistStore {
  PlaylistStore(this._prefs);
  final SharedPreferences _prefs;
  static const _key = 'yingji.playlists';

  static Future<PlaylistStore> create() async =>
      PlaylistStore(await SharedPreferences.getInstance());

  List<YingjiPlaylist> load() => (_prefs.getStringList(_key) ?? const [])
      .map((value) => jsonDecode(value))
      .whereType<Map<String, dynamic>>()
      .map(YingjiPlaylist.fromJson)
      .toList(growable: false);

  Future<void> save(YingjiPlaylist playlist) async {
    final rows = load().where((item) => item.id != playlist.id).toList()
      ..insert(0, playlist);
    await _write(rows);
  }

  Future<void> remove(String id) =>
      _write(load().where((item) => item.id != id).toList());

  Future<void> _write(List<YingjiPlaylist> rows) => _prefs.setStringList(
    _key,
    rows.map((item) => jsonEncode(item.toJson())).toList(),
  );
}
