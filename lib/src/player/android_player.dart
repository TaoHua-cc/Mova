import 'dart:io' show Platform;

import 'package:shared_preferences/shared_preferences.dart';

import '../history/watch_state_store.dart';
import '../cache/video_cache.dart';
import 'native_dolby_vision.dart';

const androidPlayerEngineKey = 'yingji.player.android-engine';

/// Unknown/old preferences use the Android default; mpv is always explicit.
String androidPlayerEngine(SharedPreferences prefs) =>
    prefs.getString(androidPlayerEngineKey) == 'mpv' ? 'mpv' : 'exo';

Future<bool> useAndroidExoPlayer() async =>
    Platform.isAndroid &&
    androidPlayerEngine(await SharedPreferences.getInstance()) == 'exo';

Future<void> playAndroidExoPlayer({
  required WatchState state,
  required Map<String, String> headers,
  String? container,
}) async {
  final cache = await VideoCacheStore.tryCreate();
  NativeDolbyVisionPlaybackResult result;
  try {
    if (cache == null && Uri.parse(state.mediaId).scheme == 'http') {
      throw StateError('本机播放代理不可用，请检查应用存储空间后重试');
    }
    final url = await cache?.playbackUrl(state.mediaId, headers: headers);
    result = await NativeDolbyVisionPlayer.play(
      url: url ?? state.mediaId,
      title: state.title,
      headers: url == null ? headers : const {},
      initialPosition: state.position,
      container: container,
      useExoPlayer: true,
    );
  } finally {
    await cache?.closePlaybackProxy();
  }
  if (result.position > Duration.zero || result.completed) {
    final store = await WatchStateStore.create();
    await store.save(
      WatchState.fromJson({
        ...state.toJson(),
        'position': result.position.inMilliseconds,
        'duration':
            (result.duration > Duration.zero ? result.duration : state.duration)
                .inMilliseconds,
        'isPlayed': result.completed,
        'progressOrigin': 'local',
        'progressOriginName': null,
        'updatedAt': DateTime.now().toIso8601String(),
      }),
    );
  }
  if (result.error != null) throw StateError('ExoPlayer：${result.error}');
}
