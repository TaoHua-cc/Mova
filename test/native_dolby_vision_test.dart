import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/player/native_dolby_vision.dart';

void main() {
  test('recognizes server Dolby Vision range labels', () {
    for (final value in [
      'DOVI',
      'Dolby Vision',
      'DolbyVision',
      'DV',
      'HDR10+DV',
      'Dolby Vision Profile 8',
    ]) {
      expect(
        NativeDolbyVisionPlayer.isDolbyVision(value),
        isTrue,
        reason: value,
      );
    }
  });

  test('does not route ordinary dynamic ranges to native DV', () {
    for (final value in [null, '', 'SDR', 'HDR', 'HDR10', 'HDR10+', 'HLG']) {
      expect(
        NativeDolbyVisionPlayer.isDolbyVision(value),
        isFalse,
        reason: '$value',
      );
    }
  });
}
