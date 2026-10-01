import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

void main() {
  testWidgets('background depth follows sub-step scrolling continuously', (
    tester,
  ) async {
    final controller = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          controller: controller,
          children: const [SizedBox(height: 3000)],
        ),
      ),
    );
    final position = controller.position;
    final viewport = position.viewportDimension;
    for (final fraction in [0.001, 0.002, 0.017, 0.019, 0.51, 1.2]) {
      controller.jumpTo(viewport * fraction);
      expect(yingjiScrollDepth(position), closeTo(fraction.clamp(0, 1), 1e-9));
    }
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
