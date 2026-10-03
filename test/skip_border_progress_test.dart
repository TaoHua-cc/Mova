import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/player/skip_border_progress.dart';

void main() {
  test('countdown outline paints safely at endpoints and narrow sizes', () {
    for (final size in [Size.zero, const Size(180, 44), const Size(120, 34)]) {
      for (final remaining in [-1.0, 0.0, .5, 1.0, 2.0]) {
        final recorder = PictureRecorder();
        SkipBorderProgress(remaining).paint(Canvas(recorder), size);
        recorder.endRecording().dispose();
      }
    }
    expect(
      const SkipBorderProgress(.5).shouldRepaint(const SkipBorderProgress(1)),
      isTrue,
    );
    expect(
      const SkipBorderProgress(.5).shouldRepaint(const SkipBorderProgress(.5)),
      isFalse,
    );
  });
}
