import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native seek commits once on release and preserves retry target', () {
    final source = File('windows/native_player/main.cpp').readAsStringSync();
    final move = source.substring(
      source.indexOf('case WM_MOUSEMOVE:', source.indexOf('ControlsProc')),
      source.indexOf('case WM_LBUTTONUP:', source.indexOf('ControlsProc')),
    );
    final release = source.substring(
      source.indexOf('case WM_LBUTTONUP:', source.indexOf('ControlsProc')),
      source.indexOf('case WM_CAPTURECHANGED:', source.indexOf('ControlsProc')),
    );

    expect(move, isNot(contains('MpvCommand("seek"')));
    expect(release, contains('SeekToFraction(g_seek_drag_target)'));
    expect(source, contains('g_pending_seek_seconds.load()'));
  });

  test('native seek preserves danmaku textures and gets bounded recovery', () {
    final source = File('windows/native_player/main.cpp').readAsStringSync();
    final seekReset = source.substring(
      source.indexOf('if (g_danmaku_last_position >= 0'),
      source.indexOf('} else if (g_danmaku_last_position < 0)'),
    );
    final interruption = source.substring(
      source.indexOf('case kPlaybackInterrupted:'),
      source.indexOf('case kPlayerStateChanged:'),
    );

    expect(seekReset, isNot(contains('item.texture.reset()')));
    expect(seekReset, contains('if (next_cursor < previous_cursor)'));
    expect(interruption, contains('kSeekInterruptRetries'));
  });

  test('Windows native playback enables cache pause around range seeks', () {
    final source = File(
      'lib/src/player/windows_native_player.dart',
    ).readAsStringSync();

    expect(source, contains("'--cache=yes'"));
    expect(source, contains("'--cache-pause=yes'"));
    expect(source, contains("'--cache-pause-wait=2'"));
  });
}
