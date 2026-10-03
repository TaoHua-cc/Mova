import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/tracking/broadcast_platforms.dart';

void main() {
  test('bilibili aliases merge once and retain a usable logo', () {
    final logo = Uri.parse('https://example.com/bilibili.png');
    for (final alias in ['Bilibili', 'bilibili TV', '哔哩哔哩', 'B站', '哔哩哔哩动画']) {
      expect(broadcastPlatformName(alias), '哔哩哔哩');
    }
    expect(
      mergeBroadcastPlatforms([
        {'Bilibili': null},
        {'哔哩哔哩': logo},
        {'bilibili TV': null},
      ]),
      {'哔哩哔哩': logo},
    );
    expect(broadcastPlatformName('未知频道'), '未知频道');
  });
}
