import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'both player paths sample delivered bytes every second and display zero',
    () {
      final page = File('lib/src/player/player_page.dart').readAsStringSync();
      final windows = File('lib/src/player/windows_native_player.dart')
          .readAsStringSync();
      final native = File('windows/native_player/main.cpp').readAsStringSync();
      expect(page, contains('Timer.periodic(const Duration(seconds: 1)'));
      expect(page, contains('playbackBytesRead(url)'));
      expect(page, contains('return playbackNetworkLabel('));
      expect(page, isNot(contains("'cache-speed'")));
      expect(windows, contains('Timer.periodic(const Duration(seconds: 1)'));
      expect(windows, contains('cache?.playbackBytesRead(url)'));
      expect(windows, contains('speedTimer.cancel();'));
      expect(native, contains('g_network_speed_available'));
      expect(native, contains('demuxer-cache-duration'));
    },
  );
}
