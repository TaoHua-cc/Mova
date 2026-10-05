import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yingji/src/player/seek_preview.dart';
import 'package:yingji/src/sources/media_source.dart';

void main() {
  Uint8List bif() {
    final bytes = Uint8List(94);
    bytes.setRange(0, 8, [0x89, 0x42, 0x49, 0x46, 13, 10, 26, 10]);
    final d = ByteData.sublistView(bytes);
    d.setUint32(12, 2, Endian.little);
    d.setUint32(16, 1000, Endian.little);
    d.setUint32(64, 0, Endian.little);
    d.setUint32(68, 88, Endian.little);
    d.setUint32(72, 10, Endian.little);
    d.setUint32(76, 91, Endian.little);
    d.setUint32(80, 0xffffffff, Endian.little);
    d.setUint32(84, 94, Endian.little);
    bytes.setRange(88, 94, [1, 2, 3, 4, 5, 6]);
    return bytes;
  }

  test('BIF chooses preceding frame and clamps beyond last frame', () {
    expect(bifFrame(bif(), 0), [1, 2, 3]);
    expect(bifFrame(bif(), 9.99), [1, 2, 3]);
    expect(bifFrame(bif(), 10), [4, 5, 6]);
    expect(bifFrame(bif(), 9999), [4, 5, 6]);
    expect(bifFrame(bif(), -1), isNull);
    expect(bifFrame(bif(), double.nan), isNull);
  });
  test('BIF rejects truncated, bad signatures and invalid offsets', () {
    expect(bifFrame(Uint8List(5), 1), isNull);
    final bad = bif()..[0] = 0;
    expect(bifFrame(bad, 1), isNull);
    final invalid = bif();
    ByteData.sublistView(invalid).setUint32(76, 999, Endian.little);
    expect(bifFrame(invalid, 1), isNull);
  });
  MediaSource source(SourceKind kind) => MediaSource(
    id: 's',
    name: 's',
    kind: kind,
    endpoint: Uri.parse('https://example.test/emby/'),
  );
  test(
    'Emby BIF fetched once, authenticated and base path preserved',
    () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        expect(request.url.path, '/emby/Videos/e/index.bif');
        expect(request.headers['X-Emby-Token'], 'token');
        return http.Response.bytes(bif(), 200);
      });
      final provider = ServerSeekPreview(
        client,
        source(SourceKind.emby),
        'token',
        'e',
      );
      expect((await provider.frame(12))!.bytes, [4, 5, 6]);
      await provider.frame(2);
      expect(calls, 1);
      client.close();
    },
  );
  test('Jellyfin picks exact resource version and sprite rectangle', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (request.url.path.endsWith('/Items/e')) {
        return http.Response(
          jsonEncode({
            'Trickplay': {
              'v': {
                '320': {
                  'Width': 320,
                  'Height': 180,
                  'TileWidth': 2,
                  'TileHeight': 2,
                  'Interval': 10000,
                  'ThumbnailCount': 9,
                },
              },
            },
          }),
          200,
        );
      }
      expect(request.url.path, '/emby/Videos/e/Trickplay/320/1.jpg');
      expect(request.url.queryParameters['mediaSourceId'], 'v');
      return http.Response.bytes([1, 2, 3], 200);
    });
    final provider = ServerSeekPreview(
      client,
      source(SourceKind.jellyfin),
      'token',
      'e',
      mediaSourceId: 'v',
    );
    final frame = (await provider.frame(50))!;
    expect([frame.x, frame.y, frame.width, frame.height], [320, 0, 320, 180]);
    await provider.frame(51);
    expect(calls, 2);
    client.close();
  });
  test(
    'missing capability returns null and is not repeatedly requested',
    () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('', 404);
      });
      final provider = ServerSeekPreview(
        client,
        source(SourceKind.emby),
        'token',
        'e',
      );
      expect(await provider.frame(1), isNull);
      expect(await provider.frame(2), isNull);
      expect(calls, 1);
      client.close();
    },
  );
  test(
    'native preview and pin wiring do not seek main playback for frames',
    () {
      final native = File('windows/native_player/main.cpp').readAsStringSync();
      final decode = native.substring(
        native.indexOf('void StartPreviewDecode'),
        native.indexOf('LRESULT CALLBACK SeekPreviewProc'),
      );
      expect(decode, contains('g_mpv.create()'));
      expect(decode, isNot(contains('SeekToSeconds')));
      expect(decode, contains('"pause", "yes"'));
      expect(decode, contains('absolute+exact'));
      expect(decode, contains('if (!restarted) continue;'));
      expect(decode, contains('frames.size() >= 12'));
      expect(native, contains('HWND_TOPMOST : HWND_NOTOPMOST'));
      expect(native, contains('result->id < g_seek_preview_min_id'));
      expect(native, contains('result->id < g_seek_preview_displayed_id'));
      expect(native, contains('auto_cancelled = true'));
      final bridge = File('lib/src/player/windows_native_player.dart')
          .readAsStringSync();
      expect(bridge, contains('mova-seek-preview'));
      expect(bridge, contains('mova-show-skip-after-cancel'));
      final update = native.substring(
        native.indexOf('void UpdateAutoSkip('),
        native.indexOf('void UpdateAutoSkip(') + 3200,
      );
      expect(
        update.indexOf('segments[candidate].auto_cancelled'),
        lessThan(update.indexOf('g_skip_deadline = now')),
      );
      expect(update, contains('g_show_skip_after_cancel'));
      expect(
        native,
        contains(
          'g_hint_layout != HintLayout::AutoSkip && g_hint_mode == HintMode::Toast',
        ),
      );
      final start = native.indexOf(
        'case WM_LBUTTONUP: {\n      if (g_hint_layout',
      );
      final click = native.substring(start, start + 1300);
      expect(
        click,
        contains('SkipSegment(static_cast<size_t>(g_skip_index), false)'),
      );
      expect(click, contains('auto_cancelled = true'));
      expect(click, isNot(contains('consumed = true')));
    },
  );
  test('dragging queues latest target without starving slower frames', () {
    final native = File('windows/native_player/main.cpp').readAsStringSync();
    final update = native.substring(
      native.indexOf('void UpdateSeekPreview() {'),
      native.indexOf('void UpdateSeekPreview() {') + 2700,
    );
    expect(
      update,
      isNot(contains('g_seek_preview_decode_generation = g_seek_preview_id')),
    );
    expect(update, isNot(contains('g_seek_preview_bitmap.reset()')));
    final worker = native.substring(
      native.indexOf('void StartPreviewDecode'),
      native.indexOf('LRESULT CALLBACK SeekPreviewProc'),
    );
    expect(worker, contains('== job->epoch'));
    final bridge = File('lib/src/player/windows_native_player.dart')
        .readAsStringSync();
    final preview = bridge.substring(
      bridge.indexOf('Future<void> servePreview'),
      bridge.indexOf('final outputDone = Completer<void>()'),
    );
    expect(preview, isNot(contains('pendingPreview != null ||')));
    expect(native, isNot(contains("L'\\xE718'")));
    expect(native, contains('ConfigureControlPen(pin)'));
  });
}
