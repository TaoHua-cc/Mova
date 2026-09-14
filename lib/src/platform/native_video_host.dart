import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Win32 child-window bridge for a native `gpu-next` libmpv output.
class NativeVideoHost {
  NativeVideoHost._();

  static const MethodChannel _channel = MethodChannel('mova/native_video_host');

  static bool get isSupported => Platform.isWindows;

  static Future<int?> create() async {
    if (!isSupported) return null;
    return _channel.invokeMethod<int>('create');
  }

  static Future<void> setBounds(Rect rect, double devicePixelRatio) async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('setBounds', {
      'left': (rect.left * devicePixelRatio).round(),
      'top': (rect.top * devicePixelRatio).round(),
      'width': (rect.width * devicePixelRatio).round(),
      'height': (rect.height * devicePixelRatio).round(),
    });
  }

  static Future<void> setVisible(bool visible) async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('setVisible', visible);
  }

  static Future<void> dispose() async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('dispose');
  }
}

/// Reserves the middle of the player page for the native child window.
class NativeVideoSurface extends StatefulWidget {
  const NativeVideoSurface({
    super.key,
    required this.visible,
    this.topInset = 78,
    this.bottomInset = 154,
  });

  final bool visible;
  final double topInset;
  final double bottomInset;

  @override
  State<NativeVideoSurface> createState() => _NativeVideoSurfaceState();
}

class _NativeVideoSurfaceState extends State<NativeVideoSurface>
    with WidgetsBindingObserver {
  final GlobalKey _surfaceKey = GlobalKey();
  bool _created = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleSync();
  }

  @override
  void didUpdateWidget(covariant NativeVideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) _scheduleSync();
  }

  @override
  void didChangeMetrics() => _scheduleSync();

  void _scheduleSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_sync());
    });
  }

  Future<void> _sync() async {
    if (!_created) {
      final handle = await NativeVideoHost.create();
      if (!mounted || handle == null) return;
      _created = true;
    }
    final renderObject = _surfaceKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    await NativeVideoHost.setBounds(
      renderObject.localToGlobal(Offset.zero) & renderObject.size,
      View.of(context).devicePixelRatio,
    );
    await NativeVideoHost.setVisible(widget.visible);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // The Player releases its mpv child window during page disposal. Keep the
    // reusable host alive until the runner exits so it cannot disappear first.
    unawaited(NativeVideoHost.setVisible(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: widget.topInset, bottom: widget.bottomInset),
    child: SizedBox.expand(key: _surfaceKey),
  );
}
