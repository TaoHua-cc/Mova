import 'package:flutter_test/flutter_test.dart';

import 'package:yingji/src/history/watch_state_store.dart';

void main() {
  WatchState episode(
    String id,
    int seconds,
    int day, {
    int number = 1,
    int season = 1,
    bool played = false,
  }) => WatchState(
    mediaId: id,
    title: '示例剧',
    seasonNumber: season,
    isPlayed: played,
    episodeNumber: number,
    position: Duration(seconds: seconds),
    duration: const Duration(seconds: 1000),
    updatedAt: DateTime(2026, 9, day),
  );

  test('same series shows latest record while retaining episode history', () {
    final history = [
      episode('old-url', 600, 1),
      episode('new-url', 200, 2, number: 2),
    ];
    expect(continueWatchingRows(history).single.mediaId, 'new-url');
    expect(history.length, 2);
  });
  test('marking episode one watched preserves episode two resume progress', () {
    final history = [
      episode('episode-one-old', 400, 1),
      episode('episode-two', 250, 2, number: 2),
      episode('episode-one-marked', 0, 3, played: true),
    ];
    final row = continueWatchingRows(history).single;
    expect(row.mediaId, 'episode-two');
    expect(row.position, const Duration(seconds: 250));
    expect(history.length, 3);
  });
  test('episode state does not suppress the same number in another season', () {
    expect(
      continueWatchingRows([
        episode('season-two', 300, 1, season: 2),
        episode('season-one', 950, 2),
      ]).single.mediaId,
      'season-two',
    );
  });
  test('resetting an episode hides its stale partial duplicate only', () {
    expect(
      continueWatchingRows([
        episode('old', 400, 1),
        episode('other', 200, 2, number: 2),
        episode('reset', 0, 3),
      ]).single.mediaId,
      'other',
    );
  });
  test(
    'completion uses duration; latest completion hides stale duplicates',
    () {
      expect(episode('zero', 0, 1).isCompleted, isFalse);
      expect(episode('partial', 500, 1).isCompleted, isFalse);
      expect(episode('done', 950, 2).isCompleted, isTrue);
      expect(
        continueWatchingRows([episode('old', 400, 1), episode('done', 950, 2)]),
        isEmpty,
      );
    },
  );
}
