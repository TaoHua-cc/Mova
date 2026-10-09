import 'emby_client.dart';

int videoRangeRank(String? value) {
  final range = (value ?? '').toLowerCase().replaceAll(RegExp(r'[\s_-]'), '');
  if (range.contains('dolbyvision') ||
      range == 'dv' ||
      range.startsWith('dovi')) {
    return 6;
  }
  if (range.contains('hdr10+') || range.contains('hdr10plus')) return 5;
  if (range.contains('hdr10')) return 4;
  if (range.contains('hlg')) return 3;
  if (range.contains('hdr')) return 2;
  if (range.contains('sdr')) return 1;
  return 0;
}

int compareResourceQuality(MediaItem a, MediaItem b) {
  for (final result in [
    (b.width ?? 0).compareTo(a.width ?? 0),
    (b.height ?? 0).compareTo(a.height ?? 0),
    videoRangeRank(b.videoRange).compareTo(videoRangeRank(a.videoRange)),
    (b.bitrate ?? 0).compareTo(a.bitrate ?? 0),
    (b.size ?? 0).compareTo(a.size ?? 0),
  ]) {
    if (result != 0) return result;
  }
  return a.resourceKey.compareTo(b.resourceKey);
}

List<MediaItem> sortedResourceVersions(
  Iterable<MediaItem> resources,
  String sort,
) {
  final rows = resources.toList();
  rows.sort((a, b) {
    final primary = switch (sort) {
      'resolution' => (b.width ?? 0).compareTo(a.width ?? 0),
      'bitrate' => (b.bitrate ?? 0).compareTo(a.bitrate ?? 0),
      'size' => (b.size ?? 0).compareTo(a.size ?? 0),
      _ => videoRangeRank(b.videoRange).compareTo(videoRangeRank(a.videoRange)),
    };
    return primary != 0 ? primary : compareResourceQuality(a, b);
  });
  return rows;
}

MediaItem? bestResourceVersion(Iterable<MediaItem> resources) =>
    sortedResourceVersions(
      resources.where((row) => row.playbackUrl != null),
      'resolution',
    ).firstOrNull;
