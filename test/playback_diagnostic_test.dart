import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/player/playback_diagnostic.dart';

void main() {
  test('diagnostic whitelist never persists raw or appended credentials', () {
    for (final line in [
      'MOVA_DIAGNOSTIC=http-403',
      'MOVA_DIAGNOSTIC=timeout',
      'MOVA_ENDFILE=4|29|played=98.000|duration=2407.000|error=-13|eof=0|aborted=1',
      'MOVA_RETRY=29|98.000',
      'MOVA_RECOVER=5|38.600',
      'MOVA_SESSION=6|event=prepare',
      'MOVA_SESSION=6|event=ready',
      'MOVA_SESSION=6|event=promote',
      'MOVA_SESSION=6|event=failed',
      'MOVA_SESSION=6|event=cancelled',
      'MOVA_STREAM=4|native=0|event=load',
      'MOVA_CACHE_DIAGNOSTIC=tail-status|offset=33554432|value=403',
      'MOVA_CACHE_DIAGNOSTIC=tail-timeout|offset=33554432|value=1',
    ]) {
      expect(safePlaybackDiagnostic(line), line);
      expect(safePlaybackDiagnostic('$line token=secret'), isNull);
    }
    expect(
      safePlaybackDiagnostic('https://user:secret@host/?token=secret'),
      isNull,
    );
    expect(safePlaybackDiagnostic('MOVA_DIAGNOSTIC=secret'), isNull);
  });
}
