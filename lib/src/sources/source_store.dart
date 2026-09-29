import 'dart:async';
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
  // SourceStore instances are cheap and several pages create their own. Serialize
  // read/modify/write operations across those instances so a background probe
  // cannot overwrite a concurrent server removal (or another server edit).
  static Future<void> _mutationTail = Future<void>.value();

  static Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _mutationTail = _mutationTail.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

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

  Future<void> upsert(MediaSource source, String token) => _serialize(() async {
    final rows = load().where((item) => item.id != source.id).toList()
      ..add(source);
    if (!await _prefs.setStringList(
      _key,
      rows.map((item) => jsonEncode(item.toJson())).toList(),
    )) {
      throw StateError('服务器列表写入失败');
    }
    await _vault.saveSecret('source.${source.id}', token);
  });

  /// Update a server discovered by a background refresh, but never recreate it
  /// if the user removed it while that refresh was in flight.
  Future<bool> updateIfPresent(MediaSource source, String token) => _serialize(
    () async {
      final rows = load();
      if (!rows.any((item) => item.id == source.id)) return false;
      final updated = rows.map((item) => item.id == source.id ? source : item);
      if (!await _prefs.setStringList(
        _key,
        updated.map((item) => jsonEncode(item.toJson())).toList(),
      )) {
        throw StateError('服务器列表写入失败');
      }
      await _vault.saveSecret('source.${source.id}', token);
      return true;
    },
  );

  String? tokenFor(MediaSource source) =>
      _vault.readSecret('source.${source.id}');

  /// Cached library statistics (movie/series/episode counts, latency and the
  /// check time), so the server page can render instantly without a network
  /// round-trip on every visit.
  String? statsFor(String sourceId) =>
      _prefs.getString('$_statsPrefix$sourceId');

  Future<void> saveStats(String sourceId, String json) => _serialize(() async {
    if (!load().any((item) => item.id == sourceId)) return;
    if (!await _prefs.setString('$_statsPrefix$sourceId', json)) {
      throw StateError('服务器统计缓存写入失败');
    }
  });

  Future<void> remove(MediaSource source) => _serialize(() async {
    final existing = load();
    final rows = existing.where((item) => item.id != source.id).toList();
    if (rows.length == existing.length) return;
    if (!await _prefs.setStringList(
      _key,
      rows.map((item) => jsonEncode(item.toJson())).toList(),
    )) {
      throw StateError('服务器列表写入失败，未删除登录凭据');
    }
    await _vault.deleteSecret('source.${source.id}');
    await _prefs.remove('$_statsPrefix${source.id}');
  });
}
