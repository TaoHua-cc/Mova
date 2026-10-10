import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../cache/windows_metadata_cache.dart';
import '../tracking/calendar_events.dart';
import '../tracking/trakt_auth.dart';
import '../tracking/trakt_client.dart';
import '../tracking/broadcast_platforms.dart';
import 'tmdb_client.dart';

class SeriesAiringSnapshot {
  const SeriesAiringSnapshot({
    required this.events,
    required this.savedAt,
    this.completed = false,
    this.traktResolved = false,
    this.completedSeason,
    this.latestSeason = 0,
  });
  final List<TraktEvent> events;
  final DateTime savedAt;
  final bool completed;
  final bool traktResolved;
  final int? completedSeason;
  final int latestSeason;

  bool completedAt(DateTime now) =>
      (completed ||
          completedSeason != null ||
          calendarGroupCompleted(events, now: now)) &&
      !events.any((event) => event.airDate.isAfter(now));

  TraktEvent? nextAt(DateTime now) {
    final candidates = events
        .where(
          (event) => !event.airDate.isBefore(
            event.timeKnown ? now : DateTime(now.year, now.month, now.day),
          ),
        )
        .toList();
    return candidates
            .where((event) => event.source == 'Trakt' && event.timeKnown)
            .firstOrNull ??
        candidates.firstOrNull;
  }

  bool freshAt(DateTime now) {
    if (now.difference(savedAt) >= const Duration(hours: 6)) return false;
    if (now.day != savedAt.day &&
        events.any(
          (event) =>
              !event.timeKnown &&
              event.airDate.year == savedAt.year &&
              event.airDate.month == savedAt.month &&
              event.airDate.day == savedAt.day,
        )) {
      return false;
    }
    // Once an exact upcoming instant passes, don't keep showing yesterday's next.
    return !events.any(
      (event) =>
          event.timeKnown &&
          event.airDate.isAfter(savedAt) &&
          !event.airDate.isAfter(now),
    );
  }

  Map<String, dynamic> toJson() => {
    'savedAt': savedAt.toIso8601String(),
    'completed': completed,
    'traktResolved': traktResolved,
    'completedSeason': completedSeason,
    'latestSeason': latestSeason,
    'events': events.map((event) => event.toJson()).toList(),
  };
  factory SeriesAiringSnapshot.fromJson(Map data) => SeriesAiringSnapshot(
    savedAt: DateTime.parse('${data['savedAt']}'),
    completed: data['completed'] == true,
    traktResolved: data['traktResolved'] == true,
    completedSeason: (data['completedSeason'] as num?)?.toInt(),
    latestSeason: (data['latestSeason'] as num?)?.toInt() ?? 0,
    events: (data['events'] as List)
        .whereType<Map>()
        .map((event) => TraktEvent.fromJson(Map<String, dynamic>.from(event)))
        .toList(),
  );
}

/// Shared persisted schedule for detail and calendar, separate from image cache.
class SeriesAiringStore {
  SeriesAiringStore({TmdbClient? tmdb, TraktClient? trakt})
    : _tmdb = tmdb ?? _sharedTmdb,
      _trakt = trakt ?? _sharedTrakt;
  // App-lifetime clients keep HTTP pools and background metadata refresh alive.
  static final _sharedTmdb = TmdbClient();
  static final _sharedTrakt = TraktClient();
  final TmdbClient _tmdb;
  final TraktClient _trakt;
  static final _pending = <String, Future<SeriesAiringSnapshot>>{};

  Future<SeriesAiringSnapshot> load(
    TmdbItem item, {
    TraktCredentials? credentials,
    DateTime? now,
  }) async {
    final session = credentials ?? await TraktCredentials.read();
    final key = 'yingji.schedule.series.v1.${item.id}.${session.isConnected}';
    final existing = _pending[key];
    if (existing != null) return existing;
    final work = _load(item, session, key, now ?? DateTime.now());
    _pending[key] = work;
    try {
      return await work;
    } finally {
      if (identical(_pending[key], work)) _pending.remove(key);
    }
  }

  Future<SeriesAiringSnapshot> _load(
    TmdbItem item,
    TraktCredentials session,
    String key,
    DateTime now,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final completionKey = 'yingji.schedule.completed-season.v1.${item.id}';
    var completedSeason = prefs.getInt(completionKey);
    final latestKey = 'yingji.schedule.latest-season.v1.${item.id}';
    final knownSeason = prefs.getInt(latestKey) ?? 0;
    final stored = await WindowsMetadataCache.read(
      WindowsMetadataCache.schedule,
      key,
    );
    SeriesAiringSnapshot? cached;
    try {
      final raw = stored?.value ?? prefs.getString(key);
      if (raw != null) {
        cached = SeriesAiringSnapshot.fromJson(jsonDecode(raw) as Map);
      }
    } catch (_) {
      /* Corrupt data is replaced without touching other metadata. */
    }
    if (cached != null && knownSeason > cached.latestSeason) cached = null;
    completedSeason ??= cached?.completedSeason;
    if (completedSeason == null && cached?.completedAt(now) == true) {
      for (final event in cached!.events) {
        if ((event.seasonNumber ?? 0) > (completedSeason ?? 0)) {
          completedSeason = event.seasonNumber;
        }
      }
      if (completedSeason != null) {
        await prefs.setInt(completionKey, completedSeason);
      }
    }
    SeriesAiringSnapshot preserveCompletion(SeriesAiringSnapshot value) =>
        SeriesAiringSnapshot(
          events: value.events,
          savedAt: value.savedAt,
          completed: value.completed,
          traktResolved: value.traktResolved,
          completedSeason: completedSeason,
          latestSeason: knownSeason,
        );
    if (cached?.freshAt(now) == true) return preserveCompletion(cached!);
    final traktFuture = () async {
      if (!session.isConnected) return null;
      try {
        final refreshed = await session.refreshIfNeeded();
        return await _trakt.showAiring(
          tmdbId: item.id,
          clientId: refreshed.clientId,
          accessToken: refreshed.accessToken,
        );
      } catch (_) {
        return null;
      }
    }();
    final events = <TraktEvent>[];
    Map<String, dynamic>? metadata;
    var localSucceeded = false;
    var newestSeason = knownSeason;
    try {
      metadata = await _tmdb.seriesAiringMetadata(item);
      final upcoming = await _tmdb.upcomingEpisodes(item);
      localSucceeded = true;
      final ended = metadata['status'] == 'Ended';
      final seasons =
          (metadata['seasons'] as List? ?? const [])
              .whereType<Map>()
              .where((season) => (season['season_number'] as num? ?? 0) > 0)
              .toList()
            ..sort(
              (a, b) => (a['season_number'] as num).compareTo(
                b['season_number'] as num,
              ),
            );
      final lastSeason = seasons.lastOrNull;
      final finalSeason = (lastSeason?['season_number'] as num?)?.toInt();
      final finalNumber = (lastSeason?['episode_count'] as num?)?.toInt();
      if ((finalSeason ?? 0) > newestSeason) newestSeason = finalSeason!;
      for (final next in upcoming) {
        events.add(
          TraktEvent(
            tmdbId: item.id,
            title: next.showTitle ?? item.title,
            episode:
                '第 ${next.seasonNumber} 季 · 第 ${next.episodeNumber} 集 · ${next.title}',
            seasonNumber: next.seasonNumber,
            episodeNumber: next.episodeNumber,
            airDate: next.airDate,
            timeKnown: next.timeKnown,
            source: next.source,
            posterUrl: item.posterUrl ?? next.showPosterUrl ?? next.stillUrl,
            backdropUrl: item.backdropUrl,
            platform: next.network,
            platformLogoUrl: next.networkLogoUrl,
            platforms: next.platforms,
            totalEpisodes: next.totalEpisodes,
            seriesFinale:
                ended &&
                next.seasonNumber == finalSeason &&
                next.episodeNumber == finalNumber,
          ),
        );
      }
      final last = metadata['last_episode_to_air'];
      final date = last is Map
          ? DateTime.tryParse('${last['air_date']}')
          : null;
      if (last is Map &&
          date != null &&
          last['season_number'] == finalSeason &&
          last['episode_number'] == finalNumber) {
        if (!date.isAfter(now) &&
            (finalNumber ?? 0) > 0 &&
            !upcoming.any(
              (episode) =>
                  episode.seasonNumber == finalSeason &&
                  episode.airDate.isAfter(now),
            )) {
          completedSeason = finalSeason;
        }
        events.add(
          TraktEvent(
            tmdbId: item.id,
            title: item.title,
            episode:
                '第 $finalSeason 季 · 第 $finalNumber 集 · ${last['name'] ?? ''}',
            seasonNumber: finalSeason,
            episodeNumber: finalNumber,
            airDate: date,
            timeKnown: false,
            source: 'TMDB',
            seriesFinale: ended,
            posterUrl: item.posterUrl,
            backdropUrl: item.backdropUrl,
          ),
        );
      }
    } catch (_) {
      /* Trakt can still supply a usable schedule. */
    }

    var traktResolved = false;
    if (session.isConnected) {
      try {
        final airing = await traktFuture;
        if (airing != null) {
          traktResolved = true;
          for (final episode in [airing.next, airing.last].whereType<Map>()) {
            final stamp = '${episode['first_aired'] ?? ''}';
            final date = DateTime.tryParse(stamp);
            final season = (episode['season'] as num?)?.toInt();
            final number = (episode['number'] as num?)?.toInt();
            if ((season ?? 0) > newestSeason) newestSeason = season!;
            if (date == null || (season ?? 0) <= 0 || (number ?? 0) <= 0) {
              continue;
            }
            final finale =
                episode['episode_type'] == 'series_finale' ||
                (identical(episode, airing.last) &&
                    airing.next == null &&
                    airing.show['status'] == 'ended');
            final seasonFinale = episode['episode_type'] == 'season_finale';
            if (identical(episode, airing.last) &&
                (finale || seasonFinale) &&
                !date.isAfter(now)) {
              completedSeason = season;
            }
            if (identical(episode, airing.last) && !finale && !seasonFinale) {
              continue;
            }
            events.add(
              TraktEvent(
                tmdbId: item.id,
                title: item.title,
                traktId: ((airing.show['ids'] as Map?)?['trakt'] as num?)
                    ?.toInt(),
                episode:
                    '第 $season 季 · 第 $number 集 · ${episode['title'] ?? ''}',
                seasonNumber: season,
                episodeNumber: number,
                airDate: date,
                timeKnown: traktPublishedAirtime(stamp),
                source: 'Trakt',
                seriesFinale: finale,
                platform: airing.show['network'] as String?,
                posterUrl: item.posterUrl,
                backdropUrl: item.backdropUrl,
              ),
            );
          }
        }
      } catch (_) {
        /* Keep cached/fallback information, never fake a time. */
      }
    }
    if (!localSucceeded && !traktResolved) {
      if (cached != null) return preserveCompletion(cached);
      if (completedSeason != null) {
        return SeriesAiringSnapshot(
          events: const [],
          savedAt: now,
          completedSeason: completedSeason,
        );
      }
      throw Exception('播出安排暂时无法获取');
    }
    if (session.isConnected && !traktResolved && cached != null) {
      events.addAll(cached.events.where((event) => event.source == 'Trakt'));
    }
    // Completion rows also need the show's persisted artwork and full networks,
    // even when no future episode remains to provide those fields.
    final posterPath = '${metadata?['poster_path'] ?? ''}';
    final backdropPath = '${metadata?['backdrop_path'] ?? ''}';
    final poster =
        item.posterUrl ??
        (posterPath.isEmpty
            ? null
            : Uri.https('image.tmdb.org', '/t/p/w500$posterPath'));
    final backdrop =
        item.backdropUrl ??
        (backdropPath.isEmpty
            ? null
            : Uri.https('image.tmdb.org', '/t/p/original$backdropPath'));
    final networks = <String, Uri?>{
      for (final row
          in (metadata?['networks'] as List? ?? const []).whereType<Map>())
        if ('${row['name'] ?? ''}'.isNotEmpty)
          '${row['name']}': '${row['logo_path'] ?? ''}'.isEmpty
              ? null
              : Uri.https('image.tmdb.org', '/t/p/w300${row['logo_path']}'),
    };
    for (var index = 0; index < events.length; index++) {
      final event = events[index];
      events[index] = TraktEvent.fromJson({
        ...event.toJson(),
        'posterUrl': (event.posterUrl ?? poster)?.toString(),
        'backdropUrl': (event.backdropUrl ?? backdrop)?.toString(),
        'platforms': mergeBroadcastPlatforms([
          networks,
          event.broadcastPlatforms,
        ]).map((name, logo) => MapEntry(name, logo?.toString())),
      });
    }
    final merged = mergeCalendarEvents(
      events,
      preferTrakt: session.isConnected,
    );
    for (final event in merged) {
      if ((event.seasonNumber ?? 0) > newestSeason) {
        newestSeason = event.seasonNumber!;
      }
    }
    if (completedSeason != null && newestSeason > completedSeason) {
      completedSeason = null;
      await prefs.remove(completionKey);
    } else if (completedSeason != null) {
      await prefs.setInt(completionKey, completedSeason);
    }
    if (newestSeason > knownSeason) await prefs.setInt(latestKey, newestSeason);
    final result = SeriesAiringSnapshot(
      events: merged,
      savedAt: now,
      completed:
          calendarGroupCompleted(merged, now: now) &&
          !merged.any((event) => event.airDate.isAfter(now)),
      traktResolved: traktResolved,
      completedSeason: completedSeason,
      latestSeason: newestSeason,
    );
    final body = jsonEncode(result.toJson());
    if (Platform.isWindows) {
      try {
        await WindowsMetadataCache.write(
          WindowsMetadataCache.schedule,
          key,
          body,
        );
      } catch (_) {
        await prefs.setString(key, body);
      }
    } else {
      await prefs.setString(key, body);
    }
    return result;
  }
}
