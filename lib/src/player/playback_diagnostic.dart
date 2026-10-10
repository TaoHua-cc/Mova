/// Accept only numeric protocol fields or fixed categories, never raw mpv logs.
String? safePlaybackDiagnostic(String line) {
  final pattern = RegExp(
    r'^(?:MOVA_ENDFILE=\d+\|-?\d+\|played=-?\d+\.\d+\|duration=-?\d+\.\d+\|error=-?\d+\|eof=[01]\|aborted=[01]|MOVA_(?:RETRY|FAILED)=-?\d+\|-?\d+\.\d+|MOVA_SUSPECT_EOF=-?\d+\.\d+\|-?\d+\.\d+|MOVA_STREAM=-?\d+\|native=[01]\|event=(?:load|retry)|MOVA_CACHE_DIAGNOSTIC=(?:begin|tail-status|tail-end|tail-io|tail-timeout|proxy-error)\|offset=\d+\|value=-?\d+|MOVA_DIAGNOSTIC=(?:timeout|connection-reset|connection-refused|tls|premature-eof|decode-error|http-[45]\d{2}|other-warning))$',
  );
  return pattern.hasMatch(line) ||
          RegExp(
            r'^MOVA_SESSION=\d+\|event=(prepare|ready|promote|failed|cancelled)$',
          ).hasMatch(line) ||
          RegExp(r'^MOVA_RECOVER=\d+\|\d+\.\d+$').hasMatch(line)
      ? line
      : null;
}
