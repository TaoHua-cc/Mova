/// Conservative parser for release information from iQIYI's public search API.
/// It deliberately rejects fuzzy title matches and unannounced time patterns.
String _plainText(String html) => html
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _normalizedTitle(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

Map<String, dynamic>? exactIqiyiAlbumInfo(
  dynamic searchResponse,
  String expectedTitle,
) {
  final expected = _normalizedTitle(expectedTitle);
  if (expected.isEmpty) return null;
  final data = searchResponse is Map ? searchResponse['data'] : null;
  final templates = data is Map ? data['templates'] : null;
  if (templates is! List) return null;
  final matches = <Map<String, dynamic>>[];
  for (final template in templates.whereType<Map>()) {
    final album = template['albumInfo'];
    if (album is Map &&
        _normalizedTitle('${album['title'] ?? ''}') == expected) {
      matches.add(Map<String, dynamic>.from(album));
    }
  }
  final ids = matches
      .map((album) => album['qipuId'] ?? album['pageUrl'])
      .toSet();
  return ids.length == 1 ? matches.first : null;
}

class IqiyiReleaseSchedule {
  const IqiyiReleaseSchedule({
    required this.weekday,
    required this.hour,
    required this.minute,
    this.releasedEpisodes,
    this.totalEpisodes,
  });

  /// DateTime weekday numbering: Monday = 1, Sunday = 7.
  final int weekday;
  final int hour;
  final int minute;
  final int? releasedEpisodes;
  final int? totalEpisodes;

  Map<String, Object?> toJson() => {
    'weekday': weekday,
    'hour': hour,
    'minute': minute,
    'releasedEpisodes': releasedEpisodes,
    'totalEpisodes': totalEpisodes,
  };

  static IqiyiReleaseSchedule? fromJson(Map<String, dynamic> value) {
    final weekday = (value['weekday'] as num?)?.toInt();
    final hour = (value['hour'] as num?)?.toInt();
    final minute = (value['minute'] as num?)?.toInt();
    if (weekday == null ||
        weekday < 1 ||
        weekday > 7 ||
        hour == null ||
        hour < 0 ||
        hour > 23 ||
        minute == null ||
        minute < 0 ||
        minute > 59) {
      return null;
    }
    return IqiyiReleaseSchedule(
      weekday: weekday,
      hour: hour,
      minute: minute,
      releasedEpisodes: (value['releasedEpisodes'] as num?)?.toInt(),
      totalEpisodes: (value['totalEpisodes'] as num?)?.toInt(),
    );
  }

  DateTime nextReleaseAfter(DateTime now) {
    var days = (weekday - now.weekday + 7) % 7;
    var release = DateTime(now.year, now.month, now.day + days, hour, minute);
    if (!release.isAfter(now)) {
      release = release.add(const Duration(days: 7));
    }
    return release;
  }
}

IqiyiReleaseSchedule? parseIqiyiReleaseSchedule(String html) {
  final text = _plainText(html);
  final update = RegExp(
    r'(?:每周|周)([一二三四五六日天])\s*(?:上午|早上|晚上|晚间)?\s*(\d{1,2})\s*[:：点]\s*(\d{2})\s*(?:分)?[^。；;]{0,16}更新',
  ).firstMatch(text);
  if (update == null) return null;
  const weekdays = {
    '一': 1,
    '二': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '日': 7,
    '天': 7,
  };
  final hour = int.tryParse(update.group(2) ?? '');
  final minute = int.tryParse(update.group(3) ?? '');
  if (hour == null || hour > 23 || minute == null || minute > 59) return null;
  final period = text.substring(update.start, update.end);
  final adjustedHour =
      (period.contains('晚上') || period.contains('晚间')) && hour < 12
      ? hour + 12
      : hour;
  final released = RegExp(r'更新至\s*(\d+)\s*集').firstMatch(text);
  final total = RegExp(r'共\s*(\d+)\s*集').firstMatch(text);
  return IqiyiReleaseSchedule(
    weekday: weekdays[update.group(1)]!,
    hour: adjustedHour,
    minute: minute,
    releasedEpisodes: int.tryParse(released?.group(1) ?? ''),
    totalEpisodes: int.tryParse(total?.group(1) ?? ''),
  );
}
