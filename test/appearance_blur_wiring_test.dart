import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/brand.dart';

/// 「模糊程度」不是一根摆设滑杆：它必须真的喂给 [YingjiGlass.blur]，而且界面里
/// 不允许再出现写死的 sigma（否则拖滑杆时一部分面板不动，看着像坏了）。
void main() {
  test('appearance blur feeds the glass material', () {
    addTearDown(() => yingjiAppearance.apply(glassBlur: 30));
    yingjiAppearance.apply(glassBlur: 0);
    expect(YingjiGlass.blur, 0);
    yingjiAppearance.apply(glassBlur: 40);
    expect(YingjiGlass.blur, 40);
    // 超出滑杆量程的值被夹住，避免以后换量程时把界面糊成一团。
    yingjiAppearance.apply(glassBlur: 90);
    expect(YingjiGlass.blur, 40);
    yingjiAppearance.apply(glassBlur: -12);
    expect(YingjiGlass.blur, 0);
  });

  test('changing blur notifies the app shell', () {
    addTearDown(() => yingjiAppearance.apply(glassBlur: 30));
    var calls = 0;
    void listener() => calls++;
    yingjiAppearance.addListener(listener);
    addTearDown(() => yingjiAppearance.removeListener(listener));
    yingjiAppearance.apply(glassBlur: 8);
    expect(calls, 1);
    expect(yingjiAppearance.glassBlur, 8);
  });

  test('no hardcoded blur sigma left in the UI', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // sigmaX/sigmaY 必须是 YingjiGlass.blur、局部变量或随动画变化的表达式，
        // 不能再写 `sigmaX: 22` 这种常量。
        if (RegExp(r'sigma[XY]:\s*\d').hasMatch(line)) {
          offenders.add('${entity.path}:${i + 1}: ${line.trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '模糊半径必须统一取自 YingjiGlass.blur：\n${offenders.join('\n')}',
    );
  });
}
