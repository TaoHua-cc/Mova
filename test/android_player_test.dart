import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/history/watch_state_store.dart';
import 'package:yingji/src/player/android_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mova/platform');
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
  });

  test(
    'HTTP media uses authenticated Range proxy and closes it after playback',
    () async {
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = overrides);
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp('mova-exo-test-');
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await origin.close(force: true);
        await directory.delete(recursive: true);
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => directory.path,
          );
      origin.listen((request) async {
        expect(request.headers.value('X-Test'), 'fixture');
        expect(request.headers.value('Range'), 'bytes=0-3');
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set('Content-Range', 'bytes 0-3/4');
        request.response.contentLength = 4;
        request.response.add([1, 2, 3, 4]);
        await request.response.close();
      });
      late Uri playback;
      final url = 'http://127.0.0.1:${origin.port}/fixture.mkv';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            playback = Uri.parse(call.arguments['url'] as String);
            expect(playback.port, isNot(origin.port));
            expect(playback.host, '127.0.0.1');
            expect(call.arguments['headers'], isEmpty);
            final request = await client.getUrl(playback);
            request.headers.set('Range', 'bytes=0-3');
            final response = await request.close();
            expect(response.statusCode, HttpStatus.partialContent);
            expect(
              await response.fold<List<int>>(
                [],
                (bytes, part) => bytes..addAll(part),
              ),
              [1, 2, 3, 4],
            );
            return {'positionMs': 12000, 'durationMs': 60000};
          });
      await playAndroidExoPlayer(
        state: WatchState(
          mediaId: url,
          title: 'Test',
          position: Duration.zero,
          duration: Duration.zero,
        ),
        headers: const {'X-Test': 'fixture'},
        container: 'mkv',
      );
      expect((await WatchStateStore.create()).load().single.mediaId, url);
      client.close(force: true);
      final afterClose = HttpClient();
      addTearDown(() => afterClose.close(force: true));
      Future<void> requestClosedProxy() async {
        final request = await afterClose.getUrl(playback);
        await request.close();
      }

      await expectLater(requestClosedProxy(), throwsA(isA<IOException>()));
    },
  );

  test('Android defaults to Exo; only explicit mpv overrides it', () async {
    for (final value in [null, 'exo', 'unknown', 'mpv']) {
      SharedPreferences.setMockInitialValues({
        if (value != null) androidPlayerEngineKey: value,
      });
      expect(
        androidPlayerEngine(await SharedPreferences.getInstance()),
        value == 'mpv' ? 'mpv' : 'exo',
      );
    }
  });

  test(
    'unsupported audio is reported without changing engine or resume request',
    () async {
      SharedPreferences.setMockInitialValues({androidPlayerEngineKey: 'exo'});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'playExoPlayer');
            expect(call.arguments['positionMs'], 5000);
            return {
              'positionMs': 0,
              'durationMs': 60000,
              'error': 'audio_not_supported',
            };
          });
      await expectLater(
        playAndroidExoPlayer(
          state: const WatchState(
            mediaId: 'https://example.test/video',
            title: 'Test',
            position: Duration(seconds: 5),
            duration: Duration.zero,
          ),
          headers: const {},
        ),
        throwsA(isA<StateError>()),
      );
      expect(androidPlayerEngine(await SharedPreferences.getInstance()), 'exo');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => {'error': 'network_error'},
          );
      await expectLater(
        playAndroidExoPlayer(
          state: const WatchState(
            mediaId: 'https://example.test/video',
            title: 'Test',
            position: Duration.zero,
            duration: Duration.zero,
          ),
          headers: const {},
        ),
        throwsStateError,
      );
    },
  );

  test(
    'Exo bridge passes playback inputs and saves returned real progress',
    () async {
      SharedPreferences.setMockInitialValues({'yingji.player.hardware': false});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'playExoPlayer');
            expect(call.arguments['positionMs'], 5000);
            expect(call.arguments['headers'], {'X-Test': 'fixture'});
            expect(call.arguments['container'], 'mkv');
            return {
              'positionMs': 12000,
              'durationMs': 60000,
              'completed': false,
            };
          });
      await playAndroidExoPlayer(
        state: const WatchState(
          mediaId: 'https://example.test/video',
          title: 'Test',
          position: Duration(seconds: 5),
          duration: Duration.zero,
          sourceId: 'source',
          seasonNumber: 1,
          episodeNumber: 2,
        ),
        headers: const {'X-Test': 'fixture'},
        container: 'mkv',
      );
      final state = (await WatchStateStore.create()).load().single;
      expect(state.position, const Duration(seconds: 12));
      expect(state.duration, const Duration(seconds: 60));
      expect(state.episodeNumber, 2);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'yingji.player.hardware',
        ),
        false,
      );
    },
  );
}
