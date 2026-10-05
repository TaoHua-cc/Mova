import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/player/android_seek_preview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mova/platform');
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  testWidgets(
    'serial preview accepts completed frame while newer target waits',
    (tester) async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.red, BlendMode.src);
      final picture = recorder.endRecording();
      final bytes = await tester.runAsync(() async {
        final image = await picture.toImage(16, 9);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return data!.buffer.asUint8List();
      });
      picture.dispose();
      final first = Completer<Object?>();
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method != 'seekPreviewFrame') return null;
            calls++;
            return calls == 1 ? first.future : null;
          });
      Widget preview(int second) => MaterialApp(
        home: Center(
          child: AndroidSeekPreview(
            url: 'test-resource',
            position: Duration(seconds: second),
            fallbackUrl: () async => 'test-local-file',
          ),
        ),
      );
      await tester.pumpWidget(preview(12));
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(calls, 1);
      await tester.pumpWidget(preview(24));
      await tester.pump(const Duration(milliseconds: 200));
      expect(calls, 1);
      first.complete(bytes);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(find.text('0:12'), findsOneWidget);
      expect(calls, 2);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 9));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed extraction keeps truthful time-only state', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: AndroidSeekPreview(
            url: 'unsupported',
            position: const Duration(seconds: 75),
            fallbackUrl: () async => 'test-local-file',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.text('1:15'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SizedBox && widget.width == 192 && widget.height == 108,
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'both Android engines use preview and separate cancel from consumed state',
    () {
      final page = File('lib/src/player/player_page.dart').readAsStringSync();
      final host = File(
        'android/app/src/main/kotlin/com/taohua/mova/SeekPreview.kt',
      ).readAsStringSync();
      expect(page, contains('AndroidSeekPreview('));
      expect(
        page,
        contains("prefs.getBool('yingji.player.seek-preview') ?? true"),
      );
      expect(page, contains('_skipCancelled.contains(kind)'));
      expect(page, contains('_showSkipAfterCancel'));
      expect(page, contains('await cache.playbackUrl('));
      expect(host, contains('busy.compareAndSet(false, true)'));
      expect(host, contains('reader?.release()'));
      expect(host, contains('sourceUrl != url || sourceHeaders != headers'));
      expect(host, contains('Executors.newSingleThreadExecutor()'));
      expect(host, contains('frames.size >= 12'));
      expect(host, contains('1024 * 1024'));
      expect(host, contains('handler.postDelayed(idleClose, 30000)'));
      expect(page, contains("invokeMethod<void>('closeSeekPreview')"));
      expect(host, isNot(contains('player.seek')));
    },
  );
}
