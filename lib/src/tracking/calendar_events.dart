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
  final name = event.episode.split('·').last.trim();
  final match = RegExp(
    r'^(?:Episode|EP)\s*#?\s*(\d+)$|^第\s*(\d+)\s*集$',
    caseSensitive: false,
  ).firstMatch(name);
  final number = int.tryParse(match?.group(1) ?? match?.group(2) ?? '');
  if (number == null || number <= 0) return null;
  // "Episode 17" for season 8 may only mean S08E17, not absolute #17.
  if ((event.seasonNumber ?? 1) > 1 && number == event.episodeNumber) {
    return null;
  }
  return number;
}

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
      if (previous.seasonNumber != null &&
          previous.episodeNumber != null &&
          event.seasonNumber != null &&
          event.episodeNumber != null) {
        return previous.seasonNumber == event.seasonNumber &&
            previous.episodeNumber == event.episodeNumber;
      }
      final a = previous.airDate.toLocal();
      final b = event.airDate.toLocal();
      return previous.episode == event.episode &&
          a.year == b.year &&
          a.month == b.month &&
          a.day == b.day;
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
