import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../network/network_http_client.dart';

/// A small danmaku response adapter with native TaoHua danmu_api support.
///
/// The URL is user configurable and may contain `{tmdbId}`, `{title}`,
/// `{season}`, `{episode}` and `{url}` placeholders. Different danmaku
/// providers use different response envelopes, so the adapter accepts the
/// common `data`, `comments` and `result` list shapes.
enum DanmakuMode { scroll, top, bottom }

class DanmakuComment {
  const DanmakuComment({
    required this.time,
    required this.content,
    this.color,
    this.mode = DanmakuMode.scroll,
  });

  final Duration time;
  final String content;
  final int? color;
  final DanmakuMode mode;
}

class DanmakuClient {
  DanmakuClient({http.Client? client})
    : _client = client ?? createNetworkHttpClient();
  final http.Client _client;

  Future<List<DanmakuComment>> fetch({
    required String template,
    String? tmdbId,
    String? title,
    int? season,
    int? episode,
    String? mediaUrl,
    String? token,
  }) async {
    final isTemplate =
        template.contains(RegExp(r'\{[^}]+\}')) ||
        template.contains('/api/v2/');
    final endpoint = _expand(
      template,
      tmdbId: tmdbId,
      title: title,
      season: season,
      episode: episode,
      mediaUrl: mediaUrl,
    );
    final uri = Uri.tryParse(endpoint);
    if (uri == null || !['http', 'https'].contains(uri.scheme)) {
      throw Exception('弹幕 API 地址无效，请填写 http:// 或 https:// 地址');
    }
    final headers = <String, String>{'Accept': 'application/json'};
    final auth = token?.trim() ?? '';
    if (auth.isNotEmpty) headers['Authorization'] = 'Bearer $auth';
    try {
      // A TaoHua deployment can expose either its root API (which needs a
      // match request) or a copied episode comment endpoint such as
      // `/87654321`. Treat the latter as a direct JSON source so configuring
      // the URL from a browser/API response does not silently run a second
      // `/api/v2/match` lookup against the wrong path.
      final directEpisodeEndpoint =
          !isTemplate && RegExp(r'/\d+/?(?:\?.*)?$').hasMatch(uri.path);
      dynamic decoded;
      if (isTemplate) {
        decoded = await _getJson(uri, headers);
      } else if (directEpisodeEndpoint) {
        // Prefer the TaoHua match flow for numeric deployment prefixes (the
        // common `/<deployment-id>` form), then fall back to the URL itself
        // when the user pasted a direct comment JSON endpoint.
        try {
          decoded = await _fetchTaoHua(
            uri,
            headers,
            title: title,
            season: season,
            episode: episode,
          );
        } catch (error) {
          final message = error.toString();
          final directResponse =
              message.contains('HTTP 404') || message.contains('HTTP 405');
          if (!directResponse) rethrow;
          decoded = await _getJson(uri, headers);
        }
      } else {
        decoded = await _fetchTaoHua(
          uri,
          headers,
          title: title,
          season: season,
          episode: episode,
        );
      }
      final list = _findList(decoded);
      return list
          .map(_parseComment)
          .whereType<DanmakuComment>()
          .toList(growable: false);
    } on TimeoutException {
      throw Exception('弹幕 API 请求超时，请检查地址或网络');
    } on HandshakeException {
      throw Exception('弹幕服务 TLS 安全连接失败，请检查服务证书或 Windows 代理');
    } on SocketException {
      throw Exception('无法连接弹幕服务，请检查网络、域名或 Windows 代理');
    } on http.ClientException catch (error) {
      final message = error.message.toLowerCase();
      if (message.contains('handshake') || message.contains('tls')) {
        throw Exception('弹幕服务 TLS 安全连接失败，请检查服务证书或 Windows 代理');
      }
      throw Exception('弹幕服务连接失败，请检查地址、网络或 Windows 代理');
    } on FormatException {
      throw Exception('弹幕 API 返回的不是有效 JSON');
    } finally {
      // The client can be reused for the lifetime of a player; this method
      // intentionally does not close it.
    }
  }

  void dispose() => _client.close();

  Future<dynamic> _fetchTaoHua(
    Uri base,
    Map<String, String> headers, {
    String? title,
    int? season,
    int? episode,
  }) async {
    final cleanTitle = title?.trim() ?? '';
    if (cleanTitle.isEmpty) throw Exception('弹幕匹配需要媒体标题');
    final fileName = _matchFileName(cleanTitle, season, episode);
    final baseUrl = base.toString().replaceFirst(RegExp(r'/+$'), '');
    final match = await _postJson(
      Uri.parse('$baseUrl/api/v2/match'),
      {...headers, 'Content-Type': 'application/json'},
      {'fileName': fileName},
    );
    if (match is! Map) throw Exception('弹幕匹配接口返回格式无效');
    if (match['success'] == false) {
      final message = '${match['errorMessage'] ?? ''}'.trim();
      throw Exception(message.isEmpty ? '弹幕匹配失败' : '弹幕匹配失败：$message');
    }
    final matches = match['matches'];
    if (matches is! List || matches.isEmpty || matches.first is! Map) {
      throw Exception('未找到与“$fileName”匹配的弹幕');
    }
    final episodeId = '${(matches.first as Map)['episodeId'] ?? ''}'.trim();
    if (episodeId.isEmpty) throw Exception('弹幕匹配结果缺少 episodeId');
    final uri = Uri.parse(
      '$baseUrl/api/v2/comment/${Uri.encodeComponent(episodeId)}?format=json',
    );
    return _getJson(uri, headers);
  }

  Future<dynamic> _getJson(Uri uri, Map<String, String> headers) async {
    final response = await _client
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 15));
    return _decodeJson(response);
  }

  Future<dynamic> _postJson(
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic> body,
  ) async {
    final response = await _client
        .post(uri, headers: headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
    return _decodeJson(response);
  }

  static dynamic _decodeJson(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('弹幕 API 返回 HTTP ${response.statusCode}');
    }
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (contentType.contains('text/html')) {
      throw Exception('弹幕地址返回的是网页，不是 JSON API，请检查部署地址');
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  static String _matchFileName(String title, int? season, int? episode) {
    if (season == null && episode == null) return title;
    final seasonText = (season ?? 1).toString().padLeft(2, '0');
    final episodeText = (episode ?? 1).toString().padLeft(2, '0');
    return '$title S${seasonText}E$episodeText';
  }

  static String _expand(
    String template, {
    String? tmdbId,
    String? title,
    int? season,
    int? episode,
    String? mediaUrl,
  }) {
    final values = <String, String>{
      'tmdbId': tmdbId ?? '',
      'title': title ?? '',
      'season': season?.toString() ?? '',
      'episode': episode?.toString() ?? '',
      'url': mediaUrl ?? '',
    };
    var result = template.trim();
    values.forEach((key, value) {
      result = result.replaceAll('{$key}', Uri.encodeComponent(value));
    });
    return result;
  }

  static List<dynamic> _findList(dynamic value) {
    if (value is List) return value;
    if (value is Map) {
      for (final key in const [
        'data',
        'comments',
        'result',
        'items',
        'danmaku',
      ]) {
        final candidate = value[key];
        if (candidate is List) return candidate;
        if (candidate is Map) {
          final nested = _findList(candidate);
          if (nested.isNotEmpty) return nested;
        }
      }
    }
    return const [];
  }

  static DanmakuComment? _parseComment(dynamic value) {
    if (value is String) {
      return DanmakuComment(time: Duration.zero, content: value);
    }
    if (value is! Map) return null;
    final dandan = value['p'] is String
        ? (value['p'] as String).split(',')
        : const <String>[];
    final content =
        (value['content'] ??
                value['text'] ??
                value['comment'] ??
                value['m'] ??
                '')
            .toString()
            .trim();
    if (content.isEmpty) return null;
    final rawTime =
        value['time'] ??
        value['timestamp'] ??
        value['playTime'] ??
        (dandan.isNotEmpty ? dandan.first : 0);
    final number = rawTime is num
        ? rawTime.toDouble()
        : double.tryParse('$rawTime') ?? 0;
    // Millisecond timestamps are common in JSON APIs; seconds are more
    // convenient for mpv and are used when the value is already small.
    final seconds = number > 10000 ? number / 1000 : number;
    return DanmakuComment(
      time: Duration(milliseconds: (seconds * 1000).round()),
      content: content,
      color: _parseColor(
        value['color'] ?? (dandan.length > 2 ? int.tryParse(dandan[2]) : null),
      ),
      mode: _parseMode(
        value['mode'] ??
            value['position'] ??
            (dandan.length > 1 ? dandan[1] : null),
      ),
    );
  }

  static DanmakuMode _parseMode(dynamic value) {
    final mode = int.tryParse('$value') ?? 1;
    if (mode == 5 || mode == 4) return DanmakuMode.top;
    if (mode == 6) return DanmakuMode.bottom;
    return DanmakuMode.scroll;
  }

  static int? _parseColor(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final normalized = value.replaceFirst('#', '');
      return int.tryParse(normalized, radix: 16);
    }
    return null;
  }
}
