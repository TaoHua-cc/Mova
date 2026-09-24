import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Large, replaceable Windows metadata lives beside preferences, one entry per
/// file. Android keeps its existing SharedPreferences path for now.
abstract final class WindowsMetadataCache {
  static const tmdb = 'tmdb';
  static const schedule = 'schedule';
  static const detail = 'detail';
  static const discover = 'discover';
  static const _directoryName = 'metadata-cache-v1';

  static Future<Directory>? _rootFuture;
  static final Map<String, Future<void>> _pendingWrites = {};

  static Future<Directory> _root() => _rootFuture ??= () async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}$_directoryName');
  }();

  static String _fileName(String key) =>
      '${sha256.convert(utf8.encode(key))}.json';

  static Future<File> _file(String domain, String key) async {
    final root = await _root();
    return File(
      '${root.path}${Platform.pathSeparator}$domain'
      '${Platform.pathSeparator}${_fileName(key)}',
    );
  }

  static Future<({String value, String? savedAt})?> read(
    String domain,
    String key,
  ) async {
    if (!Platform.isWindows) return null;
    try {
      final file = await _file(domain, key);
      if (!await file.exists()) return null;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map || data['key'] != key || data['value'] is! String) {
        return null;
      }
      return (
        value: data['value'] as String,
        savedAt: data['savedAt'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(
    String domain,
    String key,
    String value, {
    String? savedAt,
  }) async {
    if (!Platform.isWindows) return;
    final id = '$domain:$key';
    final previous = _pendingWrites[id];
    final work = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // A failed older refresh must not block the next valid response.
        }
      }
      await _writeFile(domain, key, value, savedAt);
    }();
    _pendingWrites[id] = work;
    try {
      await work;
    } finally {
      if (identical(_pendingWrites[id], work)) _pendingWrites.remove(id);
    }
  }

  static Future<void> _writeFile(
    String domain,
    String key,
    String value,
    String? savedAt,
  ) async {
    final file = await _file(domain, key);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'key': key, 'value': value, 'savedAt': savedAt}),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  static Future<int> clear(String domain) async {
    if (!Platform.isWindows) return 0;
    for (final pending
        in _pendingWrites.entries
            .where((entry) => entry.key.startsWith('$domain:'))
            .map((entry) => entry.value)
            .toList()) {
      try {
        await pending;
      } catch (_) {}
    }
    final root = await _root();
    final directory = Directory('${root.path}${Platform.pathSeparator}$domain');
    if (!await directory.exists()) return 0;
    var count = 0;
    await for (final file in directory.list()) {
      if (file is File && file.path.endsWith('.json')) {
        await file.delete();
        count++;
      }
    }
    return count;
  }

  static Future<int> count(String domain) async {
    if (!Platform.isWindows) return 0;
    final root = await _root();
    final directory = Directory('${root.path}${Platform.pathSeparator}$domain');
    if (!await directory.exists()) return 0;
    return directory
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.json'))
        .length;
  }

  static Future<void> prune(String domain, int capacity) async {
    if (!Platform.isWindows) return;
    final root = await _root();
    final directory = Directory('${root.path}${Platform.pathSeparator}$domain');
    if (!await directory.exists()) return;
    final files = await directory
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.json'))
        .cast<File>()
        .toList();
    if (files.length <= capacity) return;
    final dated = await Future.wait(
      files.map(
        (file) async => (file: file, modified: await file.lastModified()),
      ),
    );
    dated.sort((a, b) => a.modified.compareTo(b.modified));
    for (final entry in dated.take(dated.length - capacity)) {
      await entry.file.delete();
    }
  }

  /// Runs before SharedPreferences is initialized. The expensive old JSON
  /// decode/write happens on a worker isolate so the brand frame keeps moving.
  static Future<void> migrateLegacy() async {
    if (!Platform.isWindows) return;
    try {
      final support = await getApplicationSupportDirectory();
      final path = support.path;
      await Isolate.run(() => migrateLegacyFiles(path));
    } catch (_) {
      // Leave old preferences intact; callers still have a legacy read path.
    }
  }
}

/// Isolate-safe migration. The old file is only replaced after every cache
/// record has been written. An interrupted replacement is recovered next run.
void migrateLegacyFiles(String supportPath) {
  final separator = Platform.pathSeparator;
  final preferences = File('$supportPath${separator}shared_preferences.json');
  final backup = File('${preferences.path}.before-metadata-cache-v1');
  if (!preferences.existsSync() && backup.existsSync()) {
    backup.renameSync(preferences.path);
  }
  if (!preferences.existsSync() || preferences.lengthSync() < 512 * 1024) {
    return;
  }
  final raw = jsonDecode(preferences.readAsStringSync());
  if (raw is! Map<String, dynamic>) return;
  final moved = <String>[];
  final root = '$supportPath${separator}metadata-cache-v1';
  for (final entry in raw.entries) {
    final diskKey = entry.key;
    if (!diskKey.startsWith('flutter.') || entry.value is! String) continue;
    final key = diskKey.substring('flutter.'.length);
    final domain = switch (key) {
      _
          when key.startsWith('yingji.tmdb.cache.') &&
              !key.endsWith('.savedAt') =>
        WindowsMetadataCache.tmdb,
      _ when key.startsWith('yingji.schedule.') =>
        WindowsMetadataCache.schedule,
      _ when key.startsWith('yingji.detail.res.v1.') =>
        WindowsMetadataCache.detail,
      _ => null,
    };
    if (domain == null) continue;
    final savedAt = domain == WindowsMetadataCache.tmdb
        ? raw['$diskKey.savedAt'] as String?
        : null;
    final directory = Directory('$root$separator$domain')
      ..createSync(recursive: true);
    final file = File(
      '${directory.path}$separator${sha256.convert(utf8.encode(key))}.json',
    );
    var existingIsValid = false;
    if (file.existsSync()) {
      try {
        existingIsValid =
            (jsonDecode(file.readAsStringSync()) as Map)['key'] == key;
      } catch (_) {}
    }
    if (!existingIsValid) {
      final temporary = File('${file.path}.tmp');
      temporary.writeAsStringSync(
        jsonEncode({'key': key, 'value': entry.value, 'savedAt': savedAt}),
        flush: true,
      );
      if (file.existsSync()) file.deleteSync();
      temporary.renameSync(file.path);
      final saved = DateTime.tryParse(savedAt ?? '');
      if (saved != null) file.setLastModifiedSync(saved);
    }
    moved.add(diskKey);
    if (savedAt != null) moved.add('$diskKey.savedAt');
  }
  if (moved.isEmpty) return;
  for (final key in moved) {
    raw.remove(key);
  }
  final next = File('${preferences.path}.next');
  next.writeAsStringSync(jsonEncode(raw), flush: true);
  if (backup.existsSync()) backup.deleteSync();
  preferences.renameSync(backup.path);
  try {
    next.renameSync(preferences.path);
  } catch (_) {
    backup.renameSync(preferences.path);
    rethrow;
  }
}
