import 'trakt_client.dart';

class CalendarProgressCounts {
  const CalendarProgressCounts({
    required this.watched,
    required this.unwatched,
    required this.total,
  });

  final int watched;
  final int unwatched;
  final int total;
}

CalendarProgressCounts calendarProgressCounts(
  TraktShowProgress progress, {
  int? announcedTotal,
}) {
  final total = announcedTotal != null && announcedTotal > progress.aired
      ? announcedTotal
      : progress.aired;
  final watched = progress.completed.clamp(0, total);
  return CalendarProgressCounts(
    watched: watched,
    unwatched: total - watched,
    total: total,
  );
}

CalendarProgressCounts localCalendarProgressCounts({
  required int watched,
  required int total,
}) {
  final safeTotal = total < 0 ? 0 : total;
  final safeWatched = watched.clamp(0, safeTotal);
  return CalendarProgressCounts(
    watched: safeWatched,
    unwatched: safeTotal - safeWatched,
    total: safeTotal,
  );
}

int? calendarAbsoluteEpisode(TraktEvent event) {
  if ((event.absoluteEpisodeNumber ?? 0) > 0) {
    return event.absoluteEpisodeNumber;
  }
  // Episode titles may follow the numbering (for example, "第 1 季 · 第 3 集 ·
  // 标题"). Read the explicit absolute marker first, then the Chinese label.
  final explicit = RegExp(
    r'\b(?:Episode|EP)\s*#?\s*(\d+)\b',
    caseSensitive: false,
  ).firstMatch(event.episode);
  final local = RegExp(r'第\s*(\d+)\s*集').firstMatch(event.episode);
  final number = int.tryParse(explicit?.group(1) ?? local?.group(1) ?? '');
  if (number == null || number <= 0) return null;
  // "Episode 17" for season 8 may only mean S08E17, not absolute #17.
  if ((_calendarSeason(event) ?? 1) > 1 &&
      number == _calendarEpisodeNumber(event)) {
    return null;
  }
  return number;
}

int? _calendarSeason(TraktEvent event) {
  if ((event.seasonNumber ?? 0) > 0) return event.seasonNumber;
  final match = RegExp(
    r'(?:第\s*(\d+)\s*季|\bS(?:eason\s*)?(\d+)\b)',
    caseSensitive: false,
  ).firstMatch(event.episode);
  return int.tryParse(match?.group(1) ?? match?.group(2) ?? '');
}

int? _calendarEpisodeNumber(TraktEvent event) {
  if ((event.episodeNumber ?? 0) > 0) return event.episodeNumber;
  final match = RegExp(
    r'\bS\d+\s*E(\d+)\b|第\s*\d+\s*季\s*[·:：-]*\s*第\s*(\d+)\s*集|第\s*(\d+)\s*集|\b(?:Episode|EP)\s*#?\s*(\d+)\b',
    caseSensitive: false,
  ).firstMatch(event.episode);
  for (final group in [1, 2, 3, 4]) {
    final number = int.tryParse(match?.group(group) ?? '');
    if (number != null && number > 0) return number;
  }
  return null;
}

bool _sameLocalCalendarDay(DateTime left, DateTime right) {
  final a = left.toLocal();
  final b = right.toLocal();
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

String _normalizedEpisodeLabel(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), '')
    .replaceAll('·', '')
    .replaceAll('：', ':');

List<TraktEvent> mergeCalendarEvents(Iterable<TraktEvent> rows) {
  final merged = <TraktEvent>[];
  for (final event in rows) {
    final index = merged.indexWhere((previous) {
      final sameShow = previous.tmdbId != null && event.tmdbId != null
          ? previous.tmdbId == event.tmdbId
          : previous.title.trim().toLowerCase() ==
                event.title.trim().toLowerCase();
      if (!sameShow) return false;
      final previousAbsolute = calendarAbsoluteEpisode(previous);
      final nextAbsolute = calendarAbsoluteEpisode(event);
      if (previousAbsolute != null && nextAbsolute != null) {
        return previousAbsolute == nextAbsolute;
      }
      final previousSeason = _calendarSeason(previous);
      final nextSeason = _calendarSeason(event);
      final previousEpisode = _calendarEpisodeNumber(previous);
      final nextEpisode = _calendarEpisodeNumber(event);
      if (previousEpisode != null && nextEpisode != null) {
        if (previousSeason != null && nextSeason != null) {
          return previousSeason == nextSeason && previousEpisode == nextEpisode;
        }
        // If a provider omitted season metadata, only use its episode number
        // within the same local broadcast date; otherwise S01E06 and S02E06
        // could be collapsed into one event.
        return previousEpisode == nextEpisode &&
            _sameLocalCalendarDay(previous.airDate, event.airDate);
      }
      return _normalizedEpisodeLabel(previous.episode) ==
              _normalizedEpisodeLabel(event.episode) &&
          _sameLocalCalendarDay(previous.airDate, event.airDate);
    });
    if (index < 0) {
      merged.add(event);
      continue;
    }
    final previous = merged[index];
    final timed = previous.timeKnown ? previous : event;
    merged[index] = TraktEvent(
      title: _preferredCalendarTitle(previous.title, event.title),
      episode: event.episode.isNotEmpty ? event.episode : previous.episode,
      airDate: timed.airDate,
      timeKnown: timed.timeKnown,
      posterUrl: event.posterUrl ?? previous.posterUrl,
      backdropUrl: event.backdropUrl ?? previous.backdropUrl,
      platform: timed.platform ?? event.platform ?? previous.platform,
      tmdbId: event.tmdbId ?? previous.tmdbId,
      seasonNumber: event.seasonNumber ?? previous.seasonNumber,
      episodeNumber: event.episodeNumber ?? previous.episodeNumber,
      absoluteEpisodeNumber:
          calendarAbsoluteEpisode(event) ?? calendarAbsoluteEpisode(previous),
      totalEpisodes: [
        event.totalEpisodes,
        previous.totalEpisodes,
      ].whereType<int>().fold<int?>(null, (a, b) => a == null || b > a ? b : a),
      platformLogoUrl: event.platformLogoUrl ?? previous.platformLogoUrl,
    );
  }
  merged.sort((a, b) => a.airDate.compareTo(b.airDate));
  return merged;
}

String _preferredCalendarTitle(String previous, String incoming) {
  final hasHan = RegExp(r'[\u3400-\u9fff]').hasMatch;
  if (hasHan(previous) && !hasHan(incoming)) return previous;
  if (incoming.trim().isNotEmpty) return incoming;
  return previous;
}

List<TraktEvent> filterCalendarEventsByShowIds(
  Iterable<TraktEvent> rows,
  Set<int> tmdbIds,
) => mergeCalendarEvents(
  rows.where((event) => event.tmdbId != null && tmdbIds.contains(event.tmdbId)),
);
