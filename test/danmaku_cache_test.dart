import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:yingji/src/cache/danmaku_cache.dart';
import 'package:yingji/src/player/danmaku_client.dart';

void main() {
  test('persists comments and native-player source metadata', () async {
    final root = await Directory.systemTemp.createTemp('mova-danmaku-cache-');
    addTearDown(() => root.delete(recursive: true));
    final cache = DanmakuCache.at(root);

    await cache.write(
      'episode',
      const [
        DanmakuComment(
          time: Duration(milliseconds: 12500),
          content: '缓存弹幕',
          color: 0xFFCC00,
          mode: DanmakuMode.top,
        ),
      ],
      matchedEpisode: '第一季 · 第二集',
      source: '主线路',
    );

    final restored = await cache.read('episode');
    expect(restored?.comments.single.content, '缓存弹幕');
    expect(restored?.comments.single.time, const Duration(milliseconds: 12500));
    expect(restored?.comments.single.mode, DanmakuMode.top);
    expect(restored?.matchedEpisode, '第一季 · 第二集');
    expect(restored?.source, '主线路');
    expect(restored?.isStale, isFalse);
  });

  test('cache key changes with source or episode', () {
    final first = DanmakuCache.keyFor(
      apis: const ['https://example.test/danmaku'],
      title: '测试剧',
      season: 1,
      episode: 1,
    );
    expect(
      DanmakuCache.keyFor(
        apis: const ['https://example.test/danmaku'],
        title: '测试剧',
        season: 1,
        episode: 2,
      ),
      isNot(first),
    );
    expect(
      DanmakuCache.keyFor(
        apis: const ['https://backup.test/danmaku'],
        title: '测试剧',
        season: 1,
        episode: 1,
      ),
      isNot(first),
    );
  });

  test('reads cache files written before source metadata existed', () async {
    final root = await Directory.systemTemp.createTemp('mova-danmaku-legacy-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}${Platform.pathSeparator}legacy.json')
        .writeAsString(
          jsonEncode({
            'savedAt': DateTime.now().millisecondsSinceEpoch,
            'matched': '旧匹配',
            'comments': [
              [1000, '旧缓存', null, 0],
            ],
          }),
        );

    final restored = await DanmakuCache.at(root).read('legacy');
    expect(restored?.comments.single.content, '旧缓存');
    expect(restored?.matchedEpisode, '旧匹配');
    expect(restored?.source, isNull);
  });
}
