/// Broadcast-source aliases, not the similarly named messaging apps.
String broadcastPlatformName(String name) {
  final key = name.toLowerCase().replaceAll(RegExp(r'[\s+_-]'), '');
  if (const {
    'tencentqq',
    'tencentvideo',
    '腾讯视频',
    'qqvideo',
    'v.qq.com',
  }.contains(key)) {
    return '腾讯视频';
  }
  if (const {'appletv', 'appletvplus'}.contains(key)) return 'Apple TV+';
  if (const {'iqiyi', '爱奇艺'}.contains(key)) return '爱奇艺';
  if (const {'youku', '优酷'}.contains(key)) return '优酷';
  if (const {
    'bilibili',
    'bilibilitv',
    'bilibili.com',
    'www.bilibili.com',
    '哔哩哔哩',
    '哔哩哔哩动画',
    'b站',
  }.contains(key)) {
    return '哔哩哔哩';
  }
  return name.trim();
}

Map<String, Uri?> mergeBroadcastPlatforms(Iterable<Map<String, Uri?>> sources) {
  final result = <String, Uri?>{};
  for (final source in sources) {
    for (final entry in source.entries) {
      final name = broadcastPlatformName(entry.key);
      if (name.isEmpty) continue;
      result[name] = result[name] ?? entry.value;
    }
  }
  return result;
}
