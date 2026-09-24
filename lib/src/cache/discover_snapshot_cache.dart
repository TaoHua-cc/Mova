import 'dart:convert';

import '../metadata/tmdb_client.dart';
import 'windows_metadata_cache.dart';

/// Windows 上次显示的真实发现栏目。源/筛选变化会自然落到另一份快照。
abstract final class DiscoverSnapshotCache {
  static const _capacity = 96;
  static int _writes = 0;

  static String key(String title, String source, String filters) =>
      jsonEncode([title, source, filters]);

  static List<TmdbItem>? decode(String raw) {
    try {
      final data = jsonDecode(raw);
      if (data is! Map || data['version'] != 1 || data['rows'] is! List) {
        return null;
      }
      final rows = <TmdbItem>[];
      for (final value in data['rows'] as List) {
        if (value is! Map<String, dynamic>) return null;
        final item = TmdbItem.fromJson(value);
        if (item.id <= 0) return null;
        rows.add(item);
      }
      return rows.take(20).toList(growable: false);
    } catch (_) {
      return null;
    }
  }

  static Future<List<TmdbItem>?> read(String key) async {
    final entry = await WindowsMetadataCache.read(
      WindowsMetadataCache.discover,
      key,
    );
    return entry == null ? null : decode(entry.value);
  }

  static Future<void> write(String key, List<TmdbItem> rows) async {
    if (rows.isEmpty) return;
    await WindowsMetadataCache.write(
      WindowsMetadataCache.discover,
      key,
      jsonEncode({
        'version': 1,
        'rows': rows.take(20).map((item) => item.toJson()).toList(),
      }),
    );
    if (++_writes % 16 == 0) {
      await WindowsMetadataCache.prune(
        WindowsMetadataCache.discover,
        _capacity,
      );
    }
  }

  static Future<int> clear() =>
      WindowsMetadataCache.clear(WindowsMetadataCache.discover);

  static Future<int> count() =>
      WindowsMetadataCache.count(WindowsMetadataCache.discover);
}
