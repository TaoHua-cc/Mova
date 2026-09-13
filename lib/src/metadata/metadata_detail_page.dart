import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../platform/window_host.dart';

import '../brand.dart';
import '../cache/image_prefetch.dart';
import '../cache/media_cache.dart';
import '../player/player_page.dart';
import '../playlists/playlist_store.dart';
import '../sources/emby_client.dart';
import '../sources/media_source.dart';
import '../sources/server_mark.dart';
import '../sources/source_store.dart';
import '../sources/webdav_client.dart';
import '../history/watchlist_store.dart';
import '../history/watch_state_store.dart';
import '../tracking/trakt_client.dart';
import 'tmdb_client.dart';
import 'ratings.dart';
import 'next_episode.dart';

String _episodeKey(int? season, int? episode) =>
    '${season ?? 0}:${episode ?? 0}';

bool _isGenericEpisodeTitle(String value) =>
    value.trim().isEmpty || RegExp(r'^第\s*\d+\s*集$').hasMatch(value.trim());

String _episodeTitle(MediaItem resource, TmdbEpisode? metadata, int fallback) {
  final title = metadata?.name.trim() ?? '';
  return _isGenericEpisodeTitle(resource.title) && title.isNotEmpty
      ? title
      : resource.title;
}

Uri? _episodeImage(MediaItem resource, TmdbEpisode? metadata) =>
    // TMDB stills are consistently available for mainland shows while some
    // Emby/Jellyfin episode records expose a non-thumbnail primary image.
    // Prefer the episode-specific still, then retain the server artwork.
    metadata?.stillUrl ?? resource.imageUrl;

String _dateLabel(DateTime? date) => date == null
    ? ''
    : '${date.year}年${date.month.toString().padLeft(2, '0')}月${date.day.toString().padLeft(2, '0')}日';

String _minuteClock(int minutes) =>
    '${minutes ~/ 60 > 0 ? '${minutes ~/ 60}:' : ''}${(minutes % 60).toString().padLeft(2, '0')}:00';

class MetadataDetailPage extends StatefulWidget {
  const MetadataDetailPage({super.key, required this.item, this.media});
  final TmdbItem item;
  final MediaItem? media;
  @override
  State<MetadataDetailPage> createState() => _MetadataDetailPageState();
}

class _MetadataDetailPageState extends State<MetadataDetailPage> {
  final _pageScroll = ScrollController();
  late Future<TmdbItem> _details;
  late Future<TmdbExtras> _extras;
  final _client = TmdbClient();
  WatchlistStore? _watchlist;
  bool _inWatchlist = false;
  bool _isFavorite = false;
  List<MediaItem> _resources = const [];
  Set<String> _completedResourceIds = const <String>{};
  Map<String, double> _episodeProgress = const <String, double>{};
  Map<int, Uri> _seasonPosters = const {};
  Map<String, TmdbEpisode> _episodeMetadata = const {};
  MediaItem? _selectedResource;
  bool _loadingResources = true;
  String? _resourceError;
  int? _selectedSeason;
  int? _selectedAudioTrack;
  int? _selectedSubtitleTrack;
  @override
  void initState() {
    super.initState();
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
          _isFavorite = (prefs.getStringList('yingji.favorites') ?? const [])
              .contains(widget.item.id.toString());
        });
      }
    });
    _loadResources();
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
    if (widget.media != null) return false;
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
    final preferred = await _preferredResource(rows);
    final history = (await WatchStateStore.create()).load();
    // Trakt 的已看剧集要联网，先用本机记录把进度渲染出来；真正聚合那一步
    // （或冷却期内的进度刷新）会再带上 Trakt 重算一次。
    final derived = _deriveProgress(rows, history, const <String>{});
    if (!mounted) return false;
    setState(() {
      _resources = rows;
      _seasonPosters = snapshot.seasonPosters;
      _selectedResource = preferred ?? rows.first;
      _completedResourceIds = derived.completed;
      _episodeProgress = derived.progress;
      _selectedSeason =
          preferred?.seasonNumber ??
          rows
              .map((row) => row.seasonNumber)
              .whereType<int>()
              .firstOrNull;
      _loadingResources = false;
    });
    // 剧集名与剧照也立刻补上：TMDB 那侧同样是缓存优先的，不会卡住界面。
    unawaited(_loadEpisodeMetadata(rows));
    YingjiImageWarmup.urls([for (final row in rows) row.imageUrl]);
    return true;
  }

  Future<void> _loadResources({bool force = false}) async {
    if (widget.media != null) {
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
      return;
    }
    // 先用上一次聚合好的快照把页面填满，再决定要不要真的去搜服务器。
    final restored = await _restoreCachedResources();
    final cooling =
        restored && await MediaDetailCache.recentlyScanned(widget.item);
    if (!force && cooling) {
      // 冷却期内重复打开同一部剧：资源卡片沿用缓存，只把观看进度按本机
      // 记录重算一遍，不再把每个服务器都重新翻一遍。
      await _refreshProgressAfterPlayback();
      return;
    }
    try {
      final store = await SourceStore.create();
      final rows = <MediaItem>[];
      final seasonPosters = <int, Uri>{};
      final matchedSeriesIds = <String>{};
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
            // A failed storage source must not hide usable server results.
          }
        } else {
          if (token == null || token.isEmpty) continue;
          final client = EmbyClient();
          try {
            final session = await client.resolveSession(
              EmbySession(source: source, token: token),
            );
            if (session.source.endpoint != source.endpoint) {
              await store.upsert(session.source, token);
            }
            var found = await client.findByTmdbId(session, widget.item.id);
            // Some Emby libraries omit ProviderIds even though their series
            // title is searchable. Search the server before falling back to
            // unrelated recently-added items, otherwise episode rails lose
            // their parent/season identity and cannot be enriched.
            if (found.isEmpty && widget.item.kind == '剧集') {
              found = await client.search(session, widget.item.title);
            }
            if (found.isEmpty) {
              rows.addAll(await client.recentlyAdded(session));
            } else {
              for (final match in found) {
                if (match.type == 'Series' || match.isContainer) {
                  matchedSeriesIds.add(match.id);
                  final seasons = await client.seasonsForSeries(
                    session,
                    match.id,
                  );
                  for (final season in seasons) {
                    final number = season.seasonNumber;
                    final image = season.imageUrl;
                    if (number != null && image != null) {
                      seasonPosters.putIfAbsent(number, () => image);
                    }
                  }
                  rows.addAll(
                    await client.episodesForSeries(session, match.id),
                  );
                } else {
                  rows.add(match);
                }
              }
            }
          } finally {
            client.dispose();
          }
        }
      }
      final title = _normaliseTitle(widget.item.title);
      final matches = rows
          .where((media) {
            // Episode titles normally do not contain the parent series title
            // (for example, “第 1 集”), so preserve episodes fetched from an
            // exact series match before applying the title fallback filter.
            if (matchedSeriesIds.isNotEmpty &&
                media.type == 'Episode' &&
                (matchedSeriesIds.contains(media.seriesId) ||
                    media.seriesId == null)) {
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
      final preferred = await _preferredResource(matches);
      final history = (await WatchStateStore.create()).load();
      final traktCompleted = await _traktCompletedEpisodes();
      final derived = _deriveProgress(matches, history, traktCompleted);
      if (mounted) {
        setState(() {
          _resources = matches;
          _seasonPosters = seasonPosters;
          _selectedResource = preferred;
          _completedResourceIds = derived.completed;
          _episodeProgress = derived.progress;
          _selectedSeason =
              preferred?.seasonNumber ??
              matches
                  .map((item) => item.seasonNumber)
                  .whereType<int>()
                  .firstOrNull;
          _loadingResources = false;
          _resourceError = null;
        });
      }
      unawaited(_loadEpisodeMetadata(matches));
      // 存下这次聚合结果：下次打开先渲染它，再按冷却间隔决定要不要重搜。
      unawaited(
        MediaDetailCache.save(
          widget.item,
          rows: matches,
          seasonPosters: seasonPosters,
        ),
      );
      unawaited(MediaDetailCache.markScanned(widget.item));
      YingjiImageWarmup.urls([
        for (final resource in matches) resource.imageUrl,
      ]);
    } catch (error) {
      if (mounted) {
        setState(() {
          _loadingResources = false;
          _resourceError = error.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  /// Derives per-episode progress and the completed-resource set from watch
  /// history (local + server) and Trakt. Shared by the initial resource load
  /// and by the post-playback refresh so both stay on the same rules.
  ({Set<String> completed, Map<String, double> progress}) _deriveProgress(
    List<MediaItem> resources,
    List<WatchState> history,
    Set<String> traktCompleted,
  ) {
    final completed = resources
        .where(
          (resource) =>
              history.any(
                (state) =>
                    (state.serverItemId == resource.id ||
                        state.mediaId == resource.playbackUrl?.toString()) &&
                    state.progress >= .92,
              ) ||
              resource.isPlayed ||
              _mediaProgress(resource) >= .92 ||
              traktCompleted.contains(
                _episodeKey(resource.seasonNumber, resource.episodeNumber),
              ),
        )
        .map((resource) => resource.id)
        .toSet();
    final progress = <String, double>{};
    for (final resource in resources) {
      final local = history
          .where(
            (state) =>
                state.serverItemId == resource.id ||
                state.mediaId == resource.playbackUrl?.toString(),
          )
          .firstOrNull;
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
      final next = serverProgress > localProgress
          ? serverProgress
          : localProgress;
      if (next > (progress[key] ?? 0)) progress[key] = next;
    }
    return (completed: completed, progress: progress);
  }

  /// Re-derives episode progress after the player closes. The initial
  /// [_loadResources] snapshot predates playback, so without this the episode
  /// rails keep showing the position captured before the session started.
  Future<void> _refreshProgressAfterPlayback() async {
    if (!mounted || _loadingResources) return;
    final history = (await WatchStateStore.create()).load();
    final traktCompleted = await _traktCompletedEpisodes();
    final derived = _deriveProgress(_resources, history, traktCompleted);
    if (!mounted) return;
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
    final prefs = await SharedPreferences.getInstance();
    final clientId = prefs.getString('yingji.trakt.client-id') ?? '';
    final token = prefs.getString('yingji.trakt.access-token') ?? '';
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
    return filtered.isEmpty ? _resources : filtered;
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
        state.serverItemId == resource.id ||
        state.mediaId == resource.playbackUrl?.toString();
    double progressFor(MediaItem resource) {
      final local = history
          .where((state) => matches(state, resource))
          .map((state) => state.progress)
          .fold<double>(0, math.max);
      final server = _mediaProgress(resource);
      return math.max(local, server);
    }

    final resumable = ordered.where((resource) {
      final progress = progressFor(resource);
      return progress > 0 && progress < .92;
    }).toList()..sort((a, b) => progressFor(b).compareTo(progressFor(a)));
    if (resumable.isNotEmpty) return resumable.first;
    final played = <String>{};
    for (final resource in ordered) {
      if (history.any((state) => matches(state, resource))) {
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

  Future<void> _selectSeason(int season) async {
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

  Future<void> _selectEpisode(MediaItem episode) async {
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
    final watchStore = await WatchStateStore.create();
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
    for (final version in versions) {
      final mediaId = version.playbackUrl?.toString() ?? version.id;
      if (completed) {
        final duration = version.runtime ?? const Duration(seconds: 1);
        await watchStore.save(
          WatchState(
            mediaId: mediaId,
            serverItemId: version.id,
            sourceId: version.source.id,
            tmdbId: widget.item.id,
            title: version.title,
            episodeTitle: version.title,
            seasonNumber: version.seasonNumber,
            episodeNumber: version.episodeNumber,
            imageUrl: version.imageUrl?.toString(),
            position: duration,
            duration: duration,
          ),
        );
      } else {
        await watchStore.remove(mediaId);
      }
    }
    final messages = <String>[];
    try {
      for (final version in versions.where(
        (item) => item.source.kind != SourceKind.webdav,
      )) {
        final store = await SourceStore.create();
        final token = store.tokenFor(version.source);
        if (token != null && token.isNotEmpty) {
          final client = EmbyClient();
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
      final prefs = await SharedPreferences.getInstance();
      final clientId = prefs.getString('yingji.trakt.client-id') ?? '';
      final token = prefs.getString('yingji.trakt.access-token') ?? '';
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
      backgroundColor: YingjiGlass.surface(strength: 1.15),
      builder: (context) => SafeArea(
        child: ListView(
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

  Future<void> _showResourcePicker({MediaSource? source}) async {
    final choices = source == null
        ? _visibleResources
        : _visibleResources
              .where((resource) => resource.source.id == source.id)
              .toList();
    if (choices.isEmpty) return;
    final selected = await showModalBottomSheet<MediaItem>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          child: GlassPanel(
            radius: 20,
            padding: const EdgeInsets.all(18),
            child: ListView(
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
                        resource.id == _selectedResource?.id &&
                        resource.source.id == _selectedResource?.source.id,
                    onTap: () => Navigator.pop(context, resource),
                  ),
                  const SizedBox(height: 9),
                ],
              ],
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
      barrierColor: Colors.black.withValues(alpha: .62),
      builder: (context) => StatefulBuilder(
        builder: (context, updateDialog) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 920,
              maxHeight: math.min(MediaQuery.sizeOf(context).height * .84, 720),
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
                                selected: _selectedSubtitleTrack == track.index,
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
                          return ListView(
                            children: [
                              SizedBox(height: 360, child: audio),
                              const SizedBox(height: 14),
                              SizedBox(height: 360, child: subtitles),
                            ],
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
    );
  }

  // ignore: unused_element
  Future<void> _showMore(TmdbItem item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
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

  String _resourceSummary(MediaItem resource) => [
    if (resource.width != null && resource.height != null)
      '${resource.width}×${resource.height}',
    if (resource.videoCodec != null) resource.videoCodec!.toUpperCase(),
    if (resource.container != null) resource.container!.toUpperCase(),
    if (resource.bitrate != null)
      '${(resource.bitrate! / 1000000).toStringAsFixed(1)} Mbps',
  ].join(' · ');

  List<PlayerResourceOption> _playerResourcesFor(MediaItem episode) {
    final rows = _resources
        .where(
          (candidate) =>
              candidate.playbackUrl != null &&
              candidate.seasonNumber == episode.seasonNumber &&
              candidate.episodeNumber == episode.episodeNumber,
        )
        .toList();
    rows.sort((a, b) {
      final resolution = (b.width ?? 0).compareTo(a.width ?? 0);
      if (resolution != 0) return resolution;
      final range = (b.videoRange ?? '').compareTo(a.videoRange ?? '');
      if (range != 0) return range;
      return (b.bitrate ?? 0).compareTo(a.bitrate ?? 0);
    });
    return rows
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
          ),
        )
        .toList(growable: false);
  }

  @override
  void dispose() {
    _pageScroll.dispose();
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: YingjiColors.canvas,
    body: FutureBuilder<TmdbItem>(
      future: _details,
      builder: (context, snapshot) {
        final item = snapshot.data ?? widget.item;
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
                    CachedNetworkImage(
                      imageUrl: item.backdropUrl.toString(),
                      fit: BoxFit.cover,
                      // 默认 500ms 淡入会让全屏大图逐帧做 alpha 合成（正好压在进
                      // 页面的转场上），背景直接显示。
                      fadeInDuration: Duration.zero,
                      fadeOutDuration: Duration.zero,
                      // 全屏窗口下 backdrop 原图可能上千像素：按窗口实际物理宽度
                      // 解码，省内存也省每帧纹理带宽。
                      memCacheWidth:
                          (MediaQuery.sizeOf(context).width *
                                  MediaQuery.devicePixelRatioOf(context))
                              .clamp(1.0, 2560.0)
                              .round(),
                      errorWidget: (_, _, _) => const SizedBox.shrink(),
                    ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.topRight,
                        radius: 1.15,
                        colors: [Color(0x553B6A4D), Color(0xE807090D)],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SafeArea(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _DetailSidebar(
                    onNavigate: (section) {
                      yingjiSectionRequest.value = section;
                      Navigator.pop(context);
                    },
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        _DetailTopBar(
                          onBack: () => Navigator.pop(context),
                          onSearch: () => _showResourceSearch(context),
                        ),
                        Expanded(
                          child: YingjiSmoothWheel(
                            controller: _pageScroll,
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
                                YingjiLayout.detailLeadingInset,
                                10,
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
                                    if (mounted) {
                                      setState(
                                        () => _inWatchlist = !_inWatchlist,
                                      );
                                    }
                                  },
                                  onFavorite: _toggleFavorite,
                                ),
                                const SizedBox(height: 32),
                                if (_resources.isNotEmpty &&
                                    item.kind == '剧集') ...[
                                  _SeasonRail(
                                    resources: _resources,
                                    posters: _seasonPosters,
                                    selectedSeason: _selectedSeason,
                                    onSelect: _selectSeason,
                                  ),
                                  const SizedBox(height: 24),
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
                                  resources: _visibleResources,
                                  selected: _selectedResource,
                                  loading: _loadingResources,
                                  error: _resourceError,
                                  // 手动重试要绕开冷却间隔，立刻重搜。
                                  onRetry: () => _loadResources(force: true),
                                  onPicker: (resource) => _showResourcePicker(
                                    source: resource.source,
                                  ),
                                  onSelect: (resource) => setState(
                                    () => _selectedResource = resource,
                                  ),
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
                                _DetailExtrasSection(extras: _extras),
                              ],
                            ),
                          ),
                        ),
                      ],
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
    if (resource?.playbackUrl == null) return;
    final watchStore = await WatchStateStore.create();
    final saved = watchStore.load().where((state) {
      return state.serverItemId == resource!.id ||
          state.mediaId == resource.playbackUrl.toString();
    }).firstOrNull;
    final remotePosition = resource!.playbackPosition ?? Duration.zero;
    final savedPosition = saved?.position ?? Duration.zero;
    final resumePosition = remotePosition > savedPosition
        ? remotePosition
        : savedPosition;
    if (!context.mounted) return;
    final episodeByKey = <String, MediaItem>{};
    for (final candidate in _resources) {
      if (candidate.playbackUrl == null || candidate.episodeNumber == null) {
        continue;
      }
      final key = _episodeKey(candidate.seasonNumber, candidate.episodeNumber);
      episodeByKey.putIfAbsent(key, () => candidate);
    }
    episodeByKey[_episodeKey(resource.seasonNumber, resource.episodeNumber)] =
        resource;
    final episodeOptions = episodeByKey.values.toList()
      ..sort((a, b) {
        final season = (a.seasonNumber ?? 0).compareTo(b.seasonNumber ?? 0);
        return season == 0
            ? (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0)
            : season;
      });
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          url: resource.playbackUrl.toString(),
          title: item.title,
          seriesLogoUrl: item.logoUrl?.toString(),
          episodeTitle: resource.title,
          resourceInfo: [
            resource.source.name,
            _resourceSummary(resource),
          ].where((value) => value.isNotEmpty).join(' · '),
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
                (episode) => PlayerEpisode(
                  url: episode.playbackUrl!.toString(),
                  title: item.title,
                  headers: episode.headers,
                  imageUrl: _episodeImage(
                    episode,
                    _episodeMetadata[_episodeKey(
                      episode.seasonNumber,
                      episode.episodeNumber,
                    )],
                  )?.toString(),
                  seriesLogoUrl: item.logoUrl?.toString(),
                  episodeTitle: _episodeTitle(
                    episode,
                    _episodeMetadata[_episodeKey(
                      episode.seasonNumber,
                      episode.episodeNumber,
                    )],
                    episode.episodeNumber ?? 1,
                  ),
                  resourceInfo: [
                    episode.source.name,
                    _resourceSummary(episode),
                  ].where((value) => value.isNotEmpty).join(' · '),
                  sourceId: episode.source.id,
                  serverItemId: episode.id,
                  tmdbId: item.id,
                  seasonNumber: episode.seasonNumber,
                  episodeNumber: episode.episodeNumber,
                  chapters: episode.chapters,
                  initialPosition:
                      episode.playbackUrl.toString() ==
                          resource.playbackUrl.toString()
                      ? resumePosition
                      : Duration.zero,
                  initialAudioTrack: _selectedAudioTrack,
                  initialSubtitleTrack: _selectedSubtitleTrack,
                  resources: _playerResourcesFor(episode),
                ),
              )
              .toList(growable: false),
        ),
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

class _DetailSidebar extends StatelessWidget {
  const _DetailSidebar({required this.onNavigate});
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) => SizedBox(
    // 宽度与内边距都取自统一栅格，侧栏按钮槽位和正文锚点一起移动。
    width: YingjiLayout.detailSidebarWidth,
    child: Padding(
      padding: YingjiLayout.detailSidebarPadding,
      child: Column(
        children: [
          const YingjiMark(size: 42),
          const SizedBox(height: 18),
          const Spacer(),
          // 顺序与首页左侧导航完全一致（首页 → 追剧 → 片单 → 服务器），
          // 同一个入口在不同页面必须落在同一个位置。
          for (final item in const <(IconData, String, String)>[
            (YingjiIcons.house, 'home', '首页'),
            (YingjiIcons.calendar, 'calendar', '追剧'),
            (YingjiIcons.heart, 'playlists', '片单'),
            (YingjiIcons.rectangle_stack, 'sources', '服务器'),
          ]) ...[
            _DetailRailButton(
              icon: item.$1,
              tooltip: item.$3,
              onPressed: () => onNavigate(item.$2),
            ),
            const SizedBox(height: 10),
          ],
          const Spacer(),
          _DetailRailButton(
            icon: YingjiIcons.gear,
            tooltip: '设置',
            onPressed: () => onNavigate('settings'),
          ),
        ],
      ),
    ),
  );
}

class _DetailRailButton extends StatelessWidget {
  const _DetailRailButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });
  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => YingjiMotionIconButton(
    icon: icon,
    tooltip: tooltip ?? '操作',
    size: 44,
    onPressed: onPressed,
  );
}

class _DetailTopBar extends StatelessWidget {
  const _DetailTopBar({required this.onBack, required this.onSearch});
  final VoidCallback onBack;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) => Padding(
    // 左边距补上侧栏宽度正好等于 YingjiLayout.pageLeft，与正文、与其它页面
    // 对齐；右侧与首页顶部栏一致，搜索按钮因此固定在屏幕最右。
    padding: EdgeInsets.only(
      left: YingjiLayout.detailLeadingInset,
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
          _DetailRailButton(icon: YingjiIcons.search, onPressed: onSearch),
        if (WindowHost.isDesktop) ...[
          const SizedBox(width: 8),
          _DetailRailButton(
            icon: YingjiIcons.minus,
            onPressed: WindowHost.minimize,
          ),
          const SizedBox(width: 8),
          _DetailRailButton(
            icon: YingjiIcons.square,
            onPressed: WindowHost.toggleMaximize,
          ),
          const SizedBox(width: 8),
          _DetailRailButton(
            icon: YingjiIcons.xmark,
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
      Row(
        children: [
          _DetailAction(
            icon: YingjiIcons.play_fill,
            label: selected?.playbackUrl == null ? '暂无可播放资源' : '播放',
            primary: true,
            enabled: selected?.playbackUrl != null,
            onPressed: onPlay,
          ),
          const SizedBox(width: 12),
          YingjiMotionIconButton(
            icon: YingjiIcons.bookmark,
            tooltip: inWatchlist ? '移出待看' : '加入待看',
            selected: inWatchlist,
            size: 46,
            onPressed: onWatchlist,
          ),
          const SizedBox(width: 8),
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
        child: YingjiSynopsisTooltip(
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
    return Tooltip(
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
    required this.posters,
    required this.selectedSeason,
    required this.onSelect,
  });
  final List<MediaItem> resources;
  final Map<int, Uri> posters;
  final int? selectedSeason;
  final ValueChanged<int> onSelect;

  @override
  State<_SeasonRail> createState() => _SeasonRailState();
}

class _SeasonRailState extends State<_SeasonRail> {
  final ScrollController _controller = ScrollController();

  void _move(double delta) {
    if (!_controller.hasClients) return;
    _controller.animateTo(
      (_controller.offset + delta).clamp(
        0,
        _controller.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  List<int> get _seasons =>
      widget.resources
          .map((item) => item.seasonNumber)
          .whereType<int>()
          .toSet()
          .toList()
        ..sort();

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
            YingjiDirectionalArrow(
              previous: true,
              tooltip: '上一组季',
              size: 34,
              onPressed: () => _move(-420),
            ),
            const SizedBox(width: 7),
            YingjiDirectionalArrow(
              previous: false,
              tooltip: '下一组季',
              size: 34,
              onPressed: () => _move(420),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 190,
          child: ListView.separated(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
            itemCount: seasons.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
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
                    width: 112,
                    child: Column(
                      children: [
                        Expanded(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              color: const Color(0xCC1A1D22),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: active
                                    ? Colors.white
                                    : Colors.white.withValues(alpha: .12),
                                width: active ? 2.2 : 1,
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
                                : CachedNetworkImage(
                                    fadeInDuration: const Duration(milliseconds: 150),
                                    imageUrl: artwork.toString(),
                                    fit: BoxFit.cover,
                                    errorWidget: (_, _, _) => const Center(
                                      child: Icon(YingjiIcons.film),
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
      ],
    );
  }
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
  int? _hoveredIndex;

  void _move(double delta) {
    if (!_controller.hasClients) return;
    _controller.animateTo(
      (_controller.offset + delta).clamp(
        0,
        _controller.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

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
    final choice = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭剧集菜单',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (dialogContext, _, _) {
        final size = MediaQuery.sizeOf(dialogContext);
        final left = position.dx.clamp(12.0, size.width - 268.0);
        final top = position.dy.clamp(12.0, size.height - 154.0);
        return Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              width: 256,
              child: Material(
                color: Colors.transparent,
                child: GlassPanel(
                  radius: 16,
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _EpisodeContextAction(
                        icon: YingjiIcons.checkmark_circle_fill,
                        label: '标记为已播放',
                        selected: completed,
                        onTap: () => Navigator.pop(dialogContext, 'played'),
                      ),
                      const SizedBox(height: 5),
                      _EpisodeContextAction(
                        icon: YingjiIcons.refresh,
                        label: '标记为未播放',
                        selected: !completed,
                        onTap: () => Navigator.pop(dialogContext, 'unplayed'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
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
          YingjiDirectionalArrow(
            previous: true,
            tooltip: '上一组剧集',
            onPressed: () => _move(-720),
          ),
          const SizedBox(width: 7),
          YingjiDirectionalArrow(
            previous: false,
            tooltip: '下一组剧集',
            onPressed: () => _move(720),
          ),
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
        child: ListView.separated(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          itemCount: widget.resources.length,
          separatorBuilder: (_, _) => const SizedBox(width: 18),
          itemBuilder: (_, index) {
            final resource = widget.resources[index];
            final effectiveSeason =
                resource.seasonNumber ?? widget.selected?.seasonNumber ?? 1;
            final effectiveEpisode = resource.episodeNumber ?? index + 1;
            final episodeMetadata =
                widget.metadata[_episodeKey(effectiveSeason, effectiveEpisode)];
            final title = _episodeTitle(resource, episodeMetadata, index + 1);
            final image = _episodeImage(resource, episodeMetadata);
            final overview = resource.overview?.trim().isNotEmpty == true
                ? resource.overview!
                : episodeMetadata?.overview;
            final published = resource.premiereDate ?? episodeMetadata?.airDate;
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
            return MouseRegion(
              onEnter: (_) => setState(() => _hoveredIndex = index),
              onExit: (_) => setState(() => _hoveredIndex = null),
              child: InkWell(
                onTap: () => widget.onSelect(resource),
                onSecondaryTapUp: (details) => _showMarkMenu(
                  context,
                  resource,
                  completed,
                  details.globalPosition,
                ),
                borderRadius: BorderRadius.circular(14),
                child: AnimatedScale(
                  scale: lifted ? 1.018 : 1,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  child: AnimatedSlide(
                    offset: lifted ? const Offset(0, -.015) : Offset.zero,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    child: SizedBox(
                      width: 238,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            height: 134,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 220),
                              clipBehavior: Clip.antiAlias,
                              decoration: BoxDecoration(
                                color: const Color(0xFF25292A),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: .1),
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
                                          fadeInDuration: const Duration(milliseconds: 150),
                                          imageUrl: image.toString(),
                                          fit: BoxFit.cover,
                                          errorWidget: (_, _, _) =>
                                              const _EpisodeArtworkFallback(),
                                        ),
                                  if (completed)
                                    const Positioned(
                                      right: 10,
                                      top: 10,
                                      child: Icon(
                                        YingjiIcons.checkmark_circle_fill,
                                      ),
                                    ),
                                  if (active)
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                            border: Border.all(
                                              color: Colors.white,
                                              width: 2.4,
                                            ),
                                          ),
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
                                                  (runtime * progress).round(),
                                                ),
                                                style: const TextStyle(
                                                  fontSize: 10.5,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                              const Spacer(),
                                              Text(
                                                _minuteClock(
                                                  (runtime * (1 - progress))
                                                      .round(),
                                                ),
                                                style: const TextStyle(
                                                  fontSize: 10.5,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              99,
                                            ),
                                            child: LinearProgressIndicator(
                                              value: progress,
                                              minHeight: 3,
                                              backgroundColor: Colors.white24,
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
                            YingjiSynopsisTooltip(
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
            );
          },
        ),
      ),
    ],
  );

  Future<void> _showAllEpisodes() {
    final completedIds = Set<String>.of(widget.completedResourceIds);
    final episodeProgress = Map<String, double>.of(widget.episodeProgress);
    return showDialog<void>(
      context: context,
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
            maxWidth: 1180,
            maxHeight: 820,
            insetPadding: const EdgeInsets.all(24),
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
                        '选择剧集继续播放，右键可更新观看状态',
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
                    final columns = constraints.maxWidth >= 960
                        ? 3
                        : constraints.maxWidth >= 620
                        ? 2
                        : 1;
                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: widget.resources.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: 14,
                        crossAxisSpacing: 14,
                        childAspectRatio: columns == 1 ? 2.25 : 1.2,
                      ),
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
                        return _AllEpisodeCard(
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

class _AllEpisodeCard extends StatelessWidget {
  const _AllEpisodeCard({
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

  @override
  Widget build(BuildContext context) => YingjiMotionSurface(
    selected: selected,
    borderRadius: 16,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onSecondaryTapUp: onSecondaryTapUp,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            color: selected
                ? YingjiGlass.surface(strength: 1.18)
                : YingjiGlass.chrome(strength: .66),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(16),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      image == null
                          ? const _EpisodeArtworkFallback()
                          : CachedNetworkImage(
                              fadeInDuration: const Duration(milliseconds: 150),
                              imageUrl: image.toString(),
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) =>
                                  const _EpisodeArtworkFallback(),
                            ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Color(0xB8000000)],
                          ),
                        ),
                      ),
                      Positioned(
                        left: 12,
                        top: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: .62),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Text(
                            'S${episode.seasonNumber ?? 1} · E${episode.episodeNumber ?? index + 1}',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 12,
                        top: 12,
                        child: Icon(
                          completed
                              ? YingjiIcons.checkmark_circle_fill
                              : progress > 0
                              ? YingjiIcons.play_circle_fill
                              : YingjiIcons.circle,
                          size: 21,
                          color: completed || progress > 0
                              ? Colors.white
                              : Colors.white54,
                        ),
                      ),
                      if (progress > 0 && !completed)
                        Positioned(
                          left: 12,
                          right: 12,
                          bottom: 10,
                          child: Column(
                            children: [
                              if (runtime != null)
                                Row(
                                  children: [
                                    Text(
                                      _minuteClock(
                                        (runtime! * progress).round(),
                                      ),
                                      style: const TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const Spacer(),
                                    Text(
                                      _minuteClock(
                                        (runtime! * (1 - progress)).round(),
                                      ),
                                      style: const TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              const SizedBox(height: 4),
                              LinearProgressIndicator(
                                value: progress.clamp(0, 1),
                                minHeight: 3,
                                borderRadius: BorderRadius.circular(99),
                                backgroundColor: Colors.white24,
                                color: Colors.white,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(13, 11, 13, 13),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '第 ${episode.episodeNumber ?? index + 1} 集 · $title',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      [
                        if (_dateLabel(published).isNotEmpty)
                          _dateLabel(published),
                        if (runtime != null) '$runtime 分钟',
                        completed
                            ? '已播放'
                            : progress > 0
                            ? '${(progress * 100).round()}%'
                            : '未播放',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: YingjiColors.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (overview?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: 6),
                      YingjiSynopsisTooltip(
                        message: overview!,
                        child: Text(
                          overview!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFD5D8DF),
                            fontSize: 11,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
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

class _EpisodeContextAction extends StatelessWidget {
  const _EpisodeContextAction({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: selected
            ? Colors.white.withValues(alpha: .13)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected ? Colors.white : Colors.transparent,
          width: selected ? 2.2 : 1,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          if (selected) const Icon(YingjiIcons.checkmark_circle_fill, size: 17),
        ],
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
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: lifted ? 1.018 : 1,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: AnimatedSlide(
          offset: lifted ? const Offset(0, -.012) : Offset.zero,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: EdgeInsets.all(lifted ? 2.2 : 0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              border: Border.all(
                color: lifted ? Colors.white : Colors.transparent,
                width: lifted ? 2.2 : 0,
              ),
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
            child: ClipRRect(
              borderRadius: BorderRadius.circular(
                math.max(0, widget.borderRadius - 2),
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

class _ResourceSection extends StatefulWidget {
  const _ResourceSection({
    required this.resources,
    required this.selected,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.onPicker,
    required this.onSelect,
  });
  final List<MediaItem> resources;
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
  static const _sortPreferenceKey = 'yingji.detail.resource-sort';
  static const _viewPreferenceKey = 'yingji.detail.resource-view';
  String _sort = 'range';
  String _viewMode = 'server';

  @override
  void initState() {
    super.initState();
    _restorePreferences();
  }

  Future<void> _restorePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final sort = prefs.getString(_sortPreferenceKey);
    final view = prefs.getString(_viewPreferenceKey);
    if (!mounted) return;
    setState(() {
      if (const {'range', 'resolution', 'bitrate', 'size'}.contains(sort)) {
        _sort = sort!;
      }
      if (const {'server', 'resource'}.contains(view)) _viewMode = view!;
    });
  }

  Future<void> _selectSort(String value) async {
    setState(() => _sort = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sortPreferenceKey, value);
  }

  Future<void> _toggleViewMode() async {
    final value = _viewMode == 'server' ? 'resource' : 'server';
    setState(() => _viewMode = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_viewPreferenceKey, value);
  }

  List<MediaItem> get _sorted {
    final rows = [...widget.resources];
    switch (_sort) {
      case 'resolution':
        rows.sort((a, b) => (b.width ?? 0).compareTo(a.width ?? 0));
      case 'bitrate':
        rows.sort((a, b) => (b.bitrate ?? 0).compareTo(a.bitrate ?? 0));
      case 'size':
        rows.sort((a, b) => (b.size ?? 0).compareTo(a.size ?? 0));
      case 'range':
        rows.sort((a, b) => (b.videoRange ?? '').compareTo(a.videoRange ?? ''));
      default:
        rows.sort(
          (a, b) => (a.container ?? a.type).compareTo(b.container ?? b.type),
        );
    }
    return rows;
  }

  List<MediaItem> get _displayed {
    if (_viewMode == 'resource') return _sorted;
    final bestByServer = <String, MediaItem>{};
    for (final resource in _sorted) {
      bestByServer.putIfAbsent(resource.source.id, () => resource);
    }
    return bestByServer.values.toList();
  }

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
          const SizedBox(width: 14),
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
          const Spacer(),
          YingjiMotionIconButton(
            icon: _viewMode == 'server'
                ? YingjiIcons.cloud
                : YingjiIcons.rectangle_stack,
            tooltip: _viewMode == 'server' ? '按服务器展示' : '按资源展示',
            selected: true,
            size: 38,
            onPressed: _toggleViewMode,
          ),
        ],
      ),
      const SizedBox(height: 14),
      if (widget.loading)
        const LinearProgressIndicator(minHeight: 2)
      else if (widget.error != null)
        _ResourceMessage(message: widget.error!, onRetry: widget.onRetry)
      else if (widget.resources.isEmpty)
        const _ResourceMessage(message: '没有在已连接来源中找到可播放资源。')
      else
        SizedBox(
          height: 144,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _displayed.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (_, index) {
              final resource = _displayed[index];
              return _ResourceCard(
                resource: resource,
                selected:
                    resource.id == widget.selected?.id &&
                    resource.source.id == widget.selected?.source.id,
                onSelect: () => widget.onSelect(resource),
                showPicker: _viewMode == 'server',
                rank: index < 3 ? index + 1 : null,
                onPicker: () => widget.onPicker(resource),
              );
            },
          ),
        ),
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
    child: Tooltip(
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

class _TrackPickerPane extends StatelessWidget {
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
              Icon(icon, size: 17),
              const SizedBox(width: 8),
              Text(
                title,
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
                  '$count 条',
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
            thumbVisibility: children.length > 5,
            child: ListView.separated(
              padding: const EdgeInsets.only(right: 4),
              itemCount: children.length,
              separatorBuilder: (_, _) => const SizedBox(height: 7),
              itemBuilder: (_, index) => children[index],
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
        Row(
          children: [
            _FilterChip(
              label: '资源详情',
              icon: YingjiIcons.info_circle,
              active: _expanded,
              onTap: () => setState(() => _expanded = !_expanded),
            ),
            const SizedBox(width: 14),
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
    required this.showPicker,
    required this.rank,
  });

  final MediaItem resource;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onPicker;
  final bool showPicker;
  final int? rank;

  @override
  Widget build(BuildContext context) => _DetailCardMotion(
    selected: selected,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: YingjiGlass.blur,
          sigmaY: YingjiGlass.blur,
        ),
        child: InkWell(
          onTap: onSelect,
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: 268,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 13),
            decoration: BoxDecoration(
              color: selected
                  ? YingjiGlass.surface(strength: 1.28)
                  : YingjiGlass.surface(strength: .86),
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
                    if (showPicker) ...[
                      const SizedBox(width: 4),
                      Tooltip(
                        message: '切换该服务器资源',
                        child: InkResponse(
                          onTap: onPicker,
                          radius: 20,
                          child: const Padding(
                            padding: EdgeInsets.all(5),
                            child: Icon(
                              YingjiIcons.slider_horizontal_3,
                              size: 16,
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

/// Detail-only card motion now matches the global shelf treatment: a small,
/// stable lift and soft halo instead of a separate, abrupt resource style.
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
      child: AnimatedScale(
        scale: widget.selected ? 1.025 : (_hovered ? 1.014 : 1),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
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
      if (snapshot.connectionState == ConnectionState.waiting) {
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
              child: ListView.separated(
                controller: _castController,
                scrollDirection: Axis.horizontal,
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
                                        child: Icon(YingjiIcons.person_fill),
                                      )
                                    : CachedNetworkImage(
                                        fadeInDuration: const Duration(milliseconds: 150),
                                        imageUrl: person.profileUrl.toString(),
                                        fit: BoxFit.cover,
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
              child: ListView.separated(
                controller: _artworkController,
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: value.artwork.length,
                separatorBuilder: (_, _) => const SizedBox(width: 14),
                itemBuilder: (context, index) {
                  final artwork = value.artwork[index];
                  return InkWell(
                    onTap: () => showDialog<void>(
                      context: context,
                      builder: (context) => Dialog(
                        backgroundColor: Colors.transparent,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: 1100,
                            maxHeight: 720,
                          ),
                          child: CachedNetworkImage(
                            fadeInDuration: const Duration(milliseconds: 150),
                            imageUrl: artwork.url.toString(),
                            fit: BoxFit.contain,
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
                        ),
                      ),
                    ),
                  );
                },
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
              child: ListView.separated(
                controller: _recommendationController,
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: value.recommendations.length,
                separatorBuilder: (_, _) => const SizedBox(width: 16),
                itemBuilder: (context, index) {
                  final item = value.recommendations[index];
                  return InkWell(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => MetadataDetailPage(item: item),
                      ),
                    ),
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
                                        fadeInDuration: const Duration(milliseconds: 150),
                                        imageUrl: item.posterUrl.toString(),
                                        fit: BoxFit.cover,
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
          ],
        ],
      );
    },
  );

  Future<void> _showCast(List<TmdbPerson> cast) => _showDetailCollection(
    title: '全部演职人员',
    subtitle: '${cast.length} 位 · 姓名、角色与人物照片来自 TMDB',
    icon: YingjiIcons.person_fill,
    child: _FilterablePersonGrid(cast: cast),
  );

  Future<void> _showArtwork(List<TmdbArtwork> artwork) => _showDetailCollection(
    title: '全部艺术图',
    subtitle: '${artwork.length} 张 · 点击查看 TMDB 原始尺寸图片',
    icon: YingjiIcons.rectangle_stack,
    child: GridView.builder(
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
        child: _FilterableRecommendationGrid(rows: rows),
      );

  Future<void> _showDetailCollection({
    required String title,
    required String subtitle,
    required IconData icon,
    required Widget child,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .66),
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: GlassPanel(
          radius: 22,
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
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _FilterablePersonGrid extends StatefulWidget {
  const _FilterablePersonGrid({required this.cast});
  final List<TmdbPerson> cast;
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
  const _FilterableRecommendationGrid({required this.rows});
  final List<TmdbItem> rows;
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
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MetadataDetailPage(item: rows[index]),
                  ),
                );
              },
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
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
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
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
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
      Text(
        title,
        style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
      ),
      if (empty) ...[
        const SizedBox(width: 14),
        const Text('暂无数据', style: TextStyle(color: YingjiColors.muted)),
      ],
      const Spacer(),
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
      YingjiDirectionalArrow(
        previous: true,
        tooltip: '向左浏览',
        onPressed: onPrevious,
      ),
      const SizedBox(width: 7),
      YingjiDirectionalArrow(
        previous: false,
        tooltip: '向右浏览',
        onPressed: onNext,
      ),
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
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: YingjiBackdrop(
      blur: 24,
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
                  return CustomScrollView(
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
                                            fadeInDuration: const Duration(milliseconds: 150),
                                            imageUrl: value.person.profileUrl
                                                .toString(),
                                            fit: BoxFit.cover,
                                          ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 28),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
                                            (text) => text?.isNotEmpty == true,
                                          )
                                          .join(' · '),
                                      style: const TextStyle(
                                        color: YingjiColors.muted,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    YingjiSynopsisTooltip(
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
                                            icon:
                                                YingjiIcons.slider_horizontal_3,
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
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      MetadataDetailPage(item: rows[index]),
                                ),
                              ),
                            ),
                            childCount: rows.length,
                          ),
                        ),
                      ),
                    ],
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
  const _ResourceMessage({required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: YingjiGlass.surface(),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: YingjiGlass.line()),
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
        if (onRetry != null)
          TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    ),
  );
}
