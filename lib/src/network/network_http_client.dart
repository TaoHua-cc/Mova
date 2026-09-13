import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:win32/win32.dart';

http.Client createNetworkHttpClient() {
  final client = HttpClient()..findProxy = _findProxy;
  return IOClient(client);
}

/// 暴露同一个代理判定给裸 [HttpClient] 使用。
///
/// 更新检查需要「不跟随重定向」的原始客户端（靠 302 的 Location 读版本号），
/// 而 `IOClient` 不给这个开关，只能自己 new 一个 `HttpClient`——但代理配置
/// 必须和 API 请求完全一致，否则同一个网络下一边通一边不通。
String findNetworkProxy(Uri uri) => _findProxy(uri);

/// Makes Flutter's [NetworkImage] use the same Windows proxy path as API calls.
void configureNetworkHttpOverrides() {
  HttpOverrides.global = _YingjiHttpOverrides();
}

class _YingjiHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = _findProxy;
}

String _findProxy(Uri uri) {
  final environment = HttpClient.findProxyFromEnvironment(uri);
  if (environment != 'DIRECT') return '$environment; DIRECT';
  final windows = _windowsProxy(uri);
  return windows == null ? 'DIRECT' : 'PROXY $windows; DIRECT';
}

String? _windowsProxy(Uri uri) {
  if (!Platform.isWindows) return null;
  return using((arena) {
    final keyPointer = arena<Pointer>();
    final subKey = arena.pcwstr(
      r'Software\Microsoft\Windows\CurrentVersion\Internet Settings',
    );
    if (RegOpenKeyEx(HKEY_CURRENT_USER, subKey, 0, KEY_READ, keyPointer) !=
        ERROR_SUCCESS) {
      return null;
    }
    final key = HKEY(keyPointer.value);
    try {
      final enabled = _readDword(key, 'ProxyEnable', arena) == 1;
      if (!enabled) return null;
      final configured = _readString(key, 'ProxyServer', arena)?.trim();
      if (configured == null || configured.isEmpty) return null;
      if (!configured.contains('=')) return _normalizeProxy(configured);
      final entries = <String, String>{};
      for (final entry in configured.split(';')) {
        final separator = entry.indexOf('=');
        if (separator <= 0) continue;
        entries[entry.substring(0, separator).trim().toLowerCase()] = entry
            .substring(separator + 1)
            .trim();
      }
      final selected = entries[uri.scheme] ?? entries['http'];
      return selected == null ? null : _normalizeProxy(selected);
    } finally {
      key.close();
    }
  });
}

int? _readDword(HKEY key, String name, Arena arena) {
  final type = arena<DWORD>();
  final size = arena<DWORD>()..value = sizeOf<DWORD>();
  final data = arena<DWORD>();
  final result = RegQueryValueEx(
    key,
    arena.pcwstr(name),
    type,
    data.cast<BYTE>(),
    size,
  );
  return result == ERROR_SUCCESS && type.value == REG_DWORD ? data.value : null;
}

String? _readString(HKEY key, String name, Arena arena) {
  final type = arena<DWORD>();
  final size = arena<DWORD>()..value = 4096;
  final data = arena<BYTE>(4096);
  final result = RegQueryValueEx(key, arena.pcwstr(name), type, data, size);
  if (result != ERROR_SUCCESS ||
      (type.value != REG_SZ && type.value != REG_EXPAND_SZ)) {
    return null;
  }
  return data.cast<Utf16>().toDartString();
}

String _normalizeProxy(String value) =>
    value.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '').trim();
