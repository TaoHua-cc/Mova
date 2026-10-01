import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract final class TrackingStatusStore {
  static const key = 'yingji.tracking.status';
  static final revision = ValueNotifier<int>(0);

  static Map<String, String> read(SharedPreferences prefs) {
    try {
      return Map<String, String>.from(
        jsonDecode(prefs.getString(key) ?? '{}') as Map,
      );
    } catch (_) {
      return {};
    }
  }

  static bool isDropped(Map<String, String> status, String title, int? id) =>
      status[title] == 'dropped' ||
      (id != null && status['tmdb:$id'] == 'dropped');

  static Future<void> setDropped(
    SharedPreferences prefs,
    String title,
    int? id,
  ) async {
    final status = read(prefs)..[title] = 'dropped';
    if (id != null && id > 0) status['tmdb:$id'] = 'dropped';
    await prefs.setString(key, jsonEncode(status));
    revision.value++;
  }

  static Future<void> resume(
    SharedPreferences prefs,
    String title,
    int? id,
  ) async {
    final status = read(prefs);
    if (!status.values.contains('dropped')) return;
    final before = status.length;
    status.remove(title);
    if (id != null) {
      status.remove('tmdb:$id');
      // Legacy drops were keyed by title. Cached calendars provide aliases
      // when the player and calendar use different localized show names.
      for (final cache in [
        'calendar-cache',
        'calendar-trakt-cache',
        'calendar-trakt-all-cache',
      ]) {
        try {
          final rows = jsonDecode(
            prefs.getString('yingji.tracking.$cache') ?? '[]',
          ) as List;
          for (final row in rows.whereType<Map>()) {
            if (row['tmdbId'] == id) status.remove(row['title']);
          }
        } catch (_) {
          // A damaged cache must not prevent playback or watchlist changes.
        }
      }
    }
    if (before == status.length) return;
    await prefs.setString(key, jsonEncode(status));
    revision.value++;
  }
}
