import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows root contains only category entries, not track contents', () {
    final source = File('windows/native_player/main.cpp').readAsStringSync();
    final root = source.substring(
      source.indexOf('if (!main_subtitles)'),
      source.indexOf('const std::string subtitle_id = MpvString("sid")'),
    );
    for (final key in [
      'mova-subtitle-main',
      'mova-subtitle-search',
      'mova-subtitle-local',
    ]) {
      expect(root, contains(key));
    }
    expect(root, isNot(contains('for (const auto& track')));
    expect(source, contains('ShowLocalSubtitleMenu(g_panel_anchor)'));
    expect(
      source,
      contains('ShowTrackMenu(g_window, false, g_panel_anchor, true)'),
    );
  });
  test(
    'Android root routes categories, external Exo subtitles use native loader',
    () {
      final source = File('lib/src/player/player_page.dart').readAsStringSync();
      final root = source.substring(
        source.indexOf("case '字幕':"),
        source.indexOf("case '主字幕':"),
      );
      expect(root, contains("['主字幕', '字幕搜索', '本地导入']"));
      expect(root, isNot(contains('_trackSelector')));
      expect(source, contains("_exoCommand('addSubtitle'"));
      final native = File(
        'android/app/src/main/kotlin/com/taohua/mova/ExoPlayerPlatformView.kt',
      ).readAsStringSync();
      expect(native, contains('setSubtitleConfigurations(listOf(subtitle))'));
      expect(native, contains('exoPlayer.playWhenReady = playing'));
    },
  );
}
