import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../security/secure_vault.dart';
import 'media_source.dart';

class SourceStore {
  SourceStore(this._prefs, this._vault);
  final SharedPreferences _prefs;
  final SecureVault _vault;
  static const _key = 'yingji.sources';
  static const _statsPrefix = 'yingji.source-stats.';

  static Future<SourceStore> create() async => SourceStore(
    await SharedPreferences.getInstance(),
    await SecureVault.create(),
  );

  List<MediaSource> load() {
    final raw = _prefs.getStringList(_key) ?? const [];
    return raw
        .map((value) => jsonDecode(value))
        .whereType<Map<String, dynamic>>()
        .map(MediaSource.fromJson)
        .toList(growable: false);
  }

  Future<void> upsert(MediaSource source, String token) async {
    final rows = load().where((item) => item.id != source.id).toList()
      ..add(source);
    await _prefs.setStringList(
      _key,
      rows.map((item) => jsonEncode(item.toJson())).toList(),
    );
    await _vault.saveSecret('source.${source.id}', token);
  }

  String? tokenFor(MediaSource source) =>
      _vault.readSecret('source.${source.id}');

  /// Cached library statistics (movie/series/episode counts, latency and the
  /// check time), so the server page can render instantly without a network
  /// round-trip on every visit.
  String? statsFor(String sourceId) =>
      _prefs.getString('$_statsPrefix$sourceId');

  Future<void> saveStats(String sourceId, String json) =>
      _prefs.setString('$_statsPrefix$sourceId', json);

  Future<void> remove(MediaSource source) async {
    final rows = load().where((item) => item.id != source.id);
    await _prefs.setStringList(
      _key,
      rows.map((item) => jsonEncode(item.toJson())).toList(),
    );
    await _vault.deleteSecret('source.${source.id}');
    await _prefs.remove('$_statsPrefix${source.id}');
  }
}
