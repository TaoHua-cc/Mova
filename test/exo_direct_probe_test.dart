import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native Exo reads preserve routing and skip competing caches', () {
    final source = File('lib/src/player/player_page.dart').readAsStringSync();
    expect(source, isNot(contains('MOVA_EXO_DIRECT_PROBE')));
    expect(source, contains('!ProxyRouting.serverUsesProxy('));
    expect(
      RegExp(r'if \(_nativeExoTransfer\) return;').allMatches(source).length,
      2,
    );
    expect(source, contains('? episode.headers'));
    final native = File(
      'android/app/src/main/kotlin/com/taohua/mova/ExoPlayerPlatformView.kt',
    ).readAsStringSync();
    expect(native, contains('.setDefaultRequestProperties(headers)'));
    expect(source, contains("event['readBytesPerSecond']"));
    expect(
      source,
      contains('final cached = await _videoCache?.cachedFile(episode.url);'),
    );
    expect(native, contains('readBytes.getAndSet(0L)'));
    expect(
      native,
      contains('if (network) readBytes.addAndGet(count.toLong())'),
    );
    expect(native, contains('now - reportedMs >= 5000L'));
  });
}
