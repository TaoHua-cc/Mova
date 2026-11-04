import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/platform/window_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('hide and restore keep the same desktop window', () async {
    const channel = MethodChannel('window_manager');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return call.method == 'isMinimized' ? false : null;
        });
    try {
      await WindowHost.hide();
      await WindowHost.bringToFront();
      expect(
        calls.where((method) => method != 'isMinimized').toList(),
        WindowHost.isDesktop ? ['hide', 'show', 'focus'] : isEmpty,
      );
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });
  test('native playback keeps the app visible and focuses it after exit', () {
    final source = File('lib/src/player/windows_native_player.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(source, isNot(contains('await WindowHost.hide()')));
    expect(
      source.indexOf('playerStarted = true;'),
      greaterThan(source.indexOf('await Process.start(')),
    );
    expect(
      source.indexOf(
        'await focusMainWindowAfterPlayback();',
        source.indexOf('final exitCode = await process.exitCode;'),
      ),
      lessThan(source.indexOf('previewClosed = true;')),
    );
    expect(
      source,
      contains(
        '} finally {\n      try {\n        await focusMainWindowAfterPlayback();',
      ),
    );
  });
}
