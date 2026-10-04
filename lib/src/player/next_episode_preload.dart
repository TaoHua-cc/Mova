/// Use real buffered time, never estimated throughput, to protect playback.
bool shouldPreloadNextEpisode({
  required Duration position,
  required Duration duration,
  required Duration bufferedEnd,
  Duration? outroStart,
  bool buffering = false,
}) {
  if (buffering || duration <= Duration.zero || position <= Duration.zero) {
    return false;
  }
  final end =
      outroStart != null && outroStart > duration ~/ 2 && outroStart < duration
      ? outroStart
      : duration;
  if (bufferedEnd < end &&
      bufferedEnd - position < const Duration(seconds: 10)) {
    return false;
  }
  return position.inMilliseconds >= end.inMilliseconds * .8 ||
      bufferedEnd >= end;
}
