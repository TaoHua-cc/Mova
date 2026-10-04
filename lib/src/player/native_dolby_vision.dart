import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class NativeDolbyVisionCapabilities {
  const NativeDolbyVisionCapabilities({
    required this.supported,
    required this.decoder,
    required this.display,
    this.decoderNames = const [],
  });

  final bool supported;
  final bool decoder;
  final bool display;
  final List<String> decoderNames;

  factory NativeDolbyVisionCapabilities.fromMap(Map<Object?, Object?> value) {
    return NativeDolbyVisionCapabilities(
      supported: value['supported'] == true,
      decoder: value['decoder'] == true,
      display: value['display'] == true,
      decoderNames: (value['decoderNames'] as List<Object?>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
    );
  }

  static const unavailable = NativeDolbyVisionCapabilities(
    supported: false,
    decoder: false,
    display: false,
  );
}

/// Bridge to Android's licensed Dolby Vision MediaCodec/display pipeline.
class NativeDolbyVisionPlayer {
  NativeDolbyVisionPlayer._();

  static const MethodChannel _channel = MethodChannel('mova/platform');

  static bool get isAvailablePlatform => Platform.isAndroid;

  /// Emby and Jellyfin currently expose variants such as DOVI, DolbyVision,
  /// Dolby Vision, DV and HDR10+DV in VideoRangeType/VideoRange.
  static bool isDolbyVision(String? videoRange) {
    final normalized = (videoRange ?? '').toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9+]'),
      '',
    );
    return normalized == 'dv' ||
        normalized.split('+').contains('dv') ||
        normalized.contains('dovi') ||
        normalized.contains('dolbyvision');
  }

  static Future<NativeDolbyVisionCapabilities> capabilities() async {
    if (!isAvailablePlatform) return NativeDolbyVisionCapabilities.unavailable;
    try {
      final value = await _channel.invokeMapMethod<Object?, Object?>(
        'dolbyVisionCapabilities',
      );
      return value == null
          ? NativeDolbyVisionCapabilities.unavailable
          : NativeDolbyVisionCapabilities.fromMap(value);
    } on PlatformException {
      return NativeDolbyVisionCapabilities.unavailable;
    } on MissingPluginException {
      return NativeDolbyVisionCapabilities.unavailable;
    }
  }
}
