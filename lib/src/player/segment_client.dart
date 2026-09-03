import 'dart:convert';

import 'package:http/http.dart' as http;

enum PlaybackSegmentType { intro, recap, credits, preview }

class PlaybackSegment {
  const PlaybackSegment({
    required this.type,
    required this.start,
    this.end,
    required this.provider,
  });

  final PlaybackSegmentType type;
  final Duration start;
  final Duration? end;
  final String provider;

  String get label => switch (type) {
    PlaybackSegmentType.intro => '片头',
    PlaybackSegmentType.recap => '前情提要',
    PlaybackSegmentType.credits => '片尾',
    PlaybackSegmentType.preview => '下集预告',
  };
}

/// Reads public crowd-sourced segment data. The request shape follows the
/// documented v3 TheIntroDB media API and intentionally needs no shared key.
class SegmentClient {
  SegmentClient({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  Future<List<PlaybackSegment>> theIntroDb({
    required int tmdbId,
    int? season,
    int? episode,
    Duration? duration,
  }) async {
    final query = <String, String>{'tmdb_id': '$tmdbId'};
    if (season != null) query['season'] = '$season';
    if (episode != null) query['episode'] = '$episode';
    if (duration != null && duration > Duration.zero) {
      query['duration_ms'] = '${duration.inMilliseconds}';
    }
    final uri = Uri.https('api.theintrodb.org', '/v3/media', query);
    final response = await _client
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 6));
    if (response.statusCode == 404) return const [];
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('TheIntroDB 返回 HTTP ${response.statusCode}');
    }
    final root = jsonDecode(response.body);
    if (root is! Map<String, dynamic>) return const [];
    final values = <PlaybackSegment>[];
    for (final type in PlaybackSegmentType.values) {
      final entries = root[type.name];
      if (entries is! List) continue;
      for (final entry in entries.whereType<Map>()) {
        final start =
            _duration(entry['start_ms'], entry['start_sec']) ?? Duration.zero;
        final end = _duration(entry['end_ms'], entry['end_sec']);
        values.add(
          PlaybackSegment(
            type: type,
            start: start,
            end: end,
            provider: 'TheIntroDB',
          ),
        );
      }
    }
    return values;
  }

  static Duration? _duration(dynamic milliseconds, dynamic seconds) {
    if (milliseconds is num)
      return Duration(milliseconds: milliseconds.round());
    if (seconds is num) return Duration(milliseconds: (seconds * 1000).round());
    return null;
  }

  void dispose() => _client.close();
}
