import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart';

/// Windows DPAPI-backed storage for server tokens and other credentials.
/// Non-Windows platforms use the same preferences namespace as a development
/// fallback, while the shipped target is Windows.
class SecureVault {
  SecureVault._(this._prefs);
  final SharedPreferences _prefs;

  static Future<SecureVault> create() async =>
      SecureVault._(await SharedPreferences.getInstance());

  Future<void> saveSecret(String key, String value) async {
    final bytes = Uint8List.fromList(utf8.encode(value));
    final encoded = _isWindows ? _protect(bytes) : base64UrlEncode(bytes);
    await _prefs.setString('yingji.secret.$key', encoded);
  }

  String? readSecret(String key) {
    final encoded = _prefs.getString('yingji.secret.$key');
    if (encoded == null || encoded.isEmpty) return null;
    try {
      final bytes = _isWindows
          ? _unprotect(encoded)
          : base64Url.decode(encoded);
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteSecret(String key) => _prefs.remove('yingji.secret.$key');

  bool get _isWindows =>
      const bool.fromEnvironment('dart.library.io') &&
      (Platform.operatingSystem == 'windows');

  String _protect(Uint8List input) {
    final inputPtr = calloc<CRYPT_INTEGER_BLOB>();
    final outputPtr = calloc<CRYPT_INTEGER_BLOB>();
    final data = calloc<Uint8>(input.length);
    try {
      data.asTypedList(input.length).setAll(0, input);
      inputPtr.ref
        ..cbData = input.length
        ..pbData = data;
      final result = CryptProtectData(
        inputPtr,
        null,
        null,
        nullptr,
        0,
        outputPtr,
      );
      if (!result.value) throw WindowsException(result.error.toHRESULT());
      final output = outputPtr.ref.pbData.asTypedList(outputPtr.ref.cbData);
      return base64UrlEncode(output);
    } finally {
      if (outputPtr.ref.pbData != nullptr) HLOCAL(outputPtr.ref.pbData).close();
      calloc.free(data);
      calloc.free(inputPtr);
      calloc.free(outputPtr);
    }
  }

  Uint8List _unprotect(String encoded) {
    final input = base64Url.decode(encoded);
    final inputPtr = calloc<CRYPT_INTEGER_BLOB>();
    final outputPtr = calloc<CRYPT_INTEGER_BLOB>();
    final data = calloc<Uint8>(input.length);
    try {
      data.asTypedList(input.length).setAll(0, input);
      inputPtr.ref
        ..cbData = input.length
        ..pbData = data;
      final result = CryptUnprotectData(
        inputPtr,
        nullptr,
        nullptr,
        nullptr,
        0,
        outputPtr,
      );
      if (!result.value) throw WindowsException(result.error.toHRESULT());
      return Uint8List.fromList(
        outputPtr.ref.pbData.asTypedList(outputPtr.ref.cbData),
      );
    } finally {
      if (outputPtr.ref.pbData != nullptr) HLOCAL(outputPtr.ref.pbData).close();
      calloc.free(data);
      calloc.free(inputPtr);
      calloc.free(outputPtr);
    }
  }
}
