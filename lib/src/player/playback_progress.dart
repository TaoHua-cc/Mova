import 'dart:math' as math;

/// Current media read throughput, not device-wide bandwidth or bitrate.
String playbackNetworkLabel({
  required double bytesPerSecond,
  required Duration position,
  required Duration buffer,
  bool buffering = false,
  bool playing = true,
  bool local = false,
}) {
  if (local) return '本地播放';
  final bytes = bytesPerSecond.isFinite ? math.max(0, bytesPerSecond) : 0;
  final speed = bytes >= 1048576
      ? '${(bytes / 1048576).toStringAsFixed(1)} MB/s'
      : '${(bytes / 1024).toStringAsFixed(0)} KB/s';
  final seconds = math.max(0, (buffer - position).inSeconds);
  final status = buffering
      ? '缓冲中'
      : !playing
      ? '已暂停'
      : bytes > 0
      ? '可播 ${seconds}s'
      : seconds > 0
      ? '已缓冲 ${seconds}s'
      : '等待数据';
  return '$speed · $status';
}

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
