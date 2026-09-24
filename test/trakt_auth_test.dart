import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/brand.dart';
import 'package:yingji/src/tracking/trakt_auth.dart';
import 'package:yingji/src/tracking/trakt_client.dart';

void main() {
  // prefs 与图标都要经过 Flutter 的通道/绑定，先声明测试绑定再跑。
  TestWidgetsFlutterBinding.ensureInitialized();

  // 日历右上角那个按钮的状态只由「是否已连接 / 是否在授权」两个布尔决定。
  // 三态写死在这里，是为了防止以后有人顺手把「等待授权」也标成 selected ——
  // 那会让未连接的用户看到一个假装已连上的按钮。
  group('traktConnectButtonState', () {
    test('未连接时给出连接入口，并且不点亮', () {
      final state = traktConnectButtonState(connected: false, busy: false);
      expect(state.label, '连接 Trakt');
      expect(state.compactLabel, 'Trakt');
      expect(state.icon, YingjiIcons.link);
      expect(state.selected, isFalse);
      expect(state.tooltip, contains('浏览器'));
    });

    test('授权中排在最前，即使上一次已是连接态', () {
      final state = traktConnectButtonState(connected: true, busy: true);
      expect(state.label, '等待授权…');
      expect(state.selected, isFalse);
    });

    test('已连接时点亮并提示可断开', () {
      final state = traktConnectButtonState(connected: true, busy: false);
      expect(state.label, 'Trakt 已连接');
      expect(state.compactLabel, '已连接');
      expect(state.icon, YingjiIcons.checkmark_seal);
      expect(state.selected, isTrue);
      expect(state.tooltip, contains('断开'));
    });

    test('窄屏文案比宽屏短，标题那一行才挤得下', () {
      for (final connected in [true, false]) {
        final state = traktConnectButtonState(
          connected: connected,
          busy: false,
        );
        expect(
          state.compactLabel.length,
          lessThan(state.label.length),
          reason: '$connected',
        );
      }
    });
  });

  group('TraktCredentials', () {
    testWidgets('shared connection panel reacts to connection changes', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      TraktConnectionStatus.connected.value = false;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: TraktConnectionPanel(compact: true)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Trakt 未连接'), findsOneWidget);
      expect(find.text('浏览器授权'), findsOneWidget);

      TraktConnectionStatus.connected.value = true;
      await tester.pump();
      expect(find.text('Trakt 已连接'), findsOneWidget);
      expect(find.text('断开连接'), findsOneWidget);
    });

    test('缺 client id 或 token 都不算已连接', () {
      const onlyId = TraktCredentials(clientId: 'id', accessToken: '');
      const onlyToken = TraktCredentials(clientId: '', accessToken: 'token');
      expect(onlyId.isConnected, isFalse);
      expect(onlyToken.isConnected, isFalse);
    });

    test('Mova 应用凭据固定配置，无需用户填写', () {
      const configured = TraktCredentials(clientId: 'id', accessToken: '');
      const complete = TraktCredentials(clientId: 'id', accessToken: '');
      expect(configured.canAuthorize, isTrue);
      expect(complete.canAuthorize, isTrue);
      expect(complete.isConnected, isFalse);
    });

    test('read 使用 Mova 应用 ID 并删除旧版用户凭据', () async {
      SharedPreferences.setMockInitialValues({
        TraktPreferences.clientIdKey: '  id  ',
        TraktPreferences.clientSecretKey: '   ',
        TraktPreferences.accessTokenKey: '  token ',
      });
      final credentials = await TraktCredentials.read();
      expect(credentials.clientId, traktMovaClientId);
      expect(credentials.accessToken, 'token');
      expect(credentials.canAuthorize, isTrue);
      expect(credentials.isConnected, isTrue);
      expect(TraktConnectionStatus.connected.value, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(TraktPreferences.clientIdKey), isNull);
      expect(prefs.getString(TraktPreferences.clientSecretKey), isNull);
    });

    test('保存或断开令牌不会保留旧版用户应用凭据', () async {
      SharedPreferences.setMockInitialValues({
        TraktPreferences.clientIdKey: 'id',
        TraktPreferences.clientSecretKey: 'secret',
      });
      final prefs = await SharedPreferences.getInstance();
      final credentials = await TraktCredentials.read();

      await credentials.saveAccessToken('  fresh  ');
      expect(prefs.getString(TraktPreferences.accessTokenKey), 'fresh');

      // 断开连接走的就是这条路：令牌清掉，Client ID / Secret 留着下次一键重连。
      await credentials.saveAccessToken('');
      expect(TraktConnectionStatus.connected.value, isFalse);
      expect(prefs.getString(TraktPreferences.accessTokenKey), isNull);
      expect(prefs.getString(TraktPreferences.clientIdKey), isNull);
      expect(prefs.getString(TraktPreferences.clientSecretKey), isNull);
    });

    test('保存 OAuth 令牌对与过期时间，断开连接时一并清除', () async {
      SharedPreferences.setMockInitialValues({
        TraktPreferences.clientIdKey: 'id',
        TraktPreferences.clientSecretKey: 'secret',
      });
      final prefs = await SharedPreferences.getInstance();
      final expiresAt = DateTime.utc(2026, 10, 1);
      const credentials = TraktCredentials(clientId: 'id', accessToken: '');
      await credentials.saveTokenPair(
        TraktOAuthToken(
          accessToken: 'access',
          refreshToken: 'refresh',
          expiresAt: expiresAt,
        ),
      );
      final saved = await TraktCredentials.read();
      expect(saved.accessToken, 'access');
      expect(saved.refreshToken, 'refresh');
      expect(saved.expiresAt, expiresAt);

      await saved.saveAccessToken('');
      expect(prefs.getString(TraktPreferences.accessTokenKey), isNull);
      expect(prefs.getString(TraktPreferences.refreshTokenKey), isNull);
      expect(prefs.getInt(TraktPreferences.expiresAtKey), isNull);
    });
  });
}
