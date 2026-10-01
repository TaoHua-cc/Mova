import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Bake blur at source-image resolution. Scrolling blends the result without
/// a viewport-sized filter. At most one texture generation is in flight.
class PreblurredBackdrop extends StatefulWidget {
  const PreblurredBackdrop({
    super.key,
    required this.image,
    required this.viewport,
    required this.sigma,
  });
  final ImageProvider image;
  final Size viewport;
  final double sigma;
  @override
  State<PreblurredBackdrop> createState() => _PreblurredBackdropState();
}

class _PreblurredBackdropState extends State<PreblurredBackdrop> {
  ImageStream? _stream;
  late final _listener = ImageStreamListener(_onImage, onError: _onError);
  ImageInfo? _source;
  ui.Image? _blurred;
  int _revision = 0;
  bool _rendering = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(PreblurredBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) {
      _resolve();
    } else if (oldWidget.viewport != widget.viewport ||
        oldWidget.sigma != widget.sigma) {
      _refresh();
    }
  }

  void _resolve() {
    final next = widget.image.resolve(createLocalImageConfiguration(context));
    if (_stream?.key == next.key) return;
    _stream?.removeListener(_listener);
    _revision++;
    _retire(_source?.image);
    _retire(_blurred);
    _source = null;
    _blurred = null;
    _stream = next..addListener(_listener);
  }

  void _onImage(ImageInfo info, bool synchronous) {
    if (!mounted) {
      info.dispose();
      return;
    }
    _retire(_source?.image);
    if (synchronous) {
      _source = info;
    } else {
      setState(() => _source = info);
    }
    _refresh();
  }

  void _onError(Object error, StackTrace? stack) {
    if (!mounted) return;
    _revision++;
    setState(() {
      _retire(_source?.image);
      _retire(_blurred);
      _source = null;
      _blurred = null;
    });
  }

  void _refresh() {
    _revision++;
    if (_source != null && !_rendering) unawaited(_render());
  }

  Future<void> _render() async {
    final source = _source?.image.clone();
    if (source == null) return;
    _rendering = true;
    final revision = _revision;
    ui.Picture? picture;
    ui.Image? result;
    try {
      final scale = math.max(
        widget.viewport.width / source.width,
        widget.viewport.height / source.height,
      );
      final sigma = scale > 0 ? widget.sigma / scale : 0.0;
      final bounds = Rect.fromLTWH(
        0,
        0,
        source.width.toDouble(),
        source.height.toDouble(),
      );
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.saveLayer(
        bounds,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            tileMode: TileMode.clamp,
          ),
      );
      canvas.drawImage(source, Offset.zero, Paint());
      canvas.restore();
      picture = recorder.endRecording();
      result = await picture.toImage(source.width, source.height);
      if (mounted && revision == _revision) {
        final previous = _blurred;
        setState(() => _blurred = result);
        result = null;
        _retire(previous);
      }
    } catch (_) {
      // Decorative backdrop failure must not block the real content.
    } finally {
      result?.dispose();
      picture?.dispose();
      source.dispose();
      _rendering = false;
      if (mounted && revision != _revision && _source != null) {
        unawaited(_render());
      }
    }
  }

  static void _retire(ui.Image? image) {
    if (image == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
  }

  @override
  void dispose() {
    _revision++;
    _stream?.removeListener(_listener);
    _retire(_source?.image);
    _retire(_blurred);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RawImage(
    image: _blurred ?? _source?.image,
    fit: BoxFit.cover,
    filterQuality: FilterQuality.medium,
  );
}
