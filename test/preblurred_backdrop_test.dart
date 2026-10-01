import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/cache/preblurred_backdrop.dart';

void main() {
  testWidgets(
    'preblur keeps source dimensions, reuses texture, and releases it',
    (tester) async {
      final bytes = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 24, 12),
          Paint()..color = Colors.blue,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(24, 12);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        return data!.buffer.asUint8List();
      });
      final provider = MemoryImage(bytes!);
      Widget view(double sigma, Size size) => MaterialApp(
        home: SizedBox.expand(
          child: PreblurredBackdrop(
            image: provider,
            viewport: size,
            sigma: sigma,
          ),
        ),
      );
      Future<void> settleTexture() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.pump();
      }

      await tester.pumpWidget(view(30, const Size(1200, 600)));
      await settleTexture();
      final texture = tester.widget<RawImage>(find.byType(RawImage)).image!;
      expect(texture.width, 24);
      expect(texture.height, 12);
      expect(find.byType(ImageFiltered), findsNothing);
      for (var i = 0; i < 5; i++) {
        await tester.pumpWidget(view(30, const Size(1200, 600)));
        expect(
          identical(
            tester.widget<RawImage>(find.byType(RawImage)).image,
            texture,
          ),
          isTrue,
        );
      }
      await tester.pumpWidget(view(10, const Size(600, 1200)));
      await settleTexture();
      final resized = tester.widget<RawImage>(find.byType(RawImage)).image!;
      expect(identical(resized, texture), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(resized.debugDisposed, isTrue);
      await tester.pumpWidget(view(20, const Size(800, 600)));
      await tester.pumpWidget(const SizedBox.shrink());
      await settleTexture();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('image failure keeps a safe empty backdrop', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PreblurredBackdrop(
          image: MemoryImage(Uint8List.fromList([0, 1, 2])),
          viewport: const Size(800, 600),
          sigma: 20,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
