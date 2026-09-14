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

class NativeDolbyVisionPlaybackResult {
  const NativeDolbyVisionPlaybackResult({
    required this.position,
    required this.duration,
    required this.completed,
    required this.nativeDolbyVision,
    this.error,
  });

  final Duration position;
  final Duration duration;
  final bool completed;
  final bool nativeDolbyVision;
  final String? error;

  factory NativeDolbyVisionPlaybackResult.fromMap(Map<Object?, Object?> value) {
    return NativeDolbyVisionPlaybackResult(
      position: Duration(
        milliseconds: (value['positionMs'] as num?)?.toInt() ?? 0,
      ),
      duration: Duration(
        milliseconds: (value['durationMs'] as num?)?.toInt() ?? 0,
      ),
      completed: value['completed'] == true,
      nativeDolbyVision: value['nativeDolbyVision'] == true,
      error: value['error'] as String?,
    );
  }
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

  static Future<NativeDolbyVisionPlaybackResult> play({
    required String url,
    required String title,
    required Map<String, String> headers,
    required Duration initialPosition,
    String? container,
  }) async {
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'playDolbyVision',
      {
        'url': url,
        'title': title,
        'headers': headers,
        'positionMs': initialPosition.inMilliseconds,
        if (container != null) 'container': container,
      },
    );
    if (value == null) {
      throw PlatformException(
        code: 'empty_result',
        message: '原生 Dolby Vision 播放器未返回状态',
      );
    }
    return NativeDolbyVisionPlaybackResult.fromMap(value);
  }
}
