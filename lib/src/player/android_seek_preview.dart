import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../brand.dart';
import '../network/network_http_client.dart';
import '../network/proxy_routing.dart';
import '../sources/media_source.dart';
import '../sources/source_store.dart';
import 'seek_preview.dart';

/// A sampled frame: keep its own timestamp while the next target is loading.
class AndroidSeekPreview extends StatefulWidget {
  const AndroidSeekPreview({
    super.key,
    required this.url,
    this.sourceId,
    this.itemId,
    required this.position,
    required this.fallbackUrl,
  });
  final String url;
  final String? sourceId, itemId;
  final Duration position;
  final Future<String> Function() fallbackUrl;

  @override
  State<AndroidSeekPreview> createState() => _AndroidSeekPreviewState();
}

class _AndroidSeekPreviewState extends State<AndroidSeekPreview> {
  static const _channel = MethodChannel('mova/platform');
  http.Client? _client;
  ServerSeekPreview? _server;
  ui.Image? _image;
  Rect? _crop;
  Duration? _frameTime;
  Duration? _pending;
  bool _busy = false;
  bool _ready = false;
  int? _lastTarget;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    debugPrint('[MovaSeekPreview] prepare');
    try {
      final store = await SourceStore.create();
      if (!mounted) return;
      final source = store
          .load()
          .where((s) => s.id == widget.sourceId)
          .firstOrNull;
      final token = source == null ? null : store.tokenFor(source);
      if (source != null &&
          source.kind != SourceKind.webdav &&
          token != null &&
          widget.itemId != null) {
        _client = ProxyRouting.serverUsesProxy(source.id)
            ? createNetworkHttpClient()
            : http.Client();
        _server = ServerSeekPreview(
          _client!,
          source,
          token,
          widget.itemId!,
          mediaSourceId: Uri.tryParse(widget.url)
              ?.queryParameters['MediaSourceId'],
        );
      }
    } catch (_) {
      // Native extraction remains available if metadata lookup fails.
    }
    if (mounted) {
      _ready = true;
      debugPrint('[MovaSeekPreview] ready server=${_server != null}');
      _schedule();
    }
  }

  @override
  void didUpdateWidget(AndroidSeekPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  void _schedule() {
    if (!_ready) return;
    final bucket = widget.position.inMilliseconds ~/ 250;
    if (_lastTarget == bucket) return;
    _lastTarget = bucket;
    _pending = widget.position;
    _timer ??= Timer(const Duration(milliseconds: 150), () {
      _timer = null;
      unawaited(_drain());
    });
  }

  Future<void> _drain() async {
    if (_busy || !mounted) return;
    _busy = true;
    try {
      while (mounted && _pending != null) {
        final target = _pending!;
        _pending = null;
        SeekPreviewFrame? frame;
        final elapsed = Stopwatch()..start();
        try {
          frame = await _server?.frame(target.inMilliseconds / 1000);
        } catch (_) {}
        debugPrint(
          '[MovaSeekPreview] server bytes=${frame?.bytes.length ?? 0} ms=${elapsed.elapsedMilliseconds} mounted=$mounted',
        );
        if (!mounted) return;
        if (frame == null) {
          try {
            final url = await widget.fallbackUrl();
            debugPrint(
              '[MovaSeekPreview] fallback route=${url.startsWith('http://127.0.0.1') ? 'loopback' : 'local'} ms=${elapsed.elapsedMilliseconds}',
            );
            if (!mounted) return;
            final bytes = await _channel
                .invokeMethod<Uint8List>('seekPreviewFrame', {
                  'url': url,
                  'milliseconds': target.inMilliseconds,
                })
                .timeout(const Duration(seconds: 8));
            if (bytes != null) frame = SeekPreviewFrame(bytes);
            debugPrint(
              '[MovaSeekPreview] native bytes=${bytes?.length ?? 0} ms=${elapsed.elapsedMilliseconds} mounted=$mounted',
            );
          } catch (error) {
            debugPrint(
              '[MovaSeekPreview] native failure=${error.runtimeType} ms=${elapsed.elapsedMilliseconds}',
            );
          }
        }
        if (!mounted || frame == null) continue;
        ui.Image? decoded;
        try {
          final codec = await ui.instantiateImageCodec(frame.bytes);
          try {
            decoded = (await codec.getNextFrame()).image;
          } finally {
            codec.dispose();
          }
          if (!mounted) {
            decoded.dispose();
            return;
          }
          final crop = frame.width > 0
              ? Rect.fromLTWH(
                  frame.x.toDouble(),
                  frame.y.toDouble(),
                  frame.width.toDouble(),
                  frame.height.toDouble(),
                )
              : Rect.fromLTWH(
                  0,
                  0,
                  decoded.width.toDouble(),
                  decoded.height.toDouble(),
                );
          if (crop.right > decoded.width || crop.bottom > decoded.height) {
            decoded.dispose();
            continue;
          }
          final previous = _image;
          setState(() {
            _image = decoded;
            _crop = crop;
            _frameTime = target;
          });
          previous?.dispose();
          debugPrint(
            '[MovaSeekPreview] displayed ms=${elapsed.elapsedMilliseconds}',
          );
        } catch (error) {
          debugPrint('[MovaSeekPreview] image failure=${error.runtimeType}');
          decoded?.dispose();
        }
      }
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    debugPrint('[MovaSeekPreview] closed');
    _timer?.cancel();
    _client?.close();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final time = _image == null ? widget.position : _frameTime!;
    final seconds = time.inSeconds;
    final label =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    return IgnorePointer(
      child: GlassPanel(
        radius: 14,
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_image != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: SizedBox(
                  width: 192,
                  height: 108,
                  child: CustomPaint(painter: _FramePainter(_image!, _crop!)),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FramePainter extends CustomPainter {
  const _FramePainter(this.image, this.crop);
  final ui.Image image;
  final Rect crop;
  @override
  void paint(Canvas canvas, Size size) {
    final fitted = applyBoxFit(BoxFit.contain, crop.size, size);
    canvas.drawImageRect(
      image,
      crop,
      Alignment.center.inscribe(fitted.destination, Offset.zero & size),
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.crop != crop;
}
