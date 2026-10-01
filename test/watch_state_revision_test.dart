import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/history/watch_state_store.dart';

void main() {
  test(
    'save publishes only persisted progress and stale merge preserves it',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = await WatchStateStore.create();
      final fresh = WatchState(
        mediaId: 'local',
        title: 'test',
        sourceId: 'source',
        serverItemId: 'episode',
        position: const Duration(seconds: 50),
        duration: const Duration(seconds: 100),
        updatedAt: DateTime(2026, 10, 1, 20),
      );
      var updates = 0;
      void listener() {
        updates++;
        expect(store.load().first.progress, .5);
      }

      WatchStateStore.revision.addListener(listener);
      try {
        await store.save(fresh, updatedAt: fresh.updatedAt);
        expect(updates, 1);
        await store.replaceAll([
          WatchState(
            mediaId: 'server',
            title: 'test',
            sourceId: 'source',
            serverItemId: 'episode',
            position: const Duration(seconds: 10),
            duration: const Duration(seconds: 100),
            updatedAt: DateTime(2026, 10, 1, 19),
            progressOrigin: 'server',
          ),
        ]);
        expect(updates, 2);
        expect(store.load().single.mediaId, 'local');
      } finally {
        WatchStateStore.revision.removeListener(listener);
      }
    },
  );
}
