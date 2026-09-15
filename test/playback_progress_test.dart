import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/player/playback_progress.dart';

void main() {
  test('buffered endpoint never falls behind playback', () {
    expect(
      normalizedBufferedPosition(
        position: const Duration(minutes: 4),
        buffer: const Duration(minutes: 2),
        duration: const Duration(minutes: 40),
      ),
      const Duration(minutes: 4),
    );
  });

  test('buffered endpoint is clamped to media duration', () {
    expect(
      normalizedBufferedPosition(
        position: const Duration(minutes: 4),
        buffer: const Duration(minutes: 50),
        duration: const Duration(minutes: 40),
      ),
      const Duration(minutes: 40),
    );
  });

  test('fully cached media paints the complete timeline', () {
    expect(
      normalizedBufferedPosition(
        position: const Duration(minutes: 4),
        buffer: Duration.zero,
        duration: const Duration(minutes: 40),
        fullyCached: true,
      ),
      const Duration(minutes: 40),
    );
  });

  test('persistent download progress survives beyond mpv readahead', () {
    expect(
      normalizedBufferedPosition(
        position: const Duration(minutes: 4),
        buffer: const Duration(minutes: 5),
        duration: const Duration(minutes: 40),
        persistentCacheFraction: .5,
      ),
      const Duration(minutes: 20),
    );
  });

  test('unknown duration has no paintable buffered range', () {
    expect(
      normalizedBufferedPosition(
        position: const Duration(seconds: 5),
        buffer: const Duration(seconds: 10),
        duration: Duration.zero,
      ),
      Duration.zero,
    );
  });
}
