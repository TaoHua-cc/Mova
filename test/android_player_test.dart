import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/player/android_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Android defaults to Exo and mpv is explicit', () async {
    for (final value in [null, 'exo', 'old', 'mpv']) {
      SharedPreferences.setMockInitialValues({
        if (value != null) androidPlayerEngineKey: value,
      });
      expect(
        androidPlayerEngine(await SharedPreferences.getInstance()),
        value == 'mpv' ? 'mpv' : 'exo',
      );
    }
  });
  test('production Android entry uses shared player, not old Activity', () {
    for (final path in [
      'lib/src/media_center.dart',
      'lib/src/metadata/metadata_detail_page.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('androidExo: true'));
      expect(source, isNot(contains('playAndroidExoPlayer(')));
    }
    final host = File(
      'android/app/src/main/kotlin/com/taohua/mova/MainActivity.kt',
    ).readAsStringSync();
    expect(host, isNot(contains('DolbyVisionPlayerActivity')));
    expect(host, contains('ExoPlayerPlatformViewFactory'));
  });
}
