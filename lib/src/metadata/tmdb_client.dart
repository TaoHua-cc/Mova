import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../network/network_http_client.dart';

Map<String, double> _parseRatingsMap(dynamic value) {
  final map = value as Map<dynamic, dynamic>?;
  if (map == null) return const {};
  final result = <String, double>{};
  for (final entry in map.entries) {
    final raw = entry.value;
    final score = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (score != null && score > 0) result['${entry.key}'] = score;
  }
  return result;
}

class TmdbItem {
  const TmdbItem({
    required this.id,
    required this.title,
    required this.kind,
    this.overview,
    this.posterPath,
    this.backdropPath,
    this.logoPath,
    this.year,
    this.rating = 0,
    this.genres = const [],
    this.ratings = const {},
  });
  final int id;
  final String title;
  final String kind;
  final String? overview;
  final String? posterPath;
  final String? backdropPath;
  final String? logoPath;
  final int? year;
  final double rating;
  final List<String> genres;
  final Map<String, double> ratings;

  Uri? get posterUrl => posterPath == null
      ? null
      : Uri.parse('https://image.tmdb.org/t/p/w500$posterPath');
  Uri? get backdropUrl => backdropPath == null
      ? null
      : Uri.parse('https://image.tmdb.org/t/p/original$backdropPath');
  Uri? get logoUrl => logoPath == null
      ? null
      : Uri.parse('https://image.tmdb.org/t/p/w500$logoPath');

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'kind': kind,
    'overview': overview,
    'posterPath': posterPath,
    'backdropPath': backdropPath,
    'logoPath': logoPath,
    'year': year,
    'rating': rating,
    'genres': genres,
    'ratings': ratings,
  };
  factory TmdbItem.fromJson(Map<String, dynamic> value) => TmdbItem(
    id: (value['id'] as num?)?.toInt() ?? 0,
    title: '${value['title'] ?? '未命名'}',
    kind: '${value['kind'] ?? '电影'}',
    overview: value['overview'] as String?,
    posterPath: value['posterPath'] as String?,
    backdropPath: value['backdropPath'] as String?,
    logoPath: value['logoPath'] as String?,
    year: (value['year'] as num?)?.toInt(),
    rating: (value['rating'] as num?)?.toDouble() ?? 0,
    genres: (value['genres'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toList(growable: false),
    ratings: _parseRatingsMap(value['ratings']),
  );
}

class TmdbPerson {
  const TmdbPerson({
    required this.id,
    required this.name,
    required this.role,
    this.profilePath,
  });
  final int id;
  final String name;
  final String role;
  final String? profilePath;
  Uri? get profileUrl => profilePath == null
      ? null
      : Uri.parse('https://image.tmdb.org/t/p/w300$profilePath');
}

class TmdbPersonDetails {
  const TmdbPersonDetails({
    required this.person,
    this.biography,
    this.birthday,
    this.placeOfBirth,
    this.credits = const [],
  });
  final TmdbPerson person;
  final String? biography;
  final String? birthday;
  final String? placeOfBirth;
  final List<TmdbItem> credits;
}

class TmdbArtwork {
  const TmdbArtwork(this.filePath);
  final String filePath;
  Uri get url => Uri.parse('https://image.tmdb.org/t/p/original$filePath');
}

class TmdbSeason {
  const TmdbSeason({required this.number, required this.name, this.posterPath});
  final int number;
  final String name;
  final String? posterPath;
  Uri? get posterUrl => posterPath == null
      ? null
      : Uri.parse('https://image.tmdb.org/t/p/w500$posterPath');
}

/// Episode metadata is used only to complete missing server presentation data:
/// a server remains the source of playable URLs and watched state.
class TmdbEpisode {
  const TmdbEpisode({
    required this.seasonNumber,
    required this.episodeNumber,
    required this.name,
    this.overview,
    this.airDate,
    this.stillPath,
    this.runtime,
  });
  final int seasonNumber;
  final int episodeNumber;
  final String name;
  final String? overview;
  final DateTime? airDate;
  final String? stillPath;
  final int? runtime;

  Uri? get stillUrl => stillPath == null
      ? null
      : Uri.parse('https://image.tmdb.org/t/p/w780$stillPath');
}

/// The next known television airing for a locally tracked show. TMDB only
/// publishes a calendar day for many providers, therefore [airTimeKnown] is
/// deliberately false unless the source supplies an actual time.
class TmdbUpcomingEpisode {
  const TmdbUpcomingEpisode({
    required this.seasonNumber,
    required this.episodeNumber,
    required this.title,
    required this.airDate,
    this.network,
    this.stillPath,
    this.timeKnown = false,
    this.source = 'TMDB',
  });
  final int seasonNumber;
  final int episodeNumber;
  final String title;
  final DateTime airDate;
  final bool timeKnown;
  final String source;
  final String? network;
  final String? stillPath;
  Uri? get stillUrl => stillPath == null
      ? null
      : Uri.parse('https://image.tmdb.org/t/p/w780$stillPath');
}

List<TmdbUpcomingEpisode> upcomingListFromTvmaze(
  dynamic episodes,
  Map show,
  DateTime now, {
  DateTime? until,
}) {
  if (episodes is! List) return const [];
  final candidates = <TmdbUpcomingEpisode>[];
  for (final row in episodes.whereType<Map>()) {
    final stamp = '${row['airstamp'] ?? ''}';
    final known =
        '${row['airtime'] ?? ''}'.isNotEmpty &&
        RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(stamp);
    final date = DateTime.tryParse(known ? stamp : '${row['airdate'] ?? ''}');
    final season = row['season'];
    final number = row['number'];
    if (date == null || season is! num || number is! num || number <= 0) {
      continue;
    }
    final cutoff = known ? now : DateTime(now.year, now.month, now.day);
    if (date.isBefore(cutoff)) continue;
    if (until != null && date.isAfter(until)) continue;
    final channel = show['webChannel'] ?? show['network'];
    candidates.add(
      TmdbUpcomingEpisode(
        seasonNumber: season.toInt(),
        episodeNumber: number.toInt(),
        title: '${row['name'] ?? ''}',
        airDate: date,
        timeKnown: known,
        network: channel is Map ? channel['name'] as String? : null,
        source: 'TVmaze',
      ),
    );
  }
  candidates.sort((a, b) => a.airDate.compareTo(b.airDate));
  return candidates;
}

TmdbUpcomingEpisode? upcomingFromTvmaze(
  dynamic episodes,
  Map show,
  DateTime now,
) {
  return upcomingListFromTvmaze(episodes, show, now).firstOrNull;
}

class TmdbExtras {
  const TmdbExtras({
    this.cast = const [],
    this.artwork = const [],
    this.recommendations = const [],
    this.seasons = const [],
  });
  final List<TmdbPerson> cast;
  final List<TmdbArtwork> artwork;
  final List<TmdbItem> recommendations;
  final List<TmdbSeason> seasons;
}

class TmdbClient {
  TmdbClient({http.Client? client})
    : _client = client ?? createNetworkHttpClient();
  final http.Client _client;
  static const managedEndpoint = 'https://yingji-metadata.gctykxy.workers.dev';

  Future<List<TmdbItem>> trending({String apiKey = ''}) async {
    final data = await _get('/trending/all/week', apiKey, {
      'language': 'zh-CN',
    });
    return _items(data);
  }

  Future<List<TmdbItem>> search(String query, {String apiKey = ''}) async {
    final data = await _get('/search/multi', apiKey, {
      'query': query,
      'language': 'zh-CN',
      'include_adult': 'false',
      'page': '1',
    });
    return _items(data);
  }

  Future<TmdbItem?> searchFirst(
    String query, {
    required String type,
    String apiKey = '',
  }) async {
    final data = await _get('/search/$type', apiKey, {
      'query': query,
      'language': 'zh-CN',
      'include_adult': 'false',
      'page': '1',
    });
    final rows = _items(data, typeHint: type);
    return rows.firstOrNull;
  }

  Future<List<TmdbItem>> doubanPublicList(String list, {int page = 1}) async {
    final uri = Uri.parse('$managedEndpoint/discover/douban/movie/$list')
        .replace(queryParameters: {'page': '$page'});
    final response = await _client
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('豆瓣公开榜单读取失败（HTTP ${response.statusCode}）');
    }
    final data = jsonDecode(response.body);
    final rows = data is Map ? data['results'] : null;
    if (rows is! List) return const [];
    final titles = rows
        .whereType<Map>()
        .map((row) => '${row['title'] ?? ''}'.trim())
        .where((title) => title.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final items = <TmdbItem>[];
    for (var offset = 0; offset < titles.length; offset += 5) {
      final resolved = await Future.wait(
        titles.skip(offset).take(5).map((title) async {
          try {
            return await searchFirst(title, type: 'movie');
          } catch (_) {
            return null;
          }
        }),
      );
      items.addAll(resolved.whereType<TmdbItem>());
    }
    return items;
  }

  Future<TmdbItem?> findByImdbId(String imdbId, {String apiKey = ''}) async {
    final data = await _get('/find/$imdbId', apiKey, {
      'external_source': 'imdb_id',
      'language': 'zh-CN',
    });
    final rows = data['tv_results'];
    if (rows is! List || rows.isEmpty || rows.first is! Map) return null;
    final id = ((rows.first as Map)['id'] as num?)?.toInt();
    if (id == null) return null;
    return details(id, kind: '剧集', apiKey: apiKey);
  }

  Future<List<TmdbItem>> popularMovies({String apiKey = ''}) => _list(
    '/movie/popular',
    apiKey,
    {'language': 'zh-CN', 'region': 'CN'},
    typeHint: 'movie',
  );

  Future<List<TmdbItem>> popularShows({String apiKey = ''}) =>
      _list('/tv/popular', apiKey, {'language': 'zh-CN'}, typeHint: 'tv');

  Future<List<TmdbItem>> topRatedMovies({String apiKey = ''}) => _list(
    '/movie/top_rated',
    apiKey,
    {'language': 'zh-CN', 'region': 'CN'},
    typeHint: 'movie',
  );

  Future<List<TmdbItem>> nowPlaying({String apiKey = ''}) => _list(
    '/movie/now_playing',
    apiKey,
    {'language': 'zh-CN', 'region': 'CN'},
    typeHint: 'movie',
  );

  Future<List<TmdbItem>> trendingToday(
    String type, {
    int page = 1,
    String apiKey = '',
  }) => _list('/trending/$type/day', apiKey, {
    'language': 'zh-CN',
    'page': '$page',
  }, typeHint: type);

  Future<List<TmdbItem>> trendingThisWeek(
    String type, {
    int page = 1,
    String apiKey = '',
  }) => _list('/trending/$type/week', apiKey, {
    'language': 'zh-CN',
    'page': '$page',
  }, typeHint: type);

  Future<List<TmdbItem>> mdblistOfficial(
    String type,
    String list, {
    int page = 1,
    String country = 'all',
  }) async {
    final uri = Uri.parse('$managedEndpoint/discover/mdblist/$type/$list')
        .replace(queryParameters: {'page': '$page', 'country': country});
    final response = await _client
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('MDBList 榜单读取失败（HTTP ${response.statusCode}）');
    }
    final data = jsonDecode(response.body);
    final rows = data is Map ? data['results'] : null;
    if (rows is! List) return const [];
    final ids = rows
        .whereType<Map>()
        .map((row) => (row['tmdbId'] as num?)?.toInt())
        .whereType<int>()
        .toSet()
        .toList(growable: false);
    final items = <TmdbItem>[];
    for (var offset = 0; offset < ids.length; offset += 5) {
      final batch = ids.skip(offset).take(5);
      final resolved = await Future.wait(
        batch.map((id) async {
          try {
            return await details(id, kind: type == 'tv' ? '剧集' : '电影');
          } catch (_) {
            return null;
          }
        }),
      );
      items.addAll(resolved.whereType<TmdbItem>());
    }
    return items;
  }

  Future<List<TmdbItem>> discover(
    String type, {
    int page = 1,
    String? originCountry,
    int? genre,
    String? genres,
    String? provider,
    String? company,
    String? originalLanguage,
    String? region,
    int? year,
    double? minimumRating,
    int? minimumVoteCount,
    int? minimumRuntime,
    int? maximumRuntime,
    String? watchRegion,
    String sortBy = 'popularity.desc',
    DateTime? dateFrom,
    DateTime? dateTo,
    String apiKey = '',
  }) => _list('/discover/$type', apiKey, {
    'language': 'zh-CN',
    'page': '$page',
    'sort_by': sortBy,
    'include_adult': 'false',
    'with_origin_country': ?originCountry,
    'with_original_language': ?originalLanguage,
    'with_genres': ?(genres ?? (genre == null ? null : '$genre')),
    'region': ?region,
    if (year != null)
      type == 'tv' ? 'first_air_date_year' : 'primary_release_year': '$year',
    if (dateFrom != null)
      type == 'tv' ? 'first_air_date.gte' : 'primary_release_date.gte':
          _dateQuery(dateFrom),
    if (dateTo != null)
      type == 'tv' ? 'first_air_date.lte' : 'primary_release_date.lte':
          _dateQuery(dateTo),
    'vote_average.gte': ?(minimumRating == null ? null : '$minimumRating'),
    'vote_count.gte': ?(minimumVoteCount == null ? null : '$minimumVoteCount'),
    'with_runtime.gte': ?(minimumRuntime == null ? null : '$minimumRuntime'),
    'with_runtime.lte': ?(maximumRuntime == null ? null : '$maximumRuntime'),
    if (provider != null) ...{
      'with_watch_providers': provider,
      'watch_region': ?watchRegion,
    },
    'with_companies': ?company,
  }, typeHint: type);

  static String _dateQuery(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  Future<List<TmdbItem>> _list(
    String path,
    String apiKey,
    Map<String, String> query, {
    required String typeHint,
  }) async => _items(await _get(path, apiKey, query), typeHint: typeHint);

  Future<TmdbItem> details(
    int id, {
    required String kind,
    String apiKey = '',
  }) async {
    final data = await _get('/${kind == '剧集' ? 'tv' : 'movie'}/$id', apiKey, {
      'language': 'zh-CN',
      'append_to_response': 'credits,videos,images,recommendations,similar',
      'include_image_language': 'zh,en,null',
    });
    final tv = kind == '剧集';
    final date =
        '${tv ? data['first_air_date'] ?? '' : data['release_date'] ?? ''}';
    return TmdbItem(
      id: id,
      title:
          '${tv ? (data['name'] ?? data['original_name']) : (data['title'] ?? data['original_title']) ?? '未命名'}',
      kind: kind,
      overview: data['overview'] as String?,
      posterPath: data['poster_path'] as String?,
      backdropPath: data['backdrop_path'] as String?,
      logoPath: _preferredLogoPath(data['images']),
      year: int.tryParse(date.split('-').first),
      rating: (data['vote_average'] as num?)?.toDouble() ?? 0,
      genres: _genreNames(data['genres']),
      ratings: _parseRatingsMap(data['ratings']),
    );
  }

  Future<List<TmdbItem>> officialList(
    String path,
    String type, {
    int page = 1,
    String apiKey = '',
  }) => _list('/$type/$path', apiKey, {
    'language': 'zh-CN',
    'page': '$page',
    'region': 'CN',
  }, typeHint: type);

  Future<TmdbExtras> extras(
    int id, {
    required String kind,
    String apiKey = '',
  }) async {
    final data = await _get('/${kind == '剧集' ? 'tv' : 'movie'}/$id', apiKey, {
      'language': 'zh-CN',
      'append_to_response': 'credits,videos,images,recommendations,similar',
      'include_image_language': 'zh,en,null',
    });
    final cast =
        (((data['credits'] as Map<String, dynamic>?)?['cast']
                    as List<dynamic>?) ??
                const [])
            .whereType<Map<String, dynamic>>()
            .map(
              (person) => TmdbPerson(
                id: (person['id'] as num?)?.toInt() ?? 0,
                name: '${person['name'] ?? '未知演员'}',
                role: '${person['character'] ?? ''}',
                profilePath: person['profile_path'] as String?,
              ),
            )
            .toList(growable: false);
    final artworkRows = <dynamic>[
      ...(((data['images'] as Map<String, dynamic>?)?['backdrops']
              as List<dynamic>?) ??
          const []),
      ...(((data['images'] as Map<String, dynamic>?)?['posters']
              as List<dynamic>?) ??
          const []),
    ];
    final artwork = artworkRows
        .whereType<Map<String, dynamic>>()
        .map((row) => row['file_path'] as String?)
        .whereType<String>()
        .map(TmdbArtwork.new)
        .toList(growable: false);
    final recommendationData =
        (data['recommendations'] as Map<String, dynamic>?) ??
        (data['similar'] as Map<String, dynamic>?) ??
        const <String, dynamic>{};
    final recommendations = _items(
      recommendationData,
      typeHint: kind == '剧集' ? 'tv' : 'movie',
    ).toList(growable: false);
    final seasons = (data['seasons'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((row) => (row['season_number'] as num?)?.toInt() != 0)
        .map(
          (row) => TmdbSeason(
            number: (row['season_number'] as num?)?.toInt() ?? 1,
            name:
                '${row['name'] ?? '第 ${(row['season_number'] as num?)?.toInt() ?? 1} 季'}',
            posterPath: row['poster_path'] as String?,
          ),
        )
        .toList(growable: false);
    return TmdbExtras(
      cast: cast,
      artwork: artwork,
      recommendations: recommendations,
      seasons: seasons,
    );
  }

  Future<TmdbPersonDetails> personDetails(int id, {String apiKey = ''}) async {
    final data = await _get('/person/$id', apiKey, {
      'language': 'zh-CN',
      'append_to_response': 'combined_credits',
    });
    final combined = data['combined_credits'] as Map<String, dynamic>?;
    final rows = (combined?['cast'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final known = <String>{};
    final credits = _items({'results': rows})
        .where((item) => known.add('${item.kind}:${item.id}'))
        .toList(growable: false);
    return TmdbPersonDetails(
      person: TmdbPerson(
        id: id,
        name: '${data['name'] ?? '未知演员'}',
        role: '',
        profilePath: data['profile_path'] as String?,
      ),
      biography: data['biography'] as String?,
      birthday: data['birthday'] as String?,
      placeOfBirth: data['place_of_birth'] as String?,
      credits: credits,
    );
  }

  Future<List<TmdbEpisode>> seasonEpisodes(
    int seriesId,
    int seasonNumber, {
    String apiKey = '',
  }) async {
    final data = await _get('/tv/$seriesId/season/$seasonNumber', apiKey, {
      'language': 'zh-CN',
      'append_to_response': 'images',
      'include_image_language': 'zh,en,null',
    });
    return (data['episodes'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(
          (row) => TmdbEpisode(
            seasonNumber: seasonNumber,
            episodeNumber: (row['episode_number'] as num?)?.toInt() ?? 0,
            name: '${row['name'] ?? ''}',
            overview: row['overview'] as String?,
            airDate: DateTime.tryParse('${row['air_date'] ?? ''}'),
            stillPath: row['still_path'] as String?,
            runtime: (row['runtime'] as num?)?.toInt(),
          ),
        )
        .where((episode) => episode.episodeNumber > 0)
        .toList(growable: false);
  }

  /// Returns every published future episode inside [horizon]. Exact instants
  /// supplied by TVmaze win; TMDB season data fills gaps without inventing a
  /// broadcast hour when only a calendar date has been announced.
  Future<List<TmdbUpcomingEpisode>> upcomingEpisodes(
    TmdbItem item, {
    String apiKey = '',
    Duration horizon = const Duration(days: 90),
  }) async {
    if (item.kind != '剧集' || item.id <= 0) return const [];
    final now = DateTime.now();
    final until = now.add(horizon);
    final data = await _get('/tv/${item.id}', apiKey, {
      'language': 'zh-CN',
      'append_to_response': 'external_ids',
    }, preferFresh: true);
    final exact = <TmdbUpcomingEpisode>[];
    try {
      final ids = data['external_ids'] as Map<String, dynamic>? ?? const {};
      final imdb = '${ids['imdb_id'] ?? ''}';
      final tvdb = ids['tvdb_id'];
      if (RegExp(r'^tt\d+$').hasMatch(imdb) || tvdb is num) {
        final show = await _scheduleJson(
          Uri.https('api.tvmaze.com', '/lookup/shows', {
            if (RegExp(r'^tt\d+$').hasMatch(imdb))
              'imdb': imdb
            else
              'thetvdb': '$tvdb',
          }),
        );
        if (show is Map && show['id'] is num) {
          final episodes = await _scheduleJson(
            Uri.https('api.tvmaze.com', '/shows/${show['id']}/episodes'),
          );
          exact.addAll(
            upcomingListFromTvmaze(episodes, show, now, until: until),
          );
        }
      }
    } catch (_) {
      /* Retain TMDB's date if the time source is unavailable. */
    }
    final networks = data['networks'] as List<dynamic>? ?? const [];
    final network = networks
        .whereType<Map<String, dynamic>>()
        .map((entry) => '${entry['name'] ?? ''}')
        .firstWhere((name) => name.isNotEmpty, orElse: () => '');
    final nextRow = data['next_episode_to_air'] as Map<String, dynamic>?;
    final firstSeason = (nextRow?['season_number'] as num?)?.toInt();
    final seasonRows = (data['seasons'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((row) {
          final number = (row['season_number'] as num?)?.toInt() ?? 0;
          if (number <= 0 || (firstSeason != null && number < firstSeason)) {
            return false;
          }
          final date = DateTime.tryParse('${row['air_date'] ?? ''}');
          return date == null || !date.isAfter(until);
        })
        .take(3)
        .toList(growable: false);
    final dated = <TmdbUpcomingEpisode>[];
    for (final season in seasonRows) {
      final number = (season['season_number'] as num?)?.toInt() ?? 0;
      try {
        final episodes = await seasonEpisodes(item.id, number, apiKey: apiKey);
        for (final episode in episodes) {
          final date = episode.airDate;
          if (date == null) continue;
          final today = DateTime(now.year, now.month, now.day);
          if (date.isBefore(today) || date.isAfter(until)) continue;
          dated.add(
            TmdbUpcomingEpisode(
              seasonNumber: episode.seasonNumber,
              episodeNumber: episode.episodeNumber,
              title: episode.name,
              airDate: date,
              network: network.isEmpty ? null : network,
              stillPath: episode.stillPath,
            ),
          );
        }
      } catch (_) {
        // Keep other seasons and the independently fetched exact schedule.
      }
    }
    if (dated.isEmpty && nextRow != null) {
      final date = DateTime.tryParse('${nextRow['air_date'] ?? ''}');
      final today = DateTime(now.year, now.month, now.day);
      if (date != null && !date.isBefore(today) && !date.isAfter(until)) {
        dated.add(
          TmdbUpcomingEpisode(
            seasonNumber: (nextRow['season_number'] as num?)?.toInt() ?? 0,
            episodeNumber: (nextRow['episode_number'] as num?)?.toInt() ?? 0,
            title: '${nextRow['name'] ?? ''}',
            airDate: date,
            network: network.isEmpty ? null : network,
            stillPath: nextRow['still_path'] as String?,
          ),
        );
      }
    }
    final merged = <String, TmdbUpcomingEpisode>{};
    for (final episode in [...dated, ...exact]) {
      final key = '${episode.seasonNumber}:${episode.episodeNumber}';
      final previous = merged[key];
      if (previous == null || episode.timeKnown) {
        merged[key] = TmdbUpcomingEpisode(
          seasonNumber: episode.seasonNumber,
          episodeNumber: episode.episodeNumber,
          title: episode.title.isEmpty ? previous?.title ?? '' : episode.title,
          airDate: episode.airDate,
          timeKnown: episode.timeKnown,
          source: episode.source,
          network: episode.network ?? previous?.network,
          stillPath: episode.stillPath ?? previous?.stillPath,
        );
      }
    }
    final result = merged.values.toList()
      ..sort((a, b) => a.airDate.compareTo(b.airDate));
    return result;
  }

  /// Compatibility helper for detail surfaces that only need the next item.
  Future<TmdbUpcomingEpisode?> upcomingEpisode(
    TmdbItem item, {
    String apiKey = '',
  }) async {
    return (await upcomingEpisodes(item, apiKey: apiKey)).firstOrNull;
  }

  Future<dynamic> _scheduleJson(Uri uri) async {
    final prefs = await SharedPreferences.getInstance();
    final key =
        'yingji.schedule.${base64UrlEncode(utf8.encode(uri.toString()))}';
    final raw = prefs.getString(key);
    Map<String, dynamic>? cached;
    try {
      if (raw != null) cached = jsonDecode(raw) as Map<String, dynamic>;
      final saved = DateTime.tryParse('${cached?['savedAt']}');
      if (saved != null &&
          DateTime.now().difference(saved) < const Duration(hours: 1)) {
        return cached!['data'];
      }
    } catch (_) {
      cached = null;
    }
    try {
      final response = await _client
          .get(uri, headers: const {'User-Agent': 'Mova/3 schedule-client'})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) throw Exception('Schedule unavailable');
      final data = jsonDecode(response.body);
      await prefs.setString(
        key,
        jsonEncode({'savedAt': DateTime.now().toIso8601String(), 'data': data}),
      );
      return data;
    } catch (_) {
      if (cached != null) return cached['data'];
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _get(
    String path,
    String apiKey,
    Map<String, String> query, {
    bool preferFresh = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final effectiveApiKey = apiKey.trim().isNotEmpty
        ? apiKey.trim()
        : (prefs.getString('yingji.tmdb.api-key') ?? '').trim();
    final normalized = path.startsWith('/') ? path : '/$path';
    final managedUri = Uri.parse('$managedEndpoint/tmdb$normalized')
        .replace(queryParameters: {...query, 'client': 'yingji-flutter'});
    // The managed service is the default path. A previously saved personal
    // key must never silently force a potentially blocked direct connection.
    // Try the personal endpoint only as a fallback when it is explicitly set.
    final uris = <Uri>[
      managedUri,
      if (effectiveApiKey.isNotEmpty)
        Uri.https('api.themoviedb.org', '/3$normalized', {
          ...query,
          'api_key': effectiveApiKey,
        }),
    ];
    for (final uri in preferFresh ? <Uri>[] : uris) {
      final cached = prefs.getString(_cacheKey(uri));
      if (cached == null || cached.isEmpty) continue;
      try {
        final data = jsonDecode(cached) as Map<String, dynamic>;
        unawaited(_refresh(uri, prefs));
        return data;
      } catch (_) {
        // Corrupt entries are replaced by the normal network path below.
      }
    }
    Object? lastError;
    for (var uriIndex = 0; uriIndex < uris.length; uriIndex++) {
      final uri = uris[uriIndex];
      final cacheKey = _cacheKey(uri);
      // A saved personal key is optional. Do not spend a second retry on a
      // blocked/expired direct endpoint before trying the managed service.
      final attempts = uriIndex > 0 ? 1 : 2;
      for (var attempt = 0; attempt < attempts; attempt++) {
        try {
          final response = await _client
              .get(
                uri,
                headers: const {
                  'Accept': 'application/json',
                  'User-Agent': 'Mova/3.1.65 (Windows; Flutter)',
                },
              )
              .timeout(const Duration(seconds: 12));
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw Exception('TMDB 请求失败（HTTP ${response.statusCode}）');
          }
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          await prefs.setString(cacheKey, response.body);
          return data;
        } catch (error) {
          lastError = error;
          if (attempt + 1 < attempts) {
            await Future<void>.delayed(const Duration(milliseconds: 350));
          }
        }
      }
      final cached = prefs.getString(cacheKey);
      if (cached != null && cached.isNotEmpty) {
        try {
          return jsonDecode(cached) as Map<String, dynamic>;
        } catch (_) {
          // Ignore a corrupt cache and try the next endpoint.
        }
      }
    }
    if (lastError is Exception) throw lastError;
    throw Exception('TMDB 网络请求失败：$lastError');
  }

  String _cacheKey(Uri uri) {
    final stableKey = base64UrlEncode(utf8.encode(uri.toString()))
        .replaceAll('=', '');
    return 'yingji.tmdb.cache.$stableKey';
  }

  Future<void> _refresh(Uri uri, SharedPreferences prefs) async {
    try {
      final response = await _client
          .get(
            uri,
            headers: const {
              'Accept': 'application/json',
              'User-Agent': 'Mova/3.1.65 (Windows; Flutter)',
            },
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        jsonDecode(response.body) as Map<String, dynamic>;
        await prefs.setString(_cacheKey(uri), response.body);
      }
    } catch (_) {
      // Cached content remains usable when a background refresh fails.
    }
  }

  List<TmdbItem> _items(
    Map<String, dynamic> data, {
    String? typeHint,
  }) => (data['results'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .where((item) {
        final type = item['media_type'];
        return type == 'movie' ||
            type == 'tv' ||
            item['title'] != null ||
            item['name'] != null;
      })
      .map((item) {
        final tv =
            item['media_type'] == 'tv' ||
            (item['media_type'] == null &&
                (item['name'] != null || item['first_air_date'] != null)) ||
            (item['media_type'] == null && typeHint == 'tv');
        final title =
            '${tv ? (item['name'] ?? item['original_name']) : (item['title'] ?? item['original_title']) ?? '未命名'}';
        final date =
            '${tv ? item['first_air_date'] ?? '' : item['release_date'] ?? ''}';
        return TmdbItem(
          id: (item['id'] as num?)?.toInt() ?? 0,
          title: title,
          kind: tv ? '剧集' : '电影',
          overview: item['overview'] as String?,
          posterPath: item['poster_path'] as String?,
          backdropPath: item['backdrop_path'] as String?,
          year: int.tryParse(date.split('-').first),
          rating: (item['vote_average'] as num?)?.toDouble() ?? 0,
          genres: _genreNamesFromIds(item['genre_ids']),
          ratings: _parseRatingsMap(item['ratings']),
        );
      })
      .toList(growable: false);

  void dispose() => _client.close();

  static List<String> _genreNames(dynamic value) =>
      (value as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((entry) => '${entry['name'] ?? ''}')
          .where((name) => name.isNotEmpty)
          .take(4)
          .toList(growable: false);

  static String? _preferredLogoPath(dynamic value) {
    final logos =
        ((value as Map<dynamic, dynamic>?)?['logos'] as List<dynamic>? ??
                const [])
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);
    if (logos.isEmpty) return null;
    for (final language in const ['zh', 'en']) {
      for (final logo in logos) {
        if (logo['iso_639_1'] == language && logo['file_path'] is String) {
          return logo['file_path'] as String;
        }
      }
    }
    return logos.first['file_path'] as String?;
  }

  static List<String> _genreNamesFromIds(dynamic value) {
    const names = <int, String>{
      28: '动作',
      12: '冒险',
      16: '动画',
      35: '喜剧',
      80: '犯罪',
      99: '纪录',
      18: '剧情',
      10751: '家庭',
      14: '奇幻',
      36: '历史',
      27: '恐怖',
      10402: '音乐',
      9648: '悬疑',
      10749: '爱情',
      878: '科幻',
      10770: '电视电影',
      53: '惊悚',
      10752: '战争',
      37: '西部',
    };
    return (value as List<dynamic>? ?? const [])
        .map((id) => names[(id as num?)?.toInt()])
        .whereType<String>()
        .take(4)
        .toList(growable: false);
  }

  Future<int> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where(
      (key) => key.startsWith('yingji.tmdb.cache.'),
    );
    var count = 0;
    for (final key in keys.toList(growable: false)) {
      if (await prefs.remove(key)) count++;
    }
    return count;
  }
}
