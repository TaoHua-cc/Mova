import 'dart:math' as math;

/// Returns the absolute timeline position that should be painted as buffered.
///
/// mpv can briefly report a stale/zero cache endpoint while opening or seeking.
/// The painted range must never end before playback, and a file already stored
/// in Mova's persistent cache is available through the full media duration.
Duration normalizedBufferedPosition({
  required Duration position,
  required Duration buffer,
  required Duration duration,
  bool fullyCached = false,
  double persistentCacheFraction = 0,
}) {
  if (duration <= Duration.zero) return Duration.zero;
  if (fullyCached) return duration;
  final persistentMilliseconds =
      duration.inMilliseconds * persistentCacheFraction.clamp(0.0, 1.0);
  final milliseconds = math.max(
    math.max(position.inMilliseconds, buffer.inMilliseconds),
    persistentMilliseconds.round(),
  );
  return Duration(milliseconds: milliseconds.clamp(0, duration.inMilliseconds));
}
