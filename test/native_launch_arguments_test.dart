import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/player/native_launch_arguments.dart';

void main() {
  test(
    'large Unicode argument lists round trip without command-line quoting',
    () {
      final args = [
        '',
        '--title=中文 "引号" \\ 路径\n换行 😀',
        '--headers=Authorization: private%20value\r\nX-Test: a|b',
        ...List.generate(1000, (i) => '--mova-playlist-title=第 $i 集'),
      ];
      final payload = encodeNativeLaunchArguments(args);
      expect(payload.length, greaterThan(32767));
      final lines = const LineSplitter().convert(payload);
      expect(lines.first, 'MOVA_ARGS_V1');
      expect(lines.skip(1).map(Uri.decodeComponent), args);
    },
  );
  test(
    'launch failures do not expose addresses, headers or original arguments',
    () {
      final message = nativeLaunchFailure(
        ProcessException(
          'private-player-path',
          ['--token=private-token'],
          'private-url',
          206,
        ),
      );
      expect(message, contains('206'));
      expect(message, isNot(contains('private')));
    },
  );
}
