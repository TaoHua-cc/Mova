import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as image_lib;
import 'package:path_provider/path_provider.dart';

import '../brand.dart';
import '../images/icon_background.dart';
import 'media_source.dart';

final Map<String, Future<Uint8List?>> _backgroundFreeIconCache = {};

class ServerMark extends StatelessWidget {
  const ServerMark({
    super.key,
    required this.source,
    this.token,
    this.size = 42,
  });

  final MediaSource source;
  final String? token;
  final double size;

  @override
  Widget build(BuildContext context) {
    final webdav = source.kind == SourceKind.webdav;
    final colors = webdav
        ? const [Color(0xFF4B88C7), Color(0xFF23456B)]
        : source.kind == SourceKind.jellyfin
        ? const [Color(0xFF9B5DE5), Color(0xFF3157C8)]
        : const [Color(0xFF58D568), Color(0xFF18853A)];
    final icon = Uri.tryParse(source.iconUrl ?? '');
    final hasImage = icon != null && icon.hasScheme;
    final fallback = _defaultMark(webdav, colors);
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: hasImage
              ? null
              : LinearGradient(
                  colors: colors,
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
          borderRadius: BorderRadius.circular(size * .29),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(size * .29),
          child: !hasImage
              ? fallback
              : source.customIcon
              ? BackgroundFreeNetworkIcon(
                  url: icon.toString(),
                  fallback: fallback,
                )
              : Image.network(
                  icon.toString(),
                  headers:
                      icon.host == source.endpoint.host &&
                          token?.isNotEmpty == true
                      ? {'X-Emby-Token': token!}
                      : null,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => fallback,
                ),
        ),
      ),
    );
  }

  Widget _defaultMark(bool webdav, List<Color> colors) => webdav
      ? Icon(YingjiIcons.cloud_fill, color: Colors.white, size: size * .46)
      : Center(
          child: Transform.rotate(
            angle: math.pi / 4,
            child: Container(
              width: size * .44,
              height: size * .44,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .94),
                borderRadius: BorderRadius.circular(size * .08),
              ),
              child: Transform.rotate(
                angle: -math.pi / 4,
                child: Icon(
                  YingjiIcons.play_fill,
                  color: colors.last,
                  size: size * .24,
                ),
              ),
            ),
          ),
        );
}

class BackgroundFreeNetworkIcon extends StatelessWidget {
  const BackgroundFreeNetworkIcon({
    super.key,
    required this.url,
    required this.fallback,
    this.alignment = Alignment.center,
  });
  final String url;
  final Widget fallback;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _backgroundFreeIconCache.putIfAbsent(url, () => _load(url)),
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      if (bytes == null) {
        return snapshot.connectionState == ConnectionState.done
            ? fallback
            : const SizedBox.shrink();
      }
      return Image.memory(
        bytes,
        fit: BoxFit.contain,
        alignment: alignment,
        gaplessPlayback: true,
      );
    },
  );
}

Future<Uint8List?> _load(String value) async {
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme) return null;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final response = await (await client.getUrl(uri)).close();
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final output = BytesBuilder(copy: false);
    await for (final chunk in response) {
      output.add(chunk);
    }
    final decoded = image_lib.decodeImage(output.takeBytes());
    if (decoded == null) return null;
    final rgba = decoded.numChannels == 4
        ? decoded
        : decoded.convert(numChannels: 4);
    removeFlatIconBackground(rgba);
    return Uint8List.fromList(image_lib.encodePng(rgba));
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

const String _markFolder = 'server_marks';
final Map<String, Future<String?>> _markFileCache = {};

/// 把 [ServerMark] 要显示的那张服务器图标落到本地磁盘，返回文件路径。
///
/// Windows 原生播放器的「资源」面板也要显示同一个图标，但它不该持有地址、令牌
/// 与请求头 —— 所以由应用按 [ServerMark] 的同一套规则先把图取下来（自定义图标
/// 去平底色、同源时带 `X-Emby-Token`），只把**文件路径**交给原生。
///
/// 任何一步失败都返回 `null`：原生会退回按来源类型画的兜底标记，图标拿不到
/// 不该影响播放。同一台服务器每次都落到同名文件，换图标直接覆盖。
Future<String?> cacheServerMarkFile(MediaSource source, String? token) {
  final iconUrl = source.iconUrl;
  if (iconUrl == null || iconUrl.isEmpty) return Future<String?>.value();
  final uri = Uri.tryParse(iconUrl);
  if (uri == null || !uri.hasScheme) return Future<String?>.value();
  return _markFileCache.putIfAbsent(
    '${source.customIcon ? 'c' : 's'}|$iconUrl',
    () => _cacheMark(
      uri,
      customIcon: source.customIcon,
      token: token,
      sameHost: uri.host == source.endpoint.host,
    ),
  );
}

Future<String?> _cacheMark(
  Uri uri, {
  required bool customIcon,
  required bool sameHost,
  String? token,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.getUrl(uri);
    if (!customIcon && sameHost && token != null && token.isNotEmpty) {
      request.headers.set('X-Emby-Token', token);
    }
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final output = BytesBuilder(copy: false);
    await for (final chunk in response) {
      output.add(chunk);
    }
    var bytes = output.takeBytes();
    if (customIcon) {
      final decoded = image_lib.decodeImage(bytes);
      if (decoded == null) return null;
      final rgba = decoded.numChannels == 4
          ? decoded
          : decoded.convert(numChannels: 4);
      removeFlatIconBackground(rgba);
      bytes = Uint8List.fromList(image_lib.encodePng(rgba));
    }
    final base = await getApplicationSupportDirectory();
    final folder = Directory(
      '${base.path}${Platform.pathSeparator}$_markFolder',
    );
    if (!await folder.exists()) await folder.create(recursive: true);
    final digest = base64Url
        .encode(utf8.encode(uri.toString()))
        .replaceAll('=', '');
    final name = digest.length > 48 ? digest.substring(0, 48) : digest;
    final file = File('${folder.path}${Platform.pathSeparator}$name.png');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
