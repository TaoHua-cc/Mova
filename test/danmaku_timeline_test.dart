import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/player/danmaku_client.dart';
import 'package:yingji/src/player/danmaku_timeline.dart';

void main() {
  final comments = [
    for (var second = 0; second < 20; second++)
      for (var line = 0; line < 10; line++)
        DanmakuComment(
          time: Duration(milliseconds: second * 1000 + line * 10),
          content: '$second:$line',
        ),
  ];
  List<String> at(double position) => activeDanmakuComments(
    comments,
    positionMs: position,
    lifetimeMs: 8000,
    density: 0,
  ).map((comment) => comment.content).toList();

  test('new comments enter while previous seconds are still on screen', () {
    expect(at(2000), containsAll(['0:0', '1:0', '2:0']));
    expect(at(7000), containsAll(['0:0', '6:0', '7:0']));
    expect(at(7000), isNot(contains('0:3')));
  });
  test('expired and rejected comments never replay when space opens', () {
    expect(at(8100), isNot(contains('0:0')));
    expect(at(8100), isNot(contains('0:3')));
    expect(at(8100), contains('8:0'));
  });
  test('seeking backwards restores the same media-time selection', () {
    final before = at(2000);
    at(15000);
    expect(at(2000), before);
  });

  test(
    'scrolling lanes reserve tail spacing and never replay rejected lines',
    () {
      final lines = [
        for (final ms in [0, 100, 1000])
          DanmakuComment(
            time: Duration(milliseconds: ms),
            content: '$ms',
          ),
      ];
      final scheduler = DanmakuLaneScheduler(
        screenWidth: 1000,
        lifetimeMs: 8000,
        lanes: 1,
      );
      var measurements = 0;
      List<DanmakuLaneEntry> frame(double ms) => scheduler
          .update(
            lines.where((comment) => comment.time.inMilliseconds <= ms),
            positionMs: ms,
            measureWidth: (comment) {
              measurements++;
              return comment.content == '1000' ? 800 : 200;
            },
          )
          .toList();
      final visible = frame(2000);
      expect(visible.map((entry) => entry.comment.content), ['0', '1000']);
      for (final ms in [2000.0, 3000.0, 4000.0]) {
        final active = frame(ms);
        final firstRight = 1000 - ms * scheduler.velocity + active.first.width;
        final secondLeft = 1000 - (ms - 1000) * scheduler.velocity;
        expect(secondLeft - firstRight, greaterThanOrEqualTo(scheduler.gap));
      }
      expect(
        measurements,
        2,
      ); // No paragraph layout repeats per animation frame.
      expect(frame(5500).map((entry) => entry.comment.content), ['1000']);
      expect(frame(1000).map((entry) => entry.comment.content), ['0', '1000']);
    },
  );

  test('fixed comments use three independent reserved rows per mode', () {
    final lines = [
      for (final mode in [DanmakuMode.top, DanmakuMode.bottom])
        for (var i = 0; i < 4; i++)
          DanmakuComment(time: Duration.zero, content: '$mode:$i', mode: mode),
    ];
    final scheduler = DanmakuLaneScheduler(
      screenWidth: 1000,
      lifetimeMs: 8000,
      lanes: 1,
    );
    final visible = scheduler
        .update(lines, positionMs: 1000, measureWidth: (_) => 200)
        .toList();
    for (final mode in [DanmakuMode.top, DanmakuMode.bottom]) {
      expect(
        visible
            .where((entry) => entry.comment.mode == mode)
            .map((entry) => entry.lane),
        [0, 1, 2],
      );
    }
  });
}
