import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exit persists before closed input pipe and waits for final output', () {
    final source = File('lib/src/player/windows_native_player.dart')
        .readAsStringSync();
    expect(
      source.indexOf('await outputDone.future'),
      lessThan(source.indexOf('final savedStates')),
    );
    expect(
      source.indexOf('await store.save(state)'),
      lessThan(source.indexOf('await process.stdin.close()')),
    );
    expect(
      source.indexOf('await _syncServerWatchStates(savedStates).timeout('),
      lessThan(source.indexOf('await download?.done')),
    );
    expect(source, contains('const Duration(seconds: 4)'));
    final native = File('windows/native_player/main.cpp').readAsStringSync();
    expect(native, contains('case WM_NCACTIVATE:'));
    expect(native, contains('DWMNCRP_DISABLED'));
    expect(
      native,
      contains('EmitProgress(g_position.load(), g_duration.load())'),
    );
  });
}
