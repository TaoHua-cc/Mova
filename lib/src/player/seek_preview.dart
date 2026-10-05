import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../sources/media_source.dart';

/// A real server frame, or one rectangle in a Jellyfin sprite sheet.
class SeekPreviewFrame {
  const SeekPreviewFrame(
    this.bytes, {
    this.x = 0,
    this.y = 0,
    this.width = 0,
    this.height = 0,
  });
  final Uint8List bytes;
  final int x, y, width, height;
}

Uint8List? bifFrame(Uint8List bytes, double seconds) {
  const magic = [0x89, 0x42, 0x49, 0x46, 0x0d, 0x0a, 0x1a, 0x0a];
  if (bytes.length < 64 || !seconds.isFinite || seconds < 0) return null;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return null;
  }
  final data = ByteData.sublistView(bytes);
  if (data.getUint32(8, Endian.little) != 0) return null;
  final count = data.getUint32(12, Endian.little);
  final interval = data.getUint32(16, Endian.little);
  final multiplier = interval == 0 ? 1000 : interval;
  if (count == 0 || count > 100000 || 64 + (count + 1) * 8 > bytes.length) {
    return null;
  }
  var selected = 0;
  for (var i = 0; i < count; i++) {
    if (data.getUint32(64 + i * 8, Endian.little) * multiplier >
        seconds * 1000) {
      break;
    }
    selected = i;
  }
  final start = data.getUint32(68 + selected * 8, Endian.little);
  final end = data.getUint32(76 + selected * 8, Endian.little);
  if (start < 64 + (count + 1) * 8 || end <= start || end > bytes.length) {
    return null;
  }
  return Uint8List.sublistView(bytes, start, end);
}

/// One capability lookup per resource. Bounded responses; never downloads video.
class ServerSeekPreview {
  ServerSeekPreview(
    this.client,
    this.source,
    this.token,
    this.itemId, {
    this.mediaSourceId,
  });
  final http.Client client;
  final MediaSource source;
  final String token, itemId;
  final String? mediaSourceId;
  Future<void>? _loading;
  Uint8List? _bif;
  Map<String, dynamic>? _tiles;
  int _resolution = 0;
  final Map<int, Uint8List> _sheets = {};

  Uri _uri(String path, [Map<String, String> extra = const {}]) => source
      .endpoint
      .resolve(path)
      .replace(queryParameters: {'api_key': token, ...extra});

  Future<Uint8List?> _read(Uri uri, int limit) async {
    final request = http.Request('GET', uri)..headers['X-Emby-Token'] = token;
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 3));
    if (response.statusCode != 200 || (response.contentLength ?? 0) > limit) {
      await response.stream.listen(null).cancel();
      return null;
    }
    final result = BytesBuilder(copy: false);
    final timer = Stopwatch()..start();
    await for (final part in response.stream.timeout(
      const Duration(seconds: 3),
    )) {
      if (result.length + part.length > limit ||
          timer.elapsedMilliseconds > 3000) {
        return null;
      }
      result.add(part);
    }
    return result.takeBytes();
  }

  Future<void> _load() async {
    try {
      if (source.kind == SourceKind.emby) {
        _bif = await _read(
          _uri('Videos/$itemId/index.bif', {'Width': '320'}),
          16 * 1024 * 1024,
        );
      } else if (source.kind == SourceKind.jellyfin) {
        final bytes = await _read(
          _uri('Items/$itemId', {'Fields': 'Trickplay'}),
          1024 * 1024,
        );
        if (bytes == null) return;
        final item = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        final versions = item['Trickplay'] as Map<String, dynamic>?;
        final version =
            versions?[mediaSourceId ?? itemId] as Map<String, dynamic>?;
        if (version == null || version.isEmpty) return;
        final widths =
            version.keys
                .map(int.tryParse)
                .whereType<int>()
                .where((w) => w > 0 && w <= 640)
                .toList()
              ..sort();
        if (widths.isEmpty) return;
        _resolution = widths.first;
        _tiles = version['$_resolution'] as Map<String, dynamic>?;
      }
    } catch (_) {
      // Capability misses and malformed data fall back to independent decoding.
    }
  }

  Future<SeekPreviewFrame?> frame(double seconds) async {
    await (_loading ??= _load());
    if (_bif != null) {
      final bytes = bifFrame(_bif!, seconds);
      return bytes == null ? null : SeekPreviewFrame(bytes);
    }
    final t = _tiles;
    if (t == null || !seconds.isFinite || seconds < 0) return null;
    int value(String key) => (t[key] as num?)?.toInt() ?? 0;
    final interval = value('Interval'),
        columns = value('TileWidth'),
        rows = value('TileHeight');
    final width = value('Width'),
        height = value('Height'),
        count = value('ThumbnailCount');
    if (interval <= 0 ||
        columns <= 0 ||
        rows <= 0 ||
        width <= 0 ||
        height <= 0 ||
        count <= 0 ||
        columns * rows > 1000) {
      return null;
    }
    final index = (seconds * 1000 / interval).floor().clamp(0, count - 1);
    final sheet = index ~/ (columns * rows);
    var bytes = _sheets[sheet];
    bytes ??= await _read(
      _uri('Videos/$itemId/Trickplay/$_resolution/$sheet.jpg', {
        'mediaSourceId': ?mediaSourceId,
      }),
      8 * 1024 * 1024,
    );
    if (bytes == null) return null;
    if (_sheets.length >= 2) _sheets.remove(_sheets.keys.first);
    _sheets[sheet] = bytes;
    final cell = index % (columns * rows);
    return SeekPreviewFrame(
      bytes,
      x: cell % columns * width,
      y: cell ~/ columns * height,
      width: width,
      height: height,
    );
  }
}
