import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../brand.dart';
import '../platform/window_host.dart';
import 'trakt_client.dart';

/// Trakt 凭据在 shared_preferences 里的键。
///
/// 设置页、日历页、继续观看同步读的是同一份配置，键名集中在这里 —— 否则哪天
/// 改键名只改一处，表现就是「设置里明明填了，日历却说没连接」。
abstract final class TraktPreferences {
  static const clientIdKey = 'yingji.trakt.client-id';
  static const clientSecretKey = 'yingji.trakt.client-secret';
  static const accessTokenKey = 'yingji.trakt.access-token';
  static const refreshTokenKey = 'yingji.trakt.refresh-token';
  static const expiresAtKey = 'yingji.trakt.expires-at';
}

/// Shared in-memory view of the persisted Trakt session. Settings, the source
/// hub and the calendar can remain mounted at the same time, so each page must
/// not keep an independent copy of the authorization state.
abstract final class TraktConnectionStatus {
  static final ValueNotifier<bool?> connected = ValueNotifier(null);
}

/// Public identifier for Mova's Trakt application. The matching secret lives
/// only in the metadata Worker environment.
const traktMovaClientId = 'yZBa7OLABFYoGpiQykaeBjUs7iJXFfPRdu61oBY6d00';

const traktDesktopCallbackPort = 43829;
const traktDesktopCallbackPath = '/trakt/callback';

Uri traktDesktopRedirectUri({int port = traktDesktopCallbackPort}) => Uri(
  scheme: 'http',
  host: '127.0.0.1',
  port: port,
  path: traktDesktopCallbackPath,
);

/// 一次读出 Trakt 的三项配置。
class TraktCredentials {
  const TraktCredentials({
    required this.clientId,
    required this.accessToken,
    this.refreshToken = '',
    this.expiresAt,
  });

  final String clientId;
  final String accessToken;
  final String refreshToken;
  final DateTime? expiresAt;

  static Future<TraktCredentials>? _refreshing;

  static Future<TraktCredentials> read() async {
    final prefs = await SharedPreferences.getInstance();
    // Remove legacy user-entered application credentials. The Mova app ID is
    // bundled as a public identifier; its secret never leaves the Worker.
    await prefs.remove(TraktPreferences.clientIdKey);
    await prefs.remove(TraktPreferences.clientSecretKey);
    final credentials = TraktCredentials(
      clientId: traktMovaClientId,
      accessToken:
          prefs.getString(TraktPreferences.accessTokenKey)?.trim() ?? '',
      refreshToken:
          prefs.getString(TraktPreferences.refreshTokenKey)?.trim() ?? '',
      expiresAt: prefs.getInt(TraktPreferences.expiresAtKey) == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              prefs.getInt(TraktPreferences.expiresAtKey)!,
              isUtc: true,
            ),
    );
    TraktConnectionStatus.connected.value ??= credentials.isConnected;
    return credentials;
  }

  /// 日历能否切到在线数据：两样都得有 —— 少了 client id 连请求头都发不出去。
  bool get isConnected => clientId.isNotEmpty && accessToken.isNotEmpty;

  /// OAuth 令牌交换由 Mova Worker 代办。
  bool get canAuthorize => clientId.isNotEmpty;

  Future<TraktCredentials> refreshIfNeeded() async {
    if (refreshToken.isEmpty ||
        expiresAt == null ||
        expiresAt!.isAfter(
          DateTime.now().toUtc().add(const Duration(minutes: 15)),
        )) {
      return this;
    }
    final current = _refreshing;
    if (current != null) return current;
    final pending = _refresh();
    _refreshing = pending;
    try {
      return await pending;
    } finally {
      if (identical(_refreshing, pending)) _refreshing = null;
    }
  }

  Future<TraktCredentials> _refresh() async {
    final client = TraktClient();
    try {
      final token = await client.refreshAccessToken(
        refreshToken: refreshToken,
        redirectUri: traktDesktopRedirectUri(),
      );
      await saveTokenPair(token);
      return TraktCredentials(
        clientId: clientId,
        accessToken: token.accessToken,
        refreshToken: token.refreshToken,
        expiresAt: token.expiresAt,
      );
    } finally {
      client.dispose();
    }
  }

  /// 只写访问令牌；应用凭据由 Mova 管理，用户偏好不保存。
  Future<void> saveAccessToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    final value = token.trim();
    if (value.isEmpty) {
      await prefs.remove(TraktPreferences.accessTokenKey);
      await prefs.remove(TraktPreferences.refreshTokenKey);
      await prefs.remove(TraktPreferences.expiresAtKey);
    } else {
      await prefs.setString(TraktPreferences.accessTokenKey, value);
    }
    TraktConnectionStatus.connected.value = value.isNotEmpty;
  }

  Future<void> saveTokenPair(TraktOAuthToken token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(TraktPreferences.accessTokenKey, token.accessToken);
    if (token.refreshToken.isNotEmpty) {
      await prefs.setString(
        TraktPreferences.refreshTokenKey,
        token.refreshToken,
      );
    } else {
      await prefs.remove(TraktPreferences.refreshTokenKey);
    }
    if (token.expiresAt != null) {
      await prefs.setInt(
        TraktPreferences.expiresAtKey,
        token.expiresAt!.millisecondsSinceEpoch,
      );
    } else {
      await prefs.remove(TraktPreferences.expiresAtKey);
    }
    TraktConnectionStatus.connected.value = token.accessToken.isNotEmpty;
  }
}

/// The same connect/disconnect control is used in Settings and the server hub.
class TraktConnectionPanel extends StatefulWidget {
  const TraktConnectionPanel({super.key, this.onChanged, this.compact = false});

  final VoidCallback? onChanged;
  final bool compact;

  @override
  State<TraktConnectionPanel> createState() => _TraktConnectionPanelState();
}

class _TraktConnectionPanelState extends State<TraktConnectionPanel> {
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    unawaited(TraktCredentials.read());
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final credentials = await TraktCredentials.read();
      if (!mounted) return;
      final token = await showDialog<TraktOAuthToken>(
        context: context,
        barrierDismissible: false,
        builder: (_) => TraktAuthDialog(clientId: credentials.clientId),
      );
      if (token == null || token.accessToken.isEmpty) return;
      await credentials.saveTokenPair(token);
      widget.onChanged?.call();
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('断开 Trakt？'),
        content: const Text('这会从本机移除 Trakt 授权，之后仍可随时重新连接。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('断开连接'),
          ),
        ],
      ),
    );
    if (confirmed != true || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final credentials = await TraktCredentials.read();
      await credentials.saveAccessToken('');
      widget.onChanged?.call();
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool?>(
    valueListenable: TraktConnectionStatus.connected,
    builder: (context, state, _) {
      final connected = state ?? false;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Icon(
                      connected ? YingjiIcons.check_mark : YingjiIcons.refresh,
                      size: 17,
                      color: connected
                          ? const Color(0xFF8BC6A3)
                          : YingjiColors.muted,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      connected ? 'Trakt 已连接' : 'Trakt 未连接',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              if (connected)
                TextButton(
                  onPressed: _busy ? null : _disconnect,
                  child: const Text('断开连接'),
                )
              else
                FilledButton.tonal(
                  onPressed: _busy ? null : _connect,
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('浏览器授权'),
                ),
            ],
          ),
          if (!widget.compact) ...[
            const SizedBox(height: 4),
            Text(
              connected ? '追剧日历与观看记录同步已启用。' : '通过 Trakt 网页授权后同步追剧日历与观看记录。',
              style: const TextStyle(color: YingjiColors.muted, fontSize: 12),
            ),
          ],
          if (_message != null) ...[
            const SizedBox(height: 6),
            Text(
              _message!,
              style: const TextStyle(color: Color(0xFFFFB4A8), fontSize: 12),
            ),
          ],
        ],
      );
    },
  );
}

/// Windows loopback OAuth callback. Bind only to 127.0.0.1; state and callback
/// path are verified before an authorization code is accepted.
class TraktDesktopAuthorization {
  TraktDesktopAuthorization({
    required this.client,
    this.port = traktDesktopCallbackPort,
  });

  final TraktClient client;
  final int port;
  final Completer<void> _cancelled = Completer<void>();
  Uri? authorizationUri;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  Future<TraktOAuthToken> authorize({
    required String clientId,
    required Future<bool> Function(String url) openUrl,
    void Function(Uri url)? onAuthorizationUri,
    void Function(bool opened)? onBrowserOpened,
  }) async {
    late final HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
    } on SocketException {
      throw Exception('无法启动 Trakt 本机登录回调，请重启 Mova 后重试');
    }
    final redirectUri = traktDesktopRedirectUri(port: server.port);
    final random = Random.secure();
    final state = base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final callback = Completer<Uri>();
    final subscription = server.listen((request) async {
      final remote = request.connectionInfo?.remoteAddress;
      if (remote == null ||
          !remote.isLoopback ||
          request.uri.path != traktDesktopCallbackPath) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      if (request.uri.queryParameters['state'] != state) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(
          'Invalid authorization state. Return to Mova and retry.',
        );
        await request.response.close();
        return;
      }
      final error = request.uri.queryParameters['error'];
      if (error != null) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.html;
        request.response.write(_callbackPage(success: false));
        await request.response.close();
        if (!callback.isCompleted) {
          callback.completeError(Exception('Trakt 授权已取消：$error'));
        }
        return;
      }
      if ((request.uri.queryParameters['code'] ?? '').isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(
          'Missing authorization code. Return to Mova and retry.',
        );
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.html;
      request.response.write(_callbackPage(success: true));
      await request.response.close();
      if (!callback.isCompleted) callback.complete(request.uri);
    });
    try {
      authorizationUri = Uri.https('auth.trakt.tv', '/oauth/authorize', {
        'response_type': 'code',
        'client_id': clientId.trim(),
        'redirect_uri': redirectUri.toString(),
        'state': state,
      });
      onAuthorizationUri?.call(authorizationUri!);
      final opened = await openUrl(authorizationUri.toString());
      onBrowserOpened?.call(opened);
      if (!opened) {
        throw Exception('无法打开 Trakt 登录页面');
      }
      final callbackUri =
          await Future.any([
            callback.future,
            _cancelled.future.then<Uri>((_) => throw Exception('授权已取消')),
          ]).timeout(
            const Duration(minutes: 5),
            onTimeout: () => throw Exception('Trakt 授权超时，请重试'),
          );
      return await client.exchangeAuthorizationCode(
        redirectUri: redirectUri,
        code: callbackUri.queryParameters['code']!,
      );
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  }

  String _callbackPage({required bool success}) =>
      '''<!doctype html><meta charset="utf-8"><title>Mova · Trakt</title><style>body{font:16px Segoe UI,sans-serif;background:#11151d;color:#f5f4f1;display:grid;place-items:center;height:90vh}main{padding:32px 40px;border:1px solid #62666e;border-radius:18px;background:#242832;text-align:center}p{color:#c5c8ce}</style><main><h2>${success ? 'Trakt 已授权' : 'Trakt 授权未完成'}</h2><p>${success ? '授权信息已返回 Mova，可以关闭此页面。' : '请返回 Mova 重试授权。'}</p></main>''';
}

/// 日历右上角 Trakt 按钮的展示状态。抽成纯函数，标签与状态位的对应关系
/// 可以在测试里直接钉住，不用起 widget。
class TraktConnectButtonState {
  const TraktConnectButtonState({
    required this.icon,
    required this.label,
    required this.compactLabel,
    required this.tooltip,
    required this.selected,
  });

  final IconData icon;

  /// 宽屏文案。日历页标题是 44px，窄屏那一行本来就紧，所以另给一份短文案。
  final String label;
  final String compactLabel;
  final String tooltip;
  final bool selected;
}

TraktConnectButtonState traktConnectButtonState({
  required bool connected,
  required bool busy,
}) {
  if (busy) {
    return const TraktConnectButtonState(
      icon: YingjiIcons.link,
      label: '等待授权…',
      compactLabel: '授权中',
      tooltip: '正在等待浏览器中的 Trakt 登录结果',
      selected: false,
    );
  }
  if (connected) {
    return const TraktConnectButtonState(
      icon: YingjiIcons.checkmark_seal,
      label: 'Trakt 已连接',
      compactLabel: '已连接',
      tooltip: 'Trakt 已连接；点击可重新授权或断开',
      selected: true,
    );
  }
  return const TraktConnectButtonState(
    icon: YingjiIcons.link,
    label: '连接 Trakt',
    compactLabel: 'Trakt',
    tooltip: '在浏览器中登录 Trakt，登录完成后自动连接',
    selected: false,
  );
}

/// 桌面走授权码 + loopback 回调；移动端保留 Trakt 设备码流程。
/// 成功时返回访问/刷新令牌，取消或超时返回 null。
class TraktAuthDialog extends StatefulWidget {
  const TraktAuthDialog({super.key, required this.clientId});

  final String clientId;

  @override
  State<TraktAuthDialog> createState() => _TraktAuthDialogState();
}

class _TraktAuthDialogState extends State<TraktAuthDialog> {
  final _client = TraktClient();
  TraktDeviceCode? _device;
  TraktDesktopAuthorization? _desktopAuthorization;
  Uri? _authorizationUri;
  String? _error;
  bool _openedInBrowser = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    // 关闭授权窗口时释放 loopback 监听并结束等待中的流程。
    _desktopAuthorization?.cancel();
    _client.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _device = null;
      _error = null;
      _authorizationUri = null;
      _openedInBrowser = false;
    });
    try {
      if (WindowHost.isDesktop) {
        final authorization = TraktDesktopAuthorization(client: _client);
        _desktopAuthorization = authorization;
        final token = await authorization.authorize(
          clientId: widget.clientId,
          openUrl: WindowHost.openUrl,
          onAuthorizationUri: (uri) {
            if (mounted) setState(() => _authorizationUri = uri);
          },
          onBrowserOpened: (opened) {
            if (mounted) setState(() => _openedInBrowser = opened);
          },
        );
        if (mounted) {
          await WindowHost.bringToFront();
          if (mounted) Navigator.pop(context, token);
        }
        return;
      }
      final device = await _client.requestDeviceCode();
      if (!mounted) return;
      setState(() => _device = device);
      final opened = await WindowHost.openUrl(device.verificationUrl);
      if (!mounted) return;
      setState(() => _openedInBrowser = opened);
      final token = await _client.pollDeviceCode(device: device);
      if (!mounted) return;
      Navigator.pop(context, TraktOAuthToken(accessToken: token));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error'.replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _openBrowser() async {
    if (_authorizationUri != null) {
      final opened = await WindowHost.openUrl(_authorizationUri.toString());
      if (mounted) setState(() => _openedInBrowser = opened);
      return;
    }
    final device = _device;
    if (device == null) return;
    final opened = await WindowHost.openUrl(device.verificationUrl);
    if (mounted) setState(() => _openedInBrowser = opened);
  }

  Future<void> _copyCode() async {
    final code = _device?.userCode ?? '';
    if (code.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('授权码已复制')));
    }
  }

  /// 等待与失败共用一行状态，失败时不会一直显示加载中。
  Widget _statusLine({required String waiting, String? error}) {
    if (error == null) {
      return Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(waiting)),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          YingjiIcons.exclamationmark_triangle,
          size: 18,
          color: Color(0xFFE2A44C),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(error, style: const TextStyle(color: Color(0xFFE2A44C))),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final device = _device;
    final desktop = WindowHost.isDesktop;
    return YingjiPinnedDialog(
      maxWidth: 470,
      header: Row(
        children: [
          const Expanded(
            child: Text(
              '连接 Trakt',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
          ),
          YingjiMotionIconButton(
            icon: YingjiIcons.xmark,
            tooltip: '关闭',
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            desktop
                ? '点击后将在浏览器中打开 Trakt。登录并允许 Mova 访问后，浏览器会自动'
                      '返回 Mova，连接完成后此窗口会自动关闭。'
                : '在打开的网页中登录 Trakt，并把下面这串代码填进去。登录完成后无需'
                      '回到这里，窗口会自动关闭。',
            style: TextStyle(color: Color(0xFFABB1BE), height: 1.6),
          ),
          const SizedBox(height: 16),
          if (desktop)
            _statusLine(
              waiting: _authorizationUri == null
                  ? '正在准备安全登录…'
                  : _openedInBrowser
                  ? '已打开浏览器，等待你登录并授权…'
                  : '正在打开浏览器登录页面…',
              error: _error,
            )
          else if (device == null)
            _statusLine(waiting: '正在向 Trakt 申请设备码…', error: _error)
          else ...[
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: const Color(0x1FFFFFFF),
                border: Border.all(color: YingjiGlass.line(strength: .9)),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 10, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        device.userCode,
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 5,
                        ),
                      ),
                    ),
                    YingjiMotionIconButton(
                      icon: YingjiIcons.doc_on_doc,
                      tooltip: '复制授权码',
                      size: 40,
                      onPressed: _copyCode,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            _statusLine(waiting: '等待浏览器中的登录结果…', error: _error),
            const SizedBox(height: 10),
            Text(
              _openedInBrowser
                  ? '浏览器已打开 ${device.verificationUrl}'
                  : '浏览器没能自动打开，请手动访问 ${device.verificationUrl}',
              style: const TextStyle(
                color: Color(0xFFABB1BE),
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
      actions: Row(
        children: [
          const Spacer(),
          if (_error != null) ...[
            TextButton(onPressed: _start, child: const Text('重新获取')),
            const SizedBox(width: 8),
          ],
          FilledButton.tonal(
            onPressed: desktop
                ? (_authorizationUri == null ? null : _openBrowser)
                : (device == null ? null : _openBrowser),
            child: Text(desktop ? '重新打开登录页面' : '打开登录页面'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }
}

/// 需要先在设置里填写应用凭据时的提示。
///
/// 直接把用户送到设置页 —— 光说「请先配置」等于让人自己找，而 Trakt 分区的
/// 位置对第一次用的人并不显然。`跳转` 用 [ValueNotifier] 请求，页面自己决定
/// 怎么滚过去。
class TraktSetupDialog extends StatelessWidget {
  const TraktSetupDialog({super.key, required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) => YingjiPinnedDialog(
    maxWidth: 470,
    header: Row(
      children: [
        const Expanded(
          child: Text(
            '连接 Trakt',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
        ),
        YingjiMotionIconButton(
          icon: YingjiIcons.xmark,
          tooltip: '关闭',
          onPressed: () => Navigator.pop(context),
        ),
      ],
    ),
    body: Text(
      'Trakt 需要 Client ID 和 Client Secret。在 trakt.tv 的「Settings → Your API Apps」'
      '创建或编辑应用，并把 Redirect URI 设置为\n${traktDesktopRedirectUri()}\n'
      '这个地址必须和 Mova 使用的地址完全一致。然后把 Client ID 与 Client Secret 填进'
      '设置页的网络分区，回到这里重新连接。',
      style: TextStyle(color: Color(0xFFABB1BE), height: 1.6),
    ),
    actions: Row(
      children: [
        const Spacer(),
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            onOpenSettings();
          },
          child: const Text('前往设置'),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}
