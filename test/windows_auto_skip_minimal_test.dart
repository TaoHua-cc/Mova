import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('windows/native_player/main.cpp').readAsStringSync();
  test('minimal skip uses fixed single row and integer updates', () {
    expect(source, contains('(layout == HintLayout::AutoSkip ? 64 : 24)'));
    expect(source, contains('*height = 34 + kHintMargin * 2'));
    expect(
      source,
      contains('FillStaticPlayerMenuSurface(graphics, path, body)'),
    );
    expect(source, contains('auto font = MakeInterfaceFont(13.0f'));
    expect(source, isNot(contains('Gdiplus::Font font(L"Segoe UI", 13.0f')));
    expect(source, contains('g_skip_hint_shown != seconds'));
    expect(source, contains('L" 秒后跳过" + label'));
    expect(source, isNot(contains('L"打开菜单可取消"')));
    final paint = source.substring(
      source.indexOf('// Reuse the menu'),
      source.indexOf('return;', source.indexOf('// Reuse the menu')),
    );
    expect(paint, contains('StringFormatFlagsNoWrap'));
    expect(source, contains('*width = title_width + 8 +'));
  });
  test('cancel is interactive without taking focus', () {
    expect(source, contains('style &= ~WS_EX_TRANSPARENT'));
    expect(source, contains('return MA_NOACTIVATE'));
    expect(source, contains('? HTCLIENT : HTTRANSPARENT'));
    expect(source, contains('ShowHint(L"本次不跳过"'));
    expect(source, contains('DockTopScreen() - Scaled(24)'));
  });
}
