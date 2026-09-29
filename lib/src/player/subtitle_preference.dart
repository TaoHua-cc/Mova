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

const _subtitleLanguageNames = <String, String>{
  'af': '南非荷兰语',
  'afr': '南非荷兰语',
  'ar': '阿拉伯语',
  'ara': '阿拉伯语',
  'bg': '保加利亚语',
  'bul': '保加利亚语',
  'bn': '孟加拉语',
  'ben': '孟加拉语',
  'ca': '加泰罗尼亚语',
  'cat': '加泰罗尼亚语',
  'cs': '捷克语',
  'ces': '捷克语',
  'cze': '捷克语',
  'da': '丹麦语',
  'dan': '丹麦语',
  'de': '德语',
  'deu': '德语',
  'ger': '德语',
  'el': '希腊语',
  'ell': '希腊语',
  'gre': '希腊语',
  'en': '英语',
  'eng': '英语',
  'es': '西班牙语',
  'spa': '西班牙语',
  'fa': '波斯语',
  'fas': '波斯语',
  'per': '波斯语',
  'fi': '芬兰语',
  'fin': '芬兰语',
  'fil': '菲律宾语',
  'tl': '菲律宾语',
  'tgl': '菲律宾语',
  'fr': '法语',
  'fra': '法语',
  'fre': '法语',
  'he': '希伯来语',
  'heb': '希伯来语',
  'iw': '希伯来语',
  'hi': '印地语',
  'hin': '印地语',
  'hr': '克罗地亚语',
  'hrv': '克罗地亚语',
  'hu': '匈牙利语',
  'hun': '匈牙利语',
  'id': '印度尼西亚语',
  'ind': '印度尼西亚语',
  'is': '冰岛语',
  'isl': '冰岛语',
  'ice': '冰岛语',
  'it': '意大利语',
  'ita': '意大利语',
  'ja': '日语',
  'jpn': '日语',
  'ko': '韩语',
  'kor': '韩语',
  'ms': '马来语',
  'msa': '马来语',
  'may': '马来语',
  'nl': '荷兰语',
  'nld': '荷兰语',
  'dut': '荷兰语',
  'no': '挪威语',
  'nor': '挪威语',
  'nb': '书面挪威语',
  'nob': '书面挪威语',
  'nn': '新挪威语',
  'nno': '新挪威语',
  'pl': '波兰语',
  'pol': '波兰语',
  'pt': '葡萄牙语',
  'por': '葡萄牙语',
  'ro': '罗马尼亚语',
  'ron': '罗马尼亚语',
  'rum': '罗马尼亚语',
  'ru': '俄语',
  'rus': '俄语',
  'sk': '斯洛伐克语',
  'slk': '斯洛伐克语',
  'slo': '斯洛伐克语',
  'sl': '斯洛文尼亚语',
  'slv': '斯洛文尼亚语',
  'sr': '塞尔维亚语',
  'srp': '塞尔维亚语',
  'sv': '瑞典语',
  'swe': '瑞典语',
  'ta': '泰米尔语',
  'tam': '泰米尔语',
  'te': '泰卢固语',
  'tel': '泰卢固语',
  'th': '泰语',
  'tha': '泰语',
  'tr': '土耳其语',
  'tur': '土耳其语',
  'uk': '乌克兰语',
  'ukr': '乌克兰语',
  'ur': '乌尔都语',
  'urd': '乌尔都语',
  'vi': '越南语',
  'vie': '越南语',
  'zh': '中文',
  'chi': '中文',
  'zho': '中文',
  'cmn': '中文',
  'yue': '粤语',
  'und': '未标注语言',
};

String subtitleTrackLabel(SubtitleTrack track) {
  final title = track.title?.trim() ?? '';
  final language = track.language?.trim() ?? '';
  final normalized = language.toLowerCase().replaceAll('_', '-');
  final languageName = switch (normalized) {
    'chs' || 'zhs' => '简体中文',
    'cht' || 'zht' => '繁体中文',
    _ =>
      normalized.startsWith('zh-')
          ? normalized.contains('hant') ||
                    normalized.endsWith('-tw') ||
                    normalized.endsWith('-hk') ||
                    normalized.endsWith('-mo')
                ? '繁体中文'
                : normalized.contains('hans') ||
                      normalized.endsWith('-cn') ||
                      normalized.endsWith('-sg')
                ? '简体中文'
                : '中文'
          : _subtitleLanguageNames[normalized] ??
                _subtitleLanguageNames[normalized.split('-').first],
  };

  if (languageName == '未标注语言') {
    if (title.isEmpty) return '未标注语言';
    if (_startsWithChinese(title)) return title;
    return '$languageName（$title）';
  }
  if (languageName != null) {
    if (title.isEmpty) return languageName;
    if (title.startsWith(languageName) || _startsWithChinese(title)) {
      return title;
    }
    return '$languageName（$title）';
  }
  if (title.isNotEmpty && _startsWithChinese(title)) return title;
  if (title.isEmpty && language.isEmpty) return '语言未标注';
  final detail = [
    title,
    language,
  ].where((value) => value.isNotEmpty).join(' · ');
  return '${languageName ?? (language.isEmpty ? '语言未标注' : '未识别语种')}（$detail）';
}

bool _startsWithChinese(String value) =>
    value.isNotEmpty && RegExp(r'^[\u3400-\u9fff]').hasMatch(value);

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
