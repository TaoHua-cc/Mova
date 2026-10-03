import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Exo track snapshots are sent on changes and subscription, not ticks',
    () {
      final native = File(
        'android/app/src/main/kotlin/com/taohua/mova/ExoPlayerPlatformView.kt',
      ).readAsStringSync();
      expect(native, contains('if (tracksPending) {'));
      expect(native, contains('tracksPending = false'));
      expect(
        native,
        matches(
          RegExp(r'onListen\([\s\S]*?tracksPending = true\s+emitState\(\)'),
        ),
      );
      expect(
        native,
        matches(
          RegExp(
            r'onTracksChanged\([\s\S]*?tracksPending = true\s+emitState\(\)',
          ),
        ),
      );
      expect(native, isNot(contains('"tracks" to flattenTracks')));
      final page = File('lib/src/player/player_page.dart').readAsStringSync();
      expect(page, contains("event.containsKey('tracks')"));
      expect(page, contains("_exoTrackSignature = '';\n      _exoState"));
      expect(
        page,
        contains(
          "? jsonEncode(event['tracks'])\n        : _exoTrackSignature;",
        ),
      );
    },
  );
}
