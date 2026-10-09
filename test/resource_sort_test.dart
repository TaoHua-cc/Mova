import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/metadata/metadata_detail_page.dart';
import 'package:yingji/src/sources/emby_client.dart';
import 'package:yingji/src/sources/media_source.dart';

void main() {
  final source = MediaSource(
    id: 'server',
    name: 'Test',
    kind: SourceKind.emby,
    endpoint: Uri.parse('http://localhost/'),
  );
  final rows = [
    MediaItem(
      id: 'a',
      title: 'A',
      type: 'Episode',
      source: source,
      width: 3840,
      bitrate: 1,
      size: 2,
      videoRange: 'SDR',
    ),
    MediaItem(
      id: 'b',
      title: 'B',
      type: 'Episode',
      source: source,
      width: 1920,
      bitrate: 3,
      size: 1,
      videoRange: 'HDR10',
    ),
    MediaItem(
      id: 'c',
      title: 'C',
      type: 'Episode',
      source: source,
      width: 1280,
      bitrate: 2,
      size: 3,
      videoRange: 'DolbyVision',
    ),
    MediaItem(id: 'missing', title: 'Missing', type: 'Episode', source: source),
  ];
  test('shared detail and player sort follows all four stored criteria', () {
    for (final entry in {
      'range': ['a', 'b', 'c', 'missing'],
      'resolution': ['a', 'b', 'c', 'missing'],
      'bitrate': ['b', 'c', 'a', 'missing'],
      'size': ['c', 'a', 'b', 'missing'],
    }.entries) {
      expect(
        sortedResourceVersions(rows, entry.key).map((row) => row.id),
        entry.value,
      );
    }
    expect(rows.map((row) => row.id), ['a', 'b', 'c', 'missing']);
    expect(sortedResourceVersions([], 'range'), isEmpty);
  });
}
