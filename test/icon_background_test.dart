import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;
import 'package:yingji/src/images/icon_background.dart';

void main() {
  test('removes a dominant flat icon backdrop but keeps the foreground', () {
    final image = image_lib.Image(width: 12, height: 12, numChannels: 4);
    image_lib.fill(image, color: image_lib.ColorRgba8(38, 208, 92, 255));
    for (var y = 3; y < 9; y++) {
      for (var x = 4; x < 8; x++) {
        image.setPixelRgba(x, y, 70, 85, 240, 255);
      }
    }

    expect(removeFlatIconBackground(image), isTrue);
    expect(image.getPixel(0, 0).a, 0);
    expect(image.getPixel(5, 5).a, 255);
  });

  test('keeps an isolated transparent-background glyph intact', () {
    final image = image_lib.Image(width: 12, height: 12, numChannels: 4);
    for (var y = 3; y < 9; y++) {
      for (var x = 4; x < 8; x++) {
        image.setPixelRgba(x, y, 255, 255, 255, 255);
      }
    }

    expect(removeFlatIconBackground(image), isFalse);
    expect(image.getPixel(5, 5).a, 255);
  });
}
