import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../metadata/tmdb_client.dart';
import 'windows_metadata_cache.dart';

/// 上次显示的真实发现栏目。源/筛选变化会自然落到另一份快照。
abstract final class DiscoverSnapshotCache {
  static const _capacity = 96;
  static int _writes = 0;
  static Future<Directory>? _androidRoot;
  static final Map<String, Future<void>> _pendingWrites = {};

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
    final raw = Platform.isWindows
        ? (await WindowsMetadataCache.read(
            WindowsMetadataCache.discover,
            key,
          ))?.value
        : Platform.isAndroid
        ? await _readAndroid(key)
        : null;
    return raw == null ? null : decode(raw);
  }

  static Future<void> write(String key, List<TmdbItem> rows) async {
    if (rows.isEmpty || (!Platform.isWindows && !Platform.isAndroid)) return;
    final value = jsonEncode({
      'version': 1,
      'rows': rows.take(20).map((item) => item.toJson()).toList(),
    });
    if (Platform.isWindows) {
      await WindowsMetadataCache.write(
        WindowsMetadataCache.discover,
        key,
        value,
      );
    } else {
      await _writeAndroid(key, value);
    }
    if (++_writes % 16 == 0) {
      if (Platform.isWindows) {
        await WindowsMetadataCache.prune(
          WindowsMetadataCache.discover,
          _capacity,
        );
      } else {
        await _pruneAndroid();
      }
    }
  }

  static Future<int> clear() async {
    if (Platform.isWindows) {
      return WindowsMetadataCache.clear(WindowsMetadataCache.discover);
    }
    if (!Platform.isAndroid) return 0;
    final root = await _androidDirectory();
    if (!await root.exists()) return 0;
    var count = 0;
    await for (final entry in root.list()) {
      if (entry is File && entry.path.endsWith('.json')) {
        await entry.delete();
        count++;
      }
    }
    return count;
  }

  static Future<int> count() async {
    if (Platform.isWindows) {
      return WindowsMetadataCache.count(WindowsMetadataCache.discover);
    }
    if (!Platform.isAndroid) return 0;
    final root = await _androidDirectory();
    if (!await root.exists()) return 0;
    return root
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.json'))
        .length;
  }

  static Future<Directory> _androidDirectory() async {
    final root = await (_androidRoot ??= () async {
      final support = await getApplicationSupportDirectory();
      return Directory(
        '${support.path}${Platform.pathSeparator}metadata-cache-v1'
        '${Platform.pathSeparator}discover',
      );
    }());
    await root.create(recursive: true);
    return root;
  }

  static Future<File> _androidFile(String key) async {
    final root = await _androidDirectory();
    final name = sha256.convert(utf8.encode(key));
    return File('${root.path}${Platform.pathSeparator}$name.json');
  }

  static Future<String?> _readAndroid(String key) async {
    try {
      final file = await _androidFile(key);
      if (!await file.exists()) return null;
      final record = jsonDecode(await file.readAsString());
      if (record is! Map ||
          record['key'] != key ||
          record['value'] is! String) {
        return null;
      }
      return record['value'] as String;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeAndroid(String key, String value) async {
    final file = await _androidFile(key);
    final id = file.path;
    final previous = _pendingWrites[id];
    final work = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({'key': key, 'value': value}),
        flush: true,
      );
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    }();
    _pendingWrites[id] = work;
    try {
      await work;
    } finally {
      if (identical(_pendingWrites[id], work)) _pendingWrites.remove(id);
    }
  }

  static Future<void> _pruneAndroid() async {
    final root = await _androidDirectory();
    final files = await root
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.json'))
        .cast<File>()
        .toList();
    if (files.length <= _capacity) return;
    final dated = await Future.wait(
      files.map(
        (file) async => (file: file, modified: await file.lastModified()),
      ),
    );
    dated.sort((a, b) => a.modified.compareTo(b.modified));
    for (final entry in dated.take(dated.length - _capacity)) {
      await entry.file.delete();
    }
  }
}
