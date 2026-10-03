// Headless local-origin probe. No private media or server credentials required.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

Future<void> main() async {
  if (!Platform.isWindows) throw StateError('Windows only');
  final dll = DynamicLibrary.open(
    '${Directory.current.path}/build/windows/x64/runner/Release/libmpv-2.dll',
  );
  final create = dll
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'mpv_create',
      );
  final initialize = dll
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('mpv_initialize');
  final set = dll
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
        int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
      >('mpv_set_option_string');
  final command = dll
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Pointer<Utf8>>),
        int Function(Pointer<Void>, Pointer<Pointer<Utf8>>)
      >('mpv_command');
  final get = dll
      .lookupFunction<
        Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>),
        Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
      >('mpv_get_property_string');
  final free = dll
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('mpv_free');
  final destroy = dll
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('mpv_terminate_destroy');
  final handle = create();
  if (handle == nullptr) throw StateError('mpv_create failed');
  void option(String name, String value) => using((arena) {
    if (set(
          handle,
          name.toNativeUtf8(allocator: arena),
          value.toNativeUtf8(allocator: arena),
        ) <
        0) {
      throw StateError('Unsupported option: $name');
    }
  });
  void send(List<String> values) => using((arena) {
    final args = arena<Pointer<Utf8>>(values.length + 1);
    for (var i = 0; i < values.length; i++) {
      args[i] = values[i].toNativeUtf8(allocator: arena);
    }
    args[values.length] = nullptr;
    if (command(handle, args) < 0) {
      throw StateError('Command failed: ${values.first}');
    }
  });
  String property(String name) => using((arena) {
    final value = get(handle, name.toNativeUtf8(allocator: arena));
    if (value == nullptr) return '';
    try {
      return value.toDartString();
    } finally {
      free(value.cast());
    }
  });
  final wave = Uint8List(44 + 44100 * 2 * 2 * 80);
  final data = ByteData.sublistView(wave);
  void label(int offset, String text) =>
      wave.setRange(offset, offset + text.length, ascii.encode(text));
  label(0, 'RIFF');
  data.setUint32(4, wave.length - 8, Endian.little);
  label(8, 'WAVE');
  label(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 2, Endian.little);
  data.setUint32(24, 44100, Endian.little);
  data.setUint32(28, 176400, Endian.little);
  data.setUint16(32, 4, Endian.little);
  data.setUint16(34, 16, Endian.little);
  label(36, 'data');
  data.setUint32(40, wave.length - 44, Endian.little);
  final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var requests = 0, ranges = 0, bytes = 0, wrongHeaders = 0;
  final serving = origin.listen((request) async {
    requests++;
    final expected = request.uri.path == '/one' ? 'fixture-one' : null;
    if (request.headers.value('Authorization') != expected) {
      wrongHeaders++;
      request.response.statusCode = 401;
      await request.response.close();
      return;
    }
    final range = request.headers.value('Range');
    final start =
        int.tryParse(
          RegExp(r'bytes=(\d+)-').firstMatch(range ?? '')?.group(1) ?? '',
        ) ??
        0;
    if (range != null) ranges++;
    if (start >= wave.length) {
      request.response.statusCode = 416;
      await request.response.close();
      return;
    }
    request.response.headers.set('Content-Type', 'audio/wav');
    request.response.headers.set('Accept-Ranges', 'bytes');
    if (range != null) {
      request.response.statusCode = 206;
      request.response.headers.set(
        'Content-Range',
        'bytes $start-${wave.length - 1}/${wave.length}',
      );
    }
    request.response.contentLength = wave.length - start;
    try {
      for (var cursor = start; cursor < wave.length; cursor += 32768) {
        final end = (cursor + 32768).clamp(0, wave.length);
        request.response.add(Uint8List.sublistView(wave, cursor, end));
        bytes += end - cursor;
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 12));
      }
      await request.response.close();
    } on IOException {
      /* Seeking cancels the old response. */
    }
  });
  Future<void> waitFor(bool Function() predicate, String phase) async {
    final clock = Stopwatch()..start();
    while (!predicate()) {
      if (clock.elapsedMilliseconds > 10000) {
        throw StateError('Timed out: $phase');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  try {
    for (final entry in {
      'config': 'no',
      'vo': 'null',
      'ao': 'null',
      'terminal': 'no',
      'cache': 'yes',
      'cache-secs': '10',
      'demuxer-readahead-secs': '10',
      'cache-on-disk': 'no',
      'demuxer-max-bytes': '128MiB',
      'demuxer-max-back-bytes': '32MiB',
      'http-proxy': '',
      'tls-verify': 'yes',
    }.entries) {
      option(entry.key, entry.value);
    }
    if (initialize(handle) < 0) throw StateError('mpv_initialize failed');
    send(['set', 'http-header-fields', 'Authorization: fixture-one']);
    send(['loadfile', 'http://127.0.0.1:${origin.port}/one', 'replace']);
    await waitFor(
      () => (double.tryParse(property('time-pos')) ?? 0) > .2,
      'first playback',
    );
    var maximumReadSpeed = 0.0;
    var maximumBufferedSeconds = 0.0;
    for (var i = 0; i < 25; i++) {
      final speed = double.tryParse(property('cache-speed')) ?? 0;
      if (speed > maximumReadSpeed) maximumReadSpeed = speed;
      final buffered = double.tryParse(property('demuxer-cache-duration')) ?? 0;
      if (buffered > maximumBufferedSeconds) maximumBufferedSeconds = buffered;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (maximumReadSpeed <= 0) throw StateError('Native I/O speed unavailable');
    if (maximumBufferedSeconds <= 0) {
      throw StateError('Native buffer duration unavailable');
    }
    send(['seek', '30', 'absolute']);
    await waitFor(
      () => (double.tryParse(property('time-pos')) ?? 0) >= 29,
      'seek',
    );
    send(['set', 'http-header-fields', '']);
    send(['loadfile', 'http://127.0.0.1:${origin.port}/two', 'replace']);
    await waitFor(
      () =>
          property('path').endsWith('/two') &&
          (double.tryParse(property('time-pos')) ?? 0) > .2,
      'second playback',
    );
    if (wrongHeaders != 0) throw StateError('Headers leaked across files');
    if (ranges == 0) throw StateError('No Range requests observed');
    stdout.writeln(
      'PASS native HTTP playback, seek, header reset, I/O speed; requests=$requests ranges=$ranges bytes=$bytes maxReadBytesPerSecond=${maximumReadSpeed.round()} maxBufferedSeconds=${maximumBufferedSeconds.round()}',
    );
  } finally {
    destroy(handle);
    await origin.close(force: true);
    await serving.cancel();
  }
}
