import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/player/dolby_vision_color.dart';

void main() {
  test('Windows Dolby Vision prioritizes intact RPU metadata', () {
    expect(
      playerHwdecValue(enabled: true, dolbyVision: true, isDesktop: true),
      'no',
    );
  });

  test('ordinary Windows video uses zero-copy hardware decoding', () {
    expect(
      playerHwdecValue(enabled: true, dolbyVision: false, isDesktop: true),
      'd3d11va',
    );
  });

  test('software decoding stays selectable and Android is unchanged', () {
    expect(
      playerHwdecValue(enabled: false, dolbyVision: false, isDesktop: true),
      'no',
    );
    expect(
      playerHwdecValue(enabled: true, dolbyVision: false, isDesktop: false),
      'mediacodec-copy',
    );
  });

  test('HDR pipeline adapts to the display and computes scene peak', () {
    final properties = playerColorProperties(hdrEnabled: true);
    expect(properties['target-colorspace-hint'], 'auto');
    expect(properties['target-colorspace-hint-mode'], 'target');
    expect(properties['tone-mapping'], 'bt.2446a');
    expect(properties['gamut-mapping-mode'], 'perceptual');
    expect(properties['hdr-compute-peak'], 'auto');
  });
}
