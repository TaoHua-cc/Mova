import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('windows/native_player/main.cpp').readAsStringSync();

  test('iOS style keeps grouped choices and compact numeric HUD', () {
    expect(source, contains('Consecutive choices share one grouped surface'));
    expect(
      source,
      contains('item.row == PanelRow::Option || item.row == PanelRow::Track'),
    );
    expect(source, contains('HintDetailIsValue(text) ? 160 : 240'));
    expect(
      source,
      contains('ShowHint(detail, std::wstring(), icon, HintMode::Toast'),
    );
    expect(source, contains('enabled ? 24.0f + amount * 48.0f : 12.0f'));
  });

  test(
    'desktop chrome stays compact and danmaku uses Android continuous controls',
    () {
      expect(source, contains('kUiMaxScale = 1.1f'));
      expect(source, contains('kPanelOptionHeight = 56.0f'));
      expect(source, contains('PanelRow::Toggle'));
      expect(source, contains('SetCapture(window)'));
      expect(source, contains('case WM_CAPTURECHANGED:'));
      expect(
        source,
        contains(
          'DragPanelSlider(static_cast<int>(GET_X_LPARAM(lparam) / scale), false)',
        ),
      );
      expect(
        source,
        contains('if (persist) EmitSetting("yingji.danmaku." + name, emitted)'),
      );
      expect(source, contains('std::clamp(value, item.minimum, item.maximum)'));
      expect(
        source,
        contains('item.enabled = g_danmaku_enabled && !g_danmaku_loading'),
      );
      expect(source, isNot(contains('NextStep({0.25, 0.5, 0.75, 1.0}, area)')));
    },
  );

  test('native secondary menus use Android glass and fixed title geometry', () {
    expect(source, contains('kPanelContentWidth = 440'));
    expect(source, contains('kPanelPadding = 20'));
    expect(source, contains('kPanelTitleHeight = 46.0f'));
    expect(source, contains('Color(top_alpha, 27, 29, 34)'));
    expect(source, contains('.66 + g_glass_blur.load() / 240.0'));
    expect(source, contains('PanelTitleHeight() +'));
    expect(source, contains('if (!item.selected && !opens_panel) return;'));
  });

  test('native polish keeps shared fixed material and drag feedback', () {
    final material = source.substring(
      source.indexOf('void FillGlassSurface('),
      source.indexOf('/// 播放器二级菜单采用固定雾面材质'),
    );
    expect(
      material,
      contains('FillStaticPlayerMenuSurface(graphics, path, rect)'),
    );
    expect(material, isNot(contains('graphics.FillPath')));
    expect(
      source,
      contains('const float track_size = hovering_seek ? 4.0f : 2.5f'),
    );
    expect(source, contains('static_cast<float>(thumb_fraction), 0.0f, 1.0f'));
    expect(source, contains('id == kPlayPause ? 44.0f : 40.0f'));
    expect(source, contains('items.insert(first_track, std::move(item))'));
  });

  test('native transport painting and input share the left dock layout', () {
    final hit = source.substring(
      source.indexOf('ControlId HitControl('),
      source.indexOf(
        'void AddRoundedRectPath(',
        source.indexOf('ControlId HitControl('),
      ),
    );
    expect(hit, contains('TransportLayout(width)'));
    expect(source, contains('TransportLayout(static_cast<int>(width))'));
    expect(source, contains('static_cast<float>(i) * 44.0f'));
    expect(source, contains('hit == kPlayPause'));
    expect(source, contains('hit == kPreviousEpisode'));
    expect(source, isNot(contains('center - 166')));
    expect(source, contains('tool == "全集列表"'));
    expect(source, contains('id == kPlayPause && !g_paused.load()'));
  });

  test('native audio and subtitle menus are separate', () {
    final tracks = source.substring(
      source.indexOf('void ShowTrackMenu('),
      source.indexOf('void ShowSubtitleSearchMenu('),
    );
    final audio = tracks.substring(
      tracks.indexOf('if (audio)'),
      tracks.indexOf('const std::string subtitle_id'),
    );
    expect(audio, contains('"aid"'));
    expect(audio, contains('return;'));
    expect(audio, isNot(contains('"sid"')));
    expect(tracks, isNot(contains('L"字幕与音轨"')));
    expect(
      tracks.substring(tracks.indexOf('const std::string subtitle_id')),
      isNot(contains('"aid"')),
    );
  });
}
