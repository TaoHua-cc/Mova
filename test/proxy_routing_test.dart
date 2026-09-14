import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/network/proxy_routing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await ProxyRouting.load();
  });

  test('servers use direct routing until explicitly selected', () {
    expect(ProxyRouting.serverUsesProxy('living-room'), isFalse);
  });

  test('selecting and selecting again toggles system proxy routing', () async {
    await ProxyRouting.setServerProxy('living-room', true);
    expect(ProxyRouting.serverUsesProxy('living-room'), isTrue);

    await ProxyRouting.setServerProxy('living-room', false);
    expect(ProxyRouting.serverUsesProxy('living-room'), isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('yingji.proxy.servers'), isEmpty);
  });

  test('saved proxy selections remain compatible', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'yingji.proxy.servers': 'living-room,bedroom',
    });

    await ProxyRouting.load();

    expect(ProxyRouting.proxyServerIds, {'living-room', 'bedroom'});
  });
}
