import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../network/network_http_client.dart';

const int _maxSubtitleBytes = 20 * 1024 * 1024;
const List<String> _subtitleExtensions = ['.srt', '.ass', '.ssa', '.vtt'];
const String _subHdHost = 'www.subhd.me';

class SubtitleSearchQuery {
  const SubtitleSearchQuery({
    required this.title,
    this.season,
    this.episode,
    this.episodeTitle,
    this.language = 'zh',
  });

  final String title;
  final int? season;
  final int? episode;
  final String? episodeTitle;
  final String language;

  String get episodeLabel {
    final seasonNumber = season;
    final episodeNumber = episode;
    final location = seasonNumber == null || episodeNumber == null
        ? ''
        : ' · 第 $seasonNumber 季第 $episodeNumber 集';
    final name = episodeTitle?.trim();
    final episodeName = name == null || name.isEmpty ? '' : ' · $name';
    return '$title$location$episodeName';
  }

  String get searchText {
    final seasonNumber = season;
    final episodeNumber = episode;
    final suffix = seasonNumber == null || episodeNumber == null
        ? ''
        : ' S${seasonNumber.toString().padLeft(2, '0')}E${episodeNumber.toString().padLeft(2, '0')}';
    final name = episodeTitle?.trim();
    final episodeName = name == null || name.isEmpty ? '' : ' $name';
    return '$title$suffix$episodeName'.trim();
  }
}

class SubtitleSearchResult {
  const SubtitleSearchResult({
    required this.provider,
    required this.providerId,
    required this.title,
    required this.fileName,
    required this.language,
    required this.downloadUri,
    required this.referrer,
  });

  final String provider;
  final String providerId;
  final String title;
  final String fileName;
  final String language;
  final Uri downloadUri;
  final Uri referrer;
}

class SubtitleSearchResponse {
  const SubtitleSearchResponse({required this.results, required this.status});

  final List<SubtitleSearchResult> results;

  /// Per-source status. A source can be unavailable while another still returns results.
  final Map<String, String> status;
}

class DownloadedSubtitle {
  const DownloadedSubtitle({
    required this.path,
    required this.fileName,
    required this.language,
  });

  final String path;
  final String fileName;
  final String language;
}

class SubtitleSearchService {
  SubtitleSearchService({http.Client? client, this.temporaryDirectory})
    : _client = client ?? createNetworkHttpClient(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Directory? temporaryDirectory;

  void dispose() {
    if (_ownsClient) _client.close();
  }

  Future<SubtitleSearchResponse> search(
    SubtitleSearchQuery query, {
    void Function(
      String provider,
      List<SubtitleSearchResult> results,
      String status,
    )?
    onSourceResults,
  }) async {
    final title = query.title.trim();
    if (title.isEmpty) throw ArgumentError.value(title, 'title', '片名不能为空');

    final tasks = await Future.wait(
      <Future<(String, List<SubtitleSearchResult>, String)>>[
        _searchSubHd(query).then((result) {
          onSourceResults?.call(result.$1, result.$2, result.$3);
          return result;
        }),
        _searchGestdown(query).then((result) {
          onSourceResults?.call(result.$1, result.$2, result.$3);
          return result;
        }),
      ],
    );
    final results = <SubtitleSearchResult>[];
    final seen = <String>{};
    final status = <String, String>{};
    for (final (provider, found, message) in tasks) {
      status[provider] = message;
      for (final result in found) {
        final key = '${result.provider}:${result.providerId}';
        if (seen.add(key)) results.add(result);
      }
    }
    return SubtitleSearchResponse(results: results, status: status);
  }

  Future<(String, List<SubtitleSearchResult>, String)> _searchSubHd(
    SubtitleSearchQuery query,
  ) async {
    const provider = 'SubHD';
    final searchUri = Uri.https(_subHdHost, '/search/${query.searchText}');
    try {
      final response = await _send(
        http.Request('GET', searchUri)..headers['User-Agent'] = _userAgent,
      );
      _checkStatus(provider, response, searchUri);
      final body = _decodeText(response.bodyBytes);
      _checkChallenge(provider, body, searchUri);
      final entries = parseSubHdSearchPage(body, baseUri: searchUri);
      return (
        provider,
        entries,
        entries.isEmpty ? '没有匹配字幕' : '找到 ${entries.length} 条',
      );
    } on SubtitleSourceException catch (error) {
      return (provider, const <SubtitleSearchResult>[], error.message);
    } on Object catch (error) {
      return (
        provider,
        const <SubtitleSearchResult>[],
        '搜索失败：${_cleanError(error)}',
      );
    }
  }

  Future<(String, List<SubtitleSearchResult>, String)> _searchGestdown(
    SubtitleSearchQuery query,
  ) async {
    const provider = 'Gestdown';
    if (query.season == null || query.episode == null) {
      return (provider, const <SubtitleSearchResult>[], '需要剧集季数和集数');
    }
    try {
      final showUri = Uri.https(
        'api.gestdown.info',
        '/shows/search/${query.title.trim()}',
      );
      final showResponse = await _send(
        http.Request('GET', showUri)..headers['User-Agent'] = _userAgent,
      );
      _checkStatus(provider, showResponse, showUri);
      final shows = _decodeJson(showResponse);
      final show = _bestShow(shows, query.title);
      if (show == null) {
        return (provider, const <SubtitleSearchResult>[], '没有匹配剧集');
      }
      final showId = _firstString(show, const [
        'showUniqueId',
        'uniqueId',
        'id',
      ]);
      if (showId == null || showId.isEmpty) {
        return (provider, const <SubtitleSearchResult>[], '来源未提供剧集编号');
      }
      final subtitlesUri = Uri.https(
        'api.gestdown.info',
        '/subtitles/get/$showId/${query.season}/${query.episode}/${query.language}',
      );
      final subtitleResponse = await _send(
        http.Request('GET', subtitlesUri)..headers['User-Agent'] = _userAgent,
      );
      if (subtitleResponse.statusCode == 404) {
        return (provider, const <SubtitleSearchResult>[], '该集没有匹配字幕');
      }
      _checkStatus(provider, subtitleResponse, subtitlesUri);
      final payload = _decodeJson(subtitleResponse);
      final results = parseGestdownResults(
        payload,
        referrer: subtitlesUri,
        queryLanguage: query.language,
      );
      return (
        provider,
        results,
        results.isEmpty ? '该集没有匹配字幕' : '找到 ${results.length} 条',
      );
    } on SubtitleSourceException catch (error) {
      return (provider, const <SubtitleSearchResult>[], error.message);
    } on Object catch (error) {
      return (
        provider,
        const <SubtitleSearchResult>[],
        '搜索失败：${_cleanError(error)}',
      );
    }
  }

  Future<DownloadedSubtitle> download(SubtitleSearchResult result) async {
    final response = result.provider == 'SubHD'
        ? await _downloadSubHd(result)
        : await _downloadGestdown(result);
    final file = _subtitleFileFromResponse(
      response.bytes,
      suggestedName: response.fileName.isEmpty
          ? result.fileName
          : response.fileName,
    );
    final directory = temporaryDirectory ?? await getTemporaryDirectory();
    final sessionDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}mova-subtitles',
    );
    await sessionDirectory.create(recursive: true);
    final safeName = _safeFileName(file.fileName);
    final path =
        '${sessionDirectory.path}${Platform.pathSeparator}'
        '${DateTime.now().microsecondsSinceEpoch}-$safeName';
    await File(path).writeAsBytes(file.bytes, flush: true);
    return DownloadedSubtitle(
      path: path,
      fileName: safeName,
      language: result.language,
    );
  }

  Future<_DownloadedBytes> _downloadSubHd(SubtitleSearchResult result) async {
    final host = result.referrer.host;
    final downPage = Uri.https(host, '/down/${result.providerId}');
    final detailResponse = await _send(
      http.Request('GET', result.referrer)..headers['User-Agent'] = _userAgent,
    );
    _checkStatus('SubHD', detailResponse, result.referrer);
    final downResponse = await _send(
      http.Request('GET', downPage)
        ..headers.addAll({
          'User-Agent': _userAgent,
          'Referer': result.referrer.toString(),
          if (_subHdCookies([detailResponse]).isNotEmpty)
            'Cookie': _subHdCookies([detailResponse]),
        }),
    );
    _checkStatus(
      'SubHD',
      downResponse,
      downPage,
      notFoundMessage: '下载页面未找到该字幕（HTTP 404）',
    );
    final cookies = _subHdCookies([detailResponse, downResponse]);
    final downloadApi = Uri.https(host, '/api/sub/down');
    final response = await _send(
      http.Request('POST', downloadApi)
        ..headers.addAll({
          'User-Agent': _userAgent,
          'Referer': downPage.toString(),
          'Origin': 'https://$host',
          'Accept': 'application/json, text/plain, */*',
          'Content-Type': 'application/json',
          if (cookies.isNotEmpty) 'Cookie': cookies,
        })
        ..body = jsonEncode({'sid': result.providerId, 'cap': ''}),
    );
    _checkStatus(
      'SubHD',
      response,
      result.referrer,
      notFoundMessage: '下载接口未找到该字幕记录（HTTP 404）',
    );
    final payload = _decodeJson(response);
    if (payload is! Map) {
      _checkChallenge('SubHD', _decodeText(response.bodyBytes), downPage);
      throw const SubtitleSourceException('SubHD', '下载接口未返回有效结果');
    }
    final message = _firstString(payload, const ['msg', 'message']);
    if (payload['pass'] == false ||
        (message != null && _looksLikeChallenge(message))) {
      throw SubtitleSourceException(
        'SubHD',
        '站点要求验证码，请在 SubHD 网页完成验证后重试',
        searchUri: downPage,
        challenge: true,
      );
    }
    if (payload['success'] != true) {
      throw SubtitleSourceException(
        'SubHD',
        message ?? '下载接口未提供字幕文件',
        searchUri: downPage,
      );
    }
    final downloadAddress = _firstString(payload, const ['url', 'downloadUrl']);
    if (downloadAddress == null || downloadAddress.isEmpty) {
      throw const SubtitleSourceException('SubHD', '下载接口未提供字幕文件地址');
    }
    final downloadUri = downloadApi.resolve(downloadAddress);
    final fileResponse = await _send(
      http.Request('GET', downloadUri)
        ..headers.addAll({
          'User-Agent': _userAgent,
          'Referer': downPage.toString(),
          if (downloadUri.host == host && cookies.isNotEmpty) 'Cookie': cookies,
        }),
    );
    _checkStatus(
      'SubHD',
      fileResponse,
      result.referrer,
      notFoundMessage: '字幕文件链接已失效或文件已被移除（HTTP 404）',
    );
    final fileName = _fileNameFromHeaders(fileResponse.headers);
    return _DownloadedBytes(
      fileResponse.bodyBytes,
      fileName.isEmpty ? result.fileName : fileName,
    );
  }

  static String _subHdCookies(Iterable<http.Response> responses) {
    final pairs = <String, String>{};
    for (final response in responses) {
      final header = response.headers['set-cookie'];
      if (header == null) continue;
      for (final part in header.split(RegExp(r',(?=[^;,\s]+=)'))) {
        final pair = part.split(';').first.trim();
        final equals = pair.indexOf('=');
        if (equals > 0) {
          pairs[pair.substring(0, equals)] = pair.substring(equals + 1);
        }
      }
    }
    return pairs.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
  }

  Future<_DownloadedBytes> _downloadGestdown(
    SubtitleSearchResult result,
  ) async {
    final response = await _send(
      http.Request('GET', result.downloadUri)
        ..headers['User-Agent'] = _userAgent,
    );
    _checkStatus('Gestdown', response, result.referrer);
    final body = response.bodyBytes;
    if (_looksLikeJson(response, body)) {
      final payload = _decodeJson(response);
      final directUrl = _firstString(payload, const [
        'url',
        'downloadUrl',
        'subtitleUrl',
      ]);
      if (directUrl != null && directUrl.isNotEmpty) {
        final uri = result.downloadUri.resolve(directUrl);
        final downloaded = await _send(
          http.Request('GET', uri)..headers['User-Agent'] = _userAgent,
        );
        _checkStatus('Gestdown', downloaded, result.referrer);
        final fileName = _fileNameFromHeaders(downloaded.headers);
        return _DownloadedBytes(
          downloaded.bodyBytes,
          fileName.isEmpty ? result.fileName : fileName,
        );
      }
      final content = _firstString(payload, const ['content', 'text', 'data']);
      if (content != null && content.isNotEmpty) {
        return _DownloadedBytes(utf8.encode(content), result.fileName);
      }
      throw const SubtitleSourceException('Gestdown', '来源返回了无法识别的数据');
    }
    final fileName = _fileNameFromHeaders(response.headers);
    return _DownloadedBytes(
      body,
      fileName.isEmpty ? result.fileName : fileName,
    );
  }

  Future<http.Response> _send(http.Request request) async {
    final streamed = await _client
        .send(request)
        .timeout(const Duration(seconds: 18));
    final bytes = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in streamed.stream.timeout(
      const Duration(seconds: 18),
    )) {
      length += chunk.length;
      if (length > _maxSubtitleBytes) {
        throw const FormatException('字幕响应超过 20 MB 限制');
      }
      bytes.add(chunk);
    }
    return http.Response.bytes(
      bytes.takeBytes(),
      streamed.statusCode,
      headers: streamed.headers,
      request: request,
    );
  }

  static List<SubtitleSearchResult> parseSubHdSearchPage(
    String html, {
    required Uri baseUri,
  }) {
    if (_looksLikeChallenge(html)) {
      throw SubtitleSourceException(
        'SubHD',
        '站点要求验证。Mova 不会绕过验证码或反爬校验，可打开 SubHD 网页继续。',
        searchUri: baseUri,
      );
    }
    final found = <SubtitleSearchResult>[];
    final seen = <String>{};
    for (final match in _anchorPattern.allMatches(html)) {
      final attributes = match.group(1) ?? '';
      final href = _attribute(attributes, 'href');
      if (href == null) continue;
      final resultUri = baseUri.resolve(href);
      if (resultUri.host != baseUri.host) continue;
      // SubHD's newer subtitle pages use short alphanumeric ids (e.g. pQULiK),
      // not only the numeric ids used by older entries.
      final idMatch = RegExp(r'^/a/([A-Za-z0-9_-]+)/?$')
          .firstMatch(resultUri.path);
      if (idMatch == null || !seen.add(idMatch.group(1)!)) continue;
      final id = idMatch.group(1)!;
      final title = _plainText(match.group(2) ?? '');
      final row = _outerElementForAnchor(html, match.start);
      final rowText = _plainText(row);
      final format = RegExp(
        r'格式\s*[：:]\s*(\S+)',
        caseSensitive: false,
      ).firstMatch(rowText)?.group(1);
      final version = RegExp(r'版本\s*[：:]\s*(.+?)(?:\s{2,}|$)')
          .firstMatch(rowText)
          ?.group(1);
      final fileName = _candidateFileName(
        title: version == null ? title : '$title · $version',
        format: format,
      );
      found.add(
        SubtitleSearchResult(
          provider: 'SubHD',
          providerId: id,
          title: title.isEmpty ? 'SubHD 字幕 $id' : title,
          fileName: fileName,
          language: _attribute(attributes, 'data-lang') ?? '中文 / 多语言',
          downloadUri: baseUri,
          referrer: resultUri,
        ),
      );
      if (found.length >= 20) break;
    }
    return found;
  }

  static List<SubtitleSearchResult> parseGestdownResults(
    Object? payload, {
    required Uri referrer,
    required String queryLanguage,
  }) {
    final results = <SubtitleSearchResult>[];
    final seen = <String>{};
    for (final item in _deepMaps(payload)) {
      final id = _firstString(item, const [
        'subtitleId',
        'subtitleID',
        'uniqueId',
        'id',
      ]);
      if (id == null || !seen.add(id)) continue;
      final fileName =
          _firstString(item, const [
            'fileName',
            'filename',
            'release',
            'releaseName',
            'name',
            'title',
          ]) ??
          'SRT 字幕';
      final language =
          _firstString(item, const [
            'language',
            'languageName',
            'languageCode',
          ]) ??
          queryLanguage;
      results.add(
        SubtitleSearchResult(
          provider: 'Gestdown',
          providerId: id,
          title: fileName,
          fileName: _candidateFileName(title: fileName),
          language: language,
          downloadUri: Uri.https(
            'api.gestdown.info',
            '/subtitles/download/$id',
          ),
          referrer: referrer,
        ),
      );
      if (results.length >= 30) break;
    }
    return results;
  }

  static _DownloadedBytes _subtitleFileFromResponse(
    List<int> bytes, {
    required String suggestedName,
  }) {
    if (bytes.isEmpty) throw const FormatException('下载到的字幕文件为空');
    if (bytes.length > _maxSubtitleBytes) {
      throw const FormatException('字幕文件超过 20 MB 限制');
    }
    final name = _safeFileName(suggestedName);
    final isZip =
        bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4b &&
        (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07);
    if (isZip || name.toLowerCase().endsWith('.zip')) {
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      if (archive.files.length > 100) {
        throw const FormatException('字幕压缩包包含过多文件');
      }
      final files = archive.files
          .where((file) => file.isFile && _supportedExtension(file.name))
          .where((file) => file.size > 0 && file.size <= _maxSubtitleBytes)
          .toList(growable: false);
      if (files.isEmpty) {
        throw const FormatException('压缩包内没有可用的 SRT/ASS/SSA/VTT 字幕');
      }
      files.sort(
        (a, b) =>
            _subtitleFileRank(a.name).compareTo(_subtitleFileRank(b.name)),
      );
      final selected = files.first;
      return _DownloadedBytes(selected.content, _safeFileName(selected.name));
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x61 &&
        bytes[2] == 0x72 &&
        bytes[3] == 0x21) {
      throw const FormatException('该来源返回 RAR 压缩包，暂不支持自动解压；请选择其他字幕结果');
    }
    final prefix = utf8
        .decode(bytes.take(2048).toList(growable: false), allowMalformed: true)
        .trimLeft()
        .toLowerCase();
    if (prefix.startsWith('<!doctype html') ||
        prefix.startsWith('<html') ||
        prefix.startsWith('{"error"') ||
        prefix.startsWith('{"message"')) {
      throw const FormatException('来源返回了网页或错误信息，不是字幕文件');
    }
    if (!_supportedExtension(name)) {
      throw FormatException('不支持的字幕格式：${_extensionOf(name)}');
    }
    return _DownloadedBytes(bytes, name);
  }

  static String _candidateFileName({required String title, String? format}) {
    final normalizedTitle = title.trim().isEmpty ? 'subtitle' : title.trim();
    final titleExt = _extensionOf(normalizedTitle);
    if (_supportedExtension(normalizedTitle) || titleExt == '.zip') {
      return normalizedTitle;
    }
    final formatExt = '.${(format ?? '').toLowerCase().replaceAll('.', '')}';
    final ext = _subtitleExtensions.contains(formatExt) || formatExt == '.zip'
        ? formatExt
        : '.srt';
    return '$normalizedTitle$ext';
  }

  static Map<String, dynamic>? _bestShow(Object? payload, String title) {
    final shows = _deepMaps(payload)
        .where(
          (map) =>
              _firstString(map, const ['showUniqueId', 'uniqueId', 'id']) !=
              null,
        )
        .toList(growable: false);
    if (shows.isEmpty) return null;
    final normalized = _normalizeTitle(title);
    for (final show in shows) {
      final showTitle = _firstString(show, const ['name', 'title', 'showName']);
      if (showTitle != null && _normalizeTitle(showTitle) == normalized) {
        return show;
      }
    }
    return shows.first;
  }

  static Object? _decodeJson(http.Response response) {
    try {
      return jsonDecode(_decodeText(response.bodyBytes));
    } on FormatException {
      return null;
    }
  }

  static String _decodeText(List<int> bytes) =>
      utf8.decode(bytes, allowMalformed: true);

  static bool _looksLikeJson(http.Response response, List<int> body) {
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (contentType.contains('json')) return true;
    final text = _decodeText(body).trimLeft();
    return text.startsWith('{') || text.startsWith('[');
  }

  static Iterable<Map<String, dynamic>> _deepMaps(Object? value) sync* {
    if (value is Map) {
      final map = <String, dynamic>{
        for (final entry in value.entries)
          if (entry.key is String) entry.key as String: entry.value,
      };
      yield map;
      for (final child in map.values) {
        yield* _deepMaps(child);
      }
    } else if (value is Iterable) {
      for (final child in value) {
        yield* _deepMaps(child);
      }
    }
  }

  static String? _firstString(Object? value, List<String> keys) {
    if (value is! Map) return null;
    for (final key in keys) {
      final candidate = value[key];
      if (candidate is String && candidate.trim().isNotEmpty) {
        return candidate.trim();
      }
      if (candidate is num && candidate > 0) return candidate.toString();
    }
    return null;
  }

  static void _checkStatus(
    String provider,
    http.Response response,
    Uri referrer, {
    String? notFoundMessage,
  }) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    final challenge = response.statusCode == 403 || response.statusCode == 503;
    final message = switch (response.statusCode) {
      404 => notFoundMessage ?? '没有找到匹配内容',
      423 => '来源正在更新索引，请稍后重试',
      429 => '来源请求过于频繁，请稍后重试',
      403 || 503 => '站点要求验证或暂时限制访问。Mova 不会绕过验证。',
      _ => '来源返回 HTTP ${response.statusCode}',
    };
    throw SubtitleSourceException(
      provider,
      message,
      searchUri: referrer,
      challenge: challenge,
    );
  }

  static void _checkChallenge(String provider, String body, Uri uri) {
    if (_looksLikeChallenge(body)) {
      throw SubtitleSourceException(
        provider,
        '站点要求验证。Mova 不会绕过验证码或反爬校验。',
        searchUri: uri,
        challenge: true,
      );
    }
  }

  static bool _looksLikeChallenge(String body) {
    final lower = body.toLowerCase();
    return lower.contains('captcha') ||
        lower.contains('verify you are human') ||
        lower.contains('just a moment') ||
        lower.contains('验证码') ||
        lower.contains('人机验证');
  }

  static String _fileNameFromHeaders(Map<String, String> headers) {
    final header = headers['content-disposition'] ?? '';
    final utf8Name = RegExp(
      r"filename\*=utf-8''([^;]+)",
      caseSensitive: false,
    ).firstMatch(header)?.group(1);
    if (utf8Name != null) return Uri.decodeComponent(utf8Name);
    final quoted = RegExp(
      r'filename\s*=\s*"([^"]+)"',
      caseSensitive: false,
    ).firstMatch(header)?.group(1);
    return quoted ??
        RegExp(
          r'filename\s*=\s*([^;]+)',
          caseSensitive: false,
        ).firstMatch(header)?.group(1)?.trim() ??
        '';
  }

  static String _safeFileName(String value) {
    final leaf = value.replaceAll('\\', '/').split('/').last.trim();
    final safe = leaf
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ');
    return safe.isEmpty ? 'subtitle.srt' : safe;
  }

  static String _extensionOf(String value) {
    final leaf = value.replaceAll('\\', '/').split('/').last;
    final dot = leaf.lastIndexOf('.');
    return dot < 0 ? '' : leaf.substring(dot).toLowerCase();
  }

  static bool _supportedExtension(String value) =>
      _subtitleExtensions.contains(_extensionOf(value));

  static int _subtitleFileRank(String name) {
    final normalized = name.toLowerCase();
    final language =
        normalized.contains('zh') ||
            normalized.contains('chs') ||
            normalized.contains('简体')
        ? 0
        : normalized.contains('en') || normalized.contains('eng')
        ? 1
        : 2;
    final extension = switch (_extensionOf(name)) {
      '.ass' => 0,
      '.ssa' => 1,
      '.srt' => 2,
      '.vtt' => 3,
      _ => 4,
    };
    return language * 10 + extension;
  }

  static String _normalizeTitle(String value) => value.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]', unicode: true),
    '',
  );

  static String _cleanError(Object error) => error
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst('Bad state: ', '');

  static String get _userAgent =>
      'Mova (subtitle search; https://github.com/TaoHua-cc/Mova)';

  static final _anchorPattern = RegExp(
    r'<a\b([^>]*)>(.*?)</a\s*>',
    caseSensitive: false,
    dotAll: true,
  );

  static String? _attribute(String attributes, String name) => RegExp(
    '(?:^|\\s)${RegExp.escape(name)}\\s*=\\s*(["\\\'])(.*?)\\1',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(attributes)?.group(2);

  static String _plainText(String html) => _decodeEntities(
    html
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim(),
  );

  static String _decodeEntities(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ')
      .replaceAllMapped(RegExp(r'&#(x[\da-f]+|\d+);', caseSensitive: false), (
        match,
      ) {
        final value = match.group(1)!;
        final codePoint = value.startsWith('x') || value.startsWith('X')
            ? int.tryParse(value.substring(1), radix: 16)
            : int.tryParse(value);
        return codePoint == null
            ? match.group(0)!
            : String.fromCharCode(codePoint);
      });

  static String _outerElementForAnchor(String html, int anchorStart) {
    final start = html.lastIndexOf('<li', anchorStart);
    if (start < 0) {
      return html.substring(
        anchorStart,
        (anchorStart + 1200).clamp(0, html.length),
      );
    }
    final end = html.indexOf('</li>', anchorStart);
    if (end < 0) {
      return html.substring(start, (start + 1400).clamp(0, html.length));
    }
    return html.substring(start, end + 5);
  }
}

class SubtitleSourceException implements Exception {
  const SubtitleSourceException(
    this.provider,
    this.message, {
    this.searchUri,
    this.challenge = false,
  });

  final String provider;
  final String message;
  final Uri? searchUri;
  final bool challenge;

  @override
  String toString() => '$provider：$message';
}

class _DownloadedBytes {
  const _DownloadedBytes(this.bytes, this.fileName);

  final List<int> bytes;
  final String fileName;
}
