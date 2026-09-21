import 'package:flutter_test/flutter_test.dart';

import 'package:yingji/src/player/windows_native_player.dart';

/// 换集之后新的这一集从哪儿起播，由这份规则决定（见 `episodeResumeSeconds`）。
///
/// 它直接对应一个用户可见的 bug：「切换上下集时，没有正确根据上下集进度播放，
/// 都是从上一集的进度播放」。原生侧那条根因（mpv 的 `--start` 会在换文件时被
/// 重新应用）由 `tool/probe_episode_switch_resume.py` 覆盖；这里守住的是**下发
/// 什么值**这一半 —— 尤其是两条边界：看完的集不能从片尾接上（会立刻连播走），
/// 刚开头的集不值得多一次 seek。
void main() {
  test('no watch record means play from the start', () {
    expect(episodeResumeSeconds(progress: null, duration: 2400), isNull);
    expect(episodeResumeSeconds(progress: .4, duration: null), isNull);
    expect(episodeResumeSeconds(progress: null, duration: null), isNull);
  });

  test('a nonsense duration is treated as no record', () {
    expect(episodeResumeSeconds(progress: .4, duration: 0), isNull);
    expect(episodeResumeSeconds(progress: .4, duration: -10), isNull);
  });

  test('a finished episode restarts from the beginning', () {
    // 从片尾接上会立刻「播完 → 连播下一集」，用户只看到闪一下。
    expect(episodeResumeSeconds(progress: 1, duration: 2400), isNull);
    expect(episodeResumeSeconds(progress: .95, duration: 2400), isNull);
    expect(episodeResumeSeconds(progress: .97, duration: 2400), isNull);
  });

  test('an episode barely started also restarts', () {
    // 2 秒 ≈ 刚点开就退出：与从头播没有区别，不必多一次 seek。
    expect(episodeResumeSeconds(progress: 2 / 2400, duration: 2400), isNull);
    expect(episodeResumeSeconds(progress: 0, duration: 2400), isNull);
  });

  test('a partly watched episode keeps its own position', () {
    expect(
      episodeResumeSeconds(progress: .5, duration: 2400),
      closeTo(1200, 1e-6),
    );
    // 4 位小数的比例 × 一小时片 ≈ 0.4 秒误差，够定位。
    expect(
      episodeResumeSeconds(progress: .0238, duration: 3600),
      closeTo(85.68, 1e-6),
    );
  });

  test('boundaries stay on the documented side', () {
    expect(episodeResumeSeconds(progress: .9499, duration: 2400), isNotNull);
    expect(
      episodeResumeSeconds(progress: 5 / 2400, duration: 2400),
      closeTo(5, 1e-9),
    );
    expect(episodeResumeSeconds(progress: 4.9 / 2400, duration: 2400), isNull);
  });
}
