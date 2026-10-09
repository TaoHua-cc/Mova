import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show RenderBox, ScrollCacheExtent;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/window_host.dart';

import '../brand.dart';
import '../motion.dart';
import '../cache/image_prefetch.dart';
import '../cache/media_cache.dart';
import '../cache/preblurred_backdrop.dart';
import '../network/proxy_routing.dart';
import '../player/player_page.dart';
import '../player/android_player.dart';
import '../player/windows_native_player.dart';
import '../playlists/playlist_store.dart';
import '../sources/emby_client.dart';
import '../sources/media_source.dart';
import '../sources/server_mark.dart';
import '../sources/source_store.dart';
import '../sources/webdav_client.dart';
import '../history/watchlist_store.dart';
import '../tracking/trakt_watchlist_sync.dart';
import '../history/watch_state_store.dart';
import '../tracking/trakt_client.dart';
import '../tracking/trakt_auth.dart';
import 'tmdb_client.dart';
import 'ratings.dart';
import 'next_episode.dart';
import 'episode_search_gate.dart';

String _episodeKey(int? season, int? episode) =>
    '${season ?? 0}:${episode ?? 0}';

const _resourceSortPreferenceKey = 'yingji.detail.resource-sort';

List<MediaItem> sortedResourceVersions(
  Iterable<MediaItem> resources,
  String sort,
) {
  final rows = resources.toList();
  rows.sort(
    (a, b) => switch (sort) {
      'resolution' => (b.width ?? 0).compareTo(a.width ?? 0),
      'bitrate' => (b.bitrate ?? 0).compareTo(a.bitrate ?? 0),
      'size' => (b.size ?? 0).compareTo(a.size ?? 0),
      _ => (b.videoRange ?? '').compareTo(a.videoRange ?? ''),
    },
  );
  return rows;
}

/// Keep server order while showing the explicitly selected version of a server.
List<MediaItem> serverResourceRepresentatives(
  Iterable<MediaItem> resources,
  MediaItem? selected,
) {
  final servers = <String, MediaItem>{};
  for (final resource in resources) {
    servers.putIfAbsent(resource.source.id, () => resource);
    if (resource.resourceKey == selected?.resourceKey) {
      servers[resource.source.id] = resource;
    }
  }
  return servers.values.toList(growable: false);
}

class _PlaybackEpisodeOption {
  const _PlaybackEpisodeOption({
    this.seasonNumber,
    this.episodeNumber,
    this.metadata,
    this.resource,
  });

  final int? seasonNumber;
  final int? episodeNumber;
  final TmdbEpisode? metadata;
  final MediaItem? resource;

  String get key => _episodeKey(seasonNumber, episodeNumber);
}

bool webDavFilenameMatchesEpisode(
  String filename,
  Iterable<String> showTitles,
  int season,
  int episode,
) {
  final name = filename.toLowerCase();
  final compact = name.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
  if (!showTitles.any((title) {
    final normalized = title.toLowerCase().replaceAll(
      RegExp(r'[^\p{L}\p{N}]', unicode: true),
      '',
    );
    return normalized.isNotEmpty && compact.contains(normalized);
  })) {
    return false;
  }
  return RegExp(
        's0*$season[^0-9]*e0*$episode(?![0-9])',
        caseSensitive: false,
      ).hasMatch(name) ||
      RegExp('(?:^|[^0-9])0*$season\\s*x\\s*0*$episode(?![0-9])')
          .hasMatch(name) ||
      RegExp('第\\s*0*$season\\s*季.*第\\s*0*$episode\\s*集').hasMatch(name);
}

bool _isGenericEpisodeTitle(String value) =>
    value.trim().isEmpty || RegExp(r'^第\s*\d+\s*集$').hasMatch(value.trim());

String _episodeTitle(
  MediaItem resource,
  TmdbEpisode? metadata,
  int fallback, {
  String? seriesTitle,
}) {
  final tmdbName = metadata?.name.trim() ?? '';
  final serverTitle = resource.title.trim();
  // 部分服务器的单集条目会直接以剧名命名（单集标题 == 剧名），或者只给
  // 「第 N 集」这种序号 —— 这两种名字当副标题都没有信息量，TMDB 有集名时
  // 优先采用；只有服务器给的是真集名时才沿用服务器的。
  final uninformative =
      _isGenericEpisodeTitle(serverTitle) ||
      (seriesTitle != null && serverTitle == seriesTitle.trim());
  if (uninformative && tmdbName.isNotEmpty) return tmdbName;
  if (serverTitle.isNotEmpty && !uninformative) return serverTitle;
  if (tmdbName.isNotEmpty) return tmdbName;
  return '第 $fallback 集';
}

Uri? _episodeImage(MediaItem resource, TmdbEpisode? metadata) =>
    // TMDB stills are consistently available for mainland shows while some
    // Emby/Jellyfin episode records expose a non-thumbnail primary image.
    // Prefer the episode-specific still, then retain the server artwork.
    metadata?.stillUrl ?? resource.imageUrl;

/// Returns every server version for the exact episode stored in a resume row.
/// Season is part of the identity: episode 2 in season 1 is not season 2's E2.
List<MediaItem> episodeResourcesForResume(
  List<MediaItem> resources, {
  required int? seasonNumber,
  required int? episodeNumber,
}) {
  if (seasonNumber == null || episodeNumber == null) return const [];
  return resources
      .where(
        (resource) =>
            resource.seasonNumber == seasonNumber &&
            resource.episodeNumber == episodeNumber,
      )
      .toList(growable: false);
}

({int? season, int? episode}) detailInitialEpisode(
  int tmdbId,
  List<WatchState> recentFirst,
  List<TmdbSeason> seasons, {
  int? initialSeason,
  int? initialEpisode,
  MediaItem? media,
}) {
  final recent = recentFirst
      .where(
        (state) =>
            state.tmdbId == tmdbId &&
            state.seasonNumber != null &&
            state.episodeNumber != null,
      )
      .firstOrNull;
  final ordered = [...seasons]..sort((a, b) => a.number.compareTo(b.number));
  if (initialEpisode == null &&
      recent != null &&
      recent.isCompleted &&
      (initialSeason == null || initialSeason == recent.seasonNumber)) {
    final currentSeason = ordered
        .where((season) => season.number == recent.seasonNumber)
        .firstOrNull;
    final nextEpisode = recent.episodeNumber! + 1;
    final count = currentSeason?.episodeCount;
    if (count == null || nextEpisode <= count) {
      return (season: recent.seasonNumber, episode: nextEpisode);
    }
    final nextSeason = ordered
        .where(
          (season) =>
              season.number > recent.seasonNumber! &&
              (season.episodeCount == null || season.episodeCount! > 0),
        )
        .firstOrNull;
    if (nextSeason != null) {
      return (season: nextSeason.number, episode: 1);
    }
    // The series' final episode remains selected; do not invent a new episode.
  }
  return (
    season:
        initialSeason ??
        recent?.seasonNumber ??
        ordered.firstOrNull?.number ??
        media?.seasonNumber,
    episode:
        initialEpisode ??
        (initialSeason != null && recent?.seasonNumber != initialSeason
            ? null
            : recent?.episodeNumber) ??
        (ordered.isEmpty ? media?.episodeNumber : null),
  );
}

String _dateLabel(DateTime? date) => date == null
    ? ''
    : '${date.year}年${date.month.toString().padLeft(2, '0')}月${date.day.toString().padLeft(2, '0')}日';

String _minuteClock(int minutes) =>
    '${minutes ~/ 60 > 0 ? '${minutes ~/ 60}:' : ''}${(minutes % 60).toString().padLeft(2, '0')}:00';

String episodeProgressTime(Duration value) {
  final seconds = value.inSeconds.clamp(0, 86400000);
  return '${seconds >= 3600 ? '${seconds ~/ 3600}:' : ''}'
      '${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:'
      '${(seconds % 60).toString().padLeft(2, '0')}';
}

class MetadataDetailPage extends StatefulWidget {
  const MetadataDetailPage({
    super.key,
    required this.item,
    this.media,
    this.initialSeasonNumber,
    this.initialEpisodeNumber,
  });
  final TmdbItem item;
  final MediaItem? media;
  final int? initialSeasonNumber;
  final int? initialEpisodeNumber;

  /// 从被点击的作品卡展开详情；入口不在可见卡片内时自然退回淡入。
  static Future<void> open(
    BuildContext sourceContext, {
    required TmdbItem item,
    MediaItem? media,
    int? initialSeasonNumber,
    int? initialEpisodeNumber,
    Offset? tapPosition,
  }) {
    final navigator = Navigator.of(sourceContext);
    if (WindowHost.isAndroid) {
      return navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => MetadataDetailPage(
            item: item,
            media: media,
            initialSeasonNumber: initialSeasonNumber,
            initialEpisodeNumber: initialEpisodeNumber,
          ),
        ),
      );
    }
    final sourceBox = sourceContext.findRenderObject();
    final overlayBox = navigator.overlay?.context.findRenderObject();
    Rect? origin;
    if (sourceBox is RenderBox &&
        sourceBox.hasSize &&
        overlayBox is RenderBox &&
        overlayBox.hasSize &&
        sourceBox.size.width < overlayBox.size.width * .8 &&
        sourceBox.size.height < overlayBox.size.height * .8) {
      final rect =
          sourceBox.localToGlobal(Offset.zero, ancestor: overlayBox) &
          sourceBox.size;
      final viewport = Offset.zero & overlayBox.size;
      if (rect.overlaps(viewport)) origin = rect.intersect(viewport);
    }
    if (origin == null && tapPosition != null && overlayBox is RenderBox) {
      final center = overlayBox.globalToLocal(tapPosition);
      origin = Rect.fromCenter(
        center: center,
        width: 180,
        height: 240,
      ).intersect(Offset.zero & overlayBox.size);
    }
    Alignment? originAlignment;
    if (origin != null &&
        overlayBox is RenderBox &&
        overlayBox.size.width > 0 &&
        overlayBox.size.height > 0) {
      final center = origin.center;
      originAlignment = Alignment(
        (center.dx / overlayBox.size.width) * 2 - 1,
        (center.dy / overlayBox.size.height) * 2 - 1,
      );
    }
    return navigator.push<void>(
      PageRouteBuilder<void>(
        opaque: true,
        allowSnapshotting: true,
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, _, _) => MetadataDetailPage(
          item: item,
          media: media,
          initialSeasonNumber: initialSeasonNumber,
          initialEpisodeNumber: initialEpisodeNumber,
        ),
        transitionsBuilder: (context, animation, _, child) {
          if (originAlignment == null ||
              MediaQuery.disableAnimationsOf(context)) {
            return FadeTransition(opacity: animation, child: child);
          }
          final curve = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curve,
            child: ScaleTransition(
              alignment: originAlignment,
              scale: Tween<double>(begin: .97, end: 1).animate(curve),
              child: RepaintBoundary(child: child),
            ),
          );
        },
      ),
    );
  }

  @override
  State<MetadataDetailPage> createState() => _MetadataDetailPageState();
}

class _MetadataDetailPageState extends State<MetadataDetailPage> {
  late TmdbItem _item = widget.item;

  void _selectCollectionMovie(TmdbItem item) {
    if (item.id == _item.id) return;
    setState(() => _item = item);
  }

  @override
  Widget build(BuildContext context) {
    final original = _item.id == widget.item.id;
    return _MetadataDetailBody(
      item: _item,
      media: original ? widget.media : null,
      initialSeasonNumber: original ? widget.initialSeasonNumber : null,
      initialEpisodeNumber: original ? widget.initialEpisodeNumber : null,
      onCollectionMovieSelected: _selectCollectionMovie,
    );
  }
}

class _MetadataDetailBody extends StatefulWidget {
  const _MetadataDetailBody({
    required this.item,
    this.media,
    this.initialSeasonNumber,
    this.initialEpisodeNumber,
    required this.onCollectionMovieSelected,
  });
  final TmdbItem item;
  final MediaItem? media;
  final int? initialSeasonNumber;
  final int? initialEpisodeNumber;
  final ValueChanged<TmdbItem> onCollectionMovieSelected;

  @override
  State<_MetadataDetailBody> createState() => _MetadataDetailBodyState();
}

class _MetadataDetailBodyState extends State<_MetadataDetailBody> {
  final _pageScroll = ScrollController();
  final _pageBackdropDepth = ValueNotifier<double>(0);
  final _playlistPickerScroll = ScrollController();
  final _resourcePickerScroll = ScrollController();
  final _compactTrackPickerScroll = ScrollController();
  late Future<TmdbItem> _details;
  late Future<TmdbExtras> _extras;
  final _client = TmdbClient();
  final Map<String, EmbySession> _resolvedEpisodeSessions = {};
  final Map<String, List<String>> _episodeSeriesIds = {};
  WatchlistStore? _watchlist;
  bool _inWatchlist = false;
  bool _isFavorite = false;
  List<MediaItem> _resources = const [];
  Set<String> _completedResourceIds = const <String>{};
  Map<String, double> _episodeProgress = const <String, double>{};
  List<WatchState> _episodeWatchHistory = const [];
  Map<int, Uri> _seasonPosters = const {};
  Map<String, TmdbEpisode> _episodeMetadata = const {};
  List<TmdbSeason> _catalogSeasons = const [];
  int? _selectedEpisodeNumber;
  int _searchGeneration = 0;
  int _resourceGeneration = 0;
  Future<void>? _selectedEpisodeSearch;
  final _episodeSearchTasks = <String, Future<void>>{};
  final _episodeSearchRevisions = <String, int>{};
  final _episodeSearchResults =
      <String, ({List<MediaItem> rows, String? error})>{};
  MediaItem? _selectedResource;
  bool _loadingResources = true;
  String? _resourceError;
  String _resourceSort = 'range';
  int? _selectedSeason;
  int? _selectedAudioTrack;
  int? _selectedSubtitleTrack;
  @override
  void initState() {
    super.initState();
    _pageScroll.addListener(_syncPageBackdropDepth);
    WatchStateStore.revision.addListener(_refreshLocalProgress);
    _details =
        widget.item.id > 0 &&
            (widget.item.kind == '剧集' || widget.item.kind == '电影')
        ? _client.details(widget.item.id, kind: widget.item.kind)
        : Future.value(widget.item);
    _extras = widget.item.id > 0
        ? _client.extras(widget.item.id, kind: widget.item.kind)
        : Future.value(const TmdbExtras());
    WatchlistStore.create().then((store) {
      if (mounted) {
        setState(() {
          _watchlist = store;
          _inWatchlist = store.load().any((item) => item.id == widget.item.id);
        });
      }
    });
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() {
          final sort = prefs.getString(_resourceSortPreferenceKey);
          if (const {'range', 'resolution', 'bitrate', 'size'}.contains(sort)) {
            _resourceSort = sort!;
          }
          _isFavorite = (prefs.getStringList('yingji.favorites') ?? const [])
              .contains(widget.item.id.toString());
        });
      }
    });
    if (widget.item.kind == '剧集' && widget.item.id > 0) {
      _initializeSeriesCatalog();
    } else {
      _loadResources();
    }
  }

  void _syncPageBackdropDepth() {
    if (!_pageScroll.hasClients) return;
    final next = yingjiScrollDepth(_pageScroll.position);
    if (_pageBackdropDepth.value != next) _pageBackdropDepth.value = next;
  }

  @override
  void didUpdateWidget(covariant _MetadataDetailBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id == widget.item.id) return;
    ++_searchGeneration;
    ++_resourceGeneration;
    _resources = const [];
    _selectedResource = null;
    _selectedAudioTrack = null;
    _selectedSubtitleTrack = null;
    _completedResourceIds = const {};
    _episodeProgress = const {};
    _resourceError = null;
    _loadingResources = true;
    _inWatchlist =
        _watchlist?.load().any((item) => item.id == widget.item.id) ?? false;
    _isFavorite = false;
    _details = widget.item.id > 0
        ? _client.details(widget.item.id, kind: widget.item.kind)
        : Future.value(widget.item);
    _extras = widget.item.id > 0
        ? _client.extras(widget.item.id, kind: widget.item.kind)
        : Future.value(const TmdbExtras());
    final id = widget.item.id;
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted || widget.item.id != id) return;
      setState(
        () =>
            _isFavorite = (prefs.getStringList('yingji.favorites') ?? const [])
                .contains('$id'),
      );
    });
    unawaited(_loadResources());
  }

  Future<void> _initializeSeriesCatalog() async {
    final history = (await WatchStateStore.create()).load();
    TmdbExtras extras;
    try {
      extras = await _extras;
    } catch (_) {
      extras = const TmdbExtras();
    }
    final seasons = [...extras.seasons]
      ..sort((a, b) => a.number.compareTo(b.number));
    final selection = detailInitialEpisode(
      widget.item.id,
      history,
      seasons,
      initialSeason: widget.initialSeasonNumber,
      initialEpisode: widget.initialEpisodeNumber,
      media: widget.media,
    );
    final season = selection.season;
    if (!mounted) return;
    setState(() {
      _catalogSeasons = seasons;
      _episodeWatchHistory = history;
      _seasonPosters = {
        for (final season in seasons)
          if (season.posterUrl != null) season.number: season.posterUrl!,
      };
      _selectedSeason = season;
      _selectedEpisodeNumber = selection.episode;
      if (widget.media?.seasonNumber == season &&
          widget.media?.episodeNumber == _selectedEpisodeNumber) {
        _resources = [widget.media!];
        _selectedResource = widget.media;
      }
      _episodeProgress = {
        for (final state in history.reversed)
          if (state.tmdbId == widget.item.id &&
              state.seasonNumber != null &&
              state.episodeNumber != null)
            _episodeKey(state.seasonNumber, state.episodeNumber):
                state.progress,
      };
    });
    if (season == null) {
      setState(() {
        _loadingResources = false;
        _resourceError = '尚未获取到剧集目录，请稍后重试。';
      });
      return;
    }
    if (_selectedEpisodeNumber != null) {
      unawaited(_searchSelectedEpisode());
    }
    await _loadCatalogSeason(season);
    if (!mounted || _selectedSeason != season) return;
    final firstEpisode = _episodeMetadata.values
        .where((episode) => episode.seasonNumber == season)
        .map((episode) => episode.episodeNumber)
        .fold<int?>(
          null,
          (first, number) => first == null || number < first ? number : first,
        );
    if (_selectedEpisodeNumber == null && firstEpisode != null) {
      setState(() => _selectedEpisodeNumber = firstEpisode);
    }
    if (_selectedEpisodeNumber == null && mounted) {
      setState(() {
        _loadingResources = false;
        _resourceError = '本季暂未公布剧集。';
      });
    } else if (_searchGeneration == 0) {
      await _searchSelectedEpisode();
    }
  }

  Future<void> _loadCatalogSeason(int season) async {
    if (_episodeMetadata.values.any((row) => row.seasonNumber == season)) {
      return;
    }
    try {
      final episodes = await _client.seasonEpisodes(widget.item.id, season);
      if (!mounted) return;
      setState(() {
        _episodeMetadata = {
          ..._episodeMetadata,
          for (final episode in episodes)
            _episodeKey(season, episode.episodeNumber): episode,
        };
      });
      YingjiImageWarmup.episodes(episodes);
    } catch (_) {
      // The catalog stays visible even when one season fails to load.
    }
  }

  Future<void> _searchSelectedEpisode({bool force = false}) {
    final future = _runSelectedEpisodeSearch(force: force);
    _selectedEpisodeSearch = future;
    return future;
  }

  Future<MediaItem?> _searchSelectedEpisodeForPlayback({
    required String? preferredSourceId,
    void Function(List<MediaItem> resources)? onResourcesPublished,
  }) async {
    final season = _selectedSeason;
    final episode = _selectedEpisodeNumber;
    if (season == null || episode == null) return null;
    final gate = EpisodeSearchGate<MediaItem>(
      preferredSourceId: preferredSourceId,
    );
    final search = _runSelectedEpisodeSearch(
      firstPlayable: gate,
      onResourcesPublished: onResourcesPublished,
    );
    _selectedEpisodeSearch = search;
    final generation = _searchGeneration;
    unawaited(search);
    final selected = await gate.result;
    if (selected != null &&
        mounted &&
        generation == _searchGeneration &&
        _selectedSeason == season &&
        _selectedEpisodeNumber == episode) {
      setState(() => _selectedResource = selected);
    }
    return selected;
  }

  Future<void> _runSelectedEpisodeSearch({
    bool force = false,
    EpisodeSearchGate<MediaItem>? firstPlayable,
    void Function(List<MediaItem> resources)? onResourcesPublished,
  }) async {
    final season = _selectedSeason;
    final episode = _selectedEpisodeNumber;
    if (season == null || episode == null) {
      firstPlayable?.finish();
      return;
    }
    final key = _episodeKey(season, episode);
    final generation = ++_searchGeneration;
    final existing = force ? null : _episodeSearchTasks[key];
    if (existing == null) _episodeSearchRevisions[key] = generation;
    if (existing != null &&
        !_episodeSearchResults.containsKey(key) &&
        mounted) {
      setState(() {
        _resources = const [];
        _selectedResource = null;
        _resourceError = null;
        _loadingResources = true;
      });
    }
    final task =
        existing ??
        _performSelectedEpisodeSearch(
          generation: generation,
          firstPlayable: firstPlayable,
          onResourcesPublished: onResourcesPublished,
        );
    _episodeSearchTasks[key] = task;
    await task;
    final result = _episodeSearchResults[key];
    if (mounted && generation == _searchGeneration && result != null) {
      setState(() {
        _resources = result.rows;
        _selectedResource = result.rows.firstOrNull;
        _resourceError = result.error;
        _loadingResources = false;
      });
      unawaited(_refreshEpisodeProgress(result.rows, _searchGeneration));
      onResourcesPublished?.call(result.rows);
      for (final row in result.rows.where((row) => row.playbackUrl != null)) {
        firstPlayable?.offer(row.source.id, row);
      }
    }
    firstPlayable?.finish();
  }

  Future<void> _performSelectedEpisodeSearch({
    required int generation,
    EpisodeSearchGate<MediaItem>? firstPlayable,
    void Function(List<MediaItem> resources)? onResourcesPublished,
  }) async {
    final season = _selectedSeason;
    final episode = _selectedEpisodeNumber;
    if (season == null || episode == null) return;
    if (mounted) {
      setState(() {
        _loadingResources = true;
        _resourceError = null;
        _resources = const [];
        _selectedResource = null;
      });
    }
    final results = <MediaItem>[];
    final updatedSessions = <EmbySession>[];
    var failedSources = 0;

    void publish(List<MediaItem> found) {
      if (found.isEmpty || !mounted) return;
      results.addAll(found);
      final unique = <String, MediaItem>{
        for (final row in results) row.resourceKey: row,
      }.values.toList(growable: false);
      if (generation != _searchGeneration) return;
      setState(() {
        _resources = unique;
        _selectedResource ??= unique.firstOrNull;
      });
      onResourcesPublished?.call(unique);
      final playable = unique.where(
        (row) =>
            row.seasonNumber == season &&
            row.episodeNumber == episode &&
            row.playbackUrl != null,
      );
      for (final row in playable) {
        firstPlayable?.offer(row.source.id, row);
      }
    }

    try {
      final store = await SourceStore.create();
      // The primary TMDB title is already available. Do not wait for optional
      // metadata before querying the first source; original-title matching is
      // only needed as a fallback after the stable TMDB-ID lookup misses.
      final titles = <String>[widget.item.title];
      await Future.wait(
        store.load().map((source) async {
          if (!mounted) return;
          final token = store.tokenFor(source);
          if (token == null || token.isEmpty) return;
          if (source.kind == SourceKind.webdav) {
            try {
              final credentials = utf8
                  .decode(base64Url.decode(token))
                  .split('\u0000');
              if (credentials.length < 2) return;
              final client = WebDavClient();
              try {
                final rows = await client.list(
                  source: source,
                  username: credentials[0],
                  password: credentials[1],
                );
                var matches = rows
                    .where(
                      (row) => webDavFilenameMatchesEpisode(
                        row.title,
                        titles,
                        season,
                        episode,
                      ),
                    )
                    .toList(growable: false);
                if (matches.isEmpty) {
                  final extras = await _extras.catchError(
                    (_) => const TmdbExtras(),
                  );
                  final originalTitle = extras.originalTitle?.trim();
                  if (originalTitle?.isNotEmpty == true &&
                      originalTitle != widget.item.title) {
                    matches = rows
                        .where(
                          (row) => webDavFilenameMatchesEpisode(
                            row.title,
                            [...titles, originalTitle!],
                            season,
                            episode,
                          ),
                        )
                        .toList(growable: false);
                  }
                }
                publish(matches);
              } finally {
                client.dispose();
              }
            } catch (_) {
              failedSources++;
            }
            return;
          }
          final client = EmbyClient(
            proxy: ProxyRouting.serverUsesProxy(source.id),
          );
          try {
            final cacheKey = '${source.id}|$token';
            final session = _resolvedEpisodeSessions[cacheKey] ??= await client
                .resolveSession(EmbySession(source: source, token: token));
            if (session.source.endpoint != source.endpoint) {
              updatedSessions.add(session);
            }
            final seriesKey = '$cacheKey|${widget.item.id}';
            var seriesIds = _episodeSeriesIds[seriesKey] ?? const <String>[];
            if (seriesIds.isEmpty) {
              var found = await client.findByTmdbId(
                session,
                widget.item.id,
                includeItemTypes: 'Series',
              );
              if (found.isEmpty) {
                found = await client.search(
                  session,
                  widget.item.title,
                  includeItemTypes: 'Series',
                );
                if (found.isEmpty) {
                  final extras = await _extras.catchError(
                    (_) => const TmdbExtras(),
                  );
                  final originalTitle = extras.originalTitle?.trim();
                  if (originalTitle?.isNotEmpty == true &&
                      originalTitle != widget.item.title) {
                    found = await client.search(
                      session,
                      originalTitle!,
                      includeItemTypes: 'Series',
                    );
                  }
                }
              }
              seriesIds = found
                  .where((row) => row.type == 'Series')
                  .map((row) => row.id)
                  .toList(growable: false);
              if (seriesIds.isNotEmpty) {
                _episodeSeriesIds[seriesKey] = seriesIds;
              }
            }
            final sourceResults = <MediaItem>[];
            for (final seriesId in seriesIds) {
              sourceResults.addAll(
                await client.episodesForSeries(
                  session,
                  seriesId,
                  seasonNumber: season,
                  episodeNumber: episode,
                ),
              );
            }
            publish(sourceResults);
          } catch (_) {
            failedSources++;
          } finally {
            client.dispose();
          }
        }),
      );
      final unique = <String, MediaItem>{
        for (final row in results) row.resourceKey: row,
      }.values.toList(growable: false);
      if (_episodeSearchRevisions[_episodeKey(season, episode)] == generation) {
        _episodeSearchResults[_episodeKey(season, episode)] = (
          rows: unique,
          error: failedSources == 0
              ? null
              : '$failedSources 个服务器未完成搜索，可点击重新搜索。',
        );
      }
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _resources = unique;
        _selectedResource ??= unique.firstOrNull;
        _loadingResources = false;
        _resourceError = failedSources == 0
            ? null
            : '$failedSources 个服务器未完成搜索，可点击重新搜索。';
      });
      // These writes and derived state are useful, but never gate playback.
      unawaited(_persistResolvedSessions(store, updatedSessions));
      unawaited(_refreshEpisodeProgress(unique, generation));
    } catch (_) {
      if (_episodeSearchRevisions[_episodeKey(season, episode)] == generation) {
        _episodeSearchResults[_episodeKey(season, episode)] = (
          rows: List<MediaItem>.of(results),
          error: '当前集搜索失败，请检查连接后重新搜索。',
        );
      }
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _loadingResources = false;
        _resourceError = '当前集搜索失败，请检查连接后重新搜索。';
      });
    } finally {
      firstPlayable?.finish();
    }
  }

  Future<void> _persistResolvedSessions(
    SourceStore store,
    List<EmbySession> sessions,
  ) async {
    for (final session in sessions) {
      try {
        await store.upsert(session.source, session.token);
      } catch (_) {
        // The in-memory resolved route remains usable for this detail page.
      }
    }
  }

  Future<void> _refreshEpisodeProgress(
    List<MediaItem> resources,
    int generation,
  ) async {
    try {
      final history = (await WatchStateStore.create()).load();
      if (!mounted || generation != _searchGeneration) return;
      final local = _deriveProgress(resources, history, const {});
      setState(() {
        _completedResourceIds = local.completed;
        _episodeProgress = {..._episodeProgress, ...local.progress};
      });
      final traktCompleted = await _traktCompletedEpisodes();
      if (!mounted || generation != _searchGeneration) return;
      final freshHistory = (await WatchStateStore.create()).load();
      if (!mounted || generation != _searchGeneration) return;
      final combined = _deriveProgress(resources, freshHistory, traktCompleted);
      setState(() {
        _completedResourceIds = combined.completed;
        _episodeProgress = {..._episodeProgress, ...combined.progress};
      });
    } catch (_) {
      // Progress sync must never delay or invalidate resource playback.
    }
  }

  String _normaliseTitle(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[\s\W_]+', unicode: true), '');

  double _mediaProgress(MediaItem media) {
    if (media.playbackPosition == null ||
        media.runtime == null ||
        media.runtime! <= Duration.zero) {
      return media.isPlayed ? 1 : 0;
    }
    return (media.playbackPosition!.inMilliseconds /
            media.runtime!.inMilliseconds)
        .clamp(0.0, 1.0);
  }

  Future<void> _toggleFavorite() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = {...(prefs.getStringList('yingji.favorites') ?? const [])};
    final id = widget.item.id.toString();
    final next = !ids.contains(id);
    if (next) {
      ids.add(id);
    } else {
      ids.remove(id);
    }
    await prefs.setStringList('yingji.favorites', ids.toList());
    if (mounted) setState(() => _isFavorite = next);
  }

  /// 用上一次聚合好的资源快照立刻把详情页渲染出来，返回是否真的用上了缓存。
  ///
  /// 缓存里存的是「已经按标题匹配过的行」，所以这里不需要再走一遍聚合；
  /// 但仍然要过两道筛：来源被删掉、或来源地址改过的行不能再拿来播放。
  Future<bool> _restoreCachedResources() async {
    final generation = _resourceGeneration;
    final snapshot = await MediaDetailCache.load(widget.item);
    if (snapshot == null) return false;
    final store = await SourceStore.create();
    final endpoints = <String, Uri>{
      for (final source in store.load()) source.id: source.endpoint,
    };
    final rows = snapshot.rows
        .where((row) {
          final endpoint = endpoints[row.source.id];
          return endpoint != null && endpoint == row.source.endpoint;
        })
        .toList(growable: false);
    if (rows.isEmpty) return false;
    final direct = widget.media;
    final retained = direct == null
        ? null
        : rows
              .where(
                (row) =>
                    row.source.id == direct.source.id && row.id == direct.id,
              )
              .firstOrNull;
    final preferred = retained ?? await _initialResource(rows);
    final history = (await WatchStateStore.create()).load();
    // Trakt 的已看剧集要联网，先用本机记录把进度渲染出来；真正聚合那一步
    // （或冷却期内的进度刷新）会再带上 Trakt 重算一次。
    final derived = _deriveProgress(rows, history, const <String>{});
    if (!mounted || generation != _resourceGeneration) return false;
    setState(() {
      _resources = rows;
      _seasonPosters = snapshot.seasonPosters;
      _selectedResource = preferred ?? rows.first;
      _completedResourceIds = derived.completed;
      _episodeProgress = widget.item.kind == '剧集'
          ? {..._episodeProgress, ...derived.progress}
          : derived.progress;
      _selectedSeason =
          preferred?.seasonNumber ??
          rows.map((row) => row.seasonNumber).whereType<int>().firstOrNull;
      _loadingResources = false;
    });
    // 剧集名与剧照也立刻补上：TMDB 那侧同样是缓存优先的，不会卡住界面。
    unawaited(_loadEpisodeMetadata(rows));
    YingjiImageWarmup.urls([for (final row in rows) row.imageUrl]);
    return true;
  }

  Future<void> _loadResources({bool force = false}) async {
    final generation = ++_resourceGeneration;
    bool current() => mounted && generation == _resourceGeneration;
    if (widget.media != null && !force) {
      if (mounted) {
        setState(() {
          _resources = [widget.media!];
          _selectedResource = widget.media;
          _selectedSeason = widget.media!.seasonNumber;
          _episodeProgress = {
            _episodeKey(
              widget.media!.seasonNumber,
              widget.media!.episodeNumber,
            ): _mediaProgress(
              widget.media!,
            ),
          };
          _loadingResources = false;
        });
      }
      unawaited(_loadEpisodeMetadata([widget.media!]));
      if (widget.item.kind != '剧集' || widget.item.id <= 0) return;
    }
    // 先用上一次聚合好的快照把页面填满，再决定要不要真的去搜服务器。
    final restored = force && _resources.isNotEmpty
        ? true
        : await _restoreCachedResources();
    // 冷却应覆盖“上次搜索没有命中”的情况。空结果不会生成资源快照，但扫描时间
    // 仍然有效；否则每次重进都会重新遍历全部服务器并卡在加载态。
    final cooling = await MediaDetailCache.recentlyScanned(widget.item);
    if (!current()) return;
    if (!force && cooling && (restored || widget.media == null)) {
      if (restored) {
        // 冷却期内重复打开同一部剧：资源卡片沿用缓存，只把观看进度按本机
        // 记录重算一遍，不再把每个服务器都重新翻一遍。
        await _refreshProgressAfterPlayback();
      } else if (mounted) {
        // 上次扫描没有可恢复的结果时直接结束加载；用户仍可通过资源区的
        // “重试”按钮主动绕过冷却重新搜索。
        setState(() {
          _loadingResources = false;
          _resourceError = '最近一次检查已结束，点击重试可立即重新搜索。';
        });
      }
      return;
    }
    if (force && mounted) {
      setState(() {
        _loadingResources = true;
        _resourceError = null;
      });
    }
    try {
      final store = await SourceStore.create();
      final rows = <MediaItem>[];
      final seasonPosters = <int, Uri>{};
      final exactEpisodeKeys = <String>{};
      var failedSources = 0;
      for (final source in store.load()) {
        final token = store.tokenFor(source);
        if (source.kind == SourceKind.webdav) {
          if (token == null || token.isEmpty) continue;
          try {
            final credentials = utf8
                .decode(base64Url.decode(token))
                .split('\u0000');
            if (credentials.length < 2) continue;
            final client = WebDavClient();
            try {
              rows.addAll(
                await client.list(
                  source: source,
                  username: credentials[0],
                  password: credentials[1],
                ),
              );
            } finally {
              client.dispose();
            }
          } catch (_) {
            failedSources++;
            // A failed storage source must not hide usable server results.
          }
        } else {
          if (token == null || token.isEmpty) continue;
          final client = EmbyClient(
            proxy: ProxyRouting.serverUsesProxy(source.id),
          );
          try {
            final session = await client.resolveSession(
              EmbySession(source: source, token: token),
            );
            if (session.source.endpoint != source.endpoint) {
              await store.upsert(session.source, token);
            }
            final series = widget.item.kind == '剧集';
            var found = await client.findByTmdbId(
              session,
              widget.item.id,
              includeItemTypes: series ? 'Series' : 'Movie',
            );
            // Some Emby libraries omit ProviderIds even though their series
            // title is searchable. Search the server before falling back to
            // unrelated recently-added items, otherwise episode rails lose
            // their parent/season identity and cannot be enriched.
            if (found.isEmpty && widget.item.kind == '剧集') {
              found = await client.search(
                session,
                widget.item.title,
                includeItemTypes: 'Series',
              );
            }
            if (found.isEmpty) {
              rows.addAll(await client.recentlyAdded(session));
            } else {
              for (final match in found) {
                if (match.type == 'Series' || match.isContainer) {
                  List<MediaItem> seasons;
                  try {
                    seasons = await client.seasonsForSeries(session, match.id);
                  } catch (_) {
                    seasons = const [];
                  }
                  for (final season in seasons) {
                    final number = season.seasonNumber;
                    final image = season.imageUrl;
                    if (number != null && image != null) {
                      seasonPosters.putIfAbsent(number, () => image);
                    }
                  }
                  final episodes = await client.episodesForSeries(
                    session,
                    match.id,
                  );
                  rows.addAll(episodes);
                  exactEpisodeKeys.addAll(
                    episodes.map((episode) => '${source.id}:${episode.id}'),
                  );
                } else {
                  rows.add(match);
                }
              }
            }
          } catch (_) {
            failedSources++;
          } finally {
            client.dispose();
          }
        }
      }
      final title = _normaliseTitle(widget.item.title);
      if (!current()) return;
      final matches = rows
          .where((media) {
            // Episode titles normally do not contain the parent series title
            // (for example, “第 1 集”), so preserve episodes fetched from an
            // exact series match before applying the title fallback filter.
            if (media.type == 'Episode' &&
                exactEpisodeKeys.contains('${media.source.id}:${media.id}')) {
              return true;
            }
            final candidate = _normaliseTitle(media.title);
            final providerMatch = media.providerIds.entries.any(
              (entry) =>
                  entry.key.toLowerCase() == 'tmdb' &&
                  entry.value == widget.item.id.toString(),
            );
            return providerMatch ||
                (candidate.isNotEmpty &&
                    (candidate.contains(title) || title.contains(candidate)));
          })
          .toList(growable: false);
      if (failedSources > 0 && matches.isEmpty && _resources.isNotEmpty) {
        if (mounted) {
          setState(() {
            _loadingResources = false;
            _resourceError = '$failedSources 个服务器连接或读取失败；保留已缓存资源，可重新搜索。';
          });
        }
        await MediaDetailCache.markScanned(widget.item);
        return;
      }
      final previous = _selectedResource;
      final selectedSeason = _selectedSeason;
      final retained = previous == null
          ? null
          : matches
                .where(
                  (row) =>
                      row.seasonNumber == previous.seasonNumber &&
                      row.episodeNumber == previous.episodeNumber &&
                      row.source.id == previous.source.id,
                )
                .firstOrNull;
      final sameSeason = selectedSeason == null
          ? <MediaItem>[]
          : matches
                .where((row) => row.seasonNumber == selectedSeason)
                .toList(growable: false);
      final preferred =
          retained ??
          (sameSeason.isNotEmpty
              ? await _preferredResource(sameSeason)
              : await _initialResource(matches));
      final traktCompleted = await _traktCompletedEpisodes();
      final history = (await WatchStateStore.create()).load();
      if (!current()) return;
      final derived = _deriveProgress(matches, history, traktCompleted);
      if (mounted) {
        setState(() {
          _resources = matches;
          _seasonPosters = seasonPosters;
          _selectedResource = preferred;
          _completedResourceIds = derived.completed;
          _episodeProgress = derived.progress;
          _selectedSeason =
              (selectedSeason != null &&
                      matches.any((row) => row.seasonNumber == selectedSeason)
                  ? selectedSeason
                  : preferred?.seasonNumber) ??
              matches
                  .map((item) => item.seasonNumber)
                  .whereType<int>()
                  .firstOrNull;
          _loadingResources = false;
          _resourceError = failedSources == 0
              ? null
              : '$failedSources 个服务器连接或读取失败；已显示其他服务器的资源，可重新搜索。';
        });
      }
      unawaited(_loadEpisodeMetadata(matches));
      // 存下这次聚合结果：下次打开先渲染它，再按冷却间隔决定要不要重搜。
      if (failedSources == 0) {
        unawaited(
          MediaDetailCache.save(
            widget.item,
            rows: matches,
            seasonPosters: seasonPosters,
          ),
        );
      }
      await MediaDetailCache.markScanned(widget.item);
      YingjiImageWarmup.urls([
        for (final resource in matches) resource.imageUrl,
      ]);
    } catch (error) {
      if (!current()) return;
      // 失败也记录自动尝试时间，避免每次重进都再次等待同一轮超时；手动重试
      // 会传 force 并立即执行，不受这个冷却影响。
      await MediaDetailCache.markScanned(widget.item);
      if (current()) {
        setState(() {
          _loadingResources = false;
          _resourceError = '服务器搜索未完成，请检查连接后点击重新搜索。';
        });
      }
    }
  }

  /// Derives per-episode progress and the completed-resource set from watch
  /// history (local + server) and Trakt. Shared by the initial resource load
  /// and by the post-playback refresh so both stay on the same rules.
  WatchState? _localWatch(MediaItem resource, List<WatchState> history) =>
      history
          .where(
            (state) =>
                (state.sourceId == resource.source.id &&
                    state.serverItemId == resource.id) ||
                state.mediaId == resource.playbackUrl?.toString() ||
                (widget.item.id > 0 &&
                    state.tmdbId == widget.item.id &&
                    state.seasonNumber == resource.seasonNumber &&
                    state.episodeNumber == resource.episodeNumber &&
                    state.episodeNumber != null),
          )
          .firstOrNull;

  ({Set<String> completed, Map<String, double> progress}) _deriveProgress(
    List<MediaItem> resources,
    List<WatchState> history,
    Set<String> traktCompleted,
  ) {
    final completed = resources
        .where((resource) {
          final local = _localWatch(resource, history);
          return local != null
              ? local.isCompleted
              : resource.isPlayed ||
                    _mediaProgress(resource) >= .92 ||
                    traktCompleted.contains(
                      _episodeKey(
                        resource.seasonNumber,
                        resource.episodeNumber,
                      ),
                    );
        })
        .map((resource) => resource.id)
        .toSet();
    final progress = <String, double>{};
    for (final state in history) {
      if (state.tmdbId == widget.item.id &&
          state.seasonNumber != null &&
          state.episodeNumber != null) {
        progress.putIfAbsent(
          _episodeKey(state.seasonNumber, state.episodeNumber),
          () => state.progress,
        );
      }
    }
    final localKeys = progress.keys.toSet();
    for (final resource in resources) {
      final local = _localWatch(resource, history);
      final localProgress = local?.progress ?? 0;
      final serverDuration = resource.runtime;
      final serverProgress =
          resource.playbackPosition == null ||
              serverDuration == null ||
              serverDuration <= Duration.zero
          ? 0.0
          : (resource.playbackPosition!.inMilliseconds /
                    serverDuration.inMilliseconds)
                .clamp(0.0, 1.0);
      final key = _episodeKey(resource.seasonNumber, resource.episodeNumber);
      if (localKeys.contains(key)) continue;
      final next = local != null
          ? localProgress
          : serverProgress > localProgress
          ? serverProgress
          : localProgress;
      if (next > (progress[key] ?? 0)) progress[key] = next;
    }
    return (completed: completed, progress: progress);
  }

  /// Re-derives episode progress after the player closes. The initial
  /// [_loadResources] snapshot predates playback, so without this the episode
  /// rails keep showing the position captured before the session started.
  WatchState? _catalogWatchTime(TmdbEpisode episode) {
    final saved = _episodeWatchHistory
        .where(
          (state) =>
              state.tmdbId == widget.item.id &&
              state.seasonNumber == episode.seasonNumber &&
              state.episodeNumber == episode.episodeNumber,
        )
        .firstOrNull;
    if (saved != null) return saved;
    final resource = _resources
        .where(
          (row) =>
              row.seasonNumber == episode.seasonNumber &&
              row.episodeNumber == episode.episodeNumber,
        )
        .firstOrNull;
    if (resource == null) return null;
    return _localWatch(resource, _episodeWatchHistory) ??
        WatchState(
          mediaId: resource.id,
          title: widget.item.title,
          position: resource.playbackPosition ?? Duration.zero,
          duration: resource.runtime ?? Duration.zero,
        );
  }

  Future<void> _refreshLocalProgress() async {
    final history = (await WatchStateStore.create()).load();
    if (!mounted) return;
    final derived = _deriveProgress(_resources, history, const {});
    setState(() {
      _episodeProgress = derived.progress;
      _episodeWatchHistory = history;
      _completedResourceIds = derived.completed;
    });
  }

  Future<void> _refreshProgressAfterPlayback() async {
    final generation = _resourceGeneration;
    if (!mounted || _loadingResources) return;
    await _refreshLocalProgress();
    final traktCompleted = await _traktCompletedEpisodes();
    final history = (await WatchStateStore.create()).load();
    final derived = _deriveProgress(_resources, history, traktCompleted);
    if (!mounted || generation != _resourceGeneration) return;
    setState(() {
      _episodeProgress = derived.progress;
      _completedResourceIds = derived.completed;
    });
  }

  Future<void> _loadEpisodeMetadata(List<MediaItem> resources) async {
    if (widget.item.kind != '剧集' || widget.item.id <= 0) return;
    final seasons = resources
        .map((resource) => resource.seasonNumber)
        .whereType<int>()
        .where((season) => season > 0)
        .toSet();
    // A number of domestic-library naming conventions omit season/episode
    // indexes. Treat those rows as season one for metadata presentation so
    // the real Chinese episode stills and names can still be recovered.
    if (seasons.isEmpty) seasons.add(1);
    try {
      final groups = await Future.wait(
        seasons.map((season) => _client.seasonEpisodes(widget.item.id, season)),
      );
      final episodes = <String, TmdbEpisode>{
        for (final group in groups)
          for (final episode in group)
            _episodeKey(episode.seasonNumber, episode.episodeNumber): episode,
      };
      if (mounted && episodes.isNotEmpty) {
        setState(() => _episodeMetadata = episodes);
      }
      // 剧照提前写进磁盘缓存，切季/切集时不再逐张现下。
      YingjiImageWarmup.episodes(episodes.values);
    } catch (_) {
      // Server-provided media details remain usable when TMDB enrichment fails.
    }
  }

  Future<Set<String>> _traktCompletedEpisodes() async {
    if (widget.item.id <= 0 || widget.item.kind != '剧集') {
      return const <String>{};
    }
    var credentials = await TraktCredentials.read();
    try {
      credentials = await credentials.refreshIfNeeded();
    } catch (_) {}
    final clientId = credentials.clientId;
    final token = credentials.accessToken;
    if (clientId.isEmpty || token.isEmpty) return const <String>{};
    final trakt = TraktClient();
    try {
      return await trakt.watchedEpisodeKeys(
        clientId: clientId,
        accessToken: token,
        tmdbId: widget.item.id,
      );
    } catch (_) {
      return const <String>{};
    } finally {
      trakt.dispose();
    }
  }

  List<MediaItem> get _visibleResources {
    final selected = _selectedResource;
    if (selected == null) return _resources;
    final filtered = _resources
        .where(
          (item) =>
              item.seasonNumber == selected.seasonNumber &&
              item.episodeNumber == selected.episodeNumber,
        )
        .toList(growable: false);
    return filtered;
  }

  List<MediaItem> get _episodeChoices {
    final season = _selectedSeason;
    final rows =
        _resources
            .where((item) => season == null || item.seasonNumber == season)
            .toList()
          ..sort(
            (a, b) => (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0),
          );
    final unique = <String, MediaItem>{};
    for (final row in rows) {
      unique.putIfAbsent(
        '${row.seasonNumber ?? 0}:${row.episodeNumber ?? 0}',
        () => row,
      );
    }
    return unique.values.toList(growable: false);
  }

  List<TmdbEpisode> get _catalogEpisodeChoices =>
      _episodeMetadata.values
          .where((episode) => episode.seasonNumber == _selectedSeason)
          .toList()
        ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));

  List<_PlaybackEpisodeOption> _playerEpisodeCatalog(MediaItem current) {
    final options = <String, _PlaybackEpisodeOption>{};
    void include({
      int? season,
      int? episode,
      TmdbEpisode? metadata,
      MediaItem? resource,
    }) {
      if (season == null || episode == null) {
        if (resource == null) return;
      }
      final key = _episodeKey(season, episode);
      final previous = options[key];
      options[key] = _PlaybackEpisodeOption(
        seasonNumber: season ?? previous?.seasonNumber,
        episodeNumber: episode ?? previous?.episodeNumber,
        metadata: metadata ?? previous?.metadata,
        resource: resource ?? previous?.resource,
      );
    }

    for (final season in _catalogSeasons) {
      final count = season.episodeCount ?? 0;
      for (var number = 1; number <= count; number++) {
        final metadata = _episodeMetadata[_episodeKey(season.number, number)];
        include(season: season.number, episode: number, metadata: metadata);
      }
    }
    for (final metadata in _episodeMetadata.values) {
      include(
        season: metadata.seasonNumber,
        episode: metadata.episodeNumber,
        metadata: metadata,
      );
    }
    for (final resource in _resources) {
      include(
        season: resource.seasonNumber,
        episode: resource.episodeNumber,
        metadata:
            _episodeMetadata[_episodeKey(
              resource.seasonNumber,
              resource.episodeNumber,
            )],
        resource: resource,
      );
    }
    include(
      season: current.seasonNumber,
      episode: current.episodeNumber,
      metadata:
          _episodeMetadata[_episodeKey(
            current.seasonNumber,
            current.episodeNumber,
          )],
      resource: current,
    );
    return options.values.toList()..sort((a, b) {
      final season = (a.seasonNumber ?? 0).compareTo(b.seasonNumber ?? 0);
      return season == 0
          ? (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0)
          : season;
    });
  }

  String _catalogEpisodeTitle(
    _PlaybackEpisodeOption option, {
    required String seriesTitle,
  }) {
    final metadata = option.metadata;
    final resource = option.resource;
    if (resource != null) {
      return _episodeTitle(
        resource,
        metadata,
        option.episodeNumber ?? 1,
        seriesTitle: seriesTitle,
      );
    }
    final name = metadata?.name.trim() ?? '';
    return name.isNotEmpty ? name : '第 ${option.episodeNumber ?? 1} 集';
  }

  Uri? _catalogEpisodeImage(_PlaybackEpisodeOption option) =>
      option.metadata?.stillUrl ?? option.resource?.imageUrl;

  Future<MediaItem?> _preferredResource(List<MediaItem> resources) async {
    if (resources.isEmpty) return null;
    final ordered = [...resources]
      ..sort((a, b) {
        final season = (a.seasonNumber ?? 0).compareTo(b.seasonNumber ?? 0);
        if (season != 0) return season;
        final episode = (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
        if (episode != 0) return episode;
        return a.source.name.compareTo(b.source.name);
      });
    final history = (await WatchStateStore.create()).load();
    bool matches(WatchState state, MediaItem resource) =>
        _localWatch(resource, [state]) != null &&
        (state.position > Duration.zero || state.isCompleted);
    double progressFor(MediaItem resource) {
      return _localWatch(resource, history)?.progress ??
          _mediaProgress(resource);
    }

    final resumable = ordered.where((resource) {
      final progress = progressFor(resource);
      return progress > 0 && progress < .92;
    }).toList()..sort((a, b) => progressFor(b).compareTo(progressFor(a)));
    if (resumable.isNotEmpty) return resumable.first;
    final played = <String>{};
    for (final resource in ordered) {
      final local = _localWatch(resource, history);
      if (local != null &&
          (local.position > Duration.zero || local.isCompleted)) {
        played.add(resource.id);
      }
    }
    final recentState = history
        .where((state) => ordered.any((resource) => matches(state, resource)))
        .firstOrNull;
    if (recentState != null) {
      final recentIndex = ordered.indexWhere(
        (resource) => matches(recentState, resource),
      );
      if (recentIndex >= 0 && recentState.progress < .92) {
        return ordered[recentIndex];
      }
      for (var index = recentIndex + 1; index < ordered.length; index++) {
        if (!played.contains(ordered[index].id)) return ordered[index];
      }
    }
    return ordered.firstWhere(
      (resource) => !played.contains(resource.id),
      orElse: () => recentState == null
          ? ordered.first
          : ordered.firstWhere(
              (resource) => matches(recentState, resource),
              orElse: () => ordered.last,
            ),
    );
  }

  Future<MediaItem?> _initialResource(List<MediaItem> resources) {
    final resumedEpisode = episodeResourcesForResume(
      resources,
      seasonNumber: widget.initialSeasonNumber,
      episodeNumber: widget.initialEpisodeNumber,
    );
    return _preferredResource(
      resumedEpisode.isEmpty ? resources : resumedEpisode,
    );
  }

  Future<void> _selectSeason(int season) async {
    if (widget.item.kind == '剧集' && widget.item.id > 0) {
      ++_searchGeneration;
      setState(() {
        _selectedSeason = season;
        _selectedEpisodeNumber = null;
        _resources = const [];
        _selectedResource = null;
        _loadingResources = true;
      });
      await _loadCatalogSeason(season);
      if (!mounted || _selectedSeason != season) return;
      final first = _episodeMetadata.values
          .where((row) => row.seasonNumber == season)
          .map((row) => row.episodeNumber)
          .fold<int?>(
            null,
            (current, next) =>
                current == null || next < current ? next : current,
          );
      if (first == null) {
        setState(() {
          _loadingResources = false;
          _resourceError = '本季剧集目录暂不可用，请稍后重试。';
        });
        return;
      }
      setState(() => _selectedEpisodeNumber = first);
      await _searchSelectedEpisode();
      return;
    }
    final candidates = _resources
        .where((resource) => resource.seasonNumber == season)
        .toList(growable: false);
    final preferred = await _preferredResource(candidates);
    if (!mounted) return;
    setState(() {
      _selectedSeason = season;
      _selectedResource = preferred ?? candidates.firstOrNull;
    });
  }

  void _selectCatalogEpisode(TmdbEpisode episode) {
    ++_searchGeneration;
    setState(() {
      _selectedSeason = episode.seasonNumber;
      _selectedEpisodeNumber = episode.episodeNumber;
    });
    unawaited(_searchSelectedEpisode());
  }

  Future<void> _playSelectedCatalogEpisode(
    BuildContext context,
    TmdbEpisode episode,
  ) async {
    bool matchesEpisode(MediaItem item) =>
        item.seasonNumber == episode.seasonNumber &&
        item.episodeNumber == episode.episodeNumber &&
        item.playbackUrl != null;
    MediaItem? playableResource() {
      final current = _selectedResource;
      if (current != null && matchesEpisode(current)) return current;
      return _resources.where(matchesEpisode).firstOrNull;
    }

    var resource = playableResource();
    if (resource == null && _loadingResources) {
      await _selectedEpisodeSearch;
      if (!mounted || !context.mounted) return;
      resource = playableResource();
    }
    if (resource == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _loadingResources ? '正在搜索本集可播放资源…' : '本集没有找到可播放资源，请重新搜索。',
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _selectedResource = resource);
    await _play(context, widget.item);
  }

  Future<void> _selectEpisode(MediaItem episode) async {
    if (widget.item.kind == '剧集' && widget.item.id > 0) {
      ++_searchGeneration;
      setState(() {
        _selectedSeason = episode.seasonNumber;
        _selectedEpisodeNumber = episode.episodeNumber;
      });
      await _searchSelectedEpisode();
      return;
    }
    final candidates = _resources
        .where(
          (resource) =>
              resource.seasonNumber == episode.seasonNumber &&
              resource.episodeNumber == episode.episodeNumber,
        )
        .toList(growable: false);
    final preferred = await _preferredResource(candidates);
    if (!mounted) return;
    setState(() {
      _selectedSeason = episode.seasonNumber ?? _selectedSeason;
      _selectedResource = preferred ?? candidates.firstOrNull ?? episode;
    });
  }

  Future<void> _setEpisodeCompleted(MediaItem resource, bool completed) async {
    final siblings = _resources
        .where(
          (item) =>
              item.seasonNumber == resource.seasonNumber &&
              item.episodeNumber == resource.episodeNumber,
        )
        .toList(growable: false);
    final versions = siblings.isEmpty ? <MediaItem>[resource] : siblings;
    final episodeKey = _episodeKey(
      resource.seasonNumber,
      resource.episodeNumber,
    );
    if (mounted) {
      setState(() {
        final ids = {..._completedResourceIds};
        if (completed) {
          ids.addAll(versions.map((item) => item.id));
        } else {
          ids.removeAll(versions.map((item) => item.id));
        }
        _completedResourceIds = ids;
        _episodeProgress = {..._episodeProgress, episodeKey: completed ? 1 : 0};
      });
    }
    final watchStore = await WatchStateStore.create();
    final version = resource;
    final mediaId = version.playbackUrl?.toString() ?? version.id;
    final duration = version.runtime ?? const Duration(seconds: 1);
    await watchStore.setPlayed(
      WatchState(
        mediaId: mediaId,
        serverItemId: version.id,
        sourceId: version.source.id,
        tmdbId: widget.item.id,
        title: widget.item.title,
        episodeTitle: version.title,
        seasonNumber: version.seasonNumber,
        episodeNumber: version.episodeNumber,
        imageUrl: version.imageUrl?.toString(),
        position: duration,
        duration: duration,
      ),
      completed,
    );
    if (await WatchStateStore.localOnly()) {
      // 「观看记录只保存在本机」：本机记录上面已经写好，这里不再回写媒体
      // 服务器与 Trakt，只如实告诉用户这次标记存在了哪里。
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(completed ? '已标记播放完成 · 仅保存在本机' : '已标记未播放 · 仅保存在本机'),
        ),
      );
      return;
    }
    final messages = <String>[];
    try {
      for (final version in versions.where(
        (item) => item.source.kind != SourceKind.webdav,
      )) {
        final store = await SourceStore.create();
        final token = store.tokenFor(version.source);
        if (token != null && token.isNotEmpty) {
          final client = EmbyClient(
            proxy: ProxyRouting.serverUsesProxy(version.source.id),
          );
          try {
            await client.setPlayed(
              EmbySession(source: version.source, token: token),
              version.id,
              played: completed,
            );
          } finally {
            client.dispose();
          }
        }
      }
      if (versions.any((item) => item.source.kind != SourceKind.webdav)) {
        messages.add('服务器已同步');
      }
      var credentials = await TraktCredentials.read();
      try {
        credentials = await credentials.refreshIfNeeded();
      } catch (_) {}
      final clientId = credentials.clientId;
      final token = credentials.accessToken;
      if (widget.item.id > 0 && clientId.isNotEmpty && token.isNotEmpty) {
        final trakt = TraktClient();
        try {
          await trakt.setEpisodeWatched(
            clientId: clientId,
            accessToken: token,
            tmdbId: widget.item.id,
            season: resource.seasonNumber ?? 1,
            episode: resource.episodeNumber ?? 1,
            watched: completed,
          );
          messages.add('Trakt 已同步');
        } finally {
          trakt.dispose();
        }
      }
    } catch (error) {
      messages.add(error.toString().replaceFirst('Exception: ', ''));
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          completed
              ? '已标记播放完成${messages.isEmpty ? '' : ' · ${messages.join(' · ')}'}'
              : '已标记未播放${messages.isEmpty ? '' : ' · ${messages.join(' · ')}'}',
        ),
      ),
    );
  }

  Future<void> _setCatalogEpisodeCompleted(
    TmdbEpisode episode,
    bool completed,
  ) async {
    final resource = _resources
        .where(
          (item) =>
              item.seasonNumber == episode.seasonNumber &&
              item.episodeNumber == episode.episodeNumber,
        )
        .firstOrNull;
    if (resource != null) {
      await _setEpisodeCompleted(resource, completed);
      return;
    }
    final mediaId =
        'tmdb:${widget.item.id}:s${episode.seasonNumber}:e${episode.episodeNumber}';
    if (mounted) {
      setState(
        () => _episodeProgress = {
          ..._episodeProgress,
          _episodeKey(episode.seasonNumber, episode.episodeNumber): completed
              ? 1
              : 0,
        },
      );
    }
    final store = await WatchStateStore.create();
    final duration = Duration(minutes: episode.runtime ?? 1);
    await store.setPlayed(
      WatchState(
        mediaId: mediaId,
        tmdbId: widget.item.id,
        title: widget.item.title,
        episodeTitle: episode.name,
        seasonNumber: episode.seasonNumber,
        episodeNumber: episode.episodeNumber,
        imageUrl: episode.stillUrl?.toString(),
        position: duration,
        duration: duration,
      ),
      completed,
    );
    if (!mounted) return;
    if (await WatchStateStore.localOnly()) return;
    final credentials = await TraktCredentials.read();
    if (credentials.clientId.isEmpty || credentials.accessToken.isEmpty) return;
    final trakt = TraktClient();
    try {
      await trakt.setEpisodeWatched(
        clientId: credentials.clientId,
        accessToken: credentials.accessToken,
        tmdbId: widget.item.id,
        season: episode.seasonNumber,
        episode: episode.episodeNumber,
        watched: completed,
      );
    } finally {
      trakt.dispose();
    }
  }

  Future<void> _addToPlaylist(TmdbItem item) async {
    final store = await PlaylistStore.create();
    final playlists = store.load();
    if (!mounted) return;
    if (playlists.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先在“片单”页创建自定义片单。')));
      return;
    }
    final selected = await showModalBottomSheet<YingjiPlaylist>(
      context: context,
      sheetAnimationStyle: MovaMotion.dialogAnimationStyle(context),
      backgroundColor: YingjiGlass.surface(strength: 1.15),
      builder: (context) => YingjiStableScrollGlass(
        child: SafeArea(
          child: YingjiSmoothWheel(
            controller: _playlistPickerScroll,
            child: ListView(
              controller: _playlistPickerScroll,
              physics:
                  yingjiWheelPhysics ??
                  const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
              shrinkWrap: true,
              children: [
                const ListTile(
                  title: Text(
                    '加入片单',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text('选择一个本地自定义片单'),
                ),
                ...playlists.map(
                  (playlist) => ListTile(
                    leading: const Icon(YingjiIcons.rectangle_stack),
                    title: Text(playlist.name),
                    subtitle: Text('${playlist.items.length} 部内容'),
                    onTap: () => Navigator.pop(context, playlist),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected == null) return;
    final items = selected.items.where((value) => value.id != item.id).toList()
      ..insert(0, item);
    await store.save(selected.copyWith(items: items));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已加入“${selected.name}”')));
    }
  }

  Future<void> _selectResourceSort(String value) async {
    setState(() => _resourceSort = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_resourceSortPreferenceKey, value);
  }

  Future<void> _showResourcePicker({MediaSource? source}) async {
    final sorted = sortedResourceVersions(_visibleResources, _resourceSort);
    final choices = source == null
        ? sorted
        : sorted.where((resource) => resource.source.id == source.id).toList();
    if (choices.isEmpty) return;
    final selected = await showModalBottomSheet<MediaItem>(
      context: context,
      sheetAnimationStyle: MovaMotion.dialogAnimationStyle(context),
      backgroundColor: Colors.transparent,
      // GlassPanel owns the surface; do not inherit the theme's second frame.
      shape: const RoundedRectangleBorder(),
      elevation: 0,
      showDragHandle: false,
      barrierColor: Colors.black54,
      builder: (context) => YingjiStableScrollGlass(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            child: GlassPanel(
              radius: 20,
              padding: const EdgeInsets.all(18),
              child: YingjiSmoothWheel(
                controller: _resourcePickerScroll,
                child: ListView(
                  controller: _resourcePickerScroll,
                  physics:
                      yingjiWheelPhysics ??
                      const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                  shrinkWrap: true,
                  children: [
                    const Row(
                      children: [
                        Icon(YingjiIcons.slider_horizontal_3, size: 18),
                        SizedBox(width: 8),
                        Text(
                          '切换资源',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      '选择版本后，播放与音轨信息会同步更新。',
                      style: TextStyle(color: YingjiColors.muted, fontSize: 12),
                    ),
                    const SizedBox(height: 14),
                    for (final resource in choices) ...[
                      _ResourcePickerCard(
                        resource: resource,
                        selected:
                            resource.resourceKey ==
                            _selectedResource?.resourceKey,
                        onTap: () => Navigator.pop(context, resource),
                      ),
                      const SizedBox(height: 9),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() {
        _selectedResource = selected;
        _selectedAudioTrack = null;
        _selectedSubtitleTrack = null;
      });
    }
  }

  Future<void> _showTrackPicker() async {
    final resource = _selectedResource;
    if (resource == null) return;
    await showDialog<void>(
      context: context,
      animationStyle: MovaMotion.dialogAnimationStyle(context),
      barrierColor: Colors.black.withValues(alpha: .62),
      builder: (context) => YingjiStableScrollGlass(
        child: StatefulBuilder(
          builder: (context, updateDialog) => Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 920,
                maxHeight: math.min(
                  MediaQuery.sizeOf(context).height * .84,
                  720,
                ),
              ),
              child: GlassPanel(
                radius: 20,
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const _TrackPickerHeadingIcon(),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '预选音轨与字幕',
                                style: TextStyle(
                                  fontSize: 21,
                                  height: 1.15,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              SizedBox(height: 5),
                              Text(
                                '播放此版本时优先使用；仍可在播放器中随时切换。',
                                style: TextStyle(
                                  color: YingjiColors.muted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        YingjiMotionIconButton(
                          icon: YingjiIcons.xmark,
                          tooltip: '关闭',
                          size: 38,
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _TrackResourceSummary(resource: resource),
                    const SizedBox(height: 18),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final audio = _TrackPickerPane(
                            icon: YingjiIcons.speaker_2_fill,
                            title: '音轨',
                            count: resource.audioTracks.length,
                            children: [
                              _TrackPickerOption(
                                icon: YingjiIcons.sparkles,
                                title: '自动选择',
                                detail: '使用服务器默认音轨',
                                selected: _selectedAudioTrack == null,
                                onTap: () {
                                  setState(() {
                                    _selectedAudioTrack = null;
                                  });
                                  updateDialog(() {});
                                },
                              ),
                              for (final track in resource.audioTracks)
                                _TrackPickerOption(
                                  icon: YingjiIcons.speaker_2_fill,
                                  title: track.title,
                                  detail: _trackSummary(track),
                                  badge: track.isDefault ? '默认' : null,
                                  selected: _selectedAudioTrack == track.index,
                                  onTap: () {
                                    setState(() {
                                      _selectedAudioTrack = track.index;
                                    });
                                    updateDialog(() {});
                                  },
                                ),
                            ],
                          );
                          final subtitles = _TrackPickerPane(
                            icon: YingjiIcons.captions_bubble,
                            title: '字幕',
                            count: resource.subtitleTracks.length,
                            children: [
                              _TrackPickerOption(
                                icon: YingjiIcons.sparkles,
                                title: '自动选择',
                                detail: '按字幕语言偏好智能选择',
                                selected: _selectedSubtitleTrack == null,
                                onTap: () {
                                  setState(() {
                                    _selectedSubtitleTrack = null;
                                  });
                                  updateDialog(() {});
                                },
                              ),
                              _TrackPickerOption(
                                icon: YingjiIcons.captions_bubble,
                                title: '关闭字幕',
                                detail: '播放时不加载字幕轨道',
                                selected: _selectedSubtitleTrack == -1,
                                onTap: () {
                                  setState(() {
                                    _selectedSubtitleTrack = -1;
                                  });
                                  updateDialog(() {});
                                },
                              ),
                              for (final track in resource.subtitleTracks)
                                _TrackPickerOption(
                                  icon: YingjiIcons.captions_bubble,
                                  title: track.title,
                                  detail: _trackSummary(track),
                                  badge: track.isDefault ? '默认' : null,
                                  selected:
                                      _selectedSubtitleTrack == track.index,
                                  onTap: () {
                                    setState(() {
                                      _selectedSubtitleTrack = track.index;
                                    });
                                    updateDialog(() {});
                                  },
                                ),
                            ],
                          );
                          if (constraints.maxWidth < 680) {
                            return YingjiSmoothWheel(
                              controller: _compactTrackPickerScroll,
                              child: ListView(
                                controller: _compactTrackPickerScroll,
                                physics:
                                    yingjiWheelPhysics ??
                                    const BouncingScrollPhysics(
                                      parent: AlwaysScrollableScrollPhysics(),
                                    ),
                                children: [
                                  SizedBox(height: 360, child: audio),
                                  const SizedBox(height: 14),
                                  SizedBox(height: 360, child: subtitles),
                                ],
                              ),
                            );
                          }
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: audio),
                              const SizedBox(width: 14),
                              Expanded(child: subtitles),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ignore: unused_element
  Future<void> _showMore(TmdbItem item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      sheetAnimationStyle: MovaMotion.dialogAnimationStyle(context),
      backgroundColor: YingjiGlass.surface(strength: 1.15),
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(YingjiIcons.doc_on_doc),
              title: const Text('复制片名'),
              onTap: () => Navigator.pop(context, 'copy'),
            ),
            ListTile(
              leading: const Icon(YingjiIcons.rectangle_stack_badge_plus),
              title: const Text('加入片单'),
              onTap: () => Navigator.pop(context, 'playlist'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: item.title));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已复制片名')));
      }
    } else if (action == 'playlist') {
      await _addToPlaylist(item);
    }
  }

  String _trackSummary(MediaTrack track) => [
    track.codec.toUpperCase(),
    if (track.language?.isNotEmpty == true) track.language!,
    if (track.channels != null) '${track.channels} 声道',
    if (track.sampleRate != null) '${track.sampleRate} Hz',
  ].join(' · ');

  /// 资源版本概要：分辨率 · 色彩范围 · 码率 · 大小。原生资源面板的明细行、
  /// 应用内播放器的资源标签共用这一份；缺哪项就跳过哪项，不画假数据。
  String _resourceSummary(MediaItem resource) => [
    if (resource.width != null && resource.height != null)
      '${resource.width}×${resource.height}',
    if (resource.videoRange?.isNotEmpty == true)
      _videoRangeLabel(resource.videoRange!),
    if (resource.bitrate != null)
      '${(resource.bitrate! / 1000000).toStringAsFixed(1)} Mbps',
    if (resource.size != null && resource.size! > 0)
      _fileSizeLabel(resource.size!),
  ].join(' · ');

  /// Emby / Jellyfin 的 VideoRangeType 取值五花八门（DOVIWithHDR10 之类），
  /// 统一收敛成面板能放下的短标签；未知取值原样展示，总好过消失。
  String _videoRangeLabel(String range) {
    final value = range.trim().toUpperCase();
    if (value.contains('DOVI') || value.contains('DOLBY') || value == 'DV') {
      return '杜比视界';
    }
    if (value.contains('HDR10+')) return 'HDR10+';
    if (value.contains('HDR')) return 'HDR10';
    if (value.contains('HLG')) return 'HLG';
    return value;
  }

  String _fileSizeLabel(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(bytes / (1024 * 1024)).round()} MB';
  }

  /// 资源版本在「全部已连接服务器」聚合列表里的稳定标识。同一台服务器上的同一
  /// 集，使用来源、条目与 MediaSourceId 区分版本；图标与名次按它对齐。
  String _resourceKey(MediaItem version) => version.resourceKey;

  /// 原生资源面板的兜底标记编号，与 `ServerMark` 的配色一一对应：
  /// Emby 绿、Jellyfin 紫、WebDAV 蓝。图标文件取不到时才用得上。
  int _serverMarkOf(MediaSource source) => switch (source.kind) {
    SourceKind.emby => 1,
    SourceKind.jellyfin => 2,
    SourceKind.webdav => 3,
  };

  /// 该集总时长（秒）。服务器给的时长最准，TMDB 的分钟数只在服务器没报时兜底，
  /// 两者都没有就返回 null —— 原生卡片会省掉进度条，而不是画一条假的。
  int? _episodeSeconds(MediaItem episode, TmdbEpisode? metadata) {
    final runtime = episode.runtime;
    if (runtime != null && runtime > Duration.zero) return runtime.inSeconds;
    final minutes = metadata?.runtime;
    return minutes != null && minutes > 0 ? minutes * 60 : null;
  }

  /// 「资源」的候选版本：当前剧集在**全部已连接服务器**上的条目，遵循详情页
  /// 当前排序条件。原生「资源」面板与 Flutter 播放页共用这一份顺序。
  /// 返回条目本身（而不是 PlayerResourceOption），因为重新起播还需要 headers、
  /// videoRange、时长等字段，只有 URL 是重建不出来的。
  List<MediaItem> _resourceVersionsFor(MediaItem episode) {
    return _sortResourceVersions(
      _resources,
      seasonNumber: episode.seasonNumber,
      episodeNumber: episode.episodeNumber,
    );
  }

  List<MediaItem> _sortResourceVersions(
    Iterable<MediaItem> resources, {
    required int? seasonNumber,
    required int? episodeNumber,
  }) {
    final rows = resources
        .where(
          (candidate) =>
              candidate.playbackUrl != null &&
              candidate.seasonNumber == seasonNumber &&
              candidate.episodeNumber == episodeNumber,
        )
        .toList();
    return sortedResourceVersions(rows, _resourceSort);
  }

  List<PlayerResourceOption> _playerResourcesFor(MediaItem episode) {
    return _playerResourceOptions(
      _resources,
      seasonNumber: episode.seasonNumber,
      episodeNumber: episode.episodeNumber,
    );
  }

  List<PlayerResourceOption> _playerResourceOptions(
    Iterable<MediaItem> resources, {
    required int? seasonNumber,
    required int? episodeNumber,
  }) {
    return _sortResourceVersions(
          resources,
          seasonNumber: seasonNumber,
          episodeNumber: episodeNumber,
        )
        .map(
          (candidate) => PlayerResourceOption(
            url: candidate.playbackUrl!.toString(),
            headers: candidate.headers,
            label: [
              candidate.source.name,
              _resourceSummary(candidate),
            ].where((value) => value.isNotEmpty).join(' · '),
            sourceId: candidate.source.id,
            serverItemId: candidate.id,
            source: candidate.source,
            videoRange: candidate.videoRange,
          ),
        )
        .toList(growable: false);
  }

  @override
  void dispose() {
    _pageScroll.removeListener(_syncPageBackdropDepth);
    WatchStateStore.revision.removeListener(_refreshLocalProgress);
    _pageBackdropDepth.dispose();
    _pageScroll.dispose();
    _playlistPickerScroll.dispose();
    _resourcePickerScroll.dispose();
    _compactTrackPickerScroll.dispose();
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: YingjiColors.canvas,
    body: FutureBuilder<TmdbItem>(
      future: _details,
      builder: (context, snapshot) {
        final item = snapshot.data?.id == widget.item.id
            ? snapshot.data!
            : widget.item;
        // 整页隔离成独立图层：页面转场（透明度 / 位移）时可直接复用已光栅化的
        // 结果，不必每帧重绘全屏背景、阴影与玻璃模糊 —— 窗口越大越省。
        return RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (item.backdropUrl != null)
                      // 详情页背景与首页同一套逻辑：**顶部是清晰的海报，往下滚才
                      // 逐渐变糊**。以前这里是无条件 `blur(glassBlur * .5)`，一进
                      // 详情页背景就已经糊死，和首页的观感对不上；现在深度由
                      // [yingjiScrollDepth] 给出，清晰层与固定模糊层叠加。
                      // 滚动时实时更新混合比例，不重新计算模糊强度。
                      Stack(
                        fit: StackFit.expand,
                        children: [
                          RepaintBoundary(
                            child: CachedNetworkImage(
                              key: const ValueKey('detail-clear-backdrop'),
                              imageUrl: item.backdropUrl.toString(),
                              useOldImageOnUrlChange: true,
                              fit: BoxFit.cover,
                              // 默认 500ms 淡入会让全屏大图逐帧做 alpha 合成
                              // （正好压在进页面的转场上），背景直接显示。
                              fadeInDuration: Duration.zero,
                              fadeOutDuration: Duration.zero,
                              memCacheWidth: 1280,
                              errorWidget: (_, _, _) => const SizedBox.shrink(),
                            ),
                          ),
                          ValueListenableBuilder<double>(
                            valueListenable: _pageBackdropDepth,
                            builder: (context, depth, blurred) =>
                                Opacity(opacity: depth, child: blurred),
                            child: AnimatedBuilder(
                              animation: yingjiAppearance,
                              builder: (context, _) => RepaintBoundary(
                                child: LayoutBuilder(
                                  builder: (context, size) =>
                                      PreblurredBackdrop(
                                        key: ValueKey(
                                          'detail-blur-${item.backdropUrl}',
                                        ),
                                        viewport: size.biggest,
                                        sigma: YingjiGlass.blur,
                                        image: ResizeImage(
                                          CachedNetworkImageProvider(
                                            item.backdropUrl.toString(),
                                          ),
                                          // 反正会被糊掉：模糊拉得很低时这层不再是
                                          // 「氛围光」，改按原分辨率解码，免得出现一层
                                          // 低清放大图压在清晰背景上的发虚重影。
                                          width: YingjiGlass.blur >= 10
                                              ? 320
                                              : 1280,
                                          height: YingjiGlass.blur >= 10
                                              ? 320
                                              : 1280,
                                          policy: ResizeImagePolicy.fit,
                                        ),
                                      ),
                                ),
                              ),
                            ),
                          ),
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                center: Alignment.topRight,
                                radius: 1.15,
                                colors: [Color(0x553B6A4D), Color(0x9907090D)],
                              ),
                            ),
                          ),
                          // 下滑时整体再压暗一档，保证滚动进来的卡片、文字
                          // 始终压得住海报（与首页 depth 驱动压暗同一目的）。
                          ValueListenableBuilder<double>(
                            valueListenable: _pageBackdropDepth,
                            child: const ColoredBox(color: Colors.black),
                            builder: (context, depth, shade) =>
                                Opacity(opacity: .12 * depth, child: shade),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              SafeArea(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned.fill(
                      child: YingjiSmoothWheel(
                        controller: _pageScroll,
                        // 桌面详情页外层同时移动背景、海报货架和多个玻璃面；
                        // 暂停这些玻璃面的背板采样，避免滚轮期间每帧重复合成。
                        // Android 保留现有材质策略；“全部剧集”弹窗另有稳定玻璃范围。
                        stableGlass: !WindowHost.isDesktop,
                        child: ListView(
                          controller: _pageScroll,
                          scrollCacheExtent: const ScrollCacheExtent.pixels(
                            900,
                          ),
                          // 桌面端交出滚轮处理权，改由 YingjiSmoothWheel
                          // 平滑驱动；移动端保持原有的回弹手感。
                          physics:
                              yingjiWheelPhysics ??
                              const BouncingScrollPhysics(
                                parent: AlwaysScrollableScrollPhysics(),
                              ),
                          padding: EdgeInsets.fromLTRB(
                            YingjiLayout.pageLeft,
                            92,
                            YingjiLayout.pageRight,
                            80,
                          ),
                          children: [
                            _DetailHeroCopy(
                              item: item,
                              selected: _selectedResource,
                              loading: _loadingResources,
                              inWatchlist: _inWatchlist,
                              favorite: _isFavorite,
                              onPlay: () => _play(context, item),
                              onWatchlist: () async {
                                final store = _watchlist;
                                if (store == null) return;
                                await store.toggle(item);
                                if (!mounted) return;
                                setState(() => _inWatchlist = !_inWatchlist);
                                try {
                                  await synchronizeTraktWatchlist(store);
                                } catch (error) {
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Mova 已更新，Trakt 同步失败：${error.toString().replaceFirst('Exception: ', '')}',
                                      ),
                                    ),
                                  );
                                }
                              },
                              onFavorite: _toggleFavorite,
                            ),
                            const SizedBox(height: 32),
                            if (item.kind == '剧集' &&
                                (_catalogSeasons.isNotEmpty ||
                                    _resources.isNotEmpty)) ...[
                              _SeasonRail(
                                resources: _resources,
                                catalogSeasons: _catalogSeasons,
                                posters: _seasonPosters,
                                selectedSeason: _selectedSeason,
                                onSelect: _selectSeason,
                              ),
                              const SizedBox(height: 24),
                              if (_catalogEpisodeChoices.isNotEmpty)
                                _CatalogEpisodeRail(
                                  episodes: _catalogEpisodeChoices,
                                  selectedEpisode: _selectedEpisodeNumber,
                                  progress: _episodeProgress,
                                  timings: {
                                    for (final episode
                                        in _catalogEpisodeChoices)
                                      _episodeKey(
                                        episode.seasonNumber,
                                        episode.episodeNumber,
                                      ): _catalogWatchTime(
                                        episode,
                                      ),
                                  },
                                  onSelect: _selectCatalogEpisode,
                                  onPlay: (episode) =>
                                      _playSelectedCatalogEpisode(
                                        context,
                                        episode,
                                      ),
                                  onMarkPlayed: _setCatalogEpisodeCompleted,
                                )
                              else if (_resources.isNotEmpty)
                                _EpisodePreviewRail(
                                  resources: _episodeChoices,
                                  selected: _selectedResource,
                                  completedResourceIds: _completedResourceIds,
                                  metadata: _episodeMetadata,
                                  episodeProgress: _episodeProgress,
                                  onMarkPlayed: _setEpisodeCompleted,
                                  onSelect: _selectEpisode,
                                ),
                              const SizedBox(height: 30),
                            ],
                            _ResourceSection(
                              sort: _resourceSort,
                              onSortChanged: _selectResourceSort,
                              resources: _visibleResources,
                              selected: _selectedResource,
                              loading: _loadingResources,
                              error: _resourceError,
                              onRetry: () => item.kind == '剧集' && item.id > 0
                                  ? _searchSelectedEpisode(force: true)
                                  : _loadResources(force: true),
                              onPicker: (resource) =>
                                  _showResourcePicker(source: resource.source),
                              onSelect: (resource) =>
                                  setState(() => _selectedResource = resource),
                            ),
                            const SizedBox(height: 18),
                            _ResourceDetailsPanel(
                              item: item,
                              resource: _selectedResource,
                              selectedAudioTrack: _selectedAudioTrack,
                              selectedSubtitleTrack: _selectedSubtitleTrack,
                              onSelectTracks: _showTrackPicker,
                            ),
                            const SizedBox(height: 36),
                            if (item.kind == '电影')
                              _MovieCollectionSection(
                                extras: _extras,
                                currentId: item.id,
                                onSelect: widget.onCollectionMovieSelected,
                              ),
                            _DetailExtrasSection(extras: _extras),
                          ],
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.topCenter,
                      child: RepaintBoundary(
                        child: _DetailTopBar(
                          onBack: () => Navigator.pop(context),
                          onSearch: () => _showResourceSearch(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  Future<void> _play(BuildContext context, TmdbItem item) async {
    final resource = _selectedResource;
    if (resource == null || resource.playbackUrl == null) return;
    final watchStore = await WatchStateStore.create();
    final saved = _localWatch(resource, watchStore.load());
    final remotePosition = resource.playbackPosition ?? Duration.zero;
    final savedPosition = saved?.position ?? Duration.zero;
    var resumePosition = saved != null ? savedPosition : remotePosition;
    if (saved?.isCompleted == true) resumePosition = Duration.zero;
    if (!context.mounted) return;
    // 展示目录来自全部季/集元数据，不以当前只搜索过资源的集数裁剪列表。
    // 对没有 URL 的目录项，用户选中后才触发该集的服务器聚合。
    final episodeOptions = _playerEpisodeCatalog(resource);
    void mergeEpisodeCatalog() {
      final merged = {for (final option in episodeOptions) option.key: option};
      for (final fresh in _playerEpisodeCatalog(resource)) {
        final previous = merged[fresh.key];
        merged[fresh.key] = _PlaybackEpisodeOption(
          seasonNumber: fresh.seasonNumber,
          episodeNumber: fresh.episodeNumber,
          metadata: fresh.metadata ?? previous?.metadata,
          resource: fresh.resource ?? previous?.resource,
        );
      }
      episodeOptions
        ..clear()
        ..addAll(merged.values)
        ..sort((a, b) {
          final season = (a.seasonNumber ?? 0).compareTo(b.seasonNumber ?? 0);
          return season == 0
              ? (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0)
              : season;
        });
    }

    PlayerEpisode playerEpisode(
      _PlaybackEpisodeOption option, {
      MediaItem? overrideResource,
      Duration initialPosition = Duration.zero,
    }) {
      final episode = overrideResource ?? option.resource;
      final savedSeconds = episodeResumeSeconds(
        progress: _episodeProgress[option.key],
        duration: episode == null
            ? (option.metadata?.runtime == null
                  ? null
                  : option.metadata!.runtime! * 60)
            : _episodeSeconds(episode, option.metadata),
      );
      final progressPosition = savedSeconds == null
          ? Duration.zero
          : Duration(milliseconds: (savedSeconds * 1000).round());
      final resourcePosition =
          episode == null ||
              _episodeProgress.containsKey(option.key) ||
              _mediaProgress(episode) >= .95
          ? Duration.zero
          : episode.playbackPosition ?? Duration.zero;
      final resumePosition = [
        initialPosition,
        progressPosition,
        resourcePosition,
      ].reduce((a, b) => a > b ? a : b);
      final episodeTitle = _catalogEpisodeTitle(
        option,
        seriesTitle: item.title,
      );
      return PlayerEpisode(
        url: episode?.playbackUrl?.toString() ?? '',
        title: item.title,
        headers: episode?.headers ?? const {},
        initialPosition: resumePosition,
        imageUrl: (_catalogEpisodeImage(option) ?? item.posterUrl)?.toString(),
        seriesLogoUrl: item.logoUrl?.toString(),
        episodeTitle: episodeTitle,
        resourceInfo: episode == null
            ? '选择后搜索服务器资源'
            : [
                episode.source.name,
                _resourceSummary(episode),
              ].where((value) => value.isNotEmpty).join(' · '),
        videoRange: episode?.videoRange,
        sourceId: episode?.source.id,
        serverItemId: episode?.id,
        tmdbId: item.id,
        seasonNumber: option.seasonNumber,
        episodeNumber: option.episodeNumber,
        chapters: episode?.chapters ?? const [],
        initialAudioTrack: _selectedAudioTrack,
        initialSubtitleTrack: _selectedSubtitleTrack,
        resources: episode == null ? const [] : _playerResourcesFor(episode),
      );
    }

    Future<PlayerEpisode?> resolvePlayerEpisode(
      int season,
      int episode,
      void Function(List<PlayerResourceOption> resources) onResourcesChanged,
    ) async {
      if (!mounted) return null;
      setState(() {
        _selectedSeason = season;
        _selectedEpisodeNumber = episode;
      });
      mergeEpisodeCatalog();
      // Episode metadata enriches the catalog but is not required to resolve
      // the stream URL, so fetch it alongside the server search.
      unawaited(
        _loadCatalogSeason(season).then((_) {
          if (!mounted || _selectedSeason != season) return;
          mergeEpisodeCatalog();
        }),
      );
      final selected = await _searchSelectedEpisodeForPlayback(
        preferredSourceId: resource.source.id,
        onResourcesPublished: (rows) {
          final target = rows
              .where(
                (row) =>
                    row.seasonNumber == season &&
                    row.episodeNumber == episode &&
                    row.playbackUrl != null,
              )
              .firstOrNull;
          if (target != null) {
            onResourcesChanged(
              _playerResourceOptions(
                rows,
                seasonNumber: season,
                episodeNumber: episode,
              ),
            );
          }
        },
      );
      if (!mounted || _selectedSeason != season) return null;
      mergeEpisodeCatalog();
      if (selected?.seasonNumber != season ||
          selected?.episodeNumber != episode ||
          selected?.playbackUrl == null) {
        return null;
      }
      final key = _episodeKey(season, episode);
      final index = episodeOptions.indexWhere((option) => option.key == key);
      final option = _PlaybackEpisodeOption(
        seasonNumber: season,
        episodeNumber: episode,
        metadata: _episodeMetadata[key],
        resource: selected,
      );
      if (index >= 0) episodeOptions[index] = option;
      onResourcesChanged(
        _playerResourceOptions(
          _resources,
          seasonNumber: season,
          episodeNumber: episode,
        ),
      );
      return playerEpisode(option, overrideResource: selected);
    }

    if (await useAndroidExoPlayer()) {
      if (!context.mounted) return;
      try {
        await Navigator.push<void>(
          context,
          MaterialPageRoute<void>(
            builder: (_) => PlayerPage(
              url: resource.playbackUrl.toString(),
              title: item.title,
              initialPosition: resumePosition,
              imageUrl: resource.imageUrl?.toString(),
              sourceId: resource.source.id,
              serverItemId: resource.id,
              episodeTitle: resource.title,
              seasonNumber: resource.seasonNumber,
              episodeNumber: resource.episodeNumber,
              headers: resource.headers,
              container: resource.container,
              episodes: episodeOptions
                  .map((option) => playerEpisode(option))
                  .toList(growable: false),
              onResolveEpisode: resolvePlayerEpisode,
              androidExo: true,
            ),
          ),
        );
        await _refreshProgressAfterPlayback();
        return;
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('播放失败，可在设置中切换 mpv：$error')));
        }
        await _refreshProgressAfterPlayback();
        return;
      }
    }
    if (!context.mounted) return;
    if (WindowHost.isDesktop) {
      // Resolve resource identity/headers in the app; load the new source in the
      // existing native window instead of closing and launching another process.
      var available = _resourceVersionsFor(resource);
      var activeResource = resource;
      var startAt = resumePosition;
      // 剧集面板要逐集显示剧照，资源面板要显示服务器图标 —— 两样都必须由应用侧
      // 先取好：原生不联网，也不该持有令牌。图落到本地磁盘缓存后只把路径下发。
      // 目录海报只需缓存一次；新选中的季加载元数据后会补缓存该季剧照。
      Future<Map<String, String?>> cacheEpisodeImages() =>
          WindowsNativePlayer.cachedImageFiles({
            for (final option in episodeOptions)
              option.key: (_catalogEpisodeImage(option) ?? item.posterUrl)
                  ?.toString(),
          });
      var episodeImages = await cacheEpisodeImages();
      WindowsNativePlaylistEntry nativeEntry(
        _PlaybackEpisodeOption option, {
        MediaItem? overrideResource,
      }) {
        final episode = overrideResource ?? option.resource;
        final key = option.key;
        final metadata = option.metadata;
        final seconds = episode == null
            ? (metadata?.runtime == null ? null : metadata!.runtime! * 60)
            : _episodeSeconds(episode, metadata);
        final progress = _episodeProgress[key];
        // 这一集自己该从哪儿起播（规则见 episodeResumeSeconds 的注释）。
        final resume = episodeResumeSeconds(
          progress: progress,
          duration: seconds,
        );
        return WindowsNativePlaylistEntry(
          url: episode?.playbackUrl?.toString() ?? '',
          title: episode?.title ?? item.title,
          headers: episode?.headers ?? const {},
          // 单集剧照缺失是常态：TMDB 剧照优先（与详情页同一套规则），
          // 再退到剧集海报，避免继续观看卡片沦为字母占位块。
          imageUrl: (_catalogEpisodeImage(option) ?? item.posterUrl)
              ?.toString(),
          sourceId: episode?.source.id,
          serverItemId: episode?.id,
          tmdbId: item.id,
          episodeTitle: _catalogEpisodeTitle(option, seriesTitle: item.title),
          seasonNumber: option.seasonNumber,
          episodeNumber: option.episodeNumber,
          imagePath: episodeImages[key],
          progress: progress,
          duration: seconds,
          watched:
              (progress ?? 0) >= .95 ||
              (episode != null && _completedResourceIds.contains(episode.id)),
          resumeSeconds: resume,
          meta: [
            if (metadata?.airDate case final date?)
              '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
            if ((metadata?.runtime ?? 0) > 0) '${metadata!.runtime} 分钟',
          ].join(' · '),
        );
      }

      Future<WindowsNativePlaylistEntry?> prepareNativeEpisode(
        int season,
        int episode,
      ) async {
        final current = activeResource;
        final source = current.source;
        if (!mounted || source.kind == SourceKind.webdav) return null;
        final store = await SourceStore.create();
        final token = store.tokenFor(source);
        if (token == null || token.isEmpty) return null;
        final client = EmbyClient(
          proxy: ProxyRouting.serverUsesProxy(source.id),
        );
        try {
          final session = await client.resolveSession(
            EmbySession(source: source, token: token),
          );
          final seriesId = current.seriesId;
          if (seriesId == null || seriesId.isEmpty) return null;
          final rows = await client.episodesForSeries(
            session,
            seriesId,
            seasonNumber: season,
            episodeNumber: episode,
          );
          if (!mounted) return null;
          final resource = rows
              .where(
                (row) =>
                    row.playbackUrl != null &&
                    row.seasonNumber == season &&
                    row.episodeNumber == episode,
              )
              .firstOrNull;
          final option = episodeOptions
              .where(
                (option) =>
                    option.seasonNumber == season &&
                    option.episodeNumber == episode,
              )
              .firstOrNull;
          if (resource == null || option == null) return null;
          return nativeEntry(option, overrideResource: resource);
        } finally {
          client.dispose();
        }
      }

      Future<WindowsNativePlaylistEntry?> resolveNativeEpisode(
        int season,
        int episode,
        void Function(List<WindowsNativeResourceOption>, int)
        onResourcesChanged,
      ) async {
        if (!mounted) return null;
        setState(() {
          _selectedSeason = season;
          _selectedEpisodeNumber = episode;
        });
        mergeEpisodeCatalog();
        unawaited(
          _loadCatalogSeason(season).then((_) {
            if (!mounted || _selectedSeason != season) return;
            mergeEpisodeCatalog();
          }),
        );

        var resourceRevision = 0;
        List<MediaItem> latestRows = const [];
        void publishResources(List<MediaItem> rows, MediaItem current) {
          final versions = _sortResourceVersions(
            rows,
            seasonNumber: season,
            episodeNumber: episode,
          );
          if (versions.isEmpty) return;
          // Keep the caller's index-to-resource mapping in lockstep with the
          // incrementally refreshed native menu, including after this search
          // callback has already returned to playback.
          available = versions;
          final currentIndex = versions.indexWhere(
            (version) => version.resourceKey == current.resourceKey,
          );
          final revision = ++resourceRevision;
          unawaited(() async {
            final icons = await Future.wait(
              versions.map((version) async {
                try {
                  return await cacheServerMarkFile(
                    version.source,
                    version.headers['X-Emby-Token'],
                  );
                } catch (_) {
                  return null;
                }
              }),
            );
            if (!mounted || revision != resourceRevision) return;
            onResourcesChanged([
              for (var index = 0; index < versions.length; index++)
                WindowsNativeResourceOption(
                  source: versions[index].source.name,
                  detail: _resourceSummary(versions[index]),
                  iconPath: icons[index],
                  mark: _serverMarkOf(versions[index].source),
                  rank: index < 3 ? index + 1 : 0,
                ),
            ], currentIndex < 0 ? 0 : currentIndex);
          }());
        }

        final selected = await _searchSelectedEpisodeForPlayback(
          preferredSourceId: activeResource.source.id,
          onResourcesPublished: (rows) {
            latestRows = rows;
            final current = _selectedResource;
            if (current != null &&
                current.seasonNumber == season &&
                current.episodeNumber == episode) {
              publishResources(rows, current);
            }
          },
        );
        if (selected == null || !mounted || _selectedSeason != season) {
          return null;
        }
        publishResources(latestRows, selected);
        final key = _episodeKey(season, episode);
        final optionIndex = episodeOptions.indexWhere(
          (option) => option.key == key,
        );
        if (optionIndex < 0) return null;
        activeResource = selected;
        available = _resourceVersionsFor(selected);
        final option = episodeOptions[optionIndex];
        return nativeEntry(option, overrideResource: selected);
      }

      while (true) {
        available = _resourceVersionsFor(activeResource);
        var activeIndex = available.indexWhere(
          (candidate) => candidate.resourceKey == activeResource.resourceKey,
        );
        if (activeIndex < 0) {
          available = <MediaItem>[activeResource, ...available];
          activeIndex = 0;
        }
        final ranks = <String, int>{
          for (var index = 0; index < available.length && index < 3; index++)
            _resourceKey(available[index]): index + 1,
        };
        final resourceIcons = <String, String?>{};
        await Future.wait<void>(
          available.map((version) async {
            resourceIcons[_resourceKey(version)] = await cacheServerMarkFile(
              version.source,
              version.headers['X-Emby-Token'],
            );
          }),
        ).timeout(const Duration(seconds: 4), onTimeout: () => <void>[]);
        final activeKey = _episodeKey(
          activeResource.seasonNumber,
          activeResource.episodeNumber,
        );
        final playlist = episodeOptions
            .map(
              (option) => nativeEntry(
                option,
                overrideResource: option.key == activeKey
                    ? activeResource
                    : null,
              ),
            )
            .toList(growable: false);
        final activeMetadata =
            _episodeMetadata[_episodeKey(
              activeResource.seasonNumber,
              activeResource.episodeNumber,
            )];
        try {
          final result = await WindowsNativePlayer.play(
            WindowsNativePlaybackRequest(
              url: activeResource.playbackUrl.toString(),
              title: item.title,
              headers: activeResource.headers,
              initialPosition: startAt,
              imageUrl:
                  (_episodeImage(activeResource, activeMetadata) ??
                          item.posterUrl)
                      ?.toString(),
              seriesLogoUrl: item.logoUrl?.toString(),
              sourceId: activeResource.source.id,
              serverItemId: activeResource.id,
              tmdbId: item.id,
              episodeTitle: _episodeTitle(
                activeResource,
                activeMetadata,
                activeResource.episodeNumber ?? 1,
                seriesTitle: item.title,
              ),
              seasonNumber: activeResource.seasonNumber,
              episodeNumber: activeResource.episodeNumber,
              videoRange: activeResource.videoRange,
              initialAudioTrack: _selectedAudioTrack,
              initialSubtitleTrack: _selectedSubtitleTrack,
              playlist: playlist,
              playlistIndex: playlist.indexWhere(
                (episode) =>
                    _episodeKey(episode.seasonNumber, episode.episodeNumber) ==
                    activeKey,
              ),
              resources: available
                  .map(
                    (version) => WindowsNativeResourceOption(
                      source: version.source.name,
                      detail: _resourceSummary(version),
                      iconPath: resourceIcons[_resourceKey(version)],
                      mark: _serverMarkOf(version.source),
                      rank: ranks[_resourceKey(version)] ?? 0,
                    ),
                  )
                  .toList(growable: false),
              resourceIndex: activeIndex,
              onEpisodeMark: (index, completed) async {
                if (index < 0 || index >= episodeOptions.length) return;
                final option = episodeOptions[index];
                if (option.metadata != null) {
                  await _setCatalogEpisodeCompleted(
                    option.metadata!,
                    completed,
                  );
                } else if (option.resource != null) {
                  await _setEpisodeCompleted(option.resource!, completed);
                }
              },
              onResolveEpisode: resolveNativeEpisode,
              onResolveResource: (index) async {
                if (!mounted || index < 0 || index >= available.length) {
                  return null;
                }
                final selected = available[index];
                final key = _episodeKey(
                  selected.seasonNumber,
                  selected.episodeNumber,
                );
                final option =
                    episodeOptions
                        .where((option) => option.key == key)
                        .firstOrNull ??
                    _PlaybackEpisodeOption(
                      seasonNumber: selected.seasonNumber,
                      episodeNumber: selected.episodeNumber,
                      resource: selected,
                    );
                activeResource = selected;
                return nativeEntry(option, overrideResource: selected);
              },
              onPrepareEpisode: prepareNativeEpisode,
            ),
          );
          final requestedSeason = result.episodeSeason;
          final requestedEpisode = result.episodeNumber;
          if (requestedSeason != null && requestedEpisode != null) {
            if (context.mounted) {
              setState(() {
                _selectedSeason = requestedSeason;
                _selectedEpisodeNumber = requestedEpisode;
              });
            }
            await _loadCatalogSeason(requestedSeason);
            if (!context.mounted) break;
            mergeEpisodeCatalog();
            await _searchSelectedEpisode();
            if (!context.mounted) break;
            mergeEpisodeCatalog();
            final selected = _selectedResource;
            final found =
                selected?.seasonNumber == requestedSeason &&
                selected?.episodeNumber == requestedEpisode &&
                selected?.playbackUrl != null;
            if (found) {
              activeResource = selected!;
              final savedNext = _localWatch(activeResource, watchStore.load());
              final remoteNext =
                  activeResource.playbackPosition ?? Duration.zero;
              final savedPositionNext = savedNext?.position ?? Duration.zero;
              startAt = savedNext != null ? savedPositionNext : remoteNext;
              if (savedNext?.isCompleted == true) startAt = Duration.zero;
              final key = _episodeKey(requestedSeason, requestedEpisode);
              final index = episodeOptions.indexWhere(
                (option) => option.key == key,
              );
              if (index >= 0) {
                episodeOptions[index] = _PlaybackEpisodeOption(
                  seasonNumber: requestedSeason,
                  episodeNumber: requestedEpisode,
                  metadata: _episodeMetadata[key],
                  resource: activeResource,
                );
              }
              episodeImages = await cacheEpisodeImages();
              continue;
            }
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('该集未找到可播放资源，已返回当前集')),
              );
            }
            startAt = result.episodePosition ?? startAt;
            continue;
          }
          final picked = result.resourceIndex;
          if (picked == null || picked < 0 || picked >= available.length) {
            break;
          }
          activeResource = available[picked];
          activeIndex = picked;
          // 接着刚才的位置继续，而不是从这一集的开头重放。
          startAt = result.resourcePosition ?? startAt;
        } catch (error) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Windows 原生播放器启动失败：$error')));
          }
          break;
        }
      }
      await _refreshProgressAfterPlayback();
      return;
    }
    if (!context.mounted) return;
    await Navigator.push<void>(
      context,
      PageRouteBuilder<void>(
        opaque: true,
        allowSnapshotting: false,
        transitionDuration: const Duration(milliseconds: 280),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, _, _) => PlayerPage(
          url: resource.playbackUrl.toString(),
          title: item.title,
          seriesLogoUrl: item.logoUrl?.toString(),
          episodeTitle: resource.title,
          resourceInfo: [
            resource.source.name,
            _resourceSummary(resource),
          ].where((value) => value.isNotEmpty).join(' · '),
          videoRange: resource.videoRange,
          headers: resource.headers,
          imageUrl: resource.imageUrl?.toString(),
          sourceId: resource.source.id,
          serverItemId: resource.id,
          seasonNumber: resource.seasonNumber,
          episodeNumber: resource.episodeNumber,
          chapters: resource.chapters,
          initialPosition: resumePosition,
          initialAudioTrack: _selectedAudioTrack,
          initialSubtitleTrack: _selectedSubtitleTrack,
          episodes: episodeOptions
              .map(
                (option) => playerEpisode(
                  option,
                  initialPosition:
                      option.key ==
                          _episodeKey(
                            resource.seasonNumber,
                            resource.episodeNumber,
                          )
                      ? resumePosition
                      : Duration.zero,
                ),
              )
              .toList(growable: false),
          onResolveEpisode: resolvePlayerEpisode,
        ),
        transitionsBuilder: (context, animation, _, child) {
          if (MediaQuery.disableAnimationsOf(context)) {
            return child;
          }
          if (WindowHost.isAndroid) {
            return FadeTransition(opacity: animation, child: child);
          }
          final curve = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curve,
            child: ScaleTransition(
              scale: Tween<double>(begin: .985, end: 1).animate(curve),
              child: RepaintBoundary(child: child),
            ),
          );
        },
      ),
    );
    // The player flushed its final position before popping; re-derive the
    // episode rails now so bars/completion reflect where playback stopped.
    await _refreshProgressAfterPlayback();
    final currentEpisodeResources = _resources
        .where(
          (candidate) =>
              candidate.seasonNumber == resource.seasonNumber &&
              candidate.episodeNumber == resource.episodeNumber,
        )
        .toList(growable: false);
    final preferred = await _preferredResource(currentEpisodeResources);
    if (mounted && preferred != null) {
      setState(() {
        _selectedResource = preferred;
        _selectedSeason = preferred.seasonNumber ?? _selectedSeason;
      });
    }
  }

  Future<void> _showResourceSearch(BuildContext context) async {
    final controller = TextEditingController();
    final query = await showDialog<String>(
      context: context,
      animationStyle: MovaMotion.dialogAnimationStyle(context),
      builder: (dialogContext) => AlertDialog(
        title: const Text('搜索资源'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入资源名称或来源'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('搜索'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (query == null || query.isEmpty || !context.mounted) return;
    final normalized = query.toLowerCase();
    final match = _resources.where((resource) {
      return resource.title.toLowerCase().contains(normalized) ||
          resource.source.name.toLowerCase().contains(normalized) ||
          (resource.container?.toLowerCase().contains(normalized) ?? false) ||
          (resource.videoCodec?.toLowerCase().contains(normalized) ?? false);
    }).firstOrNull;
    if (match == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('没有找到与“$query”匹配的资源')));
      return;
    }
    setState(() {
      _selectedResource = match;
      _selectedSeason = match.seasonNumber ?? _selectedSeason;
    });
  }
}

/// 详情页顶栏的小图标按钮。
class _DetailRailButton extends StatelessWidget {
  const _DetailRailButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });
  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) => YingjiMotionIconButton(
    icon: icon,
    tooltip: tooltip,
    size: YingjiLayout.railButtonSize,
    onPressed: onPressed,
  );
}

class _DetailTopBar extends StatelessWidget {
  const _DetailTopBar({required this.onBack, required this.onSearch});
  final VoidCallback onBack;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) => Padding(
    // 顶栏和正文直接使用同一个左锚点。
    padding: EdgeInsets.only(
      left: YingjiLayout.pageLeft,
      right: WindowHost.isDesktop ? 0 : 14,
    ),
    child: SizedBox(
      height: 82,
      child: Row(
        children: [
          YingjiMotionIconButton(
            icon: YingjiIcons.chevron_left,
            tooltip: '返回',
            onPressed: onBack,
            size: 44,
          ),
          const SizedBox(width: 14),
          // 用剩余宽度把搜索按钮推到最右。桌面端顺带当成窗口拖拽区；移动端
          // 没有窗口可拖，用普通占位——旧实现只在桌面端插这一段，安卓上
          // 搜索按钮就贴到了返回键右边。
          Expanded(
            child: WindowHost.isDesktop
                ? WindowHost.dragArea(child: const SizedBox.expand())
                : const SizedBox.expand(),
          ),
          _DetailRailButton(
            icon: YingjiIcons.search,
            tooltip: '搜索资源',
            onPressed: onSearch,
          ),
          if (WindowHost.isDesktop) ...[
            const SizedBox(width: 8),
            _DetailRailButton(
              icon: YingjiIcons.minus,
              tooltip: '最小化',
              onPressed: WindowHost.minimize,
            ),
            const SizedBox(width: 8),
            _DetailRailButton(
              icon: YingjiIcons.square,
              tooltip: '最大化或还原',
              onPressed: WindowHost.toggleMaximize,
            ),
            const SizedBox(width: 8),
            _DetailRailButton(
              icon: YingjiIcons.xmark,
              tooltip: '关闭窗口',
              onPressed: WindowHost.close,
            ),
            const SizedBox(width: 14),
          ],
        ],
      ),
    ),
  );
}

class _DetailHeroCopy extends StatelessWidget {
  const _DetailHeroCopy({
    required this.item,
    required this.selected,
    required this.loading,
    required this.inWatchlist,
    required this.favorite,
    required this.onPlay,
    required this.onWatchlist,
    required this.onFavorite,
  });
  final TmdbItem item;
  final MediaItem? selected;
  final bool loading;
  final bool inWatchlist;
  final bool favorite;
  final VoidCallback onPlay;
  final VoidCallback onWatchlist;
  final VoidCallback onFavorite;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        height: 118,
        width: 520,
        child: item.logoUrl == null
            ? Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 58,
                    height: .96,
                    letterSpacing: -1.6,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              )
            : CachedNetworkImage(
                fadeInDuration: const Duration(milliseconds: 150),
                imageUrl: item.logoUrl.toString(),
                alignment: Alignment.centerLeft,
                fit: BoxFit.contain,
                // 标题 logo 容器宽 520，按显示分辨率解码。
                memCacheWidth: (560 * MediaQuery.devicePixelRatioOf(context))
                    .clamp(1.0, 640.0)
                    .round(),
                errorWidget: (_, _, _) => Text(
                  item.title,
                  style: const TextStyle(
                    fontSize: 58,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (item.year != null) _DetailMetaChip('${item.year}'),
          _DetailMetaChip(item.kind),
          for (final genre in item.genres) _DetailMetaChip(genre),
        ],
      ),
      const SizedBox(height: 22),
      _DetailRatingRow(item: item),
      if (item.kind == '剧集') ...[
        const SizedBox(height: 10),
        NextEpisodeLabel(item: item),
      ],
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _DetailAction(
            icon: YingjiIcons.play_fill,
            label: selected?.playbackUrl == null ? '暂无可播放资源' : '播放',
            primary: true,
            enabled: selected?.playbackUrl != null,
            onPressed: onPlay,
          ),
          YingjiMotionIconButton(
            icon: YingjiIcons.bookmark,
            tooltip: inWatchlist ? '移出待看' : '加入待看',
            selected: inWatchlist,
            size: 46,
            onPressed: onWatchlist,
          ),
          YingjiMotionIconButton(
            icon: favorite ? YingjiIcons.heart_fill : YingjiIcons.heart,
            tooltip: favorite ? '取消收藏' : '收藏',
            selected: favorite,
            size: 46,
            onPressed: onFavorite,
          ),
        ],
      ),
      const SizedBox(height: 28),
      Text(
        '简介  ${item.title}',
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 10),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780),
        child: YingjiGlassTooltip(
          message: item.overview?.isNotEmpty == true
              ? item.overview!
              : '暂无剧情简介。',
          child: Text(
            item.overview?.isNotEmpty == true ? item.overview! : '暂无剧情简介。',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              height: 1.45,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
      if (loading) ...[
        const SizedBox(height: 10),
        const Text('正在匹配已连接媒体来源…', style: TextStyle(color: YingjiColors.muted)),
      ],
    ],
  );
}

class _DetailMetaChip extends StatelessWidget {
  const _DetailMetaChip(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: YingjiGlass.chrome(strength: .8),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Text(
        label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
    ),
  );
}

class _DetailRatingRow extends StatelessWidget {
  const _DetailRatingRow({required this.item});
  final TmdbItem item;
  @override
  Widget build(BuildContext context) =>
      MediaRatingRow(item: item, expanded: true);
}

class _DetailAction extends StatelessWidget {
  const _DetailAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.enabled = true,
  });
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool primary;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: _DetailActionSurface(
      icon: icon,
      label: label,
      primary: primary,
      enabled: enabled,
      onPressed: onPressed,
    ),
  );
}

class _DetailActionSurface extends StatefulWidget {
  const _DetailActionSurface({
    required this.icon,
    required this.label,
    required this.primary,
    required this.enabled,
    required this.onPressed,
  });
  final IconData icon;
  final String label;
  final bool primary;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  State<_DetailActionSurface> createState() => _DetailActionSurfaceState();
}

class _DetailActionSurfaceState extends State<_DetailActionSurface> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final active = _hovered && widget.enabled;
    final foreground = widget.primary ? Colors.black : Colors.white;
    return YingjiGlassTooltip(
      message: widget.label,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          onTapDown: widget.enabled
              ? (_) => setState(() => _pressed = true)
              : null,
          onTapUp: widget.enabled
              ? (_) => setState(() => _pressed = false)
              : null,
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.enabled ? widget.onPressed : null,
          child: AnimatedScale(
            scale: _pressed ? .965 : (active ? 1.018 : 1),
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 46,
              constraints: BoxConstraints(minWidth: widget.primary ? 236 : 116),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration: BoxDecoration(
                color: !widget.enabled
                    ? Colors.white24
                    : widget.primary
                    ? Colors.white
                    : YingjiGlass.chrome(strength: active ? .96 : .78),
                borderRadius: BorderRadius.circular(24),
                border: widget.primary
                    ? null
                    : Border.all(
                        color: YingjiGlass.line(strength: active ? 1.2 : 1),
                      ),
                boxShadow: active
                    ? const [
                        BoxShadow(
                          color: Color(0x55000000),
                          blurRadius: 18,
                          offset: Offset(0, 8),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(widget.icon, size: 17, color: foreground),
                  const SizedBox(width: 8),
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SeasonRail extends StatefulWidget {
  const _SeasonRail({
    required this.resources,
    required this.catalogSeasons,
    required this.posters,
    required this.selectedSeason,
    required this.onSelect,
  });
  final List<MediaItem> resources;
  final List<TmdbSeason> catalogSeasons;
  final Map<int, Uri> posters;
  final int? selectedSeason;
  final ValueChanged<int> onSelect;

  @override
  State<_SeasonRail> createState() => _SeasonRailState();
}

class _SeasonRailState extends State<_SeasonRail> {
  final ScrollController _controller = ScrollController();

  List<int> get _seasons => [
    ...widget.catalogSeasons.map((season) => season.number),
    ...widget.resources.map((item) => item.seasonNumber),
  ].whereType<int>().toSet().toList()..sort();

  void _centerSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_controller.hasClients) return;
      final selectedSeason = widget.selectedSeason;
      if (selectedSeason == null) return;
      final index = _seasons.indexOf(selectedSeason);
      if (index < 0) return;
      final viewport = _controller.position.viewportDimension;
      final target = (index * 126.0 - (viewport - 112) / 2).clamp(
        0.0,
        _controller.position.maxScrollExtent,
      );
      _controller.animateTo(
        target,
        duration: const Duration(milliseconds: 440),
        curve: Curves.easeOutBack,
      );
    });
  }

  @override
  void initState() {
    super.initState();
    _centerSelected();
  }

  @override
  void didUpdateWidget(covariant _SeasonRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedSeason != widget.selectedSeason) _centerSelected();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seasons = _seasons;
    if (seasons.length < 2) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '季',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
            ),
            const SizedBox(width: 12),
            Text(
              '${seasons.length} 季',
              style: const TextStyle(color: YingjiColors.muted),
            ),
            const Spacer(),
            const SizedBox(width: 7),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 232,
          child: YingjiSmoothWheel(
            controller: _controller,
            stableGlass: true,
            child: MovaHorizontalDrag(
              child: ListView.separated(
                controller: _controller,
                scrollDirection: Axis.horizontal,

                physics:
                    yingjiWheelPhysics ??
                    const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
                itemCount: seasons.length,
                separatorBuilder: (_, _) => const SizedBox(width: 16),
                itemBuilder: (context, index) {
                  final season = seasons[index];
                  final active = season == widget.selectedSeason;
                  final artwork = widget.posters[season];
                  return InkWell(
                    onTap: () => widget.onSelect(season),
                    borderRadius: BorderRadius.circular(14),
                    child: _DetailPosterHover(
                      selected: active,
                      borderRadius: 14,
                      child: SizedBox(
                        width: 140,
                        child: Column(
                          children: [
                            Expanded(
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 220),
                                clipBehavior: Clip.antiAlias,
                                decoration: BoxDecoration(
                                  color: const Color(0xCC1A1D22),
                                  borderRadius: BorderRadius.circular(14),
                                  // 选中态的白框只保留 _DetailPosterHover 的外层大框；
                                  // 这里再画一圈会形成双描边，未选中保留极淡的分界。
                                  border: Border.all(
                                    color: active
                                        ? Colors.transparent
                                        : Colors.white.withValues(alpha: .12),
                                    width: active ? 0 : 1,
                                  ),
                                  boxShadow: active
                                      ? const [
                                          BoxShadow(
                                            color: Color(0x66000000),
                                            blurRadius: 24,
                                            offset: Offset(0, 12),
                                          ),
                                        ]
                                      : null,
                                ),
                                child: artwork == null
                                    ? const Center(
                                        child: Icon(
                                          YingjiIcons.film,
                                          color: YingjiColors.muted,
                                        ),
                                      )
                                    // 放大 4% 再裁切：季海报素材四周常自带一圈
                                    // 5~7px 的暗边/暗角，不裁掉的话白描边（已严格
                                    // 贴住海报边缘，缝隙实测 0px）与画面之间仍会
                                    // 看成一条黑缝。4% 只吃掉边缘，画面损失极小。
                                    : Transform.scale(
                                        scale: 1.04,
                                        child: CachedNetworkImage(
                                          fadeInDuration: const Duration(
                                            milliseconds: 150,
                                          ),
                                          imageUrl: artwork.toString(),
                                          fit: BoxFit.cover,
                                          // 季海报显示宽 ~190，按物理像素解码即可，
                                          // 不必用原图——批量解码卡在进页面转场的最后一帧。
                                          memCacheWidth:
                                              (320 *
                                                      MediaQuery.devicePixelRatioOf(
                                                        context,
                                                      ))
                                                  .clamp(1.0, 512.0)
                                                  .round(),
                                          errorWidget: (_, _, _) =>
                                              const Center(
                                                child: Icon(YingjiIcons.film),
                                              ),
                                        ),
                                      ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '第 $season 季',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: active
                                    ? FontWeight.w800
                                    : FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// TMDB's real episode catalog is independent of server playback availability.
class _PublishedEpisodeNumbers extends StatelessWidget {
  const _PublishedEpisodeNumbers({
    required this.episodes,
    required this.selected,
    required this.onSelect,
    required this.controller,
  });
  final List<TmdbEpisode> episodes;
  final int? selected;
  final ValueChanged<TmdbEpisode> onSelect;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final published = episodes
        .where(
          (episode) =>
              episode.airDate != null && episode.airDate!.isBefore(tomorrow),
        )
        .toList(growable: false);
    if (published.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 48,
      child: MovaHorizontalDrag(
        child: ListView.separated(
          controller: controller,
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          itemCount: published.length,
          separatorBuilder: (_, _) => const SizedBox(width: 4),
          itemBuilder: (context, index) {
            final episode = published[index];
            return Center(
              child: Semantics(
                label: '第 ${episode.episodeNumber} 集，已发布',
                selected: selected == episode.episodeNumber,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Transform.scale(
                    scale: .82,
                    transformHitTests: false,
                    child: YingjiMotionSurface(
                      selected: selected == episode.episodeNumber,
                      borderRadius: 22,
                      child: YingjiGlassSurface(
                        circle: true,
                        depth: false,
                        strength: selected == episode.episodeNumber
                            ? 1.28
                            : .86,
                        child: InkWell(
                          onTap: () => onSelect(episode),
                          customBorder: const CircleBorder(),
                          child: Center(
                            child: Text(
                              '${episode.episodeNumber}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _EpisodeProgressOverlay extends StatelessWidget {
  const _EpisodeProgressOverlay({
    required this.progress,
    this.watch,
    this.duration,
    this.position,
  });
  final double progress;
  final WatchState? watch;
  final Duration? duration;
  final Duration? position;

  @override
  Widget build(BuildContext context) {
    final total = watch != null && watch!.duration > Duration.zero
        ? watch!.duration
        : duration;
    final exact = watch?.position ?? position;
    final elapsed =
        exact ??
        (total == null
            ? null
            : Duration(
                milliseconds: (total.inMilliseconds * progress.clamp(0, 1))
                    .round(),
              ));
    return Positioned(
      left: 8,
      right: 8,
      bottom: 6,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (elapsed != null)
            Text(
              '${exact == null ? '≈ ' : ''}${episodeProgressTime(elapsed)}${total != null && total > Duration.zero ? ' / ${episodeProgressTime(total)}' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                shadows: [Shadow(color: Colors.black87, blurRadius: 3)],
              ),
            ),
          const SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: progress.clamp(0, 1),
              minHeight: 3,
              backgroundColor: Colors.white24,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _CatalogEpisodeRail extends StatefulWidget {
  const _CatalogEpisodeRail({
    required this.episodes,
    required this.selectedEpisode,
    required this.progress,
    required this.timings,
    required this.onSelect,
    required this.onPlay,
    required this.onMarkPlayed,
  });

  final List<TmdbEpisode> episodes;
  final int? selectedEpisode;
  final Map<String, double> progress;
  final Map<String, WatchState?> timings;
  final ValueChanged<TmdbEpisode> onSelect;
  final ValueChanged<TmdbEpisode> onPlay;
  final Future<void> Function(TmdbEpisode, bool) onMarkPlayed;

  @override
  State<_CatalogEpisodeRail> createState() => _CatalogEpisodeRailState();
}

class _CatalogEpisodeRailState extends State<_CatalogEpisodeRail> {
  static const _episodeCardWidth = 238.0;
  static const _episodeItemExtent = 256.0;
  final _controller = ScrollController();
  final _allEpisodesController = ScrollController();
  final _numberController = ScrollController();

  @override
  void initState() {
    super.initState();
    _centerSelected();
  }

  void _centerSelected({int? number}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final index = widget.episodes.indexWhere(
        (episode) =>
            episode.episodeNumber == (number ?? widget.selectedEpisode),
      );
      if (index < 0) return;
      final position = _controller.position;
      final target =
          6.0 +
          index * _episodeItemExtent +
          _episodeCardWidth / 2 -
          position.viewportDimension / 2;
      _controller.animateTo(
        target.clamp(0.0, position.maxScrollExtent),
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeOutCubic,
      );
      if (_numberController.hasClients) {
        final now = DateTime.now();
        final tomorrow = DateTime(now.year, now.month, now.day + 1);
        final published = widget.episodes
            .where(
              (episode) =>
                  episode.airDate != null &&
                  episode.airDate!.isBefore(tomorrow),
            )
            .toList();
        final numberIndex = published.indexWhere(
          (episode) =>
              episode.episodeNumber == (number ?? widget.selectedEpisode),
        );
        if (numberIndex >= 0) {
          final position = _numberController.position;
          _numberController.animateTo(
            (numberIndex * 48 + 22 - position.viewportDimension / 2).clamp(
              0.0,
              position.maxScrollExtent,
            ),
            duration: const Duration(milliseconds: 360),
            curve: Curves.easeOutCubic,
          );
        }
      }
    });
  }

  Future<void> _showMarkMenu(
    TmdbEpisode episode,
    Offset position, {
    ValueChanged<bool>? onChoice,
  }) async {
    final played =
        (widget.progress[_episodeKey(
              episode.seasonNumber,
              episode.episodeNumber,
            )] ??
            0) >=
        .92;
    final choice = await showYingjiContextMenu(
      context: context,
      position: position,
      actions: [
        YingjiContextAction(
          value: 'played',
          label: '标记为已播放',
          icon: YingjiIcons.checkmark_circle_fill,
          selected: played,
        ),
        YingjiContextAction(
          value: 'unplayed',
          label: '标记为未播放',
          icon: YingjiIcons.refresh,
          selected: false,
        ),
      ],
    );
    if (choice != null) {
      final played = choice == 'played';
      onChoice?.call(played);
      await widget.onMarkPlayed(episode, played);
    }
  }

  Widget _contextEpisode(
    TmdbEpisode episode,
    Widget child, {
    ValueChanged<bool>? onChoice,
  }) => Listener(
    onPointerDown: (event) {
      if (event.kind == PointerDeviceKind.mouse &&
          event.buttons & kSecondaryMouseButton != 0) {
        _showMarkMenu(episode, event.position, onChoice: onChoice);
      }
    },
    child: GestureDetector(
      onLongPressStart: (details) =>
          _showMarkMenu(episode, details.globalPosition, onChoice: onChoice),
      child: child,
    ),
  );

  @override
  void didUpdateWidget(covariant _CatalogEpisodeRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedEpisode != widget.selectedEpisode ||
        (oldWidget.episodes.isEmpty && widget.episodes.isNotEmpty)) {
      _centerSelected();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _allEpisodesController.dispose();
    _numberController.dispose();
    super.dispose();
  }

  Future<void> _showAll() async {
    final progressByEpisode = Map<String, double>.of(widget.progress);
    int? dialogSelectedEpisode = widget.selectedEpisode;
    int? hoveredEpisodeNumber;
    await showDialog<void>(
      context: context,
      animationStyle: MovaMotion.dialogAnimationStyle(context),
      barrierColor: Colors.black.withValues(alpha: .58),
      builder: (dialogContext) => YingjiStableScrollGlass(
        child: StatefulBuilder(
          builder: (context, updateDialog) => YingjiSmoothWheel(
            controller: _allEpisodesController,
            child: Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 720,
                  maxHeight: 760,
                ),
                child: Padding(
                  padding: EdgeInsets.zero,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(22, 20, 14, 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '第 ${widget.episodes.first.seasonNumber} 季 · 全部剧集',
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            YingjiMotionIconButton(
                              icon: YingjiIcons.xmark,
                              tooltip: '关闭',
                              size: 38,
                              onPressed: () => Navigator.pop(dialogContext),
                            ),
                          ],
                        ),
                      ),
                      Divider(
                        height: 1,
                        color: YingjiGlass.line(strength: .85),
                      ),
                      Flexible(
                        child: GlassPanel(
                          radius: 22,
                          padding: EdgeInsets.zero,
                          child: ScrollConfiguration(
                            behavior: ScrollConfiguration.of(context)
                                .copyWith(scrollbars: false),
                            child: ListView.builder(
                              controller: _allEpisodesController,
                              physics: yingjiWheelPhysics,
                              padding: const EdgeInsets.fromLTRB(
                                14,
                                12,
                                14,
                                16,
                              ),
                              itemCount: widget.episodes.length,
                              itemBuilder: (context, index) {
                                final episode = widget.episodes[index];
                                final key = _episodeKey(
                                  episode.seasonNumber,
                                  episode.episodeNumber,
                                );
                                final progress = progressByEpisode[key] ?? 0;
                                final selected =
                                    episode.episodeNumber ==
                                    dialogSelectedEpisode;
                                final played = progress >= .92;
                                final hovered =
                                    hoveredEpisodeNumber ==
                                    episode.episodeNumber;
                                final overview = episode.overview?.trim();
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      _contextEpisode(
                                        episode,
                                        MouseRegion(
                                          cursor: SystemMouseCursors.click,
                                          onEnter: (_) => updateDialog(
                                            () => hoveredEpisodeNumber =
                                                episode.episodeNumber,
                                          ),
                                          onExit: (_) {
                                            if (hoveredEpisodeNumber ==
                                                episode.episodeNumber) {
                                              updateDialog(
                                                () =>
                                                    hoveredEpisodeNumber = null,
                                              );
                                            }
                                          },
                                          child: AnimatedContainer(
                                            duration: MovaMotion.standard,
                                            curve: MovaMotion.standardEase,
                                            decoration: BoxDecoration(
                                              color: selected
                                                  ? Colors.white.withValues(
                                                      alpha: .12,
                                                    )
                                                  : hovered
                                                  ? Colors.white.withValues(
                                                      alpha: .055,
                                                    )
                                                  : Colors.transparent,
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              border: Border.all(
                                                color: selected
                                                    ? Colors.white.withValues(
                                                        alpha: .78,
                                                      )
                                                    : hovered
                                                    ? Colors.white.withValues(
                                                        alpha: .58,
                                                      )
                                                    : Colors.transparent,
                                                width: 1.4,
                                              ),
                                            ),
                                            child: ListTile(
                                              selected: false,
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(14),
                                              ),
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 5,
                                                  ),
                                              leading: SizedBox(
                                                width: 112,
                                                height: 64,
                                                child: ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  child:
                                                      episode.stillUrl == null
                                                      ? const _EpisodeArtworkFallback()
                                                      : CachedNetworkImage(
                                                          imageUrl: episode
                                                              .stillUrl
                                                              .toString(),
                                                          fit: BoxFit.cover,
                                                          errorWidget: (
                                                            _,
                                                            _,
                                                            _,
                                                          ) => const _EpisodeArtworkFallback(),
                                                        ),
                                                ),
                                              ),
                                              title: Text(
                                                '第 ${episode.episodeNumber} 集 · ${episode.name}',
                                              ),
                                              subtitle: Text(
                                                [
                                                      _dateLabel(
                                                        episode.airDate,
                                                      ),
                                                      if (episode.runtime !=
                                                          null)
                                                        '${episode.runtime} 分钟',
                                                    ]
                                                    .where(
                                                      (part) => part.isNotEmpty,
                                                    )
                                                    .join(' · '),
                                              ),
                                              onTap: () {
                                                if (selected) {
                                                  Navigator.pop(dialogContext);
                                                  widget.onPlay(episode);
                                                } else {
                                                  dialogSelectedEpisode =
                                                      episode.episodeNumber;
                                                  widget.onSelect(episode);
                                                  updateDialog(() {});
                                                }
                                              },
                                              trailing: AnimatedSwitcher(
                                                duration: MovaMotion.standard,
                                                switchInCurve:
                                                    MovaMotion.spring,
                                                switchOutCurve: MovaMotion.exit,
                                                transitionBuilder:
                                                    (child, animation) =>
                                                        ScaleTransition(
                                                          scale: animation,
                                                          child: FadeTransition(
                                                            opacity: animation,
                                                            child: child,
                                                          ),
                                                        ),
                                                child: played
                                                    ? Container(
                                                        key: const ValueKey(
                                                          'played',
                                                        ),
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 10,
                                                              vertical: 6,
                                                            ),
                                                        decoration: BoxDecoration(
                                                          color:
                                                              const Color(
                                                                0xFF6AD7A1,
                                                              ).withValues(
                                                                alpha: .19,
                                                              ),
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                999,
                                                              ),
                                                          border: Border.all(
                                                            color:
                                                                const Color(
                                                                  0xFF8CE9B5,
                                                                ).withValues(
                                                                  alpha: .72,
                                                                ),
                                                          ),
                                                        ),
                                                        child: const Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            Icon(
                                                              YingjiIcons
                                                                  .checkmark_circle_fill,
                                                              size: 16,
                                                              color: Color(
                                                                0xFF9BF1BF,
                                                              ),
                                                            ),
                                                            SizedBox(width: 6),
                                                            Text(
                                                              '已播放',
                                                              style: TextStyle(
                                                                fontSize: 12,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w800,
                                                                color: Color(
                                                                  0xFFB9F6D0,
                                                                ),
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      )
                                                    : Icon(
                                                        YingjiIcons.play_circle,
                                                        key: const ValueKey(
                                                          'unplayed',
                                                        ),
                                                        color: selected
                                                            ? Colors.white
                                                            : Colors.white54,
                                                      ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        onChoice: (played) => updateDialog(
                                          () => progressByEpisode[key] = played
                                              ? 1
                                              : 0,
                                        ),
                                      ),
                                      if (overview != null &&
                                          overview.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                            12,
                                            5,
                                            12,
                                            1,
                                          ),
                                          child: YingjiGlassTooltip(
                                            message: overview,
                                            child: Text(
                                              overview,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: YingjiColors.muted,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Text(
            '集',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
          ),
          const SizedBox(width: 12),
          Text(
            '${widget.episodes.length} 集',
            style: const TextStyle(color: YingjiColors.muted),
          ),
          const Spacer(),
          const SizedBox(width: 7),
          const SizedBox(width: 7),
          YingjiMotionIconButton(
            icon: YingjiIcons.rectangle_stack,
            tooltip: '全部剧集',
            size: 34,
            onPressed: _showAll,
          ),
        ],
      ),
      const SizedBox(height: 8),
      _PublishedEpisodeNumbers(
        episodes: widget.episodes,
        selected: widget.selectedEpisode,
        controller: _numberController,
        onSelect: (episode) {
          _centerSelected(number: episode.episodeNumber);
          if (episode.episodeNumber != widget.selectedEpisode) {
            widget.onSelect(episode);
          }
        },
      ),
      SizedBox(
        height: 236,
        key: const ValueKey('catalog-episode-previews'),
        child: YingjiSmoothWheel(
          controller: _controller,
          stableGlass: true,
          child: MovaHorizontalDrag(
            child: ListView.builder(
              controller: _controller,
              scrollDirection: Axis.horizontal,

              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
              // Fixed extents keep the initial scroll boundary exact even when
              // the selected episode has not been built by the lazy viewport.
              itemExtent: _episodeItemExtent,
              itemCount: widget.episodes.length,
              itemBuilder: (context, index) {
                final episode = widget.episodes[index];
                final selected =
                    episode.episodeNumber == widget.selectedEpisode;
                final progress =
                    widget.progress[_episodeKey(
                      episode.seasonNumber,
                      episode.episodeNumber,
                    )] ??
                    0;
                final overview = episode.overview?.trim();
                return Padding(
                  padding: const EdgeInsets.only(
                    right: _episodeItemExtent - _episodeCardWidth,
                  ),
                  child: _contextEpisode(
                    episode,
                    SizedBox(
                      width: _episodeCardWidth,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          InkWell(
                            borderRadius: BorderRadius.circular(11),
                            onTap: () {
                              _centerSelected(number: episode.episodeNumber);
                              selected
                                  ? widget.onPlay(episode)
                                  : widget.onSelect(episode);
                            },
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _DetailPosterHover(
                                  selected: selected,
                                  borderRadius: 14,
                                  child: SizedBox(
                                    height: 134,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(14),
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          if (episode.stillUrl != null)
                                            CachedNetworkImage(
                                              imageUrl: episode.stillUrl
                                                  .toString(),
                                              fit: BoxFit.cover,
                                              errorWidget: (_, _, _) =>
                                                  const _EpisodeArtworkFallback(),
                                            )
                                          else
                                            const _EpisodeArtworkFallback(),
                                          Positioned(
                                            top: 9,
                                            right: 9,
                                            child: AnimatedSwitcher(
                                              duration: MovaMotion.standard,
                                              switchInCurve: MovaMotion.spring,
                                              switchOutCurve: MovaMotion.exit,
                                              transitionBuilder:
                                                  (child, animation) =>
                                                      ScaleTransition(
                                                        scale: animation,
                                                        child: FadeTransition(
                                                          opacity: animation,
                                                          child: child,
                                                        ),
                                                      ),
                                              child: progress >= .92
                                                  ? const Icon(
                                                      YingjiIcons
                                                          .checkmark_circle_fill,
                                                      key: ValueKey('played'),
                                                      color: Colors.white,
                                                      size: 23,
                                                    )
                                                  : const SizedBox.square(
                                                      key: ValueKey('unplayed'),
                                                      dimension: 23,
                                                    ),
                                            ),
                                          ),
                                          if (progress > 0)
                                            _EpisodeProgressOverlay(
                                              progress: progress,
                                              watch:
                                                  widget.timings[_episodeKey(
                                                    episode.seasonNumber,
                                                    episode.episodeNumber,
                                                  )],
                                              duration: episode.runtime == null
                                                  ? null
                                                  : Duration(
                                                      minutes: episode.runtime!,
                                                    ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 7),
                                Text(
                                  '第 ${episode.episodeNumber} 集 · ${episode.name}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  [
                                        _dateLabel(episode.airDate),
                                        if (episode.runtime != null)
                                          '${episode.runtime} 分钟',
                                      ]
                                      .where((part) => part.isNotEmpty)
                                      .join(' · '),
                                  style: const TextStyle(
                                    color: YingjiColors.muted,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (overview?.isNotEmpty == true)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(2, 5, 2, 0),
                              child: YingjiGlassTooltip(
                                message: overview!,
                                child: Text(
                                  overview,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: YingjiColors.muted,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ],
  );
}

class _EpisodePreviewRail extends StatefulWidget {
  const _EpisodePreviewRail({
    required this.resources,
    required this.selected,
    required this.completedResourceIds,
    required this.episodeProgress,
    required this.metadata,
    required this.onMarkPlayed,
    required this.onSelect,
  });
  final List<MediaItem> resources;
  final MediaItem? selected;
  final Set<String> completedResourceIds;
  final Map<String, double> episodeProgress;
  final Map<String, TmdbEpisode> metadata;
  final Future<void> Function(MediaItem resource, bool completed) onMarkPlayed;
  final ValueChanged<MediaItem> onSelect;

  @override
  State<_EpisodePreviewRail> createState() => _EpisodePreviewRailState();
}

class _EpisodePreviewRailState extends State<_EpisodePreviewRail> {
  final ScrollController _controller = ScrollController();
  final ScrollController _episodeDialogScroll = ScrollController();
  int? _hoveredIndex;

  void _centerSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_controller.hasClients) return;
      final index = widget.resources.indexWhere(
        (resource) =>
            resource.seasonNumber == widget.selected?.seasonNumber &&
            resource.episodeNumber == widget.selected?.episodeNumber,
      );
      if (index < 0) return;
      final viewport = _controller.position.viewportDimension;
      final target = (index * 256.0 - (viewport - 238) / 2).clamp(
        0.0,
        _controller.position.maxScrollExtent,
      );
      _controller.animateTo(
        target,
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _showMarkMenu(
    BuildContext context,
    MediaItem resource,
    bool completed,
    Offset position, {
    ValueChanged<bool>? onChoice,
  }) async {
    final choice = await showYingjiContextMenu(
      context: context,
      position: position,
      actions: [
        YingjiContextAction(
          value: 'played',
          label: '标记为已播放',
          icon: YingjiIcons.checkmark_circle_fill,
          selected: completed,
        ),
        YingjiContextAction(
          value: 'unplayed',
          label: '标记为未播放',
          icon: YingjiIcons.refresh,
          selected: false,
        ),
      ],
    );
    if (!mounted || choice == null) return;
    final markedPlayed = choice == 'played';
    onChoice?.call(markedPlayed);
    await widget.onMarkPlayed(resource, markedPlayed);
  }

  @override
  void initState() {
    super.initState();
    _centerSelected();
  }

  @override
  void didUpdateWidget(covariant _EpisodePreviewRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected?.seasonNumber != widget.selected?.seasonNumber ||
        oldWidget.selected?.episodeNumber != widget.selected?.episodeNumber) {
      _centerSelected();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _episodeDialogScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Text(
            '集',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
          ),
          const SizedBox(width: 12),
          Text(
            '${widget.resources.length} 集',
            style: const TextStyle(color: YingjiColors.muted),
          ),
          const Spacer(),
          const SizedBox(width: 7),
          const SizedBox(width: 7),
          YingjiMotionIconButton(
            icon: YingjiIcons.rectangle_stack,
            tooltip: '全部剧集',
            size: 34,
            onPressed: _showAllEpisodes,
          ),
        ],
      ),
      const SizedBox(height: 8),
      SizedBox(
        height: 236,
        child: YingjiSmoothWheel(
          controller: _controller,
          stableGlass: true,
          child: MovaHorizontalDrag(
            child: ListView.builder(
              controller: _controller,
              scrollDirection: Axis.horizontal,

              physics:
                  yingjiWheelPhysics ??
                  const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
              itemExtent: 256,
              itemCount: widget.resources.length,
              itemBuilder: (_, index) {
                final resource = widget.resources[index];
                final effectiveSeason =
                    resource.seasonNumber ?? widget.selected?.seasonNumber ?? 1;
                final effectiveEpisode = resource.episodeNumber ?? index + 1;
                final episodeMetadata = widget
                    .metadata[_episodeKey(effectiveSeason, effectiveEpisode)];
                final title = _episodeTitle(
                  resource,
                  episodeMetadata,
                  index + 1,
                );
                final image = _episodeImage(resource, episodeMetadata);
                final overview = resource.overview?.trim().isNotEmpty == true
                    ? resource.overview!
                    : episodeMetadata?.overview;
                final published =
                    resource.premiereDate ?? episodeMetadata?.airDate;
                final runtime =
                    resource.runtime?.inMinutes ?? episodeMetadata?.runtime;
                final active =
                    resource.seasonNumber == widget.selected?.seasonNumber &&
                    resource.episodeNumber == widget.selected?.episodeNumber;
                final progress =
                    widget.episodeProgress[_episodeKey(
                      effectiveSeason,
                      effectiveEpisode,
                    )] ??
                    0;
                final completed =
                    widget.completedResourceIds.contains(resource.id) ||
                    progress >= .92;
                final lifted = active || _hoveredIndex == index;
                return Padding(
                  padding: const EdgeInsets.only(right: 18),
                  child: MouseRegion(
                    onEnter: (_) => setState(() => _hoveredIndex = index),
                    onExit: (_) => setState(() => _hoveredIndex = null),
                    child: GestureDetector(
                      onSecondaryTapUp: (details) => _showMarkMenu(
                        context,
                        resource,
                        completed,
                        details.globalPosition,
                      ),
                      onLongPressStart: (details) => _showMarkMenu(
                        context,
                        resource,
                        completed,
                        details.globalPosition,
                      ),
                      child: InkWell(
                        onTap: () => widget.onSelect(resource),
                        borderRadius: BorderRadius.circular(14),
                        child: AnimatedScale(
                          scale: lifted ? 1.018 : 1,
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          child: AnimatedSlide(
                            offset: lifted
                                ? const Offset(0, -.015)
                                : Offset.zero,
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOutCubic,
                            child: SizedBox(
                              width: 238,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // 选中与悬浮描边只包裹剧照，不延伸到集名和日期。
                                  SizedBox(
                                    width: double.infinity,
                                    height: 134,
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 220,
                                      ),
                                      clipBehavior: Clip.antiAlias,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF25292A),
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: active
                                              ? Colors.white
                                              : _hoveredIndex == index
                                              ? Colors.white.withValues(
                                                  alpha: .58,
                                                )
                                              : Colors.white.withValues(
                                                  alpha: .1,
                                                ),
                                          width: active
                                              ? 2.4
                                              : _hoveredIndex == index
                                              ? 1.4
                                              : 1,
                                        ),
                                        boxShadow: lifted
                                            ? const [
                                                BoxShadow(
                                                  color: Color(0x8A000000),
                                                  blurRadius: 28,
                                                  offset: Offset(0, 14),
                                                ),
                                              ]
                                            : null,
                                      ),
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          image == null
                                              ? const _EpisodeArtworkFallback()
                                              : CachedNetworkImage(
                                                  fadeInDuration:
                                                      const Duration(
                                                        milliseconds: 150,
                                                      ),
                                                  imageUrl: image.toString(),
                                                  fit: BoxFit.cover,
                                                  // 剧集静帧显示宽 ~238，按物理像素解码即可，
                                                  // 避免几十张原图在进页面时批量解码卡住转场末帧。
                                                  memCacheWidth:
                                                      (320 *
                                                              MediaQuery.devicePixelRatioOf(
                                                                context,
                                                              ))
                                                          .clamp(1.0, 512.0)
                                                          .round(),
                                                  errorWidget: (_, _, _) =>
                                                      const _EpisodeArtworkFallback(),
                                                ),
                                          Positioned(
                                            right: 10,
                                            top: 10,
                                            child: AnimatedSwitcher(
                                              duration: MovaMotion.standard,
                                              switchInCurve: MovaMotion.spring,
                                              switchOutCurve: MovaMotion.exit,
                                              transitionBuilder:
                                                  (child, animation) =>
                                                      ScaleTransition(
                                                        scale: animation,
                                                        child: FadeTransition(
                                                          opacity: animation,
                                                          child: child,
                                                        ),
                                                      ),
                                              child: completed
                                                  ? const Icon(
                                                      YingjiIcons
                                                          .checkmark_circle_fill,
                                                      key: ValueKey('played'),
                                                      color: Colors.white,
                                                    )
                                                  : const SizedBox.square(
                                                      key: ValueKey('unplayed'),
                                                      dimension: 24,
                                                    ),
                                            ),
                                          ),
                                          if (progress > 0 &&
                                              !completed &&
                                              runtime != null)
                                            Positioned(
                                              left: 10,
                                              right: 10,
                                              bottom: 8,
                                              child: Column(
                                                children: [
                                                  Row(
                                                    children: [
                                                      Text(
                                                        _minuteClock(
                                                          (runtime * progress)
                                                              .round(),
                                                        ),
                                                        style: const TextStyle(
                                                          fontSize: 10.5,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                      ),
                                                      const Spacer(),
                                                      Text(
                                                        _minuteClock(
                                                          (runtime *
                                                                  (1 -
                                                                      progress))
                                                              .round(),
                                                        ),
                                                        style: const TextStyle(
                                                          fontSize: 10.5,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 4),
                                                  ClipRRect(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          99,
                                                        ),
                                                    child: LinearProgressIndicator(
                                                      value: progress,
                                                      minHeight: 3,
                                                      backgroundColor:
                                                          Colors.white24,
                                                      valueColor:
                                                          const AlwaysStoppedAnimation<
                                                            Color
                                                          >(Colors.white),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 7),
                                  Text(
                                    '第 $effectiveEpisode 集 · $title',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: active
                                          ? FontWeight.w800
                                          : FontWeight.w700,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    [
                                      if (_dateLabel(published).isNotEmpty)
                                        _dateLabel(published),
                                      if (runtime != null) '$runtime 分钟',
                                    ].join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: YingjiColors.muted,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (overview?.isNotEmpty == true) ...[
                                    const SizedBox(height: 3),
                                    YingjiGlassTooltip(
                                      message: overview!,
                                      child: Text(
                                        overview,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Color(0xFFD5D8DF),
                                          fontSize: 11,
                                          height: 1.28,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ],
  );

  Future<void> _showAllEpisodes() {
    final completedIds = Set<String>.of(widget.completedResourceIds);
    final episodeProgress = Map<String, double>.of(widget.episodeProgress);
    return showDialog<void>(
      context: context,
      animationStyle: MovaMotion.dialogAnimationStyle(context),
      barrierColor: Colors.black.withValues(alpha: .72),
      builder: (context) => StatefulBuilder(
        builder: (context, updateDialog) {
          final playedCount = widget.resources.where((episode) {
            final key = _episodeKey(
              episode.seasonNumber,
              episode.episodeNumber,
            );
            return completedIds.contains(episode.id) ||
                (episodeProgress[key] ?? 0) >= .92;
          }).length;
          final watchingCount = widget.resources.where((episode) {
            final progress =
                episodeProgress[_episodeKey(
                  episode.seasonNumber,
                  episode.episodeNumber,
                )] ??
                0;
            return progress > 0 && progress < .92;
          }).length;
          final unplayedCount =
              widget.resources.length - playedCount - watchingCount;
          return YingjiPinnedDialog(
            transparentHeader: true,
            maxWidth: 1180,
            maxHeight: 820,
            insetPadding: const EdgeInsets.all(24),
            scrollController: _episodeDialogScroll,
            header: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(YingjiIcons.rectangle_stack, size: 22),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '全部剧集',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        '选择剧集继续播放，长按 / 右键可更新观看状态',
                        style: TextStyle(
                          color: YingjiColors.muted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                _EpisodeStat(label: '总集数', value: widget.resources.length),
                const SizedBox(width: 8),
                _EpisodeStat(label: '已播放', value: playedCount),
                const SizedBox(width: 8),
                _EpisodeStat(label: '观看中', value: watchingCount),
                const SizedBox(width: 8),
                _EpisodeStat(label: '未播放', value: unplayedCount),
                const SizedBox(width: 14),
                YingjiMotionIconButton(
                  icon: YingjiIcons.xmark,
                  tooltip: '关闭',
                  size: 38,
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            body: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: LinearProgressIndicator(
                          value: widget.resources.isEmpty
                              ? 0
                              : playedCount / widget.resources.length,
                          minHeight: 5,
                          backgroundColor: Colors.white.withValues(alpha: .1),
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      widget.resources.isEmpty
                          ? '0%'
                          : '${(playedCount / widget.resources.length * 100).round()}%',
                      style: const TextStyle(
                        color: YingjiColors.muted,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                LayoutBuilder(
                  builder: (context, constraints) {
                    return ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: widget.resources.length,
                      itemBuilder: (_, index) {
                        final episode = widget.resources[index];
                        final metadata =
                            widget.metadata[_episodeKey(
                              episode.seasonNumber,
                              episode.episodeNumber,
                            )];
                        final title = _episodeTitle(
                          episode,
                          metadata,
                          index + 1,
                        );
                        final image = _episodeImage(episode, metadata);
                        final published =
                            episode.premiereDate ?? metadata?.airDate;
                        final runtime =
                            episode.runtime?.inMinutes ?? metadata?.runtime;
                        final selected =
                            episode.seasonNumber ==
                                widget.selected?.seasonNumber &&
                            episode.episodeNumber ==
                                widget.selected?.episodeNumber;
                        final progress =
                            episodeProgress[_episodeKey(
                              episode.seasonNumber,
                              episode.episodeNumber,
                            )] ??
                            0;
                        final completed =
                            completedIds.contains(episode.id) ||
                            progress >= .92;
                        return _AllEpisodeRow(
                          episode: episode,
                          index: index,
                          title: title,
                          image: image,
                          published: published,
                          runtime: runtime,
                          progress: progress,
                          completed: completed,
                          selected: selected,
                          overview: episode.overview?.trim().isNotEmpty == true
                              ? episode.overview!
                              : metadata?.overview,
                          onTap: () {
                            Navigator.pop(context);
                            widget.onSelect(episode);
                          },
                          onSecondaryTapUp: (details) => _showMarkMenu(
                            context,
                            episode,
                            completed,
                            details.globalPosition,
                            onChoice: (marked) {
                              updateDialog(() {
                                final key = _episodeKey(
                                  episode.seasonNumber,
                                  episode.episodeNumber,
                                );
                                if (marked) {
                                  completedIds.add(episode.id);
                                  episodeProgress[key] = 1;
                                } else {
                                  completedIds.remove(episode.id);
                                  episodeProgress[key] = 0;
                                }
                              });
                            },
                          ),
                          onLongPressStart: (details) => _showMarkMenu(
                            context,
                            episode,
                            completed,
                            details.globalPosition,
                            onChoice: (marked) {
                              updateDialog(() {
                                final key = _episodeKey(
                                  episode.seasonNumber,
                                  episode.episodeNumber,
                                );
                                if (marked) {
                                  completedIds.add(episode.id);
                                  episodeProgress[key] = 1;
                                } else {
                                  completedIds.remove(episode.id);
                                  episodeProgress[key] = 0;
                                }
                              });
                            },
                          ),
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _EpisodeStat extends StatelessWidget {
  const _EpisodeStat({required this.label, required this.value});
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
    decoration: BoxDecoration(
      color: YingjiGlass.chrome(strength: .72),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text.rich(
      TextSpan(
        text: '$value ',
        style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
        children: [
          TextSpan(
            text: label,
            style: const TextStyle(
              color: YingjiColors.muted,
              fontWeight: FontWeight.w600,
              fontSize: 11,
            ),
          ),
        ],
      ),
    ),
  );
}

class _AllEpisodeRow extends StatelessWidget {
  const _AllEpisodeRow({
    required this.episode,
    required this.index,
    required this.title,
    required this.image,
    required this.published,
    required this.runtime,
    required this.progress,
    required this.completed,
    required this.selected,
    required this.overview,
    required this.onTap,
    required this.onSecondaryTapUp,
    required this.onLongPressStart,
  });

  final MediaItem episode;
  final int index;
  final String title;
  final Uri? image;
  final DateTime? published;
  final int? runtime;
  final double progress;
  final bool completed;
  final bool selected;
  final String? overview;
  final VoidCallback onTap;
  final GestureTapUpCallback onSecondaryTapUp;
  final GestureLongPressStartCallback onLongPressStart;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Listener(
          onPointerDown: (event) {
            if (event.kind == PointerDeviceKind.mouse &&
                event.buttons & kSecondaryMouseButton != 0) {
              onSecondaryTapUp(
                TapUpDetails(
                  globalPosition: event.position,
                  kind: PointerDeviceKind.mouse,
                ),
              );
            }
          },
          child: GestureDetector(
            onLongPressStart: onLongPressStart,
            child: YingjiMotionSurface(
              selected: selected,
              borderRadius: 14,
              child: YingjiGlassSurface(
                radius: 14,
                strength: .78,
                padding: const EdgeInsets.all(8),
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(11),
                    onTap: onTap,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 124,
                            height: 70,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(9),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  image == null
                                      ? const _EpisodeArtworkFallback()
                                      : CachedNetworkImage(
                                          imageUrl: image.toString(),
                                          fit: BoxFit.cover,
                                          errorWidget: (_, _, _) =>
                                              const _EpisodeArtworkFallback(),
                                        ),
                                  if (progress > 0 || completed)
                                    _EpisodeProgressOverlay(
                                      progress: completed ? 1 : progress,
                                      duration:
                                          episode.runtime ??
                                          (runtime == null
                                              ? null
                                              : Duration(minutes: runtime!)),
                                      position: episode.playbackPosition,
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '第 ${episode.episodeNumber ?? index + 1} 集 · $title',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  [
                                        _dateLabel(published),
                                        if (runtime != null) '$runtime 分钟',
                                        if (completed) '已播放',
                                      ]
                                      .where((part) => part.isNotEmpty)
                                      .join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: YingjiColors.muted,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          AnimatedSwitcher(
                            duration: MovaMotion.standard,
                            switchInCurve: MovaMotion.spring,
                            switchOutCurve: MovaMotion.exit,
                            transitionBuilder: (child, animation) =>
                                ScaleTransition(
                                  scale: animation,
                                  child: FadeTransition(
                                    opacity: animation,
                                    child: child,
                                  ),
                                ),
                            child: completed
                                ? const Icon(
                                    YingjiIcons.checkmark_circle_fill,
                                    key: ValueKey('played'),
                                    color: Colors.white,
                                  )
                                : const Icon(
                                    YingjiIcons.circle,
                                    key: ValueKey('unplayed'),
                                    color: YingjiColors.muted,
                                  ),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (overview?.trim().isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 5, 14, 1),
            child: YingjiGlassTooltip(
              message: overview!.trim(),
              child: Text(
                overview!.trim(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: YingjiColors.muted,
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _EpisodeArtworkFallback extends StatelessWidget {
  const _EpisodeArtworkFallback();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xFF25292A),
    child: Center(
      child: Icon(
        YingjiIcons.play_rectangle,
        color: YingjiColors.muted,
        size: 28,
      ),
    ),
  );
}

/// Detail imagery shares one physical hover response: a subtle lift, a soft
/// context shadow and a selected-state enlargement. It deliberately avoids
/// layout movement so horizontal shelves retain their rhythm.
class _DetailPosterHover extends StatefulWidget {
  const _DetailPosterHover({
    required this.child,
    required this.borderRadius,
    this.selected = false,
  });
  final Widget child;
  final double borderRadius;
  final bool selected;

  @override
  State<_DetailPosterHover> createState() => _DetailPosterHoverState();
}

class _DetailPosterHoverState extends State<_DetailPosterHover> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final lifted = _hovered || widget.selected;
    final inPopup = ModalRoute.of(context) is PopupRoute;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: lifted && !inPopup ? 1.018 : 1,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: AnimatedSlide(
          offset: lifted && !inPopup ? const Offset(0, -.012) : Offset.zero,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            // 只有阴影留在这一层。描边不能画在这里：BoxDecoration 的 border
            // 会作为 decoration.padding 把 child 内缩，白框与海报之间永远
            // 隔一条缝——描边改为覆盖层画在海报上层，内半边压住海报边缘。
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              boxShadow: lifted
                  ? const [
                      BoxShadow(
                        color: Color(0x85000000),
                        blurRadius: 28,
                        offset: Offset(0, 14),
                      ),
                    ]
                  : const [],
            ),
            child: Stack(
              children: [
                // 海报层是普通子级，负责给 Stack 定尺寸（水平列表给的是
                // 无界宽度，纯 Positioned 的 Stack 会塌成 0 导致海报消失）。
                ClipRRect(
                  borderRadius: BorderRadius.circular(widget.borderRadius),
                  child: widget.child,
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(
                          widget.borderRadius,
                        ),
                        border: Border.all(
                          color: lifted ? Colors.white : Colors.transparent,
                          width: lifted ? 2.6 : 0,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ResourceSection extends StatefulWidget {
  const _ResourceSection({
    required this.sort,
    required this.onSortChanged,
    required this.resources,
    required this.selected,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.onPicker,
    required this.onSelect,
  });
  final List<MediaItem> resources;
  final String sort;
  final ValueChanged<String> onSortChanged;
  final MediaItem? selected;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;
  final ValueChanged<MediaItem> onPicker;
  final ValueChanged<MediaItem> onSelect;

  @override
  State<_ResourceSection> createState() => _ResourceSectionState();
}

class _ResourceSectionState extends State<_ResourceSection> {
  final _controller = ScrollController();
  String get _sort => widget.sort;
  void _selectSort(String value) => widget.onSortChanged(value);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<MediaItem> get _sorted =>
      sortedResourceVersions(widget.resources, _sort);

  List<MediaItem> get _displayed =>
      serverResourceRepresentatives(_sorted, widget.selected);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Text(
            '资源',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
          ),
          const Spacer(),
          YingjiGlassPillButton(
            icon: YingjiIcons.refresh,
            label: '重新搜索',
            compactLabel: '重试',
            tooltip: '重新搜索当前选中内容在所有已连接服务器的资源',
            busy: widget.loading,
            height: 40,
            onPressed: widget.onRetry,
          ),
        ],
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _FilterChip(
            label: '色彩范围',
            icon: YingjiIcons.sparkles,
            active: _sort == 'range',
            onTap: () => _selectSort('range'),
          ),
          _FilterChip(
            label: '分辨率',
            icon: YingjiIcons.play_rectangle,
            active: _sort == 'resolution',
            onTap: () => _selectSort('resolution'),
          ),
          _FilterChip(
            label: '码率',
            icon: YingjiIcons.gauge,
            active: _sort == 'bitrate',
            onTap: () => _selectSort('bitrate'),
          ),
          _FilterChip(
            label: '大小',
            icon: YingjiIcons.rectangle_stack,
            active: _sort == 'size',
            onTap: () => _selectSort('size'),
          ),
        ],
      ),
      const SizedBox(height: 14),
      if (widget.loading) const LinearProgressIndicator(minHeight: 2),
      if (widget.error != null) _ResourceMessage(message: widget.error!),
      if (widget.resources.isNotEmpty)
        SizedBox(
          height: 144,
          child: YingjiSmoothWheel(
            controller: _controller,
            stableGlass: true,
            child: MovaHorizontalDrag(
              child: ListView.separated(
                controller: _controller,
                scrollDirection: Axis.horizontal,

                physics:
                    yingjiWheelPhysics ??
                    const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                itemCount: _displayed.length,
                separatorBuilder: (_, _) => const SizedBox(width: 14),
                itemBuilder: (_, index) {
                  final resource = _displayed[index];
                  return _ResourceCard(
                    resource: resource,
                    selected:
                        resource.resourceKey == widget.selected?.resourceKey,
                    onSelect: () => widget.onSelect(resource),
                    versionCount: widget.resources
                        .where((row) => row.source.id == resource.source.id)
                        .map((row) => row.resourceKey)
                        .toSet()
                        .length,
                    rank: index < 3 ? index + 1 : null,
                    onPicker: () => widget.onPicker(resource),
                  );
                },
              ),
            ),
          ),
        )
      else if (!widget.loading && widget.error == null)
        const _ResourceMessage(message: '没有在已连接来源中找到可播放资源。'),
    ],
  );
}

class _FilterChip extends StatefulWidget {
  const _FilterChip({
    required this.label,
    this.icon,
    this.active = false,
    this.onTap,
  });
  final String label;
  final IconData? icon;
  final bool active;
  final VoidCallback? onTap;

  @override
  State<_FilterChip> createState() => _FilterChipState();
}

class _FilterChipState extends State<_FilterChip> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 8),
    child: YingjiGlassTooltip(
      message: widget.label,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _pressed ? .94 : (_hovered ? 1.025 : 1),
            duration: const Duration(milliseconds: 130),
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: widget.active
                    ? Colors.white
                    : YingjiGlass.chrome(strength: _hovered ? .96 : .72),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: widget.active
                      ? Colors.transparent
                      : YingjiGlass.line(strength: _hovered ? 1.2 : .82),
                ),
                boxShadow: _hovered
                    ? const [
                        BoxShadow(
                          color: Color(0x4D000000),
                          blurRadius: 14,
                          offset: Offset(0, 6),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.icon != null) ...[
                    Icon(
                      widget.icon,
                      size: 14,
                      color: widget.active ? Colors.black : Colors.white,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: widget.active ? Colors.black : Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _TrackPickerHeadingIcon extends StatelessWidget {
  const _TrackPickerHeadingIcon();

  @override
  Widget build(BuildContext context) => Container(
    width: 42,
    height: 42,
    decoration: BoxDecoration(
      color: YingjiGlass.surface(strength: 1.05),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: YingjiGlass.line(strength: 1.1)),
    ),
    child: const Icon(YingjiIcons.captions_bubble, size: 20),
  );
}

class _TrackResourceSummary extends StatelessWidget {
  const _TrackResourceSummary({required this.resource});
  final MediaItem resource;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
    decoration: BoxDecoration(
      color: YingjiGlass.surface(strength: .68),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        ServerMark(
          source: resource.source,
          token: resource.headers['X-Emby-Token'],
          size: 34,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            resource.source.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          [
            if (resource.width != null && resource.height != null)
              '${resource.width}×${resource.height}',
            if (resource.container?.isNotEmpty == true)
              resource.container!.toUpperCase(),
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: YingjiColors.muted,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

class _TrackPickerPane extends StatefulWidget {
  const _TrackPickerPane({
    required this.icon,
    required this.title,
    required this.count,
    required this.children,
  });
  final IconData icon;
  final String title;
  final int count;
  final List<Widget> children;

  @override
  State<_TrackPickerPane> createState() => _TrackPickerPaneState();
}

class _TrackPickerPaneState extends State<_TrackPickerPane> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 13, 12, 12),
    decoration: BoxDecoration(
      color: YingjiGlass.surface(strength: .58),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              Icon(widget.icon, size: 17),
              const SizedBox(width: 8),
              Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: YingjiGlass.chrome(strength: .74),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${widget.count} 条',
                  style: const TextStyle(
                    color: YingjiColors.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Scrollbar(
            controller: _controller,
            thumbVisibility: widget.children.length > 5,
            child: YingjiSmoothWheel(
              controller: _controller,
              child: ListView.separated(
                controller: _controller,
                physics:
                    yingjiWheelPhysics ??
                    const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                padding: const EdgeInsets.only(right: 4),
                itemCount: widget.children.length,
                separatorBuilder: (_, _) => const SizedBox(height: 7),
                itemBuilder: (_, index) => widget.children[index],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _TrackPickerOption extends StatelessWidget {
  const _TrackPickerOption({
    required this.icon,
    required this.title,
    required this.detail,
    required this.selected,
    required this.onTap,
    this.badge,
  });
  final IconData icon;
  final String title;
  final String detail;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: '$title，$detail',
    child: _DetailCardMotion(
      selected: selected,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 170),
            curve: Curves.easeOutCubic,
            constraints: const BoxConstraints(minHeight: 68),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: selected
                  ? YingjiGlass.surface(strength: 1.14)
                  : YingjiGlass.surface(strength: .72),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? Colors.white : YingjiGlass.line(),
                width: selected ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: selected
                        ? Colors.white.withValues(alpha: .16)
                        : YingjiGlass.chrome(strength: .64),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, size: 17),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (badge != null) ...[
                            const SizedBox(width: 6),
                            Text(
                              badge!,
                              style: const TextStyle(
                                color: YingjiColors.muted,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        detail.isEmpty ? '未提供详细信息' : detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: YingjiColors.muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: Icon(
                    selected
                        ? YingjiIcons.checkmark_circle_fill
                        : YingjiIcons.circle,
                    key: ValueKey(selected),
                    size: 19,
                    color: selected ? Colors.white : YingjiColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _ResourceDetailsPanel extends StatefulWidget {
  const _ResourceDetailsPanel({
    required this.item,
    required this.resource,
    required this.selectedAudioTrack,
    required this.selectedSubtitleTrack,
    required this.onSelectTracks,
  });
  final TmdbItem item;
  final MediaItem? resource;
  final int? selectedAudioTrack;
  final int? selectedSubtitleTrack;
  final VoidCallback onSelectTracks;

  @override
  State<_ResourceDetailsPanel> createState() => _ResourceDetailsPanelState();
}

class _ResourceDetailsPanelState extends State<_ResourceDetailsPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final resource = widget.resource;
    final path = resource?.playbackUrl?.path;
    final width = resource?.width;
    final height = resource?.height;
    final bitDepth = resource?.bitDepth;
    final frameRate = resource?.frameRate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            _FilterChip(
              label: '资源详情',
              icon: YingjiIcons.info_circle,
              active: _expanded,
              onTap: () => setState(() => _expanded = !_expanded),
            ),
            _FilterChip(
              label: '预选字幕 / 音轨',
              icon: YingjiIcons.captions_bubble,
              onTap: widget.onSelectTracks,
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_expanded)
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _InfoGroup(
                title: '通用',
                entries: {
                  '来源': resource?.source.name ?? '—',
                  '封装':
                      resource?.container?.toUpperCase() ??
                      resource?.type.toLowerCase() ??
                      '—',
                  '大小': _formatBytes(resource?.size),
                  '码率': _formatBitrate(resource?.bitrate),
                  '时长': resource?.runtime == null
                      ? '—'
                      : '${resource!.runtime!.inMinutes} 分钟',
                  '标题': item.title,
                  '资源 ID': resource?.id ?? '—',
                  '章节': '${resource?.chapters.length ?? 0}',
                  if (resource?.providerIds.isNotEmpty == true)
                    '外部 ID': resource!.providerIds.entries
                        .map((entry) => '${entry.key}: ${entry.value}')
                        .join(' · '),
                  '路径': path == null || path.isEmpty ? '—' : path,
                },
              ),
              _InfoGroup(
                title: '视频',
                entries: {
                  '分辨率': width == null || height == null
                      ? '—'
                      : '$width×$height',
                  '动态范围': resource?.videoRange ?? '—',
                  '视频': resource?.videoCodec?.toUpperCase() ?? '—',
                  '位深': bitDepth == null ? '—' : '$bitDepth bit',
                  '帧率': frameRate == null
                      ? '—'
                      : '${frameRate.toStringAsFixed(3)} fps',
                },
              ),
              _InfoGroup(
                title: '音频',
                entries: _audioEntries(resource, widget.selectedAudioTrack),
              ),
              _InfoGroup(
                title: '字幕',
                entries: {
                  '流数': '${resource?.subtitleTracks.length ?? 0}',
                  '字幕列表': _subtitleSummary(
                    resource,
                    widget.selectedSubtitleTrack,
                  ),
                },
              ),
            ],
          ),
      ],
    );
  }

  static Map<String, String> _audioEntries(MediaItem? resource, int? selected) {
    final tracks = resource?.audioTracks ?? const <MediaTrack>[];
    final track =
        tracks.where((item) => item.index == selected).firstOrNull ??
        tracks.where((item) => item.isDefault).firstOrNull ??
        tracks.firstOrNull;
    return {
      '音轨': track?.title ?? '—',
      '规格': track?.codec.toUpperCase() ?? '—',
      '声道': track?.channels == null ? '—' : '${track!.channels}',
      '码率': _formatBitrate(track?.bitrate),
      '采样率': track?.sampleRate == null ? '—' : '${track!.sampleRate} Hz',
    };
  }

  static String _subtitleSummary(MediaItem? resource, int? selected) {
    if (selected == -1) return '已关闭';
    final tracks = resource?.subtitleTracks ?? const <MediaTrack>[];
    if (tracks.isEmpty) return '无字幕';
    final selectedTrack = tracks
        .where((item) => item.index == selected)
        .firstOrNull;
    if (selectedTrack != null) return selectedTrack.title;
    return tracks.map((item) => item.title).take(4).join('\n');
  }

  static String _formatBytes(int? value) {
    if (value == null || value <= 0) return '—';
    return '${(value / 1073741824).toStringAsFixed(2)} GB';
  }

  static String _formatBitrate(int? value) {
    if (value == null || value <= 0) return '—';
    return '${(value / 1000000).toStringAsFixed(2)} Mbps';
  }
}

class _InfoGroup extends StatelessWidget {
  const _InfoGroup({required this.title, required this.entries});
  final String title;
  final Map<String, String> entries;

  @override
  Widget build(BuildContext context) => Container(
    width: 350,
    constraints: const BoxConstraints(minHeight: 172),
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
    decoration: BoxDecoration(
      color: YingjiGlass.surface(strength: .9),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: YingjiGlass.line(strength: .76)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        Wrap(
          runSpacing: 9,
          children: entries.entries
              .map(
                (entry) => SizedBox(
                  width: title == '字幕' ? 320 : 156,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.key,
                        style: const TextStyle(
                          color: YingjiColors.quiet,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entry.value,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      ],
    ),
  );
}

class _ResourceCard extends StatelessWidget {
  const _ResourceCard({
    required this.resource,
    required this.selected,
    required this.onSelect,
    required this.onPicker,
    required this.versionCount,
    required this.rank,
  });

  final MediaItem resource;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onPicker;
  final int versionCount;
  final int? rank;

  @override
  Widget build(BuildContext context) => _DetailCardMotion(
    selected: selected,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: YingjiGlassSurface(
        radius: 16,
        strength: selected ? 1.28 : .86,
        child: InkWell(
          onTap: onSelect,
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: 268,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 13),
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected ? Colors.white : YingjiGlass.line(),
                width: selected ? 2.2 : 1,
              ),
              boxShadow: selected
                  ? const [
                      BoxShadow(
                        color: Color(0x73000000),
                        blurRadius: 28,
                        offset: Offset(0, 14),
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (rank != null) ...[
                      Icon(
                        rank == 1
                            ? YingjiIcons.rankFirst
                            : rank == 2
                            ? YingjiIcons.rankSecond
                            : YingjiIcons.rankThird,
                        size: 17,
                        color: rank == 1
                            ? const Color(0xFFFFD76A)
                            : rank == 2
                            ? const Color(0xFFDCE5EE)
                            : const Color(0xFFD99A68),
                      ),
                      const SizedBox(width: 7),
                    ],
                    ServerMark(
                      source: resource.source,
                      token: resource.headers['X-Emby-Token'],
                      size: 34,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            resource.source.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                              letterSpacing: -.15,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${resource.source.kindLabel} · ${resource.playbackUrl == null ? '不可播放' : '直连可用'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: YingjiColors.muted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (selected)
                      const Icon(
                        YingjiIcons.checkmark_circle_fill,
                        size: 18,
                        color: Colors.white,
                      ),
                    ...[
                      const SizedBox(width: 4),
                      YingjiGlassTooltip(
                        message: '$versionCount 个版本，点击切换',
                        child: InkResponse(
                          onTap: onPicker,
                          radius: 18,
                          child: SizedBox(
                            width:
                                Theme.of(context).platform ==
                                    TargetPlatform.android
                                ? 44
                                : 36,
                            height:
                                Theme.of(context).platform ==
                                    TargetPlatform.android
                                ? 44
                                : 36,
                            child: Center(
                              child: YingjiGlassSurface(
                                radius: 18,
                                child: SizedBox(
                                  width: 36,
                                  height: 36,
                                  child: Center(
                                    child: Text(
                                      '$versionCount',
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const Spacer(),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (resource.width != null)
                      _ResourceBadge(
                        resource.width! >= 3800
                            ? '4K'
                            : resource.width! >= 1900
                            ? '1080p'
                            : '${resource.width}p',
                      ),
                    if (resource.videoRange != null)
                      _ResourceBadge(resource.videoRange!),
                    _ResourceBadge(
                      resource.container?.toUpperCase() ?? resource.type,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  [
                    if (resource.bitrate != null)
                      '${(resource.bitrate! / 1000000).toStringAsFixed(1)} Mbps',
                    if (resource.frameRate != null)
                      '${resource.frameRate!.toStringAsFixed(2)} fps',
                    if (resource.size != null)
                      '${(resource.size! / 1073741824).toStringAsFixed(2)} GB',
                  ].join('  ·  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Resource/track feedback stays within the row's clipped viewport bounds.
class _DetailCardMotion extends StatefulWidget {
  const _DetailCardMotion({required this.selected, required this.child});
  final bool selected;
  final Widget child;

  @override
  State<_DetailCardMotion> createState() => _DetailCardMotionState();
}

class _DetailCardMotionState extends State<_DetailCardMotion> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final elevated = widget.selected || _hovered;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: elevated
              ? const [
                  BoxShadow(
                    color: Color(0x4D9BC7FF),
                    blurRadius: 22,
                    spreadRadius: -5,
                    offset: Offset(0, 9),
                  ),
                ]
              : null,
        ),
        child: widget.child,
      ),
    );
  }
}

class _ResourcePickerCard extends StatelessWidget {
  const _ResourcePickerCard({
    required this.resource,
    required this.selected,
    required this.onTap,
  });
  final MediaItem resource;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _DetailCardMotion(
    selected: selected,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: selected
              ? YingjiGlass.surface(strength: 1.2)
              : YingjiGlass.surface(strength: .82),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? Colors.white : YingjiGlass.line(),
            width: selected ? 2.2 : 1,
          ),
        ),
        child: Row(
          children: [
            ServerMark(
              source: resource.source,
              token: resource.headers['X-Emby-Token'],
              size: 34,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    resource.source.name,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _resourcePickerSummary(resource),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: YingjiColors.muted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              selected
                  ? YingjiIcons.checkmark_circle_fill
                  : YingjiIcons.chevron_right,
              color: selected ? Colors.white : YingjiColors.muted,
            ),
          ],
        ),
      ),
    ),
  );
}

String _resourcePickerSummary(MediaItem resource) => [
  if (resource.width != null)
    resource.width! >= 3800 ? '4K' : '${resource.width}p',
  if (resource.videoRange?.isNotEmpty == true) resource.videoRange!,
  if (resource.container?.isNotEmpty == true) resource.container!.toUpperCase(),
  if (resource.size != null)
    '${(resource.size! / 1073741824).toStringAsFixed(2)} GB',
].join(' · ');

class _ResourceBadge extends StatelessWidget {
  const _ResourceBadge(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .1),
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: Colors.white.withValues(alpha: .08)),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: .15,
      ),
    ),
  );
}

class _MovieCollectionSection extends StatefulWidget {
  const _MovieCollectionSection({
    required this.extras,
    required this.currentId,
    required this.onSelect,
  });
  final Future<TmdbExtras> extras;
  final int currentId;
  final ValueChanged<TmdbItem> onSelect;

  @override
  State<_MovieCollectionSection> createState() =>
      _MovieCollectionSectionState();
}

class _MovieCollectionSectionState extends State<_MovieCollectionSection> {
  final _client = TmdbClient();
  final _scroll = ScrollController();
  late Future<List<TmdbItem>> _movies;
  String? _name;

  Future<List<TmdbItem>> _load() async {
    final extras = await widget.extras;
    final id = extras.collectionId;
    if (id == null || id <= 0) return const [];
    if (mounted) setState(() => _name = extras.collectionName ?? '系列电影');
    return _client.collectionMovies(id);
  }

  @override
  void initState() {
    super.initState();
    _movies = _load();
  }

  @override
  void dispose() {
    _client.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<TmdbItem>>(
    future: _movies,
    builder: (context, snapshot) {
      if (_name == null) return const SizedBox.shrink();
      final movies = snapshot.data ?? const <TmdbItem>[];
      if (snapshot.connectionState == ConnectionState.done &&
          !snapshot.hasError &&
          movies.length < 2) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DetailSectionTitle(title: _name!, empty: false),
            const SizedBox(height: 14),
            if (snapshot.hasError)
              TextButton.icon(
                onPressed: () => setState(() => _movies = _load()),
                icon: const Icon(YingjiIcons.refresh),
                label: const Text('系列电影加载失败，点击重试'),
              )
            else if (snapshot.connectionState != ConnectionState.done)
              const LinearProgressIndicator(minHeight: 2)
            else
              SizedBox(
                height: 294,
                child: YingjiSmoothWheel(
                  controller: _scroll,
                  stableGlass: true,
                  child: MovaHorizontalDrag(
                    child: ListView.builder(
                      controller: _scroll,
                      scrollDirection: Axis.horizontal,
                      itemExtent: 180,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: movies.length,
                      itemBuilder: (context, index) {
                        final movie = movies[index];
                        final current = movie.id == widget.currentId;
                        return Padding(
                          padding: const EdgeInsets.only(right: 16),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: current
                                ? null
                                : () => widget.onSelect(movie),
                            child: _DetailPosterHover(
                              selected: current,
                              borderRadius: 14,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(14),
                                    child: SizedBox(
                                      height: 232,
                                      width: 164,
                                      child: movie.posterUrl == null
                                          ? const ColoredBox(
                                              color: YingjiColors.elevated,
                                              child: Icon(YingjiIcons.film),
                                            )
                                          : CachedNetworkImage(
                                              imageUrl: movie.posterUrl
                                                  .toString(),
                                              fit: BoxFit.cover,
                                              memCacheWidth:
                                                  (164 *
                                                          MediaQuery.devicePixelRatioOf(
                                                            context,
                                                          ))
                                                      .clamp(1.0, 512.0)
                                                      .round(),
                                              errorWidget: (_, _, _) =>
                                                  const ColoredBox(
                                                    color:
                                                        YingjiColors.elevated,
                                                    child: Icon(
                                                      YingjiIcons.film,
                                                    ),
                                                  ),
                                            ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    movie.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    [
                                      if (movie.year != null) '${movie.year}',
                                      if (current) '当前影片',
                                    ].join(' · '),
                                    style: const TextStyle(
                                      color: YingjiColors.muted,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _DetailExtrasSection extends StatefulWidget {
  const _DetailExtrasSection({required this.extras});
  final Future<TmdbExtras> extras;

  @override
  State<_DetailExtrasSection> createState() => _DetailExtrasSectionState();
}

class _DetailExtrasSectionState extends State<_DetailExtrasSection> {
  final _castController = ScrollController();
  final _artworkController = ScrollController();
  final _recommendationController = ScrollController();

  void _move(ScrollController controller, double delta) {
    if (!controller.hasClients) return;
    controller.animateTo(
      (controller.offset + delta).clamp(0, controller.position.maxScrollExtent),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _castController.dispose();
    _artworkController.dispose();
    _recommendationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<TmdbExtras>(
    future: widget.extras,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting &&
          !snapshot.hasData) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 28),
          child: LinearProgressIndicator(minHeight: 2),
        );
      }
      if (snapshot.hasError) {
        return const _ResourceMessage(message: '未能读取演员、艺术图和相似推荐。');
      }
      final value = snapshot.data ?? const TmdbExtras();
      // 头像、推荐海报与季封面提前写进磁盘缓存（重复调用只做去重判断）。
      YingjiImageWarmup.people(value.cast);
      YingjiImageWarmup.items(value.recommendations);
      YingjiImageWarmup.seasons(value.seasons);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailSectionTitle(
            title: '演职人员',
            empty: value.cast.isEmpty,
            trailing: _SectionShelfControls(
              onPrevious: () => _move(_castController, -520),
              onNext: () => _move(_castController, 520),
              onAll: () => _showCast(value.cast),
            ),
          ),
          if (value.cast.isNotEmpty) ...[
            const SizedBox(height: 14),
            SizedBox(
              height: 154,
              child: YingjiSmoothWheel(
                controller: _castController,
                stableGlass: true,
                child: MovaHorizontalDrag(
                  child: ListView.separated(
                    controller: _castController,
                    scrollDirection: Axis.horizontal,

                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    itemCount: value.cast.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 18),
                    itemBuilder: (context, index) {
                      final person = value.cast[index];
                      return InkWell(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => _PersonPage(person: person),
                          ),
                        ),
                        borderRadius: BorderRadius.circular(54),
                        child: _DetailPosterHover(
                          borderRadius: 54,
                          child: SizedBox(
                            width: 110,
                            child: Column(
                              children: [
                                ClipOval(
                                  child: SizedBox.square(
                                    dimension: 100,
                                    child: person.profileUrl == null
                                        ? const ColoredBox(
                                            color: YingjiColors.elevated,
                                            child: Icon(
                                              YingjiIcons.person_fill,
                                            ),
                                          )
                                        : CachedNetworkImage(
                                            fadeInDuration: const Duration(
                                              milliseconds: 150,
                                            ),
                                            imageUrl: person.profileUrl
                                                .toString(),
                                            fit: BoxFit.cover,
                                            // 演员头像 100px，按显示分辨率解码。
                                            memCacheWidth:
                                                (160 *
                                                        MediaQuery.devicePixelRatioOf(
                                                          context,
                                                        ))
                                                    .clamp(1.0, 512.0)
                                                    .round(),
                                            errorWidget: (_, _, _) =>
                                                const ColoredBox(
                                                  color: YingjiColors.elevated,
                                                  child: Icon(
                                                    YingjiIcons.person_fill,
                                                  ),
                                                ),
                                          ),
                                  ),
                                ),
                                const SizedBox(height: 7),
                                Text(
                                  person.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  person.role,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: YingjiColors.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 32),
          _DetailSectionTitle(
            title: '艺术图',
            empty: value.artwork.isEmpty,
            trailing: _SectionShelfControls(
              onPrevious: () => _move(_artworkController, -620),
              onNext: () => _move(_artworkController, 620),
              onAll: () => _showArtwork(value.artwork),
            ),
          ),
          if (value.artwork.isNotEmpty) ...[
            const SizedBox(height: 14),
            SizedBox(
              height: 184,
              child: YingjiSmoothWheel(
                controller: _artworkController,
                stableGlass: true,
                child: MovaHorizontalDrag(
                  child: ListView.separated(
                    controller: _artworkController,
                    scrollDirection: Axis.horizontal,

                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    clipBehavior: Clip.none,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: value.artwork.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 14),
                    itemBuilder: (context, index) {
                      final artwork = value.artwork[index];
                      return InkWell(
                        onTap: () => showDialog<void>(
                          context: context,
                          animationStyle: MovaMotion.dialogAnimationStyle(
                            context,
                          ),
                          builder: (context) => Dialog(
                            backgroundColor: Colors.transparent,
                            elevation: 0,
                            shadowColor: Colors.transparent,
                            surfaceTintColor: Colors.transparent,
                            shape: const RoundedRectangleBorder(),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxWidth: 1100,
                                maxHeight: 720,
                              ),
                              child: CachedNetworkImage(
                                fadeInDuration: const Duration(
                                  milliseconds: 150,
                                ),
                                imageUrl: artwork.url.toString(),
                                fit: BoxFit.contain,
                                // 艺术图大图弹窗（maxWidth 1100），按显示分辨率解码。
                                memCacheWidth:
                                    (1280 *
                                            MediaQuery.devicePixelRatioOf(
                                              context,
                                            ))
                                        .clamp(1.0, 1280.0)
                                        .round(),
                              ),
                            ),
                          ),
                        ),
                        child: _DetailPosterHover(
                          borderRadius: 14,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: CachedNetworkImage(
                              fadeInDuration: const Duration(milliseconds: 150),
                              imageUrl: artwork.url.toString(),
                              width: 300,
                              fit: BoxFit.cover,
                              // 艺术图货架缩略图宽 300，按显示分辨率解码。
                              memCacheWidth:
                                  (320 * MediaQuery.devicePixelRatioOf(context))
                                      .clamp(1.0, 512.0)
                                      .round(),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 32),
          _DetailSectionTitle(
            title: '相似推荐',
            empty: value.recommendations.isEmpty,
            trailing: _SectionShelfControls(
              onPrevious: () => _move(_recommendationController, -420),
              onNext: () => _move(_recommendationController, 420),
              onAll: () => _showRecommendations(value.recommendations),
            ),
          ),
          if (value.recommendations.isNotEmpty) ...[
            const SizedBox(height: 14),
            SizedBox(
              height: 298,
              child: YingjiSmoothWheel(
                controller: _recommendationController,
                stableGlass: true,
                child: MovaHorizontalDrag(
                  child: ListView.separated(
                    controller: _recommendationController,
                    scrollDirection: Axis.horizontal,

                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    clipBehavior: Clip.none,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: value.recommendations.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 16),
                    itemBuilder: (context, index) {
                      final item = value.recommendations[index];
                      return InkWell(
                        onTap: () =>
                            MetadataDetailPage.open(context, item: item),
                        borderRadius: BorderRadius.circular(14),
                        child: _DetailPosterHover(
                          borderRadius: 14,
                          child: SizedBox(
                            width: 164,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(14),
                                  child: SizedBox(
                                    width: 164,
                                    height: 232,
                                    child: item.posterUrl == null
                                        ? const ColoredBox(
                                            color: YingjiColors.elevated,
                                          )
                                        : CachedNetworkImage(
                                            fadeInDuration: const Duration(
                                              milliseconds: 150,
                                            ),
                                            imageUrl: item.posterUrl.toString(),
                                            fit: BoxFit.cover,
                                            // 相似推荐海报 164px 宽，按显示分辨率解码。
                                            memCacheWidth:
                                                (320 *
                                                        MediaQuery.devicePixelRatioOf(
                                                          context,
                                                        ))
                                                    .clamp(1.0, 512.0)
                                                    .round(),
                                            errorWidget: (_, _, _) =>
                                                const ColoredBox(
                                                  color: YingjiColors.elevated,
                                                ),
                                          ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ],
      );
    },
  );

  Future<void> _showCast(List<TmdbPerson> cast) => _showDetailCollection(
    title: '全部演职人员',
    subtitle: '${cast.length} 位 · 姓名、角色与人物照片来自 TMDB',
    icon: YingjiIcons.person_fill,
    childBuilder: (controller) =>
        _FilterablePersonGrid(cast: cast, controller: controller),
  );

  Future<void> _showArtwork(List<TmdbArtwork> artwork) => _showDetailCollection(
    title: '全部艺术图',
    subtitle: '${artwork.length} 张 · 点击查看 TMDB 原始尺寸图片',
    icon: YingjiIcons.rectangle_stack,
    childBuilder: (controller) => GridView.builder(
      controller: controller,
      physics:
          yingjiWheelPhysics ??
          const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: const EdgeInsets.only(top: 16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 390,
        mainAxisExtent: 246,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
      ),
      itemCount: artwork.length,
      itemBuilder: (_, index) =>
          _ArtworkDetailCard(artwork: artwork[index], index: index),
    ),
  );

  Future<void> _showRecommendations(List<TmdbItem> rows) =>
      _showDetailCollection(
        title: '全部相似推荐',
        subtitle: '${rows.length} 部 · 类型、年份、评分与简介',
        icon: YingjiIcons.film,
        childBuilder: (controller) =>
            _FilterableRecommendationGrid(rows: rows, controller: controller),
      );

  Future<void> _showDetailCollection({
    required String title,
    required String subtitle,
    required IconData icon,
    required Widget Function(ScrollController controller) childBuilder,
  }) async {
    final controller = ScrollController();
    try {
      await showModalBottomSheet<void>(
        context: context,
        sheetAnimationStyle: MovaMotion.dialogAnimationStyle(context),
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: .66),
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: YingjiStableScrollGlass(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: SizedBox(
                  height: MediaQuery.sizeOf(context).height * .78,
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Icon(icon, size: 22),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  subtitle,
                                  style: const TextStyle(
                                    color: YingjiColors.muted,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          YingjiMotionIconButton(
                            icon: YingjiIcons.xmark,
                            tooltip: '关闭',
                            size: 36,
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Expanded(
                        child: GlassPanel(
                          radius: 22,
                          padding: EdgeInsets.zero,
                          child: YingjiSmoothWheel(
                            controller: controller,
                            child: childBuilder(controller),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    } finally {
      controller.dispose();
    }
  }
}

class _FilterablePersonGrid extends StatefulWidget {
  const _FilterablePersonGrid({required this.cast, required this.controller});
  final List<TmdbPerson> cast;
  final ScrollController controller;
  @override
  State<_FilterablePersonGrid> createState() => _FilterablePersonGridState();
}

class _FilterablePersonGridState extends State<_FilterablePersonGrid> {
  String _query = '';
  String _sort = '原顺序';
  @override
  Widget build(BuildContext context) {
    final rows = widget.cast
        .where(
          (person) =>
              _query.isEmpty ||
              person.name.toLowerCase().contains(_query.toLowerCase()) ||
              person.role.toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    if (_sort == '姓名') rows.sort((a, b) => a.name.compareTo(b.name));
    return Column(
      children: [
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                onChanged: (value) => setState(() => _query = value),
                decoration: const InputDecoration(
                  prefixIcon: Icon(YingjiIcons.search),
                  hintText: '筛选姓名或角色',
                ),
              ),
            ),
            const SizedBox(width: 10),
            _FilterChip(
              label: '原顺序',
              icon: YingjiIcons.rectangle_stack,
              active: _sort == '原顺序',
              onTap: () => setState(() => _sort = '原顺序'),
            ),
            _FilterChip(
              label: '姓名',
              icon: YingjiIcons.person,
              active: _sort == '姓名',
              onTap: () => setState(() => _sort = '姓名'),
            ),
          ],
        ),
        Expanded(
          child: GridView.builder(
            controller: widget.controller,
            physics:
                yingjiWheelPhysics ??
                const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
            padding: const EdgeInsets.only(top: 16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 230,
              mainAxisExtent: 282,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
            ),
            itemCount: rows.length,
            itemBuilder: (_, index) => _PersonDetailCard(person: rows[index]),
          ),
        ),
      ],
    );
  }
}

class _FilterableRecommendationGrid extends StatefulWidget {
  const _FilterableRecommendationGrid({
    required this.rows,
    required this.controller,
  });
  final List<TmdbItem> rows;
  final ScrollController controller;
  @override
  State<_FilterableRecommendationGrid> createState() =>
      _FilterableRecommendationGridState();
}

class _FilterableRecommendationGridState
    extends State<_FilterableRecommendationGrid> {
  String _type = '全部';
  String _sort = '推荐';
  @override
  Widget build(BuildContext context) {
    final rows = widget.rows
        .where((item) => _type == '全部' || item.kind == _type)
        .toList();
    if (_sort == '评分') rows.sort((a, b) => b.rating.compareTo(a.rating));
    if (_sort == '年份') {
      rows.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));
    }
    return Column(
      children: [
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            children: [
              for (final label in const ['全部', '电影', '剧集'])
                _FilterChip(
                  label: label,
                  icon: YingjiIcons.film,
                  active: _type == label,
                  onTap: () => setState(() => _type = label),
                ),
              for (final label in const ['推荐', '评分', '年份'])
                _FilterChip(
                  label: label,
                  icon: YingjiIcons.slider_horizontal_3,
                  active: _sort == label,
                  onTap: () => setState(() => _sort = label),
                ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            controller: widget.controller,
            physics:
                yingjiWheelPhysics ??
                const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
            padding: const EdgeInsets.only(top: 16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 420,
              mainAxisExtent: 250,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
            ),
            itemCount: rows.length,
            itemBuilder: (_, index) => _RecommendationDetailCard(
              item: rows[index],
              onTap: (from) => MetadataDetailPage.open(from, item: rows[index]),
            ),
          ),
        ),
      ],
    );
  }
}

class _PersonDetailCard extends StatelessWidget {
  const _PersonDetailCard({required this.person});
  final TmdbPerson person;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _PersonPage(person: person)),
    ),
    borderRadius: BorderRadius.circular(14),
    child: _DetailPosterHover(
      borderRadius: 14,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: YingjiGlass.surface(strength: .78),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SizedBox.expand(
                child: person.profileUrl == null
                    ? const ColoredBox(
                        color: YingjiColors.elevated,
                        child: Icon(YingjiIcons.person_fill, size: 42),
                      )
                    : CachedNetworkImage(
                        fadeInDuration: const Duration(milliseconds: 150),
                        imageUrl: person.profileUrl.toString(),
                        fit: BoxFit.cover,
                        // 演员详情卡头像约 110px，按显示分辨率解码。
                        memCacheWidth:
                            (160 * MediaQuery.devicePixelRatioOf(context))
                                .clamp(1.0, 512.0)
                                .round(),
                        errorWidget: (_, _, _) => const ColoredBox(
                          color: YingjiColors.elevated,
                          child: Icon(YingjiIcons.person_fill, size: 42),
                        ),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    person.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(YingjiIcons.person, size: 13),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          person.role.isEmpty ? '角色信息暂缺' : '饰演 ${person.role}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: YingjiColors.muted,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ArtworkDetailCard extends StatelessWidget {
  const _ArtworkDetailCard({required this.artwork, required this.index});
  final TmdbArtwork artwork;
  final int index;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => showDialog<void>(
      context: context,
      animationStyle: MovaMotion.dialogAnimationStyle(context),
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(),
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1200, maxHeight: 780),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: CachedNetworkImage(
                  fadeInDuration: const Duration(milliseconds: 150),
                  imageUrl: artwork.url.toString(),
                  fit: BoxFit.contain,
                  // 艺术图大图弹窗（maxWidth 1200），按显示分辨率解码。
                  memCacheWidth: (1280 * MediaQuery.devicePixelRatioOf(context))
                      .clamp(1.0, 1280.0)
                      .round(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: YingjiMotionIconButton(
                icon: YingjiIcons.xmark,
                tooltip: '关闭',
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    ),
    borderRadius: BorderRadius.circular(14),
    child: _DetailPosterHover(
      borderRadius: 14,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(
            fadeInDuration: const Duration(milliseconds: 150),
            imageUrl: artwork.url.toString(),
            fit: BoxFit.cover,
            // 艺术图详情卡缩略图约 320px，按显示分辨率解码。
            memCacheWidth: (320 * MediaQuery.devicePixelRatioOf(context))
                .clamp(1.0, 512.0)
                .round(),
            errorWidget: (_, _, _) => const ColoredBox(
              color: YingjiColors.elevated,
              child: Icon(YingjiIcons.rectangle_stack),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xC9000000)],
              ),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 10,
            child: Row(
              children: [
                const Icon(YingjiIcons.fullscreen, size: 15),
                const SizedBox(width: 6),
                Text(
                  '艺术图 ${index + 1} · 查看原图',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _RecommendationDetailCard extends StatelessWidget {
  const _RecommendationDetailCard({required this.item, required this.onTap});
  final TmdbItem item;
  final ValueChanged<BuildContext> onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => onTap(context),
    borderRadius: BorderRadius.circular(14),
    child: _DetailPosterHover(
      borderRadius: 14,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: YingjiGlass.surface(strength: .82),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 146,
              height: double.infinity,
              child: item.posterUrl == null
                  ? const ColoredBox(color: YingjiColors.elevated)
                  : CachedNetworkImage(
                      fadeInDuration: const Duration(milliseconds: 150),
                      imageUrl: item.posterUrl.toString(),
                      fit: BoxFit.cover,
                      // 相似推荐详情卡海报 146px 宽，按显示分辨率解码。
                      memCacheWidth:
                          (320 * MediaQuery.devicePixelRatioOf(context))
                              .clamp(1.0, 512.0)
                              .round(),
                      errorWidget: (_, _, _) =>
                          const ColoredBox(color: YingjiColors.elevated),
                    ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      [
                        if (item.year != null) '${item.year}',
                        item.kind,
                        ...item.genres.take(2),
                      ].join(' · '),
                      style: const TextStyle(
                        color: YingjiColors.muted,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 8),
                    MediaRatingRow(item: item),
                    const SizedBox(height: 10),
                    Expanded(
                      child: Text(
                        item.overview?.trim().isNotEmpty == true
                            ? item.overview!
                            : '暂无中文简介',
                        maxLines: 5,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFD7DAE1),
                          fontSize: 12,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _DetailSectionTitle extends StatelessWidget {
  const _DetailSectionTitle({
    required this.title,
    required this.empty,
    this.trailing,
  });
  final String title;
  final bool empty;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
        ),
      ),
      if (empty) ...[
        const Text('暂无数据', style: TextStyle(color: YingjiColors.muted)),
        const SizedBox(width: 14),
      ],
      trailing ?? const SizedBox.shrink(),
    ],
  );
}

class _SectionShelfControls extends StatelessWidget {
  const _SectionShelfControls({
    required this.onPrevious,
    required this.onNext,
    required this.onAll,
  });
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onAll;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const SizedBox(width: 7),
      const SizedBox(width: 7),
      YingjiMotionIconButton(
        icon: YingjiIcons.rectangle_stack,
        tooltip: '全部列表',
        size: 34,
        onPressed: onAll,
      ),
    ],
  );
}

class _PersonPage extends StatefulWidget {
  const _PersonPage({required this.person});
  final TmdbPerson person;

  @override
  State<_PersonPage> createState() => _PersonPageState();
}

class _PersonPageState extends State<_PersonPage> {
  late final TmdbClient _client;
  late final Future<TmdbPersonDetails> _details;
  final _scroll = ScrollController();
  String _type = '全部';
  String _sort = '热门';

  @override
  void initState() {
    super.initState();
    _client = TmdbClient();
    _details = _client.personDetails(widget.person.id);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: YingjiBackdrop(
      overlay: SafeArea(
        child: Column(
          children: [
            YingjiPageChrome(onBack: () => Navigator.pop(context)),
            Expanded(
              child: FutureBuilder<TmdbPersonDetails>(
                future: _details,
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final value = snapshot.data!;
                  // 演员头像与参演作品海报提前进磁盘缓存。
                  YingjiImageWarmup.people([value.person]);
                  YingjiImageWarmup.items(value.credits);
                  var rows = value.credits
                      .where((item) => _type == '全部' || item.kind == _type)
                      .toList();
                  if (_sort == '评分') {
                    rows.sort((a, b) => b.rating.compareTo(a.rating));
                  } else if (_sort == '年份') {
                    rows.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));
                  }
                  return YingjiSmoothWheel(
                    controller: _scroll,
                    stableGlass: true,
                    child: CustomScrollView(
                      controller: _scroll,
                      physics: yingjiWheelPhysics,
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(74, 24, 64, 28),
                          sliver: SliverToBoxAdapter(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _DetailPosterHover(
                                  borderRadius: 18,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(18),
                                    child: SizedBox(
                                      width: 190,
                                      height: 270,
                                      child: value.person.profileUrl == null
                                          ? const ColoredBox(
                                              color: YingjiColors.elevated,
                                              child: Icon(
                                                YingjiIcons.person_fill,
                                                size: 52,
                                              ),
                                            )
                                          : CachedNetworkImage(
                                              fadeInDuration: const Duration(
                                                milliseconds: 150,
                                              ),
                                              imageUrl: value.person.profileUrl
                                                  .toString(),
                                              fit: BoxFit.cover,
                                              // 人物页头像 190px 宽，按显示分辨率解码。
                                              memCacheWidth:
                                                  (320 *
                                                          MediaQuery.devicePixelRatioOf(
                                                            context,
                                                          ))
                                                      .clamp(1.0, 512.0)
                                                      .round(),
                                            ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 28),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        value.person.name,
                                        style: const TextStyle(
                                          fontSize: 42,
                                          height: 1,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: -1,
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        [value.birthday, value.placeOfBirth]
                                            .where(
                                              (text) =>
                                                  text?.isNotEmpty == true,
                                            )
                                            .join(' · '),
                                        style: const TextStyle(
                                          color: YingjiColors.muted,
                                        ),
                                      ),
                                      const SizedBox(height: 16),
                                      YingjiGlassTooltip(
                                        message:
                                            value.biography?.isNotEmpty == true
                                            ? value.biography!
                                            : '暂无人物简介',
                                        child: Text(
                                          value.biography?.isNotEmpty == true
                                              ? value.biography!
                                              : '暂无人物简介',
                                          maxLines: 6,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            height: 1.55,
                                            color: Color(0xFFD9DCE3),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 20),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          for (final label in const [
                                            '全部',
                                            '电影',
                                            '剧集',
                                          ])
                                            _FilterChip(
                                              label: label,
                                              icon: label == '全部'
                                                  ? YingjiIcons.rectangle_stack
                                                  : YingjiIcons.film,
                                              active: _type == label,
                                              onTap: () =>
                                                  setState(() => _type = label),
                                            ),
                                          for (final label in const [
                                            '热门',
                                            '评分',
                                            '年份',
                                          ])
                                            _FilterChip(
                                              label: label,
                                              icon: YingjiIcons
                                                  .slider_horizontal_3,
                                              active: _sort == label,
                                              onTap: () =>
                                                  setState(() => _sort = label),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(74, 0, 64, 64),
                          sliver: SliverGrid(
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 360,
                                  mainAxisExtent: 230,
                                  mainAxisSpacing: 16,
                                  crossAxisSpacing: 16,
                                ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) => _RecommendationDetailCard(
                                item: rows[index],
                                onTap: (from) => MetadataDetailPage.open(
                                  from,
                                  item: rows[index],
                                ),
                              ),
                              childCount: rows.length,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ResourceMessage extends StatelessWidget {
  const _ResourceMessage({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: YingjiGlass.surface(),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        const Icon(YingjiIcons.info_circle, color: YingjiColors.focus),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(color: YingjiColors.muted),
          ),
        ),
      ],
    ),
  );
}
