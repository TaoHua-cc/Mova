import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

void main() {
  test('Android server cards never stretch when there are few sources', () {
    for (final available in [240.0, 600.0, 900.0, 1400.0]) {
      for (final count in [1, 2, 5, 20]) {
        final width = YingjiLayout.sourceCardWidth(
          available,
          count,
          compact: true,
        );
        expect(width, lessThanOrEqualTo(340));
        expect(width, lessThanOrEqualTo(available));
        expect(width, greaterThan(0));
      }
    }
    expect(YingjiLayout.sourceCardWidth(900, 2, compact: true), 340);
    expect(YingjiLayout.sourceCardWidth(240, 1, compact: true), 240);
  });
  test('Windows still fills the row and wraps additional sources', () {
    expect(YingjiLayout.sourceCardWidth(900, 1, compact: false), 900);
    expect(YingjiLayout.sourceCardWidth(900, 2, compact: false), 444);
    expect(YingjiLayout.sourceCardWidth(900, 8, compact: false), 444);
  });
}
