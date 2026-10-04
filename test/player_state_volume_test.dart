import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('both volume toggles use zero and restore rather than engine mute', () {
    final native = File('windows/native_player/main.cpp').readAsStringSync();
    expect(native, isNot(contains('MpvCommand("cycle", "mute")')));
    expect(
      native,
      contains('ApplyVolumeTarget(g_last_audible_volume.load(), true)'),
    );
    expect(native, contains('ApplyVolumeTarget(0, true)'));
    expect(RegExp(r'ToggleZeroVolume\(\);').allMatches(native).length, 2);
    final player = File('lib/src/player/player_page.dart').readAsStringSync();
    expect(player, contains('await _setVolume(0)'));
    expect(
      player,
      contains(
        'await _setVolume(_lastAudibleVolume <= 0 ? 100 : _lastAudibleVolume)',
      ),
    );
    expect(
      player,
      contains('allowedInteraction: SliderInteraction.tapAndSlide'),
    );
    expect(player, contains("tooltip: '关闭播放器'"));
    expect(player, contains('if (!WindowHost.isAndroid)'));
  });

  testWidgets('volume slider supports tap positioning and thumb dragging', (
    tester,
  ) async {
    double volume = 20;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: Slider(
                  value: volume,
                  min: 0,
                  max: 100,
                  allowedInteraction: SliderInteraction.tapAndSlide,
                  onChanged: (value) => setState(() => volume = value),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final bounds = tester.getRect(find.byType(Slider));
    await tester.tapAt(
      Offset(bounds.left + bounds.width * .75, bounds.center.dy),
    );
    await tester.pump();
    expect(volume, greaterThan(65));
    await tester.drag(find.byType(Slider), const Offset(-85, 0));
    await tester.pump();
    expect(volume, lessThan(50));
  });
  test(
    'fixed native chrome does not retain a capture call and chapters dedupe',
    () {
      final source = File('windows/native_player/main.cpp').readAsStringSync();
      expect(source, isNot(contains('std::thread glass_backdrop')));
      expect(source, isNot(contains('UpdateGlassBackdrop')));
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
