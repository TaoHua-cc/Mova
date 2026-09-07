import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:yingji/src/player/subtitle_preference.dart';

void main() {
  test(
    'matches configurable subtitle languages without false Chinese match',
    () {
      final tracks = [
        SubtitleTrack('1', 'English', 'eng'),
        SubtitleTrack('2', '日语', 'jpn'),
      ];
      expect(preferredSubtitle(tracks, 'en')?.id, '1');
      expect(preferredSubtitle(tracks, 'ja')?.id, '2');
      expect(preferredSubtitle(tracks, 'zh'), isNull);
    },
  );
  test('prefers simplified Chinese from language or title', () {
    final tracks = [
      SubtitleTrack('1', 'English', 'eng'),
      SubtitleTrack('2', '繁體中文', 'chi'),
      SubtitleTrack('3', '简体中英', null),
    ];
    expect(preferredChineseSubtitle(tracks)?.id, '3');
    expect(
      preferredChineseSubtitle([SubtitleTrack('4', null, 'zh-CN')])?.id,
      '4',
    );
  });
  test('does not invent Chinese when absent', () {
    expect(
      preferredChineseSubtitle([SubtitleTrack('1', 'English', 'eng')]),
      isNull,
    );
    expect(preferredChineseSubtitle([]), isNull);
  });
  test(
    'selects preferred audio language without overriding absent matches',
    () {
      final tracks = [
        AudioTrack('1', 'English 5.1', 'eng'),
        AudioTrack('2', '国语', 'chi'),
        AudioTrack('3', '日本語', 'jpn'),
      ];
      expect(preferredAudioTrack(tracks, 'zh')?.id, '2');
      expect(preferredAudioTrack(tracks, 'ja')?.id, '3');
      expect(preferredAudioTrack(tracks, 'ko'), isNull);
    },
  );
}
