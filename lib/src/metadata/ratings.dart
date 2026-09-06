import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../brand.dart';
import '../network/network_http_client.dart';
import 'tmdb_client.dart';

class MediaRating {
  const MediaRating(this.source, this.value);
  final String source;
  final double value;

  String get label =>
      const {
        'imdb': 'IMDb',
        'tmdb': 'TMDB',
        'trakt': 'Trakt',
        'tomatoes': '烂番茄',
        'popcorn': '爆米花',
        'metacritic': 'Metacritic',
        'metacriticuser': 'MC 用户',
        'letterboxd': 'Letterboxd',
        'rogerebert': 'Roger Ebert',
        'douban': '豆瓣',
        'myanimelist': 'MyAnimeList',
      }[source] ??
      source;

  String get formatted {
    final number = value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toString();
    return switch (source) {
      'tomatoes' || 'popcorn' || 'trakt' => '$number%',
      'tmdb' || 'metacritic' => '$number/100',
      'imdb' || 'metacriticuser' || 'douban' || 'myanimelist' => '$number/10',
      'letterboxd' => '$number/5',
      'rogerebert' => '$number/4',
      _ => number,
    };
  }

  static List<MediaRating> parse(dynamic rows) {
    final result = <String, MediaRating>{};
    if (rows is! List) return const [];
    for (final row in rows.whereType<Map>()) {
      final source = '${row['source'] ?? ''}'.trim().toLowerCase();
      final value = row['value'];
      if (source.isEmpty || value is! num || !value.isFinite || value < 0)
        continue;
      result[source] = MediaRating(source, value.toDouble());
    }
    return result.values.toList(growable: false);
  }
}

/// Shared by all mounted surfaces; stale data stays visible on network failure.
class RatingCache {
  static final _entries = <String, ValueNotifier<List<MediaRating>>>{};
  static final _pending = <String>{};
  static final _checked = <String, DateTime>{};
  static Future<void> _queue = Future.value();

  static ValueNotifier<List<MediaRating>> watch(TmdbItem item) {
    final type = item.kind == '剧集' ? 'tv' : 'movie';
    final key = '$type/${item.id}';
    final entry = _entries.putIfAbsent(key, () => ValueNotifier(const []));
    if (item.id <= 0 || _pending.contains(key)) return entry;
    if (_checked[key] case final checked?) {
      if (DateTime.now().difference(checked) < const Duration(minutes: 15))
        return entry;
    }
    _pending.add(key);
    unawaited(_load(key, entry));
    return entry;
  }

  static Future<void> _load(
    String key,
    ValueNotifier<List<MediaRating>> entry,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheKey = 'yingji.ratings.v1.$key';
      final raw = prefs.getString(cacheKey);
      if (raw != null) {
        try {
          final data = jsonDecode(raw) as Map<String, dynamic>;
          entry.value = MediaRating.parse(data['ratings']);
          final saved = DateTime.tryParse('${data['savedAt']}');
          if (saved != null &&
              DateTime.now().difference(saved) < const Duration(hours: 6)) {
            _checked[key] = DateTime.now();
            return;
          }
        } catch (_) {
          /* Replace malformed cache through normal request. */
        }
      }
      // Serialize uncached ratings so a large poster grid cannot flood the API.
      final task = _queue.then((_) async {
        final client = createNetworkHttpClient();
        try {
          final response = await client
              .get(Uri.parse('${TmdbClient.managedEndpoint}/ratings/$key'))
              .timeout(const Duration(seconds: 10));
          if (response.statusCode != 200) return;
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          if (data['ratings'] is! List) return;
          final rows = MediaRating.parse(data['ratings']);
          await prefs.setString(
            cacheKey,
            jsonEncode({...data, 'savedAt': DateTime.now().toIso8601String()}),
          );
          entry.value = rows;
        } catch (_) {
          /* Keep the last successful scores. */
        } finally {
          client.close();
        }
      });
      _queue = task;
      await task;
      _checked[key] = DateTime.now();
    } catch (_) {
      _checked[key] = DateTime.now();
    } finally {
      _pending.remove(key);
    }
  }
}

/// Bundled platform marks avoid external requests while browsing scores.
class RatingPlatformIcon extends StatelessWidget {
  const RatingPlatformIcon({super.key, required this.source, this.value});
  final String source;
  final double? value;

  @override
  Widget build(BuildContext context) {
    final asset = value != null && value! < 60 && source == 'tomatoes'
        ? 'tomatoes-rotten'
        : value != null && value! < 60 && source == 'popcorn'
        ? 'popcorn-negative'
        : source;
    return SizedBox(
      width: 28,
      height: 18,
      child: Image.asset(
        'app/assets/ratings/$asset.png',
        fit: BoxFit.contain,
        semanticLabel: MediaRating(source, 0).label,
        errorBuilder: (_, _, _) =>
            const Icon(YingjiIcons.info_circle, size: 16),
      ),
    );
  }
}

class MediaRatingRow extends StatefulWidget {
  const MediaRatingRow({
    super.key,
    required this.item,
    this.expanded = false,
    this.maxItems,
    this.emphasizeFirst = false,
  });
  final TmdbItem item;
  final bool expanded;
  final int? maxItems;
  final bool emphasizeFirst;
  @override
  State<MediaRatingRow> createState() => _MediaRatingRowState();
}

class _MediaRatingRowState extends State<MediaRatingRow> {
  late ValueNotifier<List<MediaRating>> _scores;
  @override
  void initState() {
    super.initState();
    _scores = RatingCache.watch(widget.item);
  }

  @override
  void didUpdateWidget(covariant MediaRatingRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.item.kind != widget.item.kind) {
      _scores = RatingCache.watch(widget.item);
    }
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<List<MediaRating>>(
        valueListenable: _scores,
        builder: (context, scores, _) {
          final rows = [...scores];
          if (rows.every((r) => r.source != 'tmdb') && widget.item.rating > 0) {
            rows.insert(0, MediaRating('tmdb', widget.item.rating * 10));
          }
          if (rows.isEmpty) return const SizedBox.shrink();
          final visibleRows = widget.maxItems == null
              ? rows
              : rows.take(widget.maxItems!).toList();
          final chips = visibleRows.indexed
              .map(
                (entry) => Tooltip(
                  message: '${entry.$2.label} ${entry.$2.formatted}',
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: entry.$1 == 0 && widget.emphasizeFirst
                          ? 9
                          : 7,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: entry.$1 == 0 && widget.emphasizeFirst
                          ? Colors.white.withValues(alpha: .13)
                          : YingjiGlass.surface(),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: YingjiGlass.line()),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RatingPlatformIcon(
                          source: entry.$2.source,
                          value: entry.$2.value,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          entry.$2.formatted,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: entry.$1 == 0 && widget.emphasizeFirst
                                ? 12
                                : 11,
                            fontWeight: entry.$1 == 0 && widget.emphasizeFirst
                                ? FontWeight.w900
                                : FontWeight.w700,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
              .toList();
          if (visibleRows.length < rows.length) {
            chips.add(
              Tooltip(
                message: rows
                    .skip(visibleRows.length)
                    .map((r) => '${r.label} ${r.formatted}')
                    .join('\n'),
                child: SizedBox(
                  width: 42,
                  height: 28,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: YingjiGlass.surface(),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: YingjiGlass.line()),
                    ),
                    child: Center(
                      child: Text(
                        '+${rows.length - visibleRows.length}',
                        style: const TextStyle(
                          color: YingjiColors.muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
          if (widget.expanded)
            return Wrap(spacing: 6, runSpacing: 6, children: chips);
          return Tooltip(
            message: rows.map((r) => '${r.label} ${r.formatted}').join('\n'),
            child: SizedBox(
              height: 28,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final chip in chips)
                      Padding(
                        padding: const EdgeInsets.only(right: 5),
                        child: chip,
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      );
}
