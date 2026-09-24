import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/cache/discover_snapshot_cache.dart';
import 'package:yingji/src/metadata/tmdb_client.dart';

void main() {
  test('snapshot keys isolate changed source and filters', () {
    final original = DiscoverSnapshotCache.key('热门剧集', 'tmdb:tv', '');
    expect(
      DiscoverSnapshotCache.key('热门剧集', 'tmdb:movie', ''),
      isNot(original),
    );
    expect(
      DiscoverSnapshotCache.key('热门剧集', 'tmdb:tv', '{"genre":"16"}'),
      isNot(original),
    );
  });

  test('snapshot restores real poster data and rejects corruption', () {
    const item = TmdbItem(
      id: 42,
      title: '本机榜单',
      kind: '剧集',
      posterPath: '/poster.jpg',
      localPosterAsset: 'assets/defaults/posters/42.jpg',
      year: 2026,
    );
    final raw = jsonEncode({
      'version': 1,
      'rows': [item.toJson()],
    });
    final restored = DiscoverSnapshotCache.decode(raw);
    expect(restored?.single.title, item.title);
    expect(restored?.single.localPosterAsset, item.localPosterAsset);
    expect(DiscoverSnapshotCache.decode('{broken'), isNull);
    expect(
      DiscoverSnapshotCache.decode(jsonEncode({'version': 2, 'rows': []})),
      isNull,
    );
    expect(
      DiscoverSnapshotCache.decode(
        jsonEncode({
          'version': 1,
          'rows': <Object>[
            {'id': 0},
          ],
        }),
      ),
      isNull,
    );
  });
}
