import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Windows danmaku refresh bypasses cache and returns current episode data',
    () {
      final source = File('lib/src/player/windows_native_player.dart')
          .readAsStringSync();
      final cache = source.substring(
        source.indexOf('static Future<_DanmakuPayload> _writeDanmakuFile'),
        source.indexOf('static Future<String?> _pushDanmaku'),
      );

      expect(cache, contains('bool forceRefresh = false'));
      expect(cache, contains('!forceRefresh'));
      expect(cache, contains('lastError ??'));
      expect(source, contains('Duration(seconds: 12 * apis.length + 2)'));
      expect(source, contains("MOVA_DANMAKU_RELOAD"));
      expect(source, contains('forceRefresh: true'));
    },
  );

  test(
    'player exposes a force-refresh action while keeping it disabled in flight',
    () {
      final source = File('lib/src/player/player_page.dart').readAsStringSync();

      expect(
        source,
        contains("label: Text(_danmakuLoading ? '正在重新获取' : '重新获取弹幕')"),
      );
      expect(source, contains('forceRefresh: true'));
      expect(source, contains('!_danmakuEnabled || _danmakuLoading'));
    },
  );

  test('native menu can request a fresh match from the app process', () {
    final source = File('windows/native_player/main.cpp').readAsStringSync();

    expect(source, contains('mova-danmaku-reload'));
    expect(source, contains('MOVA_DANMAKU_RELOAD'));
  });
}
