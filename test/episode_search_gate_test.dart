import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/metadata/episode_search_gate.dart';

void main() {
  test(
    'returns the active source when it arrives within the preference window',
    () async {
      final gate = EpisodeSearchGate<String>(
        preferredSourceId: 'active',
        preferenceWindow: const Duration(seconds: 1),
      );

      gate.offer('fast-other', 'other');
      gate.offer('active', 'active');

      expect(await gate.result, 'active');
    },
  );

  test(
    'releases the first available source after the bounded window',
    () async {
      final gate = EpisodeSearchGate<String>(
        preferredSourceId: 'active',
        preferenceWindow: const Duration(milliseconds: 5),
      );
      gate.offer('fast-other', 'other');

      expect(await gate.result, 'other');
    },
  );

  test('does not wait when no source preference exists', () async {
    final gate = EpisodeSearchGate<String>(preferredSourceId: null);
    gate.offer('any', 'first');

    expect(await gate.result, 'first');
  });

  test(
    'completes immediately at search end when there is only a fallback',
    () async {
      final gate = EpisodeSearchGate<String>(
        preferredSourceId: 'active',
        preferenceWindow: const Duration(seconds: 5),
      );
      gate.offer('other', 'fallback');
      gate.finish();

      expect(await gate.result, 'fallback');
    },
  );
}
