import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/player/windows_native_player.dart';

void main() {
  test(
    'episode resource updates encode display values without raw delimiters',
    () {
      final line = encodeEpisodeResourceSnapshotLine(
        playlistIndex: 7,
        revision: 2,
        currentIndex: 1,
        resources: const [
          WindowsNativeResourceOption(
            source: '主|服务器',
            detail: '1080p\nHEVC',
            iconPath: r'C:\cache\mark.png',
            mark: 1,
            rank: 2,
          ),
        ],
      );

      expect(line, startsWith('MOVA_EPISODE_RESOURCES=7|2|1|1|'));
      expect(line, isNot(contains('主|服务器')));
      expect(line, isNot(contains('1080p\nHEVC')));
      expect(line, contains(Uri.encodeComponent('主|服务器')));
      expect(line, contains(Uri.encodeComponent('1080p\nHEVC')));
      expect(line, contains(Uri.encodeComponent(r'C:\cache\mark.png')));
    },
  );
}
