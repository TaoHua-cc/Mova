import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('live resource path stays in native window and refreshes headers', () {
    final native = File('windows/native_player/main.cpp').readAsStringSync();
    final begin = native.indexOf('if (g_live_resource_resolution.load())');
    final end = native.indexOf('// Compatibility for callers', begin);
    final live = native.substring(begin, end);
    expect(
      live,
      contains('g_episode_search_index = g_playlist_position.load()'),
    );
    expect(live, contains('EmitResourceChoice'));
    expect(live, isNot(contains('WM_CLOSE')));
    expect(
      native,
      contains('g_default_http_headers_set || has_header_override'),
    );
    final dart = File('lib/src/player/windows_native_player.dart')
        .readAsStringSync();
    final path = dart.substring(
      dart.indexOf('final resolveResource ='),
      dart.indexOf('requestedResource = index;'),
    );
    expect(
      path.indexOf('saveSample('),
      lessThan(path.indexOf('await resolveResource(')),
    );
    expect(path, contains('entry.headers'));
    expect(path, contains('MOVA_EPISODE_RESOLVED='));
    expect(path, contains('at.inMilliseconds / 1000'));
    expect(path, isNot(contains('Process.start')));
    expect(path, contains('MOVA_EPISODE_RESOLVE_FAILED='));
  });
}
