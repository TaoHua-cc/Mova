// 描边几何回归：复刻 _DetailPosterHover 的当前结构，把海报换成纯色块，
// 这样渲染结果里「白描边」与「海报边缘」之间有没有缝可以逐像素量出来。
// 真实海报素材自带的暗边会干扰判断，所以用纯色；本测试只验证布局几何。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const double kRadius = 14;
const double kStroke = 2.6;

class HoverProbe extends StatelessWidget {
  const HoverProbe({required this.lifted, required this.child, super.key});

  final bool lifted;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadius),
        boxShadow: lifted
            ? const [
                BoxShadow(
                  color: Color(0x85000000),
                  blurRadius: 28,
                  offset: Offset(0, 14),
                ),
              ]
            : const [],
      ),
      child: Stack(
        children: [
          ClipRRect(borderRadius: BorderRadius.circular(kRadius), child: child),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(kRadius),
                  border: Border.all(
                    color: lifted ? Colors.white : Colors.transparent,
                    width: lifted ? kStroke : 0,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

void main() {
  testWidgets('stroke sits on the poster edge', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(300, 300));
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            height: 232,
            child: HoverProbe(
              lifted: true,
              child: SizedBox(
                width: 140,
                child: Column(
                  children: [
                    Expanded(
                      child: Container(
                        clipBehavior: Clip.antiAlias,
                        decoration: const BoxDecoration(
                          color: Color(0xFFFF0000),
                          borderRadius: BorderRadius.all(
                            Radius.circular(kRadius),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '第 1 季',
                      style: TextStyle(fontSize: 14, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(HoverProbe),
      matchesGoldenFile('goldens/frame_geometry.png'),
    );
  });
}
