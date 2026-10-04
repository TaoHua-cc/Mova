import 'dart:io' show Platform;

import 'package:shared_preferences/shared_preferences.dart';

const androidPlayerEngineKey = 'yingji.player.android-engine';

/// Unknown/old preferences use the Android default; mpv is always explicit.
String androidPlayerEngine(SharedPreferences prefs) =>
    prefs.getString(androidPlayerEngineKey) == 'mpv' ? 'mpv' : 'exo';

Future<bool> useAndroidExoPlayer() async =>
    Platform.isAndroid &&
    androidPlayerEngine(await SharedPreferences.getInstance()) == 'exo';
