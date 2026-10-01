import 'danmaku_client.dart';

class DanmakuLaneEntry {
  const DanmakuLaneEntry(this.comment, this.lane, this.width);
  final DanmakuComment comment;
  final int lane;
  final double width;
}

/// All scrolling lines use the same velocity. A lane becomes available only
/// after the previous tail has cleared the entry edge, including a gap.
class DanmakuLaneScheduler {
  DanmakuLaneScheduler({
    required this.screenWidth,
    required this.lifetimeMs,
    required int lanes,
    int topLanes = 3,
    this.gap = 24,
  }) : _scroll = List.filled(lanes, double.negativeInfinity),
       _top = List.filled(topLanes, double.negativeInfinity);

  final double screenWidth;
  final double lifetimeMs;
  final double gap;
  final List<double> _scroll;
  final List<double> _top;
  final _bottom = List<double>.filled(3, double.negativeInfinity);
  final _decisions = <DanmakuComment, DanmakuLaneEntry?>{};
  double _lastPosition = double.negativeInfinity;

  double get velocity => screenWidth * 2 / lifetimeMs;

  Iterable<DanmakuLaneEntry> update(
    Iterable<DanmakuComment> candidates, {
    required double positionMs,
    required double Function(DanmakuComment) measureWidth,
  }) sync* {
    if (positionMs < _lastPosition || positionMs - _lastPosition > lifetimeMs) {
      _decisions.clear();
      for (final lanes in [_scroll, _top, _bottom]) {
        lanes.fillRange(0, lanes.length, double.negativeInfinity);
      }
    }
    _lastPosition = positionMs;
    _decisions.removeWhere(
      (comment, _) => comment.time.inMilliseconds + lifetimeMs <= positionMs,
    );
    for (final comment in candidates) {
      if (!_decisions.containsKey(comment)) {
        final time = comment.time.inMilliseconds.toDouble();
        final lanes = switch (comment.mode) {
          DanmakuMode.scroll => _scroll,
          DanmakuMode.top => _top,
          DanmakuMode.bottom => _bottom,
        };
        final lane = lanes.indexWhere((available) => available <= time);
        DanmakuLaneEntry? entry;
        if (lane >= 0) {
          final width = measureWidth(comment).clamp(0.0, screenWidth);
          lanes[lane] =
              time +
              (comment.mode == DanmakuMode.scroll
                  ? (width + gap) / velocity
                  : lifetimeMs);
          entry = DanmakuLaneEntry(comment, lane, width);
        }
        // A rejected line never gets queued or admitted on a later frame.
        _decisions[comment] = entry;
      }
      final entry = _decisions[comment];
      if (entry == null) continue;
      final age = positionMs - comment.time.inMilliseconds;
      final duration = comment.mode == DanmakuMode.scroll
          ? (screenWidth + entry.width) / velocity
          : lifetimeMs;
      if (age >= 0 && age < duration) yield entry;
    }
  }
}

/// Select due comments from a sorted timeline. Density is an admission limit
/// per media second, so a full older screen never delays a newer comment.
Iterable<DanmakuComment> activeDanmakuComments(
  List<DanmakuComment> comments, {
  required double positionMs,
  required double lifetimeMs,
  required double density,
}) sync* {
  final fromMs = positionMs - lifetimeMs;
  final bucketStart = (fromMs / 1000).floor() * 1000;
  var low = 0;
  var high = comments.length;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (comments[middle].time.inMilliseconds < bucketStart) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  final cap = (3 + density.clamp(0.0, 1.0) * 10).round();
  int? bucket;
  var count = 0;
  for (var index = low; index < comments.length; index++) {
    final comment = comments[index];
    final timeMs = comment.time.inMilliseconds;
    if (timeMs > positionMs) break;
    final second = timeMs ~/ 1000;
    if (second != bucket) {
      bucket = second;
      count = 0;
    }
    count++;
    if (count <= cap && timeMs > fromMs) yield comment;
  }
}
