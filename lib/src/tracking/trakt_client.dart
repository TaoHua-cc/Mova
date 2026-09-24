import 'dart:convert';

import 'package:http/http.dart' as http;

import '../metadata/tmdb_client.dart';

class TraktEvent {
  const TraktEvent({
    required this.title,
    required this.episode,
    required this.airDate,
    this.posterUrl,
    this.backdropUrl,
    this.platform,
    this.timeKnown = true,
    this.tmdbId,
    this.traktId,
    this.seasonNumber,
    this.episodeNumber,
    this.absoluteEpisodeNumber,
    this.totalEpisodes,
    this.platformLogoUrl,
  });
  final String title;
  final String episode;
  final DateTime airDate;
  final Uri? posterUrl;
  final Uri? backdropUrl;

  /// Trakt supplies the show's broadcast network when it is known.
  final String? platform;
  final bool timeKnown;
  final int? tmdbId;
  final int? traktId;
  final int? seasonNumber;
  final int? episodeNumber;
  final int? absoluteEpisodeNumber;
  final int? totalEpisodes;
  final Uri? platformLogoUrl;

  Map<String, dynamic> toJson() => {
    'title': title,
    'episode': episode,
    'airDate': airDate.toIso8601String(),
    'posterUrl': posterUrl?.toString(),
    'backdropUrl': backdropUrl?.toString(),
    'platform': platform,
    'timeKnown': timeKnown,
    'tmdbId': tmdbId,
    'traktId': traktId,
    'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
    if (absoluteEpisodeNumber != null)
      'absoluteEpisodeNumber': absoluteEpisodeNumber,
    if (totalEpisodes != null) 'totalEpisodes': totalEpisodes,
    if (platformLogoUrl != null) 'platformLogoUrl': platformLogoUrl.toString(),
  };

  factory TraktEvent.fromJson(Map<String, dynamic> value) => TraktEvent(
    title: '${value['title'] ?? '未命名剧集'}',
    episode: '${value['episode'] ?? ''}',
    airDate: DateTime.tryParse('${value['airDate'] ?? ''}') ?? DateTime.now(),
    posterUrl: '${value['posterUrl'] ?? ''}'.isEmpty
        ? null
        : Uri.tryParse('${value['posterUrl']}'),
    backdropUrl: '${value['backdropUrl'] ?? ''}'.isEmpty
        ? null
        : Uri.tryParse('${value['backdropUrl']}'),
    platform: value['platform'] as String?,
    timeKnown: value['timeKnown'] != false,
    tmdbId: (value['tmdbId'] as num?)?.toInt(),
    traktId: (value['traktId'] as num?)?.toInt(),
    seasonNumber: (value['seasonNumber'] as num?)?.toInt(),
    episodeNumber: (value['episodeNumber'] as num?)?.toInt(),
    absoluteEpisodeNumber: (value['absoluteEpisodeNumber'] as num?)?.toInt(),
    totalEpisodes: (value['totalEpisodes'] as num?)?.toInt(),
    platformLogoUrl: '${value['platformLogoUrl'] ?? ''}'.isEmpty
        ? null
        : Uri.tryParse('${value['platformLogoUrl']}'),
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

class TraktOAuthToken {
  const TraktOAuthToken({
    required this.accessToken,
    this.refreshToken = '',
    this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime? expiresAt;

  factory TraktOAuthToken.fromJson(Map<String, dynamic> value) {
    final createdAt = (value['created_at'] as num?)?.toInt();
    final expiresIn = (value['expires_in'] as num?)?.toInt();
    final expiresAt = createdAt != null && expiresIn != null
        ? DateTime.fromMillisecondsSinceEpoch(
            (createdAt + expiresIn) * 1000,
            isUtc: true,
          )
        : null;
    return TraktOAuthToken(
      accessToken: '${value['access_token'] ?? ''}',
      refreshToken: '${value['refresh_token'] ?? ''}',
      expiresAt: expiresAt,
    );
  }
}

class TraktPlaybackProgress {
  const TraktPlaybackProgress({
    required this.tmdbId,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.progress,
    required this.pausedAt,
  });

  final int tmdbId;
  final int seasonNumber;
  final int episodeNumber;
  final double progress;
  final DateTime? pausedAt;
}

class TraktShowProgress {
  const TraktShowProgress({required this.aired, required this.completed});

  final int aired;
  final int completed;
  int get unwatched => (aired - completed).clamp(0, aired);
}

class TraktDiscoveryItem {
  const TraktDiscoveryItem({required this.tmdbId, required this.kind});
  final int tmdbId;
  final String kind;
}

class TraktClient {
  TraktClient({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  Future<String> accountUuid({
    required String clientId,
    required String accessToken,
  }) async {
    final response = await _client
        .get(
          Uri.https('api.trakt.tv', '/users/settings'),
          headers: {
            'Authorization': 'Bearer ${accessToken.trim()}',
            'trakt-api-version': '2',
            'trakt-api-key': clientId.trim(),
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Trakt 账户信息读取失败（HTTP ${response.statusCode}）');
    }
    final data = jsonDecode(response.body);
    final user = data is Map ? data['user'] : null;
    final uuid = user is Map ? '${user['uuid'] ?? ''}'.trim() : '';
    if (uuid.isEmpty) throw Exception('Trakt 未返回账户标识');
    return uuid;
  }

  Future<TraktOAuthToken> exchangeAuthorizationCode({
    required Uri redirectUri,
    required String code,
  }) async {
    final response = await _client
        .post(
          Uri.parse('${TmdbClient.managedEndpoint}/trakt/oauth/token'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'code': code,
            'redirect_uri': redirectUri.toString(),
            'grant_type': 'authorization_code',
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Trakt 令牌交换失败（HTTP ${response.statusCode}）');
    }
    final token = TraktOAuthToken.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
    if (token.accessToken.isEmpty) throw Exception('Trakt 未返回访问令牌');
    return token;
  }

  Future<TraktOAuthToken> refreshAccessToken({
    required String refreshToken,
    required Uri redirectUri,
  }) async {
    final response = await _client
        .post(
          Uri.parse('${TmdbClient.managedEndpoint}/trakt/oauth/token'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'refresh_token': refreshToken,
            'redirect_uri': redirectUri.toString(),
            'grant_type': 'refresh_token',
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Trakt 令牌刷新失败（HTTP ${response.statusCode}）');
    }
    final token = TraktOAuthToken.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
    if (token.accessToken.isEmpty || token.refreshToken.isEmpty) {
      throw Exception('Trakt 刷新未返回完整令牌');
    }
    return token;
  }

  Future<List<TraktDiscoveryItem>> discover({
    required String clientId,
    required String type,
    required String list,
    int page = 1,
  }) async {
    if (clientId.trim().isEmpty) {
      throw Exception('Mova 的 Trakt 应用配置不可用，请检查网络后重试');
    }
    final kind = type == 'shows' ? '剧集' : '电影';
    final query = {
      'page': '$page',
      'limit': '20',
      'extended': 'full',
      if (list == 'watched' || list == 'played' || list == 'collected')
        'period': 'weekly',
    };
    final headers = {
      'trakt-api-version': '2',
      'trakt-api-key': clientId.trim(),
      'Accept': 'application/json',
    };
    http.Response? response;
    Object? lastError;
    for (final uri in [
      Uri.parse('${TmdbClient.managedEndpoint}/discover/trakt/$type/$list')
          .replace(queryParameters: query),
      Uri.https('api.trakt.tv', '/$type/$list', query),
    ]) {
      try {
        response = await _client
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 15));
        if (response.statusCode >= 200 && response.statusCode < 300) break;
        lastError = Exception('HTTP ${response.statusCode}');
        response = null;
      } catch (error) {
        lastError = error;
      }
    }
    if (response == null) {
      throw Exception('Trakt 榜单读取失败：$lastError');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Trakt 榜单读取失败（HTTP ${response.statusCode}）');
    }
    final rows = jsonDecode(response.body);
    if (rows is! List) return const [];
    final result = <TraktDiscoveryItem>[];
    final seen = <int>{};
    for (final row in rows.whereType<Map>()) {
      final nested = row[type == 'shows' ? 'show' : 'movie'];
      // Trakt wraps ranked feeds (trending, watched, anticipated) but returns
      // popular feeds as direct movie/show objects.
      final Map media = nested is Map ? nested : row;
      final ids = media['ids'];
      if (ids is! Map) continue;
      final tmdbId = (ids['tmdb'] as num?)?.toInt() ?? 0;
      if (tmdbId > 0 && seen.add(tmdbId)) {
        result.add(TraktDiscoveryItem(tmdbId: tmdbId, kind: kind));
      }
    }
    return result;
  }

  Future<List<TraktPlaybackProgress>> playbackProgress({
    required String clientId,
    required String accessToken,
  }) async {
    if (clientId.trim().isEmpty || accessToken.trim().isEmpty) return const [];
    final response = await _client
        .get(
          Uri.parse(
            'https://api.trakt.tv/sync/playback/episodes?extended=full',
          ),
          headers: {
            'Authorization': 'Bearer ${accessToken.trim()}',
            'trakt-api-version': '2',
            'trakt-api-key': clientId.trim(),
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Trakt 续播记录读取失败（HTTP ${response.statusCode}）');
    }
    final data = jsonDecode(response.body);
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((row) {
          final show = row['show'] as Map? ?? const {};
          final episode = row['episode'] as Map? ?? const {};
          final ids = show['ids'] as Map? ?? const {};
          return TraktPlaybackProgress(
            tmdbId: (ids['tmdb'] as num?)?.toInt() ?? 0,
            seasonNumber: (episode['season'] as num?)?.toInt() ?? 0,
            episodeNumber: (episode['number'] as num?)?.toInt() ?? 0,
            progress: ((row['progress'] as num?)?.toDouble() ?? 0).clamp(
              0,
              100,
            ),
            pausedAt: DateTime.tryParse('${row['paused_at'] ?? ''}'),
          );
        })
        .where((row) => row.tmdbId > 0 && row.progress > 0 && row.progress < 92)
        .toList(growable: false);
  }

  Future<TraktDeviceCode> requestDeviceCode() async {
    final response = await _client
        .post(
          Uri.parse('${TmdbClient.managedEndpoint}/trakt/oauth/device/code'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(const <String, String>{}),
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

  Future<String> pollDeviceCode({required TraktDeviceCode device}) async {
    final deadline = DateTime.now().add(Duration(seconds: device.expiresIn));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(Duration(seconds: device.interval));
      final response = await _client
          .post(
            Uri.parse('${TmdbClient.managedEndpoint}/trakt/oauth/device/token'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'code': device.deviceCode}),
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
      throw Exception('Trakt 尚未连接或访问令牌已失效');
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
    return _decodeCalendar(response.body);
  }

  /// Trakt's global calendar is filtered by Mova's local watchlist by TMDB ID.
  /// It is public, so it works even when the user has not connected an account.
  Future<List<TraktEvent>> allShowsCalendar({
    required String clientId,
    DateTime? start,
  }) async {
    if (clientId.trim().isEmpty) throw Exception('缺少 Trakt Client ID');
    final day = (start ?? DateTime.now()).toIso8601String().substring(0, 10);
    final response = await _client
        .get(
          Uri.https('api.trakt.tv', '/calendars/all/shows/$day/31', {
            'extended': 'full',
          }),
          headers: {
            'trakt-api-version': '2',
            'trakt-api-key': clientId.trim(),
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Trakt 全站日历读取失败（HTTP ${response.statusCode}）');
    }
    return _decodeCalendar(response.body);
  }

  List<TraktEvent> _decodeCalendar(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! List) return const [];
    final data = decoded;
    return data
        .whereType<Map<String, dynamic>>()
        .where(
          (item) => DateTime.tryParse('${item['first_aired'] ?? ''}') != null,
        )
        .map((item) {
          final firstAired = '${item['first_aired']}';
          final show = item['show'] as Map<String, dynamic>? ?? const {};
          final episode = item['episode'] as Map<String, dynamic>? ?? const {};
          final image = (show['images'] as Map<String, dynamic>?)?['poster'];
          final poster = image is Map<String, dynamic>
              ? image['full'] as String?
              : null;
          final fanart = (show['images'] as Map<String, dynamic>?)?['fanart'];
          final backdrop = fanart is Map<String, dynamic>
              ? fanart['full'] as String?
              : null;
          return TraktEvent(
            tmdbId: ((show['ids'] as Map?)?['tmdb'] as num?)?.toInt(),
            traktId: ((show['ids'] as Map?)?['trakt'] as num?)?.toInt(),
            seasonNumber: (episode['season'] as num?)?.toInt(),
            episodeNumber: (episode['number'] as num?)?.toInt(),
            absoluteEpisodeNumber: (episode['number_abs'] as num?)?.toInt(),
            timeKnown: _hasPublishedAirtime(firstAired),
            title: '${show['title'] ?? '未命名剧集'}',
            episode:
                '第 ${episode['season'] ?? 0} 季 · 第 ${episode['number'] ?? 0} 集 · ${episode['title'] ?? ''}',
            airDate:
                DateTime.tryParse('${item['first_aired'] ?? ''}') ??
                DateTime.now(),
            posterUrl: poster == null ? null : Uri.tryParse(poster),
            backdropUrl: backdrop == null ? null : Uri.tryParse(backdrop),
            platform: '${show['network'] ?? ''}'.trim().isEmpty
                ? null
                : '${show['network']}',
          );
        })
        .toList(growable: false);
  }

  bool _hasPublishedAirtime(String value) {
    if (!RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(value)) return false;
    final aired = DateTime.tryParse(value);
    if (aired == null) return false;
    // Trakt may encode a date-only placeholder as midnight UTC. Do not present
    // that transport default as a confirmed local broadcast time.
    final utc = value.endsWith('Z') || value.endsWith('+00:00');
    return !(utc && aired.hour == 0 && aired.minute == 0 && aired.second == 0);
  }

  /// Read both media types from the authenticated Trakt watchlist.
  Future<List<TmdbItem>> watchlist({
    required String clientId,
    required String accessToken,
  }) async {
    final rows = await Future.wait([
      _watchlistRequest(
        '/sync/watchlist/shows',
        clientId: clientId,
        accessToken: accessToken,
        kind: '剧集',
        key: 'show',
      ),
      _watchlistRequest(
        '/sync/watchlist/movies',
        clientId: clientId,
        accessToken: accessToken,
        kind: '电影',
        key: 'movie',
      ),
    ]);
    return rows.expand((items) => items).toList(growable: false);
  }

  Future<List<TmdbItem>> _watchlistRequest(
    String path, {
    required String clientId,
    required String accessToken,
    required String kind,
    required String key,
  }) async {
    if (clientId.trim().isEmpty || accessToken.trim().isEmpty) {
      throw Exception('Trakt 尚未连接或访问令牌已失效');
    }
    final response = await _client
        .get(
          Uri.https('api.trakt.tv', path, {'extended': 'full'}),
          headers: {
            'Authorization': 'Bearer ${accessToken.trim()}',
            'trakt-api-version': '2',
            'trakt-api-key': clientId.trim(),
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Trakt 待看读取失败（HTTP ${response.statusCode}）');
    }
    final data = jsonDecode(response.body);
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((row) {
          final media = row[key] as Map? ?? row;
          final ids = media['ids'] as Map? ?? const {};
          return TmdbItem(
            id: (ids['tmdb'] as num?)?.toInt() ?? 0,
            title: '${media['title'] ?? '未命名'}',
            kind: kind,
            year: (media['year'] as num?)?.toInt(),
          );
        })
        .where((item) => item.id > 0)
        .toList(growable: false);
  }

  Future<void> addWatchlistItems({
    required String clientId,
    required String accessToken,
    required Iterable<TmdbItem> items,
  }) => _changeWatchlist(
    '/sync/watchlist',
    clientId: clientId,
    accessToken: accessToken,
    items: items,
  );

  Future<void> removeWatchlistItems({
    required String clientId,
    required String accessToken,
    required Iterable<TmdbItem> items,
  }) => _changeWatchlist(
    '/sync/watchlist/remove',
    clientId: clientId,
    accessToken: accessToken,
    items: items,
  );

  Future<void> _changeWatchlist(
    String path, {
    required String clientId,
    required String accessToken,
    required Iterable<TmdbItem> items,
  }) async {
    if (clientId.trim().isEmpty || accessToken.trim().isEmpty) {
      throw Exception('Trakt 尚未连接或访问令牌已失效');
    }
    final valid = items.where((item) => item.id > 0).toList(growable: false);
    if (valid.isEmpty) return;
    final shows = valid
        .where((item) => item.kind == '剧集')
        .map(
          (item) => {
            'ids': {'tmdb': item.id},
          },
        )
        .toList(growable: false);
    final movies = valid
        .where((item) => item.kind == '电影')
        .map(
          (item) => {
            'ids': {'tmdb': item.id},
          },
        )
        .toList(growable: false);
    if (shows.isEmpty && movies.isEmpty) return;
    final response = await _client
        .post(
          Uri.https('api.trakt.tv', path),
          headers: {
            'Authorization': 'Bearer ${accessToken.trim()}',
            'trakt-api-version': '2',
            'trakt-api-key': clientId.trim(),
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode({
            if (shows.isNotEmpty) 'shows': shows,
            if (movies.isNotEmpty) 'movies': movies,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Trakt 待看同步失败（HTTP ${response.statusCode}）');
    }
  }

  Future<TraktShowProgress?> showWatchedProgress({
    required String clientId,
    required String accessToken,
    required int traktId,
  }) async {
    if (clientId.trim().isEmpty || accessToken.trim().isEmpty || traktId <= 0) {
      return null;
    }
    final response = await _client
        .get(
          Uri.https('api.trakt.tv', '/shows/$traktId/progress/watched'),
          headers: {
            'Authorization': 'Bearer ${accessToken.trim()}',
            'trakt-api-version': '2',
            'trakt-api-key': clientId.trim(),
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Trakt 剧集进度读取失败（HTTP ${response.statusCode}）');
    }
    final value = jsonDecode(response.body);
    if (value is! Map) return null;
    final aired = (value['aired'] as num?)?.toInt() ?? 0;
    final completed = (value['completed'] as num?)?.toInt() ?? 0;
    if (aired <= 0) return null;
    return TraktShowProgress(
      aired: aired,
      completed: completed.clamp(0, aired),
    );
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
