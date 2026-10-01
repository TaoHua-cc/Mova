import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android distinguishes hidden UI from actual memory pressure', () {
    final host = File(
      'android/app/src/main/kotlin/com/taohua/mova/MainActivity.kt',
    ).readAsStringSync();
    final trim = host.substring(
      host.indexOf('override fun onTrimMemory'),
      host.indexOf('override fun configureFlutterEngine'),
    );
    expect(
      trim,
      contains('level == ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN'),
    );
    expect(trim, contains('renderer?.onTrimMemory(level)'));
    expect(trim, contains('platformViewsController?.onTrimMemory(level)'));
    expect(
      trim.indexOf('return'),
      lessThan(trim.indexOf('super.onTrimMemory(level)')),
    );
    expect(trim, isNot(contains('level >=')));
    expect(host, isNot(contains('override fun onLowMemory')));
  });
}
