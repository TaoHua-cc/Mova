import 'package:media_kit/media_kit.dart';

const subtitleLanguages = <String, String>{
  'zh': '中文',
  'en': '英语',
  'ja': '日语',
  'ko': '韩语',
  'fr': '法语',
  'de': '德语',
  'es': '西班牙语',
};

const audioLanguages = subtitleLanguages;

AudioTrack? preferredAudioTrack(List<AudioTrack> tracks, String preferred) {
  for (final track in tracks) {
    if (track.id == 'auto' || track.id == 'no') continue;
    final language = (track.language ?? '').toLowerCase();
    final title = (track.title ?? '').toLowerCase();
    final aliases = switch (preferred) {
      'zh' =>
        r'^(zh|zho|chi|cmn|yue)(-|_|$)|chinese|mandarin|cantonese|中文|国语|普通话|粤语',
      'en' => r'^(en|eng)(-|_|$)|english|英语|英文',
      'ja' => r'^(ja|jpn)(-|_|$)|japanese|日语|日文',
      'ko' => r'^(ko|kor)(-|_|$)|korean|韩语|韩文',
      'fr' => r'^(fr|fra|fre)(-|_|$)|french|法语',
      'de' => r'^(de|deu|ger)(-|_|$)|german|德语',
      'es' => r'^(es|spa)(-|_|$)|spanish|西班牙',
      _ => '',
    };
    if (aliases.isNotEmpty &&
        (RegExp(aliases).hasMatch(language) ||
            RegExp(aliases).hasMatch(title))) {
      return track;
    }
  }
  return null;
}

SubtitleTrack? preferredChineseSubtitle(List<SubtitleTrack> tracks) =>
    preferredSubtitle(tracks, 'zh');

SubtitleTrack? preferredSubtitle(List<SubtitleTrack> tracks, String preferred) {
  SubtitleTrack? best;
  var bestScore = 0;
  for (final track in tracks) {
    if (track.id == 'auto' || track.id == 'no') continue;
    final language = (track.language ?? '').toLowerCase();
    final title = (track.title ?? '').toLowerCase();
    final chinese =
        RegExp(r'^(zh|zho|chi|chs|cht)(-|_|$)').hasMatch(language) ||
        RegExp(r'中文|中英|简体|簡體|繁体|繁體|chinese|\bchs\b|\bcht\b').hasMatch(title);
    final aliases = switch (preferred) {
      'en' => r'^(en|eng)(-|_|$)|english|英语|英文',
      'ja' => r'^(ja|jpn)(-|_|$)|japanese|日语|日文',
      'ko' => r'^(ko|kor)(-|_|$)|korean|韩语|韩文',
      'fr' => r'^(fr|fra|fre)(-|_|$)|french|法语',
      'de' => r'^(de|deu|ger)(-|_|$)|german|德语',
      'es' => r'^(es|spa)(-|_|$)|spanish|西班牙',
      _ => '',
    };
    if (preferred == 'zh'
        ? !chinese
        : aliases.isEmpty ||
              !(RegExp(aliases).hasMatch(language) ||
                  RegExp(aliases).hasMatch(title)))
      continue;
    final simplified = RegExp(r'简|簡|chs|hans').hasMatch('$language $title');
    final score = (simplified ? 20 : 10) + (title.contains('forced') ? 0 : 2);
    if (score > bestScore) {
      best = track;
      bestScore = score;
    }
  }
  return best;
}
