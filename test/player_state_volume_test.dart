import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'fixed native chrome does not retain a capture call and chapters dedupe',
    () {
      final source = File('windows/native_player/main.cpp').readAsStringSync();
      final worker = source.substring(
        source.indexOf('std::thread glass_backdrop'),
      );
      expect(worker, isNot(contains('UpdateGlassBackdrop();')));
      expect(source, contains('if (tool == "章节") return kSegments'));
      expect(
        source,
        contains('!g_danmaku_error.empty() && g_danmaku_count <= 0'),
      );
      expect(source, contains('320.0f /'));
    },
  );
  test('Android volume uses media stream with unity player gain', () {
    final player = File('lib/src/player/player_page.dart').readAsStringSync();
    final host = File(
      'android/app/src/main/kotlin/com/taohua/mova/MainActivity.kt',
    ).readAsStringSync();
    expect(player, contains("'setMediaVolume'"));
    expect(player, contains("'getMediaVolume'"));
    expect(player, contains("await _player!.setVolume(100)"));
    expect(host, contains('volumeControlStream = AudioManager.STREAM_MUSIC'));
    expect(host, contains('audio.setStreamVolume(AudioManager.STREAM_MUSIC'));
  });
}
