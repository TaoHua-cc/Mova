import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:yingji/src/cache/video_cache.dart';

void main() {
  test(
    'desktop cache is automatically managed without rewriting legacy prefs',
    () async {
      SharedPreferences.setMockInitialValues({VideoCachePolicy.desktopKey: 0});
      final prefs = await SharedPreferences.getInstance();
      expect(
        VideoCachePolicy.readDesktop(prefs),
        VideoCachePolicy.defaultDesktop,
      );
      expect(prefs.getInt(VideoCachePolicy.desktopKey), 0);
    },
  );
  test('next episode preheat stays small without shrinking retention', () {
    const retention = 2 * 1024 * 1024 * 1024;

    expect(
      cacheDownloadTargetBytes(
        retainLimitBytes: retention,
        requestedBytes: VideoCachePolicy.nextEpisodePreheatBytes,
      ),
      2 * 1024 * 1024,
    );
  });

  test('preheat target never exceeds media or retention size', () {
    expect(
      cacheDownloadTargetBytes(retainLimitBytes: 1024, requestedBytes: 2048),
      1024,
    );
    expect(
      cacheDownloadTargetBytes(
        retainLimitBytes: 4096,
        requestedBytes: 2048,
        mediaTotalBytes: 512,
      ),
      512,
    );
  });

  test('disabled retention produces no download target', () {
    expect(cacheDownloadTargetBytes(retainLimitBytes: 0), 0);
  });

  test('final cache chunk is clipped to the download target', () {
    expect(
      cacheChunkBytesToWrite(
        writtenBytes: 1536,
        targetBytes: 2048,
        chunkBytes: 1024,
      ),
      512,
    );
    expect(
      cacheChunkBytesToWrite(
        writtenBytes: 2048,
        targetBytes: 2048,
        chunkBytes: 1024,
      ),
      0,
    );
  });

  test('partial cache only serves fully covered bounded ranges', () {
    expect(videoCacheCoversRange(cachedBytes: 4096, range: (0, 1023)), isTrue);
    expect(videoCacheCoversRange(cachedBytes: 4096, range: (0, null)), isFalse);
    expect(videoCacheCoversRange(cachedBytes: 4096, range: null), isFalse);
    expect(
      videoCacheCoversRange(cachedBytes: 4096, range: (2048, 8191)),
      isFalse,
    );
  });

  test('playback position maps to a clamped media byte offset', () {
    const mediaBytes = 1000;
    expect(
      videoCacheByteOffsetForPosition(
        position: const Duration(minutes: 5),
        duration: const Duration(minutes: 10),
        mediaTotalBytes: mediaBytes,
      ),
      500,
    );
    expect(
      videoCacheByteOffsetForPosition(
        position: const Duration(minutes: 20),
        duration: const Duration(minutes: 10),
        mediaTotalBytes: mediaBytes,
      ),
      mediaBytes - 1,
    );
    expect(
      videoCacheByteOffsetForPosition(
        position: const Duration(minutes: 5),
        duration: Duration.zero,
        mediaTotalBytes: mediaBytes,
      ),
      0,
    );
  });

  test('cache range and refill threshold are relative to window start', () {
    expect(
      videoCacheCoversRange(
        cachedBytes: 100,
        startBytes: 500,
        range: (500, 599),
      ),
      isTrue,
    );
    expect(
      videoCacheCoversRange(
        cachedBytes: 100,
        startBytes: 500,
        range: (499, 599),
      ),
      isFalse,
    );
    expect(
      videoCacheShouldAdvanceWindow(
        playheadByte: 549,
        windowStartByte: 500,
        windowBytes: 100,
      ),
      isFalse,
    );
    expect(
      videoCacheShouldAdvanceWindow(
        playheadByte: 550,
        windowStartByte: 500,
        windowBytes: 100,
      ),
      isTrue,
    );
  });
}
