import 'dart:convert';

import 'package:http/http.dart' as http;

import 'emby_client.dart';
import 'media_source.dart';

class WebDavClient {
  WebDavClient({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  Future<List<MediaItem>> list({
    required MediaSource source,
    required String username,
    required String password,
  }) async {
    final auth = base64Encode(utf8.encode('$username:$password'));
    final request = http.Request('PROPFIND', source.endpoint)
      ..headers.addAll({
        'Authorization': 'Basic $auth',
        'Depth': '1',
        'Content-Type': 'application/xml',
      });
    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(seconds: 15)),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('WebDAV 读取失败（HTTP ${response.statusCode}）');
    }
    final hrefs =
        RegExp(
              r'<(?:[\w-]+:)?href[^>]*>(.*?)</(?:[\w-]+:)?href>',
              caseSensitive: false,
            )
            .allMatches(response.body)
            .map((m) => _decode(m.group(1)!))
            .where((value) => value != source.endpoint.toString())
            .where(
              (value) => RegExp(
                r'\.(mp4|mkv|webm|mov|avi|m4v)$',
                caseSensitive: false,
              ).hasMatch(value),
            )
            .take(100);
    return hrefs
        .map((href) {
          final parsed = Uri.tryParse(href);
          final uri = parsed != null && parsed.hasScheme
              ? parsed
              : source.endpoint.resolve(href);
          return MediaItem(
            id: uri.toString(),
            title: uri.pathSegments.isEmpty ? '视频' : uri.pathSegments.last,
            type: '视频',
            source: source,
            playbackUrl: uri,
            headers: {'Authorization': 'Basic $auth'},
          );
        })
        .toList(growable: false);
  }

  String _decode(String value) =>
      Uri.decodeFull(value.replaceAll('&amp;', '&'));
  void dispose() => _client.close();
}
