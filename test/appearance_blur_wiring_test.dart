import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

void main() {
  test('glass strength is fixed and independent of appearance preferences', () {
    expect(YingjiGlass.blur, YingjiGlass.fixedBlur);
    expect(YingjiGlass.fixedBlur, 30);
    expect(YingjiGlass.fixedFrost().a, closeTo(.30, .005));
    expect(YingjiGlass.fixedDepth().stops, [0, .245, .46, .78, 1]);
  });
}
