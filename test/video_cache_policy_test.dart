import 'package:flutter_test/flutter_test.dart';

import 'package:yingji/src/cache/video_cache.dart';

void main() {
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
}
