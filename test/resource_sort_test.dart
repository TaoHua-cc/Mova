import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/metadata/metadata_detail_page.dart';
import 'package:yingji/src/sources/emby_client.dart';
import 'package:yingji/src/sources/media_source.dart';
import 'package:yingji/src/sources/resource_selection.dart';

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
      playbackUrl: Uri.parse('http://localhost/a'),
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
      playbackUrl: Uri.parse('http://localhost/b'),
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
      playbackUrl: Uri.parse('http://localhost/c'),
      width: 1280,
      bitrate: 2,
      size: 3,
      videoRange: 'DolbyVision',
    ),
    MediaItem(id: 'missing', title: 'Missing', type: 'Episode', source: source),
  ];
  test('shared detail and player sort follows all four stored criteria', () {
    for (final entry in {
      'range': ['c', 'b', 'a', 'missing'],
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
  test(
    'range ranking is semantic and default quality does not follow API order',
    () {
      expect(
        [
          'DolbyVision',
          'HDR10+',
          'HDR10',
          'HLG',
          'HDR',
          'SDR',
          null,
        ].map(videoRangeRank),
        [6, 5, 4, 3, 2, 1, 0],
      );
      expect(videoRangeRank('HDR10Plus'), 5);
      expect(videoRangeRank('DOVI'), 6);
      expect(bestResourceVersion(rows.reversed)?.id, 'a');
      expect(bestResourceVersion([rows.last]), isNull);
    },
  );
  test('server defaults use best quality and manual selection is re-sorted by visible values', () {
    final other = MediaSource(
      id: 'other',
      name: 'Other',
      kind: SourceKind.emby,
      endpoint: Uri.parse('http://localhost/'),
    );
    final row = MediaItem(
      id: 'other',
      title: 'Other',
      type: 'Episode',
      source: other,
      width: 2560,
      bitrate: 4,
      size: 4,
    );
    final candidates = sortedResourceVersions([...rows, row], 'resolution');
    expect(serverResourceRepresentatives(candidates, null).map((r) => r.id), [
      'a',
      'other',
    ]);
    final displayed = sortedResourceVersions(
      serverResourceRepresentatives(candidates, rows[2]),
      'resolution',
    );
    expect(displayed.map((r) => r.id), ['other', 'c']);
  });
}
