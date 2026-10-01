import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/history/watch_state_store.dart';
import 'package:yingji/src/history/watchlist_store.dart';
import 'package:yingji/src/metadata/tmdb_client.dart';
import 'package:yingji/src/tracking/tracking_status_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'old sync keeps drop; actual playback restores cached title alias',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'yingji.tracking.calendar-cache',
        jsonEncode([
          {'tmdbId': 10, 'title': '日历片名'},
        ]),
      );
      await TrackingStatusStore.setDropped(prefs, '日历片名', 10);
      const row = WatchState(
        mediaId: 'episode',
        title: '播放器片名',
        tmdbId: 10,
        seasonNumber: 1,
        episodeNumber: 1,
        position: Duration(seconds: 20),
        duration: Duration(minutes: 40),
      );
      final store = await WatchStateStore.create();
      await store.save(row, updatedAt: DateTime(2026, 10, 1));
      expect(
        TrackingStatusStore.isDropped(
          TrackingStatusStore.read(prefs),
          '日历片名',
          10,
        ),
        isTrue,
      );
      await store.save(row);
      expect(
        TrackingStatusStore.isDropped(
          TrackingStatusStore.read(prefs),
          '日历片名',
          10,
        ),
        isFalse,
      );
    },
  );

  test(
    'watchlist reconciliation keeps drop; explicit TV add restores it',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = await WatchlistStore.create();
      const show = TmdbItem(id: 10, title: '剧集', kind: '剧集');
      await TrackingStatusStore.setDropped(prefs, show.title, show.id);
      await store.reconcile(add: [show]);
      expect(
        TrackingStatusStore.isDropped(
          TrackingStatusStore.read(prefs),
          show.title,
          show.id,
        ),
        isTrue,
      );
      await store.add(show);
      expect(
        TrackingStatusStore.isDropped(
          TrackingStatusStore.read(prefs),
          show.title,
          show.id,
        ),
        isFalse,
      );
      await TrackingStatusStore.setDropped(prefs, '电影', 20);
      await store.add(const TmdbItem(id: 20, title: '电影', kind: '电影'));
      expect(
        TrackingStatusStore.isDropped(
          TrackingStatusStore.read(prefs),
          '电影',
          20,
        ),
        isTrue,
      );
    },
  );

  test(
    'zero progress is not a new watch and legacy status remains readable',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(TrackingStatusStore.key, '{"剧集":"dropped"}');
      await (await WatchStateStore.create()).save(
        const WatchState(
          mediaId: 'episode',
          title: '剧集',
          tmdbId: 10,
          seasonNumber: 1,
          position: Duration.zero,
          duration: Duration(minutes: 40),
        ),
      );
      expect(
        TrackingStatusStore.isDropped(
          TrackingStatusStore.read(prefs),
          '剧集',
          10,
        ),
        isTrue,
      );
    },
  );
}
