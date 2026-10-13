import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/sources/media_source.dart';
import 'package:yingji/src/sources/server_mark.dart';
import 'package:yingji/src/sources/source_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    folder = await Directory.systemTemp.createTemp('mova-icons-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => folder.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await folder.delete(recursive: true);
  });

  MediaSource source(String id, {String? url, bool custom = false}) =>
      MediaSource(
        id: id,
        name: 'Test',
        kind: SourceKind.emby,
        endpoint: Uri.parse('https://media.invalid'),
        iconUrl: url,
        customIcon: custom,
      );

  test('saved custom icon resolves offline from disk', () async {
    final item = source(
      'offline',
      url: 'https://icons.invalid/icon.png',
      custom: true,
    );
    final digest = sha256.convert(utf8.encode('${item.id}|c|${item.iconUrl}'));
    final file = File(
      '${folder.path}${Platform.pathSeparator}server_marks${Platform.pathSeparator}$digest.png',
    );
    await file.parent.create(recursive: true);
    await file.writeAsBytes(
      image.encodePng(image.Image(width: 2, height: 2, numChannels: 4)),
    );
    expect(await cacheServerMarkFile(item, null), file.path);
  });

  test('local cache identities distinguish complete URLs and sources', () async {
    for (final id in ['a', 'b']) {
      final item = source(
        id,
        url: 'https://same.invalid/long/common/prefix/icon.png',
      );
      final digest = sha256.convert(utf8.encode('$id|s|${item.iconUrl}'));
      final file = File(
        '${folder.path}${Platform.pathSeparator}server_marks${Platform.pathSeparator}$digest.png',
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(
        image.encodePng(image.Image(width: 2, height: 2)),
      );
      expect(await cacheServerMarkFile(item, null), file.path);
    }
  });

  test('late probe preserves selected icon, reset and source order', () async {
    final store = await SourceStore.create();
    final old = source('one', url: 'https://icons.invalid/old.png');
    await store.upsert(old, 'test-token');
    await store.upsert(source('two'), 'test-token');
    await store.setIcon('one', 'https://icons.invalid/selected.png');
    await store.updateIfPresent(old, 'test-token', observedSource: old);
    expect(store.load().first.iconUrl, 'https://icons.invalid/selected.png');
    final selected = store.load().first;
    await store.setIcon('one', null);
    await store.updateIfPresent(
      selected,
      'test-token',
      observedSource: selected,
    );
    expect(store.load().first.iconUrl, isNull);
    expect(store.load().map((item) => item.id), ['one', 'two']);
    await store.remove(old);
    expect(await store.updateIfPresent(old, 'test-token'), isFalse);
  });

  test('failed image lookup can recover when a valid disk image appears', () async {
    final item = source('retry', url: 'https://missing.invalid/icon.png');
    final digest = sha256.convert(utf8.encode('${item.id}|s|${item.iconUrl}'));
    final file = File(
      '${folder.path}${Platform.pathSeparator}server_marks${Platform.pathSeparator}$digest.png',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString('not an image');
    expect(await cacheServerMarkFile(item, null), isNull);
    await file.writeAsBytes(image.encodePng(image.Image(width: 2, height: 2)));
    expect(await cacheServerMarkFile(item, null), file.path);
  });

  test('ranking cards reserve a rating row even when ratings are missing', () {
    final card = File('lib/src/media_center.dart')
        .readAsStringSync()
        .split('class _RankingPosterCard ')
        .last
        .split('class _SearchPage ')
        .first;
    expect(
      card,
      contains('SizedBox(height: 28, child: MediaRatingRow(item: item))'),
    );
  });
}
