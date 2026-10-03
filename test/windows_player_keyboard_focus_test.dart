import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'startup activates player and scopes focus to its own foreground window',
    () {
      final source = File('windows/native_player/main.cpp').readAsStringSync();
      expect(source, contains('AW_BLEND | AW_ACTIVATE'));
      expect(
        source,
        contains('GetAncestor(GetForegroundWindow(), GA_ROOTOWNER) == window'),
      );
      for (final procedure in ['TopBarProc', 'ControlsProc']) {
        final start = source.indexOf('LRESULT CALLBACK $procedure(');
        expect(
          source.substring(start, start + 350),
          contains('return SendMessageW(g_window, message, wparam, lparam)'),
        );
      }
    },
  );
}
