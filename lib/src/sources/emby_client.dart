import 'dart:convert';

import 'package:http/http.dart' as http;

import 'media_source.dart';

class MediaItem {
  const MediaItem({
    required this.id,
    required this.title,
    required this.type,
    required this.source,
    this.overview,
    this.imageUrl,
    this.playbackUrl,
    this.year,
    this.premiereDate,
    this.runtime,
    this.headers = const {},
    this.providerIds = const {},
    this.parentId,
    this.seriesId,
    this.seriesTitle,
    this.seasonNumber,
    this.episodeNumber,
    this.isContainer = false,
    this.chapters = const [],
    this.container,
    this.size,
    this.bitrate,
    this.width,
    this.height,
    this.videoCodec,
    this.videoRange,
    this.bitDepth,
    this.frameRate,
    this.audioTracks = const [],
    this.subtitleTracks = const [],
    this.playbackPosition,
    this.isPlayed = false,
    this.lastPlayedAt,
  });
  final String id;
  final String title;
  final String type;
  final MediaSource source;
  final String? overview;
  final Uri? imageUrl;
  final Uri? playbackUrl;
  final int? year;
  final DateTime? premiereDate;
  final Duration? runtime;
  final Map<String, String> headers;
  final Map<String, String> providerIds;
  final String? parentId;
  final String? seriesId;

  /// Parent series name is essential when an episode is opened from global
  /// server search: its own title is often only “第 1 集”.
  final String? seriesTitle;
  final int? seasonNumber;
  final int? episodeNumber;
  final bool isContainer;
  final List<MediaChapter> chapters;
  final String? container;
  final int? size;
  final int? bitrate;
  final int? width;
  final int? height;
  final String? videoCodec;
  final String? videoRange;
  final int? bitDepth;
  final double? frameRate;
  final List<MediaTrack> audioTracks;
  final List<MediaTrack> subtitleTracks;
  final Duration? playbackPosition;
  final bool isPlayed;

  /// When the user last played/resumed this item on the server. The resume
  /// rail sends it in UserData.LastPlayedDate and the home page uses it to
  /// order continue-watching rows by the real watch time across devices.
  final DateTime? lastPlayedAt;
}

class MediaTrack {
  const MediaTrack({
    required this.index,
    required this.title,
    required this.codec,
    this.language,
    this.channels,
    this.sampleRate,
    this.bitrate,
    this.isDefault = false,
  });

  final int index;
  final String title;
  final String codec;
  final String? language;
  final int? channels;
  final int? sampleRate;
  final int? bitrate;
  final bool isDefault;
}

class MediaChapter {
  const MediaChapter({required this.title, required this.start});
  final String title;
  final Duration start;
}

class EmbySession {
  const EmbySession({required this.source, required this.token});
  final MediaSource source;
  final String token;
}

class EmbyLibraryStats {
  const EmbyLibraryStats({
    required this.movieCount,
    required this.seriesCount,
    required this.episodeCount,
    required this.latency,
  });

  final int movieCount;
  final int seriesCount;
  final int episodeCount;
  final Duration latency;
}

class EmbyClient {
  EmbyClient({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  /// Selects the first line that accepts this saved login, not merely the
  /// first reverse proxy that answers a public health request.
  Future<EmbySession> resolveSession(EmbySession session) async {
    final userId = session.source.userId;
    if (userId == null || userId.isEmpty) {
      throw Exception('媒体服务器登录信息缺少用户 ID');
    }
    Object? lastError;
    for (final endpoint in session.source.endpoints) {
      try {
        final base = _base(endpoint);
        final response = await _client
            .get(
              base
                  .resolve('Users/$userId')
                  .replace(queryParameters: {'api_key': session.token}),
              headers: {
                'Accept': 'application/json',
                'X-Emby-Token': session.token,
              },
            )
            .timeout(const Duration(seconds: 10));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          lastError = Exception(_message(response.statusCode, '服务器登录验证失败'));
          continue;
        }
        return EmbySession(
          token: session.token,
          source: MediaSource(
            id: session.source.id,
            name: session.source.name,
            kind: session.source.kind,
            endpoint: base,
            userId: userId,
            serverId: session.source.serverId,
            alternateEndpoints: session.source.endpoints
                .where((value) => value != endpoint)
                .toList(growable: false),
            iconUrl: session.source.iconUrl,
            customIcon: session.source.customIcon,
          ),
        );
      } catch (error) {
        lastError = error;
      }
    }
    throw Exception(
      lastError?.toString().replaceFirst('Exception: ', '') ?? '所有服务器线路均无法验证登录',
    );
  }

  Future<
    ({String name, String id, Uri endpoint, List<Uri> discoveredEndpoints})
  >
  serverIdentity(MediaSource source, {String? token}) async {
    Object? lastError;
    for (final endpoint in source.endpoints) {
      final base = _base(endpoint);
      for (final path in [
        if (token != null && token.isNotEmpty) 'System/Info',
        'System/Info/Public',
      ]) {
        try {
          final response = await _client
              .get(
                base
                    .resolve(path)
                    .replace(
                      queryParameters: token == null || token.isEmpty
                          ? null
                          : {'api_key': token},
                    ),
                headers: {
                  'Accept': 'application/json',
                  if (token != null && token.isNotEmpty) 'X-Emby-Token': token,
                },
              )
              .timeout(const Duration(seconds: 10));
          if (response.statusCode < 200 || response.statusCode >= 300) {
            lastError = Exception(_message(response.statusCode, '服务器信息读取失败'));
            continue;
          }
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final name = '${data['ServerName'] ?? data['Name'] ?? source.name}'
              .trim();
          final id = '${data['Id'] ?? source.serverId ?? source.id}'.trim();
          final discovered = <Uri>[];
          for (final value in [data['LocalAddress'], data['WanAddress']]) {
            final candidate = Uri.tryParse('${value ?? ''}'.trim());
            if (candidate != null &&
                ['http', 'https'].contains(candidate.scheme) &&
                candidate.host.isNotEmpty) {
              final normalized = _base(candidate);
              if (!discovered.contains(normalized)) discovered.add(normalized);
            }
          }
          return (
            name: name.isEmpty ? source.name : name,
            id: id.isEmpty ? source.id : id,
            endpoint: base,
            discoveredEndpoints: discovered,
          );
        } catch (error) {
          lastError = error;
        }
      }
    }
    throw Exception(
      lastError?.toString().replaceFirst('Exception: ', '').trim().isNotEmpty ==
              true
          ? lastError.toString().replaceFirst('Exception: ', '')
          : '所有服务器线路均无法连接',
    );
  }

  Future<EmbySession> authenticate({
    required Uri endpoint,
    required String username,
    required String password,
    SourceKind kind = SourceKind.emby,
  }) async {
    final base = _base(endpoint);
    final url = base.resolve('Users/AuthenticateByName');
    final response = await _client
        .post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'X-Emby-Authorization': 'MediaBrowser Client="Mova", Device="Windows", DeviceId="mova-windows", Version="3.1.65"',
          },
          body: jsonEncode({'Username': username, 'Pw': password}),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_message(response.statusCode, '媒体服务器登录失败'));
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final token = '${data['AccessToken'] ?? ''}';
    final userId = '${(data['User'] as Map<String, dynamic>?)?['Id'] ?? ''}';
    if (token.isEmpty || userId.isEmpty) throw Exception('媒体服务器返回的登录信息不完整');
    final source = MediaSource(
      id: '${data['ServerId'] ?? base.host}',
      name: '${data['ServerName'] ?? base.host}',
      kind: kind,
      endpoint: base,
      userId: userId,
      serverId: '${data['ServerId'] ?? ''}',
    );
    return EmbySession(source: source, token: token);
  }

  Future<List<MediaItem>> recentlyAdded(EmbySession session) async {
    final userId = session.source.userId;
    if (userId == null || userId.isEmpty) return const [];
    final query = {
      'IncludeItemTypes': 'Movie,Series,Episode',
      'Recursive': 'true',
      'SortBy': 'DateCreated',
      'SortOrder': 'Descending',
      'Limit': '50',
      'Fields': 'Overview,ProviderIds,MediaSources,RunTimeTicks,ProductionYear,PrimaryImageAspectRatio,Chapters',
      'api_key': session.token,
    };
    final response = await _client
        .get(
          session.source.endpoint
              .resolve('Users/$userId/Items')
              .replace(queryParameters: query),
          headers: {
            'Accept': 'application/json',
            'X-Emby-Token': session.token,
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_message(response.statusCode, '媒体库读取失败'));
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (data['Items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((item) => _item(session, item))
        .toList(growable: false);
  }

  /// Reads the server's resume rail so the home page can reconcile progress
  /// from another device with the local watch-state cache.
  Future<List<MediaItem>> resumeItems(EmbySession session) async {
    final userId = session.source.userId;
    if (userId == null || userId.isEmpty) return const [];
    final response = await _client
        .get(
          session.source.endpoint
              .resolve('Users/$userId/Items')
              .replace(
                queryParameters: {
                  'Filters': 'IsResumable',
                  'IncludeItemTypes': 'Movie,Series,Episode',
                  'Recursive': 'true',
                  'SortBy': 'DatePlayed',
                  'SortOrder': 'Descending',
                  'Limit': '50',
                  'Fields': 'Overview,ProviderIds,MediaSources,RunTimeTicks,ProductionYear,PremiereDate,ParentId,SeriesId,SeriesName,ParentIndexNumber,IndexNumber,Chapters,UserData',
                  'api_key': session.token,
                },
              ),
          headers: {
            'Accept': 'application/json',
            'X-Emby-Token': session.token,
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_message(response.statusCode, '服务器继续观看读取失败'));
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (data['Items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((item) => _item(session, item))
        .where((item) => item.playbackPosition != null)
        .toList(growable: false);
  }

  Future<List<MediaItem>> search(EmbySession session, String query) async {
    final userId = session.source.userId;
    if (userId == null || userId.isEmpty || query.trim().isEmpty) {
      return const [];
    }
    final response = await _client
        .get(
          session.source.endpoint
              .resolve('Users/$userId/Items')
              .replace(
                queryParameters: {
                  'SearchTerm': query.trim(),
                  'IncludeItemTypes': 'Movie,Series,Episode',
                  'Recursive': 'true',
                  'Limit': '50',
                  'Fields': 'Overview,ProviderIds,MediaSources,RunTimeTicks,ProductionYear,PremiereDate,ParentId,SeriesId,SeriesName,ParentIndexNumber,IndexNumber,Chapters',
                  'api_key': session.token,
                },
              ),
          headers: {
            'Accept': 'application/json',
            'X-Emby-Token': session.token,
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_message(response.statusCode, '服务器搜索失败'));
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (data['Items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((item) => _item(session, item))
        .toList(growable: false);
  }

  Future<void> setPlayed(
    EmbySession session,
    String itemId, {
    required bool played,
  }) async {
    final userId = session.source.userId;
    if (userId == null || userId.isEmpty || itemId.isEmpty) return;
    final request =
        http.Request(
            played ? 'POST' : 'DELETE',
            session.source.endpoint
                .resolve('Users/$userId/PlayedItems/$itemId')
                .replace(queryParameters: {'api_key': session.token}),
          )
          ..headers.addAll({
            'Accept': 'application/json',
            'X-Emby-Token': session.token,
          });
    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(seconds: 15)),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_message(response.statusCode, '播放状态同步失败'));
    }
  }

  /// Fetches one item by its server id. The continue-watching shelf stores
  /// only the episode/movie id, so opening its detail page needs a precise
  /// lookup — a title search is ambiguous and, on libraries whose episode
  /// names embed the series title, returns dozens of episodes that carry no
  /// TMDB provider id.
  Future<MediaItem> itemById(EmbySession session, String itemId) async {
    final userId = session.source.userId;
    if (userId == null || userId.isEmpty || itemId.isEmpty) {
      throw Exception('缺少媒体 ID');
    }
    final response = await _client
        .get(
          session.source.endpoint
              .resolve('Users/$userId/Items/$itemId')
              .replace(
                queryParameters: {
                  'Fields': 'Overview,ProviderIds,MediaSources,RunTimeTicks,ProductionYear,PremiereDate,ParentId,SeriesId,SeriesName,ParentIndexNumber,IndexNumber,Chapters,UserData',
                  'api_key': session.token,
                },
              ),
          headers: {
            'Accept': 'application/json',
            'X-Emby-Token': session.token,
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_message(response.statusCode, '条目读取失败'));
    }
    return _item(session, jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<List<MediaItem>> findByTmdbId(EmbySession session, int tmdbId) async {
    if (session.source.userId == null || tmdbId <= 0) return const [];
    final response = await _client
        .get(
          session.source.endpoint
              .resolve('Users/${session.source.userId}/Items')
              .replace(
                queryParameters: {
                  // This Emby 4.9 endpoint uses the `Provider.value` form.
                  'AnyProviderIdEquals': 'Tmdb.$tmdbId',
                  'IncludeItemTypes': 'Movie,Series,Episode',
                  'Recursive': 'true',
                  'Fields': 'Overview,ProviderIds,MediaSources,RunTimeTicks,ProductionYear,PremiereDate,ParentId,SeriesId,SeriesName,ParentIndexNumber,IndexNumber,Chapters',
                  'Limit': '50',
                },
              ),
          headers: {
            'Accept': 'application/json',
            'X-Emby-Token': session.token,
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_message(response.statusCode, '媒体库匹配失败'));
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (data['Items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((item) => _item(session, item))
        .toList(growable: false);
  }

  Future<List<MediaItem>> episodesForSeries(
    EmbySession session,
    String seriesId,
  ) async {
    final userId = session.source.userId;
    if (userId == null || userId.isEmpty || seriesId.isEmpty) {
      return const [];
    }
    final response = await _client
        .get(
          session.source.endpoint
              .resolve('Shows/$seriesId/Episodes')
              .replace(
                queryParameters: {
                  'UserId': userId,
                  'SortBy': 'ParentIndexNumber,IndexNumber',
                  'SortOrder': 'Ascending',
                  'Limit': '200',
                  'Fields': 'Overview,ProviderIds,MediaSources,RunTimeTicks,ProductionYear,PremiereDate,ParentId,SeriesId,ParentIndexNumber,IndexNumber,Chapters,UserData',
                  'api_key': session.token,
                },
              ),
          headers: {
            'Accept': 'application/json',
            'X-Emby-Token': session.token,
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_message(response.statusCode, '剧集资源读取失败'));
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (data['Items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((item) => _item(session, item))
        .toList(growable: false);
  }

  Future<List<MediaItem>> seasonsForSeries(
    EmbySession session,
    String seriesId,
  ) async {
    final userId = session.source.userId;
    if (userId == null || userId.isEmpty || seriesId.isEmpty) {
      return const [];
    }
    final response = await _client
        .get(
          session.source.endpoint
              .resolve('Users/$userId/Items')
              .replace(
                queryParameters: {
                  'ParentId': seriesId,
                  'IncludeItemTypes': 'Season',
                  'Recursive': 'false',
                  'SortBy': 'IndexNumber',
                  'SortOrder': 'Ascending',
                  'Fields': 'ParentIndexNumber,IndexNumber,ImageTags',
                  'api_key': session.token,
                },
              ),
          headers: {
            'Accept': 'application/json',
            'X-Emby-Token': session.token,
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_message(response.statusCode, '季海报读取失败'));
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (data['Items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((item) => _item(session, item))
        .toList(growable: false);
  }

  Future<EmbyLibraryStats> libraryStats(EmbySession session) async {
    final userId = session.source.userId;
    if (userId == null || userId.isEmpty) {
      throw Exception('媒体服务器登录信息缺少用户 ID');
    }
    final stopwatch = Stopwatch()..start();
    Future<int> count(String type) async {
      final response = await _client
          .get(
            session.source.endpoint
                .resolve('Users/$userId/Items')
                .replace(
                  queryParameters: {
                    'IncludeItemTypes': type,
                    'Recursive': 'true',
                    'Limit': '0',
                    'EnableTotalRecordCount': 'true',
                    'Fields': 'Id',
                    'api_key': session.token,
                  },
                ),
            headers: {
              'Accept': 'application/json',
              'X-Emby-Token': session.token,
            },
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(_message(response.statusCode, '媒体库统计读取失败'));
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return (data['TotalRecordCount'] as num?)?.toInt() ?? 0;
    }

    // Some reverse proxies throttle simultaneous `/Items` requests. Keep this
    // small probe sequential so all three totals are populated reliably.
    final counts = [
      await count('Movie'),
      await count('Series'),
      await count('Episode'),
    ];
    stopwatch.stop();
    return EmbyLibraryStats(
      movieCount: counts[0],
      seriesCount: counts[1],
      episodeCount: counts[2],
      latency: stopwatch.elapsed,
    );
  }

  Future<List<MediaItem>> browse(
    EmbySession session, {
    String? parentId,
  }) async {
    final userId = session.source.userId;
    if (userId == null || userId.isEmpty) return const [];
    final query = <String, String>{
      'SortBy': 'SortName',
      'SortOrder': 'Ascending',
      'Limit': '100',
      'Fields': 'Overview,ProviderIds,MediaSources,RunTimeTicks,ProductionYear,PremiereDate,ParentId,SeriesId,SeriesName,ParentIndexNumber,IndexNumber,IsFolder,Chapters',
      'api_key': session.token,
    };
    if (parentId == null) {
      query['IncludeItemTypes'] = 'CollectionFolder,Movie,Series';
    } else {
      query['ParentId'] = parentId;
      query['IncludeItemTypes'] = 'Movie,Series,Season,Episode';
    }
    final response = await _client
        .get(
          session.source.endpoint
              .resolve('Users/$userId/Items')
              .replace(queryParameters: query),
          headers: {
            'Accept': 'application/json',
            'X-Emby-Token': session.token,
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_message(response.statusCode, '媒体库读取失败'));
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (data['Items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((item) => _item(session, item))
        .toList(growable: false);
  }

  /// Performs a small authenticated request so the source page can distinguish
  /// a bad endpoint/token from an empty library.
  Future<void> checkConnection(EmbySession session) async {
    final userId = session.source.userId;
    if (userId == null || userId.isEmpty) {
      throw Exception('媒体服务器登录信息缺少用户 ID');
    }
    final response = await _client
        .get(
          session.source.endpoint
              .resolve('Users/$userId')
              .replace(queryParameters: {'api_key': session.token}),
          headers: {
            'Accept': 'application/json',
            'X-Emby-Token': session.token,
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_message(response.statusCode, '媒体服务器连接失败'));
    }
  }

  /// Announces to the server that playback of [itemId] has begun. Emby only
  /// stamps `UserData.LastPlayedDate` from these lifecycle reports, so a
  /// client that posts bare progress forever leaves every resume row undated
  /// and the server's `DatePlayed` sort (and every client's "continue
  /// watching" shelf) has nothing to order by. Sending start/stop makes this
  /// app behave like an official Emby client.
  Future<void> startSession({
    required EmbySession session,
    required String itemId,
    required Duration position,
    required Duration duration,
    required bool isPaused,
    String? playSessionId,
    String? mediaSourceId,
  }) async {
    if (itemId.isEmpty) return;
    await _postSession(
      session: session,
      path: 'Sessions/Playing',
      itemId: itemId,
      position: position,
      duration: duration,
      isPaused: isPaused,
      playSessionId: playSessionId,
      mediaSourceId: mediaSourceId,
      failure: '播放开始同步失败',
    );
  }

  /// Closes the playback session for [itemId] with its final [position].
  /// Emby uses this report to stamp the row's last-played time (and, when the
  /// item reached the end, to mark it played so it leaves the resume rail).
  Future<void> stopSession({
    required EmbySession session,
    required String itemId,
    required Duration position,
    required Duration duration,
    String? playSessionId,
    String? mediaSourceId,
  }) async {
    if (itemId.isEmpty) return;
    await _postSession(
      session: session,
      path: 'Sessions/Playing/Stopped',
      itemId: itemId,
      position: position,
      duration: duration,
      isPaused: false,
      playSessionId: playSessionId,
      mediaSourceId: mediaSourceId,
      failure: '播放结束同步失败',
    );
  }

  /// Shared sender for the Emby playback-session endpoints. Verified against a
  /// real server: `Sessions/Playing` and `Sessions/Playing/Progress` reject a
  /// body without `PlaySessionId` with 400 "Value cannot be null. (Parameter
  /// 'key')", so every playback session must carry the id its caller minted
  /// once at start. `MediaSourceId` is not mandatory (the server falls back to
  /// the item's default source) but is sent whenever the caller knows it, as
  /// official Emby clients do.
  Future<void> _postSession({
    required EmbySession session,
    required String path,
    required String itemId,
    required Duration position,
    required Duration duration,
    required bool isPaused,
    String? playSessionId,
    String? mediaSourceId,
    required String failure,
  }) async {
    final response = await _client
        .post(
          session.source.endpoint.resolve(path),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'X-Emby-Token': session.token,
          },
          body: jsonEncode({
            'ItemId': itemId,
            'PositionTicks': position.inMicroseconds * 10,
            'RunTimeTicks': duration.inMicroseconds * 10,
            'IsPaused': isPaused,
            'PlayMethod': 'DirectPlay',
            'CanSeek': true,
            if (mediaSourceId != null && mediaSourceId.isNotEmpty)
              'MediaSourceId': mediaSourceId,
            if (playSessionId != null && playSessionId.isNotEmpty)
              'PlaySessionId': playSessionId,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_message(response.statusCode, failure));
    }
  }

  Future<void> reportProgress({
    required EmbySession session,
    required String itemId,
    required Duration position,
    required Duration duration,
    required bool isPaused,
    String? playSessionId,
    String? mediaSourceId,
  }) async {
    if (itemId.isEmpty) return;
    final response = await _client
        .post(
          session.source.endpoint.resolve('Sessions/Playing/Progress'),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'X-Emby-Token': session.token,
          },
          body: jsonEncode({
            'ItemId': itemId,
            'PositionTicks': position.inMicroseconds * 10,
            'RunTimeTicks': duration.inMicroseconds * 10,
            'IsPaused': isPaused,
            'PlayMethod': 'DirectPlay',
            if (mediaSourceId != null && mediaSourceId.isNotEmpty)
              'MediaSourceId': mediaSourceId,
            if (playSessionId != null && playSessionId.isNotEmpty)
              'PlaySessionId': playSessionId,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_message(response.statusCode, '播放进度同步失败'));
    }
  }

  MediaItem _item(EmbySession session, Map<String, dynamic> item) {
    final id = '${item['Id'] ?? ''}';
    final image = session.source.endpoint
        .resolve('Items/$id/Images/Primary')
        .replace(queryParameters: {'api_key': session.token});
    final mediaSources = item['MediaSources'] as List<dynamic>? ?? const [];
    final mediaSourceId = mediaSources
        .whereType<Map<String, dynamic>>()
        .map((source) => '${source['Id'] ?? ''}')
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    final mediaSource = mediaSources
        .whereType<Map<String, dynamic>>()
        .firstOrNull;
    final streams = (mediaSource?['MediaStreams'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final video = streams
        .where((stream) => stream['Type'] == 'Video')
        .firstOrNull;
    MediaTrack track(Map<String, dynamic> stream) => MediaTrack(
      index: (stream['Index'] as num?)?.toInt() ?? 0,
      title:
          '${stream['DisplayTitle'] ?? stream['Title'] ?? stream['Language'] ?? stream['Codec'] ?? '未命名'}',
      codec: '${stream['Codec'] ?? '—'}',
      language: stream['Language'] as String?,
      channels: (stream['Channels'] as num?)?.toInt(),
      sampleRate: (stream['SampleRate'] as num?)?.toInt(),
      bitrate: (stream['BitRate'] as num?)?.toInt(),
      isDefault: stream['IsDefault'] == true,
    );
    final playbackQuery = <String, String>{
      'Static': 'true',
      'api_key': session.token,
    };
    if (mediaSourceId.isNotEmpty) {
      playbackQuery['MediaSourceId'] = mediaSourceId;
    }
    final playback = session.source.endpoint
        .resolve('Videos/$id/stream')
        .replace(queryParameters: playbackQuery);
    final providerIds =
        (item['ProviderIds'] as Map<String, dynamic>? ?? const {}).map(
          (key, value) => MapEntry(key, '$value'),
        );
    final ticks = (item['RunTimeTicks'] as num?)?.toInt();
    final userData = (item['UserData'] as Map<String, dynamic>?) ?? const {};
    final playbackTicks =
        (userData['PlaybackPositionTicks'] ?? item['PlaybackPositionTicks'])
            as num?;
    final chapters = (item['Chapters'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((chapter) {
          final startTicks =
              (chapter['StartPositionTicks'] as num?)?.toInt() ?? 0;
          return MediaChapter(
            title: '${chapter['Name'] ?? '章节'}',
            start: Duration(microseconds: startTicks ~/ 10),
          );
        })
        .where((chapter) => chapter.start >= Duration.zero)
        .toList(growable: false);
    final date = '${item['PremiereDate'] ?? ''}';
    return MediaItem(
      id: id,
      title: '${item['Name'] ?? '未命名'}',
      type: '${item['Type'] ?? '视频'}',
      source: session.source,
      overview: item['Overview'] as String?,
      imageUrl: image,
      playbackUrl: playback,
      year:
          (item['ProductionYear'] as num?)?.toInt() ??
          int.tryParse(date.substring(0, date.length.clamp(0, 4))),
      premiereDate: DateTime.tryParse(date),
      runtime: ticks == null ? null : Duration(microseconds: ticks ~/ 10),
      headers: {'X-Emby-Token': session.token},
      providerIds: providerIds,
      parentId: item['ParentId'] as String?,
      seriesId: item['SeriesId'] as String?,
      seriesTitle: item['SeriesName'] as String?,
      seasonNumber: item['Type'] == 'Season'
          ? (item['IndexNumber'] as num?)?.toInt()
          : (item['ParentIndexNumber'] as num?)?.toInt(),
      episodeNumber: (item['IndexNumber'] as num?)?.toInt(),
      isContainer:
          item['IsFolder'] == true ||
          item['Type'] == 'Series' ||
          item['Type'] == 'Season',
      chapters: chapters,
      container: mediaSource?['Container'] as String?,
      size: (mediaSource?['Size'] as num?)?.toInt(),
      bitrate: (mediaSource?['Bitrate'] as num?)?.toInt(),
      width: (video?['Width'] as num?)?.toInt(),
      height: (video?['Height'] as num?)?.toInt(),
      videoCodec: video?['Codec'] as String?,
      videoRange: (video?['VideoRangeType'] ?? video?['VideoRange']) as String?,
      bitDepth: (video?['BitDepth'] as num?)?.toInt(),
      frameRate: (video?['RealFrameRate'] as num?)?.toDouble(),
      audioTracks: streams
          .where((stream) => stream['Type'] == 'Audio')
          .map(track)
          .toList(growable: false),
      subtitleTracks: streams
          .where((stream) => stream['Type'] == 'Subtitle')
          .map(track)
          .toList(growable: false),
      playbackPosition: playbackTicks == null
          ? null
          : Duration(microseconds: playbackTicks.toInt() ~/ 10),
      isPlayed: userData['Played'] == true || item['Played'] == true,
      lastPlayedAt: DateTime.tryParse('${userData['LastPlayedDate'] ?? ''}'),
    );
  }

  Uri _base(Uri endpoint) {
    final value = endpoint.toString().trim();
    final normalized = value.endsWith('/') ? value : '$value/';
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw Exception('媒体服务器地址无效，请填写 http:// 或 https:// 地址');
    }
    return uri;
  }

  String _message(int status, String prefix) => switch (status) {
    401 => '$prefix（账号或密码错误，HTTP 401）',
    404 => '$prefix（接口不存在，HTTP 404）',
    502 => '$prefix（服务器网关错误，HTTP 502）',
    _ => '$prefix（HTTP $status）',
  };

  void dispose() => _client.close();
}
