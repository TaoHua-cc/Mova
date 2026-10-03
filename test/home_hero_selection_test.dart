import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/media_center.dart';
import 'package:yingji/src/metadata/tmdb_client.dart';

void main() {
  test('carousel refresh retains the selected title through reordering', () {
    const a = TmdbItem(id: 1, title: 'A', kind: '电影');
    const b = TmdbItem(id: 2, title: 'B', kind: '剧集');
    const sameIdMovie = TmdbItem(id: 2, title: 'C', kind: '电影');
    expect(retainedHomeHeroIndex([a, b], [b, a], 1), 0);
    expect(retainedHomeHeroIndex([a, b], [a, b], 1), 1);
    expect(retainedHomeHeroIndex([a, b], [sameIdMovie, a, b], 1), 2);
    expect(retainedHomeHeroIndex([a, b], [a], 1), 0);
    expect(retainedHomeHeroIndex([a, b], [], 1), 0);
    expect(retainedHomeHeroIndex([], [a, b], 0), 0);
  });
}
