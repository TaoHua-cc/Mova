import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/cache/video_cache.dart';

void main() {
  late Directory root;
  late HttpServer origin;
  late VideoCacheStore store;
  late HttpClient player;
  late Uint8List media;
  late List<String?> ranges;
  late bool supportsRanges;
  late bool capRanges;
  late bool interruptTail;
  late bool rejectTail;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mova-transfer-test-');
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    store = VideoCacheStore.forDirectory(root);
    player = HttpClient()..findProxy = (_) => 'DIRECT';
    media = Uint8List.fromList(List.generate(256 * 1024, (i) => i % 251));
    ranges = [];
    supportsRanges = true;
    capRanges = false;
    interruptTail = false;
    rejectTail = false;
    origin.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      if (rejectTail && range != null) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }
      final match = supportsRanges
          ? RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range ?? '')
          : null;
      final start = int.tryParse(match?.group(1) ?? '') ?? 0;
      var end = int.tryParse(match?.group(2) ?? '') ?? media.length - 1;
      if (capRanges && match != null) end = end.clamp(start, start + 65535);
      request.response.statusCode = match == null ? 200 : 206;
      request.response.contentLength = end - start + 1;
      request.response.bufferOutput = false;
      request.response.headers.contentType = ContentType('video', 'mp4');
      if (match != null) {
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${media.length}',
        );
      }
      try {
        for (var offset = start; offset <= end; offset += 8192) {
          request.response.add(
            media.sublist(offset, (offset + 8192).clamp(0, end + 1)),
          );
          await request.response.flush();
          if (interruptTail && start > 0) {
            interruptTail = false;
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await request.response.close();
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await request.response.close();
      } catch (_) {
        // The downloader intentionally closes at its retained window limit.
      }
    });
  });

  tearDown(() async {
    player.close(force: true);
    await store.closePlaybackProxy();
    await origin.close(force: true);
    await root.delete(recursive: true);
  });

  String url() => 'http://127.0.0.1:${origin.port}/video';
  Future<(HttpClientResponse, List<int>)> play(
    String proxy, {
    bool ranged = true,
  }) async {
    final request = await player.getUrl(Uri.parse(proxy));
    if (ranged) request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
      [],
      (all, block) => all..addAll(block),
    );
    return (response, bytes);
  }

  test(
    'tail index probe does not redirect the active playback download',
    () async {
      media = Uint8List.fromList(
        List.generate(4 * 1024 * 1024, (i) => i % 251),
      );
      final proxy = await store.playbackUrl(url());
      final job = store.download(url: url(), limitBytes: media.length);
      while (job.state.receivedBytes < 8192) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final start = media.length - 16384;
      final request = await player.getUrl(Uri.parse(proxy));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
      final response = await request.close();
      final bytes = await response.fold<List<int>>(
        [],
        (all, block) => all..addAll(block),
      );
      expect(bytes, orderedEquals(media.sublist(start)));
      expect(job.state.startBytes, 0);
      expect(job.isCancelled, false);
      job.cancel();
      await job.done;
    },
  );

  test(
    'open-ended playback joins growing download without duplicate origin GET',
    () async {
      final proxy = await store.playbackUrl(url(), sourceId: 'direct-server');
      final job = store.download(
        url: url(),
        limitBytes: media.length,
        sourceId: 'direct-server',
      );
      final (response, bytes) = await play(proxy)
          .timeout(const Duration(seconds: 10));
      await job.done;
      expect(response.statusCode, 206);
      expect(response.contentLength, media.length);
      expect(bytes, orderedEquals(media));
      expect(store.playbackBytesRead(url()), media.length);
      expect(ranges, [null]);
      expect(job.state.status, VideoCacheStatus.complete);
      await store.closePlaybackProxy();
      store = VideoCacheStore.forDirectory(root);
      final persistedProxy = await store.playbackUrl(url());
      final (cachedResponse, cachedBytes) = await play(
        persistedProxy,
        ranged: false,
      );
      expect(cachedResponse.statusCode, 200);
      expect(cachedBytes, orderedEquals(media));
      expect(ranges, [
        null,
      ], reason: 'complete disk cache must not contact origin');
    },
  );

  test(
    'response crossing retained window fetches only its missing tail',
    () async {
      final proxy = await store.playbackUrl(url());
      final job = store.download(url: url(), limitBytes: 64 * 1024);
      final (response, bytes) = await play(proxy)
          .timeout(const Duration(seconds: 10));
      await job.done;
      expect(response.statusCode, 206);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 0-262143/262144',
      );
      expect(bytes, orderedEquals(media));
      expect(ranges, [null, 'bytes=65536-262143']);
      expect(job.state.status, VideoCacheStatus.buffered);
      expect(job.state.receivedBytes, 64 * 1024);
    },
  );

  test(
    'finished next-episode preheat reuses prefix before fetching missing tail',
    () async {
      final diagnostics = <String>[];
      store.playbackDiagnostic = diagnostics.add;
      final job = store.download(
        url: url(),
        limitBytes: media.length,
        targetBytes: 64 * 1024,
      );
      await job.done;
      expect(job.state.status, VideoCacheStatus.buffered);
      expect(job.state.receivedBytes, 64 * 1024);
      final proxy = await store.playbackUrl(url());
      final (response, bytes) = await play(proxy)
          .timeout(const Duration(seconds: 10));
      expect(response.statusCode, 206);
      expect(bytes, orderedEquals(media));
      expect(ranges, [null, 'bytes=65536-262143']);
      expect(
        diagnostics,
        contains('MOVA_CACHE_DIAGNOSTIC=tail-status|offset=65536|value=206'),
      );
      expect(
        diagnostics,
        contains('MOVA_CACHE_DIAGNOSTIC=tail-end|offset=262144|value=196608'),
      );
    },
  );

  test(
    'preheated prefix continues across capped origin Range responses',
    () async {
      final job = store.download(
        url: url(),
        limitBytes: media.length,
        targetBytes: 65536,
      );
      await job.done;
      capRanges = true;
      final (_, bytes) = await play(await store.playbackUrl(url()))
          .timeout(const Duration(seconds: 10));
      expect(bytes, orderedEquals(media));
      expect(ranges, [
        null,
        'bytes=65536-262143',
        'bytes=131072-262143',
        'bytes=196608-262143',
      ]);
    },
  );

  test(
    'preheated prefix resumes interrupted tail at bytes already delivered',
    () async {
      final job = store.download(
        url: url(),
        limitBytes: media.length,
        targetBytes: 65536,
      );
      await job.done;
      interruptTail = true;
      final (_, bytes) = await play(await store.playbackUrl(url()))
          .timeout(const Duration(seconds: 10));
      expect(bytes, orderedEquals(media));
      expect(ranges, [null, 'bytes=65536-262143', 'bytes=73728-262143']);
    },
  );

  test(
    'unavailable preheat tail closes response after bounded retries',
    () async {
      final diagnostics = <String>[];
      store.playbackDiagnostic = diagnostics.add;
      final job = store.download(
        url: url(),
        limitBytes: media.length,
        targetBytes: 65536,
      );
      await job.done;
      rejectTail = true;
      await expectLater(
        play(await store.playbackUrl(url()))
            .timeout(const Duration(seconds: 5)),
        throwsA(isA<IOException>()),
      );
      expect(ranges.length, 4);
      expect(
        diagnostics.where((line) => line.contains('tail-status')),
        hasLength(3),
      );
      expect(
        diagnostics,
        contains('MOVA_CACHE_DIAGNOSTIC=proxy-error|offset=0|value=0'),
      );
    },
  );

  test(
    'cancelled download retains prefix and playback recovers remaining bytes',
    () async {
      final proxy = await store.playbackUrl(url());
      final job = store.download(url: url(), limitBytes: media.length);
      while (job.state.totalBytes == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
      job.cancel();
      await job.done;
      final (response, bytes) = await play(proxy)
          .timeout(const Duration(seconds: 10));
      expect(response.statusCode, 206);
      expect(bytes, orderedEquals(media));
      expect(ranges.length, 2);
      expect(ranges.last, 'bytes=${job.state.receivedBytes}-262143');
    },
  );
  test(
    'origin ignoring Range still completes playback beyond cache window',
    () async {
      supportsRanges = false;
      final proxy = await store.playbackUrl(url());
      final job = store.download(url: url(), limitBytes: 64 * 1024);
      final (_, bytes) = await play(proxy).timeout(const Duration(seconds: 10));
      await job.done;
      expect(bytes, orderedEquals(media));
      expect(ranges, [null, 'bytes=65536-262143']);
    },
  );
  test('seek redirects active download to actual requested byte without duplicate tail', () async {
    media = Uint8List.fromList(List.generate(4 * 1024 * 1024, (i) => i % 251));
    final proxy = await store.playbackUrl(url());
    final job = store.download(url: url(), limitBytes: 3 * 1024 * 1024);
    final request = await player.getUrl(Uri.parse(proxy));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=2097152-');
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
      [],
      (all, chunk) => all..addAll(chunk),
    );
    await job.done;
    expect(bytes, orderedEquals(media.sublist(2097152)));
    expect(ranges, [null, 'bytes=2097152-']);
    expect(job.state.startBytes, 2097152);
  });
}
