import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'runtime-added HTTP media hosts are allowed without disabling TLS trust',
    () {
      final config = File(
        'android/app/src/main/res/xml/network_security_config.xml',
      ).readAsStringSync();
      expect(
        config,
        contains('<base-config cleartextTrafficPermitted="true">'),
      );
      expect(config, contains('<certificates src="system"/>'));
      expect(config, isNot(contains('<domain-config')));
      final manifest = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(manifest, contains('@xml/network_security_config'));
      final exo = File(
        'android/app/src/main/kotlin/com/taohua/mova/ExoPlayerPlatformView.kt',
      ).readAsStringSync();
      expect(exo, isNot(contains('setHostnameVerifier')));
      expect(exo, isNot(contains('setSSLSocketFactory')));
    },
  );
}
