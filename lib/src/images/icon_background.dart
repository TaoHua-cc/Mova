import 'dart:math' as math;

import 'package:image/image.dart' as image_lib;

/// Removes a flat, edge-connected-looking backdrop from an icon-pack bitmap.
/// Photographic and already-transparent icons are left unchanged.
bool removeFlatIconBackground(image_lib.Image image) {
  final histogram = <int, int>{};
  var opaque = 0;
  for (final pixel in image) {
    if (pixel.a < 230) continue;
    opaque++;
    final key =
        ((pixel.r.toInt() >> 3) << 10) |
        ((pixel.g.toInt() >> 3) << 5) |
        (pixel.b.toInt() >> 3);
    histogram[key] = (histogram[key] ?? 0) + 1;
  }
  if (opaque == 0 || histogram.isEmpty) return false;
  final dominant = histogram.entries.reduce(
    (a, b) => a.value >= b.value ? a : b,
  );
  if (dominant.value / opaque < .22) return false;
  final red = ((dominant.key >> 10) & 31) * 8 + 4;
  final green = ((dominant.key >> 5) & 31) * 8 + 4;
  final blue = (dominant.key & 31) * 8 + 4;
  bool matches(image_lib.Pixel pixel) {
    if (pixel.a < 230) return false;
    final dr = pixel.r.toInt() - red;
    final dg = pixel.g.toInt() - green;
    final db = pixel.b.toInt() - blue;
    return dr * dr + dg * dg + db * db <= 28 * 28;
  }

  var edgeMatches = 0;
  for (var x = 0; x < image.width; x++) {
    if (matches(image.getPixel(x, 0))) edgeMatches++;
    if (matches(image.getPixel(x, image.height - 1))) edgeMatches++;
  }
  for (var y = 1; y < image.height - 1; y++) {
    if (matches(image.getPixel(0, y))) edgeMatches++;
    if (matches(image.getPixel(image.width - 1, y))) edgeMatches++;
  }
  final perimeter = image.width * 2 + math.max(0, image.height - 2) * 2;
  if (edgeMatches < math.max(4, perimeter ~/ 12)) return false;
  for (final pixel in image) {
    if (matches(pixel)) pixel.a = 0;
  }
  return true;
}
