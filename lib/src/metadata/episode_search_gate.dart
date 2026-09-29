import 'dart:async';

/// Releases the first playable result, briefly preferring the currently active
/// source without allowing a slow source to stall an episode switch.
class EpisodeSearchGate<T> {
  EpisodeSearchGate({
    required this.preferredSourceId,
    this.preferenceWindow = const Duration(milliseconds: 400),
  });

  final String? preferredSourceId;
  final Duration preferenceWindow;
  final Completer<T?> _result = Completer<T?>();
  Timer? _timer;
  T? _fallback;

  Future<T?> get result => _result.future;
  bool get isCompleted => _result.isCompleted;

  void offer(String sourceId, T value) {
    if (_result.isCompleted) return;
    if (preferredSourceId == null || sourceId == preferredSourceId) {
      _complete(value);
      return;
    }
    _fallback ??= value;
    _timer ??= Timer(preferenceWindow, () => _complete(_fallback));
  }

  /// Called when every source has finished; do not wait out the preference
  /// window when there is no faster preferred response left to arrive.
  void finish() {
    if (!_result.isCompleted) _complete(_fallback);
  }

  void _complete(T? value) {
    _timer?.cancel();
    if (!_result.isCompleted) _result.complete(value);
  }
}
