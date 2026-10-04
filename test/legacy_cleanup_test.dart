import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Windows production playback has no embedded HWND or capture worker',
    () {
      final page = File('lib/src/player/player_page.dart').readAsStringSync();
      final runner = File('windows/runner/flutter_window.cpp')
          .readAsStringSync();
      final native = File('windows/native_player/main.cpp').readAsStringSync();
      expect(page, isNot(contains('NativeVideoHost')));
      expect(page, isNot(contains('NativeVideoSurface')));
      expect(runner, isNot(contains('native_video_host_')));
      expect(native, isNot(contains('std::thread glass_backdrop')));
      expect(native, isNot(contains('PrintWindow(')));
      for (final path in [
        'lib/src/media_center.dart',
        'lib/src/metadata/metadata_detail_page.dart',
      ]) {
        expect(
          File(path).readAsStringSync(),
          contains('WindowsNativePlayer.play('),
        );
      }
    },
  );

  test('old demonstration posters are not bundled', () {
    final assets = File('pubspec.yaml').readAsStringSync();
    expect(assets, isNot(contains('yingji-hero-original.png')));
    expect(assets, isNot(contains('yingji-posters-original.png')));
    expect(assets, isNot(contains('- app/assets/\n')));
    expect(assets, contains('app/assets/mova-logo.png'));
  });
}
