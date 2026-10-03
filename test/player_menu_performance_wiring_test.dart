import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Structural regression only; device frame sampling remains the acceptance test.
void main() {
  test('one-second speed updates do not rebuild the player page', () {
    final source = File('lib/src/player/player_page.dart').readAsStringSync();
    final update = source.substring(
      source.indexOf('Future<void> _updateNetworkSpeed()'),
      source.indexOf('Future<void> _initializePlayer()'),
    );
    expect(update, isNot(contains('setState(')));
    expect(update, contains('_networkSpeedTick.value++'));
    expect(source, contains('valueListenable: _networkSpeedTick'));
    expect(source, contains('_networkSpeedTick.dispose()'));
  });
  test('failed legacy composition trial cannot disable native HDR surface', () {
    final source = File('lib/src/player/player_page.dart').readAsStringSync();
    expect(source, isNot(contains('MOVA_EXO_LEGACY_VIEW')));
    expect(source, contains('child: PlatformViewLink('));
  });
  test('menu rate hint is scoped and released with the native view', () {
    final native = File(
      'android/app/src/main/kotlin/com/taohua/mova/ExoPlayerPlatformView.kt',
    ).readAsStringSync();
    expect(native, contains('Surface.FRAME_RATE_COMPATIBILITY_DEFAULT'));
    expect(native, contains('} else 0f'));
    expect(native, contains('removeCallback(menuSurfaceCallback)'));
    final source = File('lib/src/player/player_page.dart').readAsStringSync();
    expect(source, contains("_exoCommand('setMenuVisible'"));
  });
  test('Exo does not lower the display cadence to the video frame rate', () {
    final native = File(
      'android/app/src/main/kotlin/com/taohua/mova/ExoPlayerPlatformView.kt',
    ).readAsStringSync();
    expect(native, contains('C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_OFF'));
  });
  test('Exo surface composition detects support and keeps native fallback', () {
    final source = File('lib/src/player/player_page.dart').readAsStringSync();
    expect(source, contains('HybridAndroidViewController.checkIfSupported()'));
    final compact = source.replaceAll(RegExp(r'\s+'), '');
    expect(compact, contains('PlatformViewsService.initHybridAndroidView'));
    expect(compact, contains('PlatformViewsService.initExpensiveAndroidView'));
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    expect(manifest, contains('io.flutter.embedding.android.EnableHcpp'));
  });
  test('player menu isolates paint and bounds thumbnail decoding', () {
    final source = File('lib/src/player/player_page.dart').readAsStringSync();
    final menu = source.substring(
      source.indexOf('Widget _consolePanel('),
      source.indexOf('List<Widget> _consoleContent('),
    );
    expect(menu, contains('child: RepaintBoundary('));
    expect(menu, contains('ListView.builder('));
    final row = source.substring(
      source.indexOf('Widget _episodeRow('),
      source.indexOf('Widget _consoleAction('),
    );
    expect(row, contains('cacheWidth:'));
    expect(row, contains('errorBuilder:'));
    expect(
      source,
      contains('!_usesAndroidExo && (_showControls || _settingsOpen)'),
    );
  });
}
