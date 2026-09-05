import 'dart:convert';

import 'package:http/http.dart' as http;

class TraktEvent {
  const TraktEvent({
    required this.title,
    required this.episode,
    required this.airDate,
    this.posterUrl,
    this.platform,
    this.timeKnown = true,
    this.tmdbId,
    this.seasonNumber,
    this.episodeNumber,
  });
  final String title;
  final String episode;
  final DateTime airDate;
  final Uri? posterUrl;

  /// Trakt supplies the show's broadcast network when it is known.
  final String? platform;
  final bool timeKnown;
  final int? tmdbId;
  final int? seasonNumber;
  final int? episodeNumber;

  Map<String, dynamic> toJson() => {
    'title': title,
    'episode': episode,
    'airDate': airDate.toIso8601String(),
    'posterUrl': posterUrl?.toString(),
    'platform': platform,
    'timeKnown': timeKnown,
    'tmdbId': tmdbId,
    'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
  };

  factory TraktEvent.fromJson(Map<String, dynamic> value) => TraktEvent(
    title: '${value['title'] ?? '未命名剧集'}',
    episode: '${value['episode'] ?? ''}',
    airDate: DateTime.tryParse('${value['airDate'] ?? ''}') ?? DateTime.now(),
    posterUrl: '${value['posterUrl'] ?? ''}'.isEmpty
        ? null
        : Uri.tryParse('${value['posterUrl']}'),
    platform: value['platform'] as String?,
    timeKnown: value['timeKnown'] != false,
    tmdbId: (value['tmdbId'] as num?)?.toInt(),
    seasonNumber: (value['seasonNumber'] as num?)?.toInt(),
    episodeNumber: (value['episodeNumber'] as num?)?.toInt(),
  );
}

class TraktDeviceCode {
  const TraktDeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.expiresIn,
    required this.interval,
  });
  final String deviceCode;
  final String userCode;
  final String verificationUrl;
  final int expiresIn;
  final int interval;
}

class TraktClient {
  TraktClient({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  Future<TraktDeviceCode> requestDeviceCode(String clientId) async {
    final response = await _client
        .post(
          Uri.parse('https://api.trakt.tv/oauth/device/code'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'client_id': clientId.trim()}),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Trakt 授权码获取失败（HTTP ${response.statusCode}）');
    }
    final value = jsonDecode(response.body) as Map<String, dynamic>;
    return TraktDeviceCode(
      deviceCode: '${value['device_code'] ?? ''}',
      userCode: '${value['user_code'] ?? ''}',
      verificationUrl: '${value['verification_url'] ?? ''}',
      expiresIn: (value['expires_in'] as num?)?.toInt() ?? 600,
      interval: (value['interval'] as num?)?.toInt() ?? 5,
    );
  }

  Future<String> pollDeviceCode({
    required String clientId,
    required String clientSecret,
    required TraktDeviceCode device,
  }) async {
    final deadline = DateTime.now().add(Duration(seconds: device.expiresIn));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(Duration(seconds: device.interval));
      final response = await _client
          .post(
            Uri.parse('https://api.trakt.tv/oauth/device/token'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'code': device.deviceCode,
              'client_id': clientId.trim(),
              'client_secret': clientSecret.trim(),
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final value = jsonDecode(response.body) as Map<String, dynamic>;
        final token = '${value['access_token'] ?? ''}';
        if (token.isNotEmpty) return token;
      }
      if (response.statusCode != 400 && response.statusCode != 409) {
        throw Exception('Trakt 授权失败（HTTP ${response.statusCode}）');
      }
    }
    throw Exception('Trakt 授权已超时，请重新开始');
  }

  Future<List<TraktEvent>> calendar({
    required String clientId,
    required String accessToken,
    DateTime? start,
  }) async {
    if (clientId.trim().isEmpty || accessToken.trim().isEmpty) {
      throw Exception('请先在设置中配置 Trakt Client ID 和访问令牌');
    }
    final day = (start ?? DateTime.now()).toIso8601String().substring(0, 10);
    final response = await _client
        .get(
          Uri.parse(
            'https://api.trakt.tv/calendars/my/shows/$day/31?extended=full',
          ),
          headers: {
            'Authorization': 'Bearer ${accessToken.trim()}',
            'trakt-api-version': '2',
            'trakt-api-key': clientId.trim(),
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 401) throw Exception('Trakt 令牌已失效，请重新配置');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Trakt 同步失败（HTTP ${response.statusCode}）');
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .whereType<Map<String, dynamic>>()
        .where(
          (item) => DateTime.tryParse('${item['first_aired'] ?? ''}') != null,
        )
        .map((item) {
          final show = item['show'] as Map<String, dynamic>? ?? const {};
          final episode = item['episode'] as Map<String, dynamic>? ?? const {};
          final image = (show['images'] as Map<String, dynamic>?)?['poster'];
          final poster = image is Map<String, dynamic>
              ? image['full'] as String?
              : null;
          return TraktEvent(
            tmdbId: ((show['ids'] as Map?)?['tmdb'] as num?)?.toInt(),
            seasonNumber: (episode['season'] as num?)?.toInt(),
            episodeNumber: (episode['number'] as num?)?.toInt(),
            timeKnown: RegExp(r'(Z|[+-]\d{2}:\d{2})$')
                .hasMatch('${item['first_aired']}'),
            title: '${show['title'] ?? '未命名剧集'}',
            episode:
                '第 ${episode['season'] ?? 0} 季 · 第 ${episode['number'] ?? 0} 集 · ${episode['title'] ?? ''}',
            airDate:
                DateTime.tryParse('${item['first_aired'] ?? ''}') ??
                DateTime.now(),
            posterUrl: poster == null ? null : Uri.tryParse(poster),
            platform: '${show['network'] ?? ''}'.trim().isEmpty
                ? null
                : '${show['network']}',
          );
        })
        .toList(growable: false);
  }

  Future<void> setEpisodeWatched({
    required String clientId,
    required String accessToken,
    required int tmdbId,
    required int season,
    required int episode,
    required bool watched,
  }) async {
    if (clientId.trim().isEmpty || accessToken.trim().isEmpty || tmdbId <= 0) {
      throw Exception('Trakt 尚未授权或缺少 TMDB 标识');
    }
    final body = {
      'shows': [
        {
          'ids': {'tmdb': tmdbId},
          'seasons': [
            {
              'number': season,
              'episodes': [
                {'number': episode},
              ],
            },
          ],
        },
      ],
    };
    final response = await _client
        .post(
          Uri.parse(
            watched
                ? 'https://api.trakt.tv/sync/history'
                : 'https://api.trakt.tv/sync/history/remove',
          ),
          headers: {
            'Authorization': 'Bearer ${accessToken.trim()}',
            'trakt-api-version': '2',
            'trakt-api-key': clientId.trim(),
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Trakt 播放状态同步失败（HTTP ${response.statusCode}）');
    }
  }

  /// Persists the current partial position in Trakt's scrobble session. Trakt
  /// does not store an arbitrary playback position through sync/history; the
  /// scrobble stop endpoint is the supported resume-progress channel.
  Future<void> scrobbleProgress({
    required String clientId,
    required String accessToken,
    required int tmdbId,
    required int season,
    required int episode,
    required Duration position,
    required Duration duration,
    required bool paused,
  }) async {
    if (clientId.trim().isEmpty || accessToken.trim().isEmpty || tmdbId <= 0) {
      return;
    }
    if (duration <= Duration.zero) return;
    final progress = (position.inMilliseconds / duration.inMilliseconds * 100)
        .clamp(0, 100);
    final endpoint = paused
        ? 'https://api.trakt.tv/scrobble/pause'
        : 'https://api.trakt.tv/scrobble/stop';
    final response = await _client
        .post(
          Uri.parse(endpoint),
          headers: {
            'Authorization': 'Bearer ${accessToken.trim()}',
            'trakt-api-version': '2',
            'trakt-api-key': clientId.trim(),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'show': {
              'ids': {'tmdb': tmdbId},
            },
            'episode': {'season': season, 'number': episode},
            'progress': progress,
          }),
        )
        .timeout(const Duration(seconds: 15));
    // Trakt returns 201 for a started scrobble and 204 for a successful stop.
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Trakt 播放进度同步失败（HTTP ${response.statusCode}）');
    }
  }

  Future<Set<String>> watchedEpisodeKeys({
    required String clientId,
    required String accessToken,
    required int tmdbId,
  }) async {
    if (clientId.trim().isEmpty || accessToken.trim().isEmpty || tmdbId <= 0) {
      return const <String>{};
    }
    final response = await _client
        .get(
          Uri.parse('https://api.trakt.tv/sync/watched/shows?extended=full'),
          headers: {
            'Authorization': 'Bearer ${accessToken.trim()}',
            'trakt-api-version': '2',
            'trakt-api-key': clientId.trim(),
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Trakt 已观看记录读取失败（HTTP ${response.statusCode}）');
    }
    final rows = jsonDecode(response.body);
    if (rows is! List) return const <String>{};
    final keys = <String>{};
    for (final row in rows.whereType<Map>()) {
      final ids = row['show']?['ids'];
      if (ids is! Map || '${ids['tmdb'] ?? ''}' != '$tmdbId') continue;
      final seasons = row['seasons'];
      if (seasons is! List) continue;
      for (final season in seasons.whereType<Map>()) {
        final number = season['number'];
        final episodes = season['episodes'];
        if (number is! num || episodes is! List) continue;
        for (final episode in episodes.whereType<Map>()) {
          final episodeNumber = episode['number'];
          if (episodeNumber is num) {
            keys.add('${number.toInt()}:${episodeNumber.toInt()}');
          }
        }
      }
    }
    return keys;
  }

  void dispose() => _client.close();
}
