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

class SegmentIdentifiers {
  const SegmentIdentifiers({this.imdbId, this.tvdbId, this.malId});
  final String? imdbId;
  final int? tvdbId;
  final int? malId;
}

/// Identifier-only public segment lookups. Titles are deliberately not used:
/// a false match would make the player skip real content.
class SegmentClient {
  SegmentClient({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  static const _timeout = Duration(seconds: 6);
  static const _metadata = 'https://yingji-metadata.gctykxy.workers.dev';

  Future<SegmentIdentifiers> identifiers({
    required int tmdbId,
    required bool movie,
  }) async {
    String? imdbId;
    int? tvdbId;
    final ids = await _json(
      Uri.parse(
        '$_metadata/tmdb/${movie ? 'movie' : 'tv'}/$tmdbId/external_ids',
      ),
      'TMDB',
    );
    if (ids is Map) {
      final imdb = '${ids['imdb_id'] ?? ''}';
      if (RegExp(r'^tt\d+$').hasMatch(imdb)) imdbId = imdb;
      tvdbId = (ids['tvdb_id'] as num?)?.toInt();
    }
    int? malId;
    for (final key in [
      if (imdbId != null) ('imdb', imdbId),
      if (tvdbId != null) ('tvdb', '$tvdbId'),
    ]) {
      try {
        final mapped = await _json(
          Uri.https('animap.id', '/api/map/${key.$1}/${key.$2}'),
          'AniMap',
        );
        final raw = mapped is Map ? mapped['mal_id'] : null;
        final matches = raw is List
            ? raw.whereType<num>().map((e) => e.toInt()).toSet()
            : <int>{};
        if (matches.length == 1) malId = matches.single;
        if (malId != null) break;
      } catch (_) {
        // Anime mapping is optional; other sources remain usable.
      }
    }
    return SegmentIdentifiers(imdbId: imdbId, tvdbId: tvdbId, malId: malId);
  }

  Future<List<PlaybackSegment>> introDb({
    required String imdbId,
    required int season,
    required int episode,
  }) async {
    final root = await _json(
      Uri.https('api.introdb.app', '/segments', {
        'imdb_id': imdbId,
        'season': '$season',
        'episode': '$episode',
      }),
      'IntroDB',
    );
    final rows = root is List
        ? root
        : root is Map && root['segments'] is List
        ? root['segments'] as List
        : root is Map
        ? [
            for (final type in const ['intro', 'recap', 'outro'])
              if (root[type] is Map)
                {...root[type] as Map, 'segment_type': type},
          ]
        : const [];
    return rows
        .whereType<Map>()
        .map(
          (row) => _segment(
            type: '${row['segment_type'] ?? row['type'] ?? ''}',
            start: row['start_sec'] ?? row['start'],
            end: row['end_sec'] ?? row['end'],
            provider: 'IntroDB',
          ),
        )
        .whereType<PlaybackSegment>()
        .toList(growable: false);
  }

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
    final root = await _json(
      Uri.https('api.theintrodb.org', '/v3/media', query),
      'TheIntroDB',
    );
    if (root is! Map) return const [];
    final result = <PlaybackSegment>[];
    for (final type in PlaybackSegmentType.values) {
      final rows = root[type.name];
      if (rows is! List) continue;
      for (final row in rows.whereType<Map>()) {
        result.add(
          PlaybackSegment(
            type: type,
            start:
                _duration(row['start_ms'], row['start_sec']) ?? Duration.zero,
            end: _duration(row['end_ms'], row['end_sec']),
            provider: 'TheIntroDB',
          ),
        );
      }
    }
    return result;
  }

  Future<List<PlaybackSegment>> aniSkip({
    required int malId,
    required int episode,
    Duration? duration,
  }) async {
    final root = await _json(
      Uri.https('api.aniskip.com', '/v2/skip-times/$malId/$episode', {
        'types': ['op', 'ed', 'mixed-op', 'mixed-ed', 'recap'],
        'episodeLength': '${duration?.inSeconds ?? 0}',
      }),
      'AniSkip',
    );
    final rows = root is Map && root['results'] is List
        ? root['results'] as List
        : const [];
    return rows
        .whereType<Map>()
        .map((row) {
          final interval = row['interval'];
          if (interval is! Map) return null;
          return _segment(
            type: '${row['skipType'] ?? ''}',
            start: interval['startTime'],
            end: interval['endTime'],
            provider: 'AniSkip',
          );
        })
        .whereType<PlaybackSegment>()
        .toList(growable: false);
  }

  Future<List<PlaybackSegment>> chaptersDb({
    String? imdbId,
    int? tvdbEpisodeId,
    int? season,
    int? episode,
  }) async {
    String? chapterId = tvdbEpisodeId == null ? null : '$tvdbEpisodeId';
    if (chapterId == null && imdbId != null) {
      final show = await _json(
        Uri.https('chaptersdb.com', '/api/v1/show/$imdbId'),
        'ChaptersDB',
      );
      if (show is Map && show['type'] == 'movie') {
        return _chapterSets(show['chapters']);
      }
      final rows = show is Map ? show['episodes'] : null;
      if (rows is List && season != null && episode != null) {
        final marker = RegExp(
          'S0*$season\\s*E0*$episode\\b',
          caseSensitive: false,
        );
        final match = rows
            .whereType<Map>()
            .where(
              (row) => marker.hasMatch('${row['title'] ?? row['slug'] ?? ''}'),
            )
            .firstOrNull;
        chapterId = '${match?['tvdbId'] ?? match?['slug'] ?? ''}';
      }
    }
    if (chapterId == null || chapterId.isEmpty) return const [];
    final root = await _json(
      Uri.https('chaptersdb.com', '/api/v1/chapters/$chapterId'),
      'ChaptersDB',
    );
    return _chapterSets(root is Map ? root['chapters'] : null);
  }

  List<PlaybackSegment> _chapterSets(dynamic value) {
    if (value is! List || value.isEmpty) return const [];
    final sets = value.whereType<Map>().toList()
      ..sort((a, b) => _score(b).compareTo(_score(a)));
    final entries = sets.first['entries'];
    if (entries is! List) return const [];
    final rows = entries.whereType<Map>().toList();
    final result = <PlaybackSegment>[];
    for (var i = 0; i < rows.length; i++) {
      final segment = _segment(
        type: '${rows[i]['name'] ?? ''}',
        start: rows[i]['time'],
        end: i + 1 < rows.length ? rows[i + 1]['time'] : null,
        provider: 'ChaptersDB',
      );
      if (segment != null) result.add(segment);
    }
    return result;
  }

  static int _score(Map row) =>
      (row['upvotes'] as num? ?? 0).toInt() -
      (row['downvotes'] as num? ?? 0).toInt();

  Future<dynamic> _json(Uri uri, String provider) async {
    final response = await _client
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(_timeout);
    if (response.statusCode == 404) return const <String, dynamic>{};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('$provider 返回 HTTP ${response.statusCode}');
    }
    return jsonDecode(response.body);
  }

  static PlaybackSegment? _segment({
    required String type,
    required dynamic start,
    dynamic end,
    required String provider,
  }) {
    final parsedType = _type(type);
    final parsedStart = _clock(start);
    if (parsedType == null || parsedStart == null) return null;
    return PlaybackSegment(
      type: parsedType,
      start: parsedStart,
      end: _clock(end),
      provider: provider,
    );
  }

  static PlaybackSegmentType? _type(String raw) {
    final value = raw.toLowerCase();
    if (value.contains('recap')) return PlaybackSegmentType.recap;
    if (value.contains('credit') ||
        value.contains('outro') ||
        value == 'ed' ||
        value == 'mixed-ed' ||
        value.contains('片尾')) {
      return PlaybackSegmentType.credits;
    }
    if (value.contains('preview')) return PlaybackSegmentType.preview;
    if (value.contains('intro') ||
        value == 'opening' ||
        value == 'op' ||
        value == 'mixed-op' ||
        value.contains('片头')) {
      return PlaybackSegmentType.intro;
    }
    return null;
  }

  static Duration? _clock(dynamic value) {
    if (value == null) return null;
    if (value is num) return Duration(milliseconds: (value * 1000).round());
    final values = '$value'.split(':').map(double.tryParse).toList();
    if (values.isEmpty || values.length > 3 || values.any((e) => e == null)) {
      return null;
    }
    var seconds = 0.0;
    for (final value in values) {
      seconds = seconds * 60 + value!;
    }
    return Duration(milliseconds: (seconds * 1000).round());
  }

  static Duration? _duration(dynamic milliseconds, dynamic seconds) =>
      milliseconds is num
      ? Duration(milliseconds: milliseconds.round())
      : _clock(seconds);

  void dispose() => _client.close();
}
