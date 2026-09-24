import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/cache/windows_metadata_cache.dart';

void main() {
  test('migration preserves settings and all cache values across retries', () {
    final support = Directory.systemTemp.createTempSync('mova-cache-migrate-');
    addTearDown(() => support.deleteSync(recursive: true));
    final preferences = File(
      '${support.path}${Platform.pathSeparator}shared_preferences.json',
    );
    const tmdbKey = 'yingji.tmdb.cache.example';
    const scheduleKey = 'yingji.schedule.example';
    const detailKey = 'yingji.detail.res.v1.tv.1';
    final old = <String, dynamic>{
      'flutter.yingji.discover.sections': ['今日热门电视剧'],
      'flutter.yingji.appearance.icon': 'play',
      'flutter.yingji.test.padding': 'x' * (512 * 1024),
      'flutter.$tmdbKey': '{"results":[]}',
      'flutter.$tmdbKey.savedAt': '2026-09-24T08:00:00.000',
      'flutter.$scheduleKey': '{"data":[1]}',
      'flutter.$detailKey': '{"rows":[1]}',
    };
    preferences.writeAsStringSync(jsonEncode(old));

    migrateLegacyFiles(support.path);
    final current = jsonDecode(preferences.readAsStringSync()) as Map;
    expect(current['flutter.yingji.discover.sections'], ['今日热门电视剧']);
    expect(current['flutter.yingji.appearance.icon'], 'play');
    expect(current.containsKey('flutter.$tmdbKey'), isFalse);
    expect(current.containsKey('flutter.$scheduleKey'), isFalse);
    expect(current.containsKey('flutter.$detailKey'), isFalse);

    final cacheRoot = Directory(
      '${support.path}${Platform.pathSeparator}metadata-cache-v1',
    );
    for (final (domain, key, value) in [
      (WindowsMetadataCache.tmdb, tmdbKey, '{"results":[]}'),
      (WindowsMetadataCache.schedule, scheduleKey, '{"data":[1]}'),
      (WindowsMetadataCache.detail, detailKey, '{"rows":[1]}'),
    ]) {
      final files = Directory(
        '${cacheRoot.path}${Platform.pathSeparator}$domain',
      ).listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      final stored = jsonDecode(files.single.readAsStringSync()) as Map;
      expect(stored['key'], key);
      expect(stored['value'], value);
    }

    migrateLegacyFiles(support.path);
    expect(jsonDecode(preferences.readAsStringSync()), current);
  });

  test('interrupted preferences replacement restores the old file', () {
    final support = Directory.systemTemp.createTempSync('mova-cache-restore-');
    addTearDown(() => support.deleteSync(recursive: true));
    final preferences = File(
      '${support.path}${Platform.pathSeparator}shared_preferences.json',
    );
    final backup = File('${preferences.path}.before-metadata-cache-v1');
    backup.writeAsStringSync(
      jsonEncode({'flutter.yingji.home.carousel-source': 'top-rated'}),
    );

    migrateLegacyFiles(support.path);

    expect(preferences.existsSync(), isTrue);
    expect(
      (jsonDecode(preferences.readAsStringSync())
          as Map)['flutter.yingji.home.carousel-source'],
      'top-rated',
    );
  });
}
