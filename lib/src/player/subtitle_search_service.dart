import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
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
    this.matchLabel = '',
  });

  final String provider;
  final String providerId;
  final String title;
  final String fileName;
  final String language;
  final Uri downloadUri;
  final Uri referrer;
  final String matchLabel;
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
    this.persistent = false,
  });

  final String path;
  final String fileName;
  final String language;
  final bool persistent;
}

class SubtitleSearchService {
  static final _downloadEpochs = <String, int>{};
  static String _episodeKey(SubtitleSearchQuery query) => sha256
      .convert(
        utf8.encode(
          '${query.title.trim().toLowerCase()}|${query.season}|${query.episode}',
        ),
      )
      .toString();

  static Future<Directory> _savedDirectory(
    SubtitleSearchQuery query,
    Directory? root,
  ) async {
    final base = root ?? await getApplicationSupportDirectory();
    return Directory(
      '${base.path}${Platform.pathSeparator}mova-saved-subtitles${Platform.pathSeparator}${_episodeKey(query)}',
    );
  }

  Future<List<(SubtitleSearchResult, DownloadedSubtitle)>> savedDownloads(
    SubtitleSearchQuery query,
  ) async {
    final directory = await _savedDirectory(query, temporaryDirectory);
    if (!await directory.exists()) return [];
    final saved = <(SubtitleSearchResult, DownloadedSubtitle)>[];
    await for (final file in directory.list()) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      try {
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final name = data['file'] as String;
        if (name != _safeFileName(name)) continue;
        final subtitle = File(
          '${directory.path}${Platform.pathSeparator}$name',
        );
        if (!await subtitle.exists() || await subtitle.length() == 0) continue;
        final id = data['id'] as String;
        final referrer = Uri.https(_subHdHost, '/a/$id');
        saved.add((
          SubtitleSearchResult(
            provider: data['provider'] as String,
            providerId: id,
            title: data['title'] as String,
            fileName: data['name'] as String,
            language: data['language'] as String,
            downloadUri: referrer,
            referrer: referrer,
            matchLabel: '已下载',
          ),
          DownloadedSubtitle(
            path: subtitle.path,
            fileName: data['name'] as String,
            language: data['language'] as String,
            persistent: true,
          ),
        ));
      } catch (_) {
        // An incomplete index or externally removed file must not hide other downloads.
      }
    }
    saved.sort((a, b) => a.$1.title.compareTo(b.$1.title));
    return saved;
  }

  static Future<void> clearDownloads(
    SubtitleSearchQuery query, {
    Directory? root,
  }) async {
    final key = _episodeKey(query);
    _downloadEpochs[key] = (_downloadEpochs[key] ?? 0) + 1;
    final directory = await _savedDirectory(query, root);
    if (await directory.exists()) await directory.delete(recursive: true);
  }

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
    final title = query.title.trim();
    final keyword = query.season == null || query.episode == null
        ? title
        : '$title S${query.season.toString().padLeft(2, '0')}E${query.episode.toString().padLeft(2, '0')}';
    final searchUri = Uri.https(_subHdHost, '/search/$keyword');
    try {
      final response = await _send(
        http.Request('GET', searchUri)..headers['User-Agent'] = _userAgent,
      );
      _checkStatus(provider, response, searchUri);
      final body = _decodeText(response.bodyBytes);
      _checkChallenge(provider, body, searchUri);
      final parsed = parseSubHdSearchPage(body, baseUri: searchUri);
      if (keyword != title &&
          !parsed.any(
            (r) => episodeMatchRank('${r.title} ${r.fileName}', query) == 0,
          )) {
        final fallbackUri = Uri.https(_subHdHost, '/search/$title');
        final fallback = await _send(
          http.Request('GET', fallbackUri)..headers['User-Agent'] = _userAgent,
        );
        _checkStatus(provider, fallback, fallbackUri);
        final seen = parsed.map((r) => r.providerId).toSet();
        parsed.addAll(
          parseSubHdSearchPage(
            _decodeText(fallback.bodyBytes),
            baseUri: fallbackUri,
          ).where((r) => seen.add(r.providerId)),
        );
      }
      final entries = <SubtitleSearchResult>[];
      for (final result in parsed) {
        final rank = episodeMatchRank(
          '${result.title} ${result.fileName}',
          query,
        );
        if (rank == 3) continue;
        entries.add(
          SubtitleSearchResult(
            provider: result.provider,
            providerId: result.providerId,
            title: result.title,
            fileName: result.fileName,
            language: result.language,
            downloadUri: result.downloadUri,
            referrer: result.referrer,
            matchLabel: query.episode == null
                ? '影片字幕'
                : ['本集 · 文件名匹配', '整季包 · 下载时核对本集', '集数未确认'][rank],
          ),
        );
      }
      entries.sort(
        (a, b) => episodeMatchRank(
          '${a.title} ${a.fileName}',
          query,
        ).compareTo(episodeMatchRank('${b.title} ${b.fileName}', query)),
      );
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

  Future<DownloadedSubtitle> download(
    SubtitleSearchResult result, {
    SubtitleSearchQuery? query,
  }) async {
    final episodeKey = query == null ? null : _episodeKey(query);
    final epoch = _downloadEpochs[episodeKey] ?? 0;
    final response = result.provider == 'SubHD'
        ? await _downloadSubHd(result)
        : await _downloadGestdown(result);
    final file = _subtitleFileFromResponse(
      response.bytes,
      query: query,
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
    if (query != null) {
      final directory = await _savedDirectory(query, temporaryDirectory);
      if ((_downloadEpochs[episodeKey] ?? 0) != epoch) {
        await File(path).delete();
        throw const FormatException('该集已播放完成，下载字幕不再保留');
      }
      await directory.create(recursive: true);
      final id = sha256
          .convert(utf8.encode('${result.provider}:${result.providerId}'))
          .toString();
      final cachedFile = File(
        '${directory.path}${Platform.pathSeparator}$id${_extensionOf(safeName)}',
      );
      final index = File('${directory.path}${Platform.pathSeparator}$id.json');
      await File(path).copy(cachedFile.path);
      await index.writeAsString(
        jsonEncode({
          'file': cachedFile.uri.pathSegments.last,
          'provider': result.provider,
          'id': result.providerId,
          'title': result.title,
          'name': safeName,
          'language': result.language,
        }),
        flush: true,
      );
      await File(path).delete();
      if ((_downloadEpochs[episodeKey] ?? 0) != epoch) {
        if (await cachedFile.exists()) await cachedFile.delete();
        if (await index.exists()) await index.delete();
        throw const FormatException('该集已播放完成，下载字幕不再保留');
      }
      return DownloadedSubtitle(
        path: cachedFile.path,
        fileName: safeName,
        language: result.language,
        persistent: true,
      );
    }
    return DownloadedSubtitle(
      path: path,
      fileName: safeName,
      language: result.language,
    );
  }

  Future<_DownloadedBytes> _downloadSubHd(SubtitleSearchResult result) async {
    final host = result.referrer.host;
    final detailResponse = await _send(
      http.Request('GET', result.referrer)..headers['User-Agent'] = _userAgent,
    );
    _checkStatus('SubHD', detailResponse, result.referrer);
    _checkChallenge(
      'SubHD',
      _decodeText(detailResponse.bodyBytes),
      result.referrer,
    );
    final prepareResponse = await _send(
      http.Request('POST', Uri.https(host, '/api/sub/prepare-download'))
        ..headers.addAll({
          'User-Agent': _userAgent,
          'Referer': result.referrer.toString(),
          'Origin': 'https://$host',
          'Content-Type': 'application/json',
          if (_subHdCookies([detailResponse]).isNotEmpty)
            'Cookie': _subHdCookies([detailResponse]),
        })
        ..body = jsonEncode({'sid': result.providerId}),
    );
    _checkStatus(
      'SubHD',
      prepareResponse,
      result.referrer,
      notFoundMessage: '下载接口未找到该字幕记录（HTTP 404）',
    );
    _checkChallenge(
      'SubHD',
      _decodeText(prepareResponse.bodyBytes),
      result.referrer,
    );
    final prepared = _decodeJson(prepareResponse);
    final address = prepared is Map && prepared['success'] == true
        ? prepared['url']
        : null;
    final downPage = address is String
        ? result.referrer.resolve(address)
        : null;
    if (downPage == null ||
        downPage.scheme != 'https' ||
        downPage.host != host ||
        !downPage.path.startsWith('/down/')) {
      throw SubtitleSourceException(
        'SubHD',
        prepared is Map
            ? '${prepared['msg'] ?? '无法准备下载，请在网页检查登录或验证要求'}'
            : '无法准备下载',
        searchUri: result.referrer,
      );
    }
    final downResponse = await _send(
      http.Request('GET', downPage)
        ..headers.addAll({
          'User-Agent': _userAgent,
          'Referer': result.referrer.toString(),
          if (_subHdCookies([detailResponse, prepareResponse]).isNotEmpty)
            'Cookie': _subHdCookies([detailResponse, prepareResponse]),
        }),
    );
    _checkStatus(
      'SubHD',
      downResponse,
      downPage,
      notFoundMessage: '下载页面未找到该字幕（HTTP 404）',
    );
    final cookies = _subHdCookies([
      detailResponse,
      prepareResponse,
      downResponse,
    ]);
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
      if (idMatch == null) continue;
      final id = idMatch.group(1)!;
      final title = _plainText(match.group(2) ?? '');
      if (!seen.add(id)) {
        final index = found.indexWhere((result) => result.providerId == id);
        if (index < 0 ||
            !_episodeMarkers.hasMatch(title) ||
            _episodeMarkers.hasMatch(found[index].title))
          continue;
        found.removeAt(index);
      }
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
    SubtitleSearchQuery? query,
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
      var files = archive.files
          .where((file) => file.isFile && _supportedExtension(file.name))
          .where((file) => file.size > 0 && file.size <= _maxSubtitleBytes)
          .toList(growable: false);
      if (files.isEmpty) {
        throw const FormatException('压缩包内没有可用的 SRT/ASS/SSA/VTT 字幕');
      }
      if (query?.episode != null) {
        final matched = files
            .where((file) => episodeMatchRank(file.name, query!) == 0)
            .toList();
        if (matched.isNotEmpty) {
          files = matched;
        } else if (files.length > 1 ||
            episodeMatchRank(files.single.name, query!) == 3) {
          throw const FormatException('压缩包内未确认到当前集字幕，未自动应用；请解压后本地导入');
        }
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
    if (query?.episode != null && episodeMatchRank(name, query!) == 3) {
      throw const FormatException('下载文件集数与当前集不一致，未应用');
    }
    return _DownloadedBytes(bytes, name);
  }

  static final _episodeMarkers = RegExp(
    r'S\d{1,2}|第\s*\d+\s*[季集]|\bE\d{1,3}',
    caseSensitive: false,
  );

  /// 0: matching episode, 1: season pack, 2: unknown, 3: explicit mismatch.
  static int episodeMatchRank(String name, SubtitleSearchQuery query) {
    if (query.episode == null) return 2;
    final range = RegExp(
      r'S(\d{1,2})[ ._-]*E(\d{1,3})\s*[-~至]\s*(?:S\d{1,2})?E?(\d{1,3})(?!\d)',
      caseSensitive: false,
    ).firstMatch(name);
    if (range != null) {
      return (query.season == null || int.parse(range[1]!) == query.season) &&
              query.episode! >= int.parse(range[2]!) &&
              query.episode! <= int.parse(range[3]!)
          ? 1
          : 3;
    }
    final full = RegExp(
      r'S(\d{1,2})[ ._-]*E(\d{1,3})(?!\d)',
      caseSensitive: false,
    ).allMatches(name).toList();
    if (full.isNotEmpty) {
      return full.any(
            (m) =>
                (query.season == null || int.parse(m[1]!) == query.season) &&
                int.parse(m[2]!) == query.episode,
          )
          ? 0
          : 3;
    }
    final season = RegExp(
      r'S(\d{1,2})(?!\d)|第\s*(\d+)\s*季',
      caseSensitive: false,
    ).firstMatch(name);
    if (season != null &&
        query.season != null &&
        int.parse(season[1] ?? season[2]!) != query.season)
      return 3;
    final episode = RegExp(
      r'\bE(\d{1,3})(?!\d)|第\s*(\d+)\s*集',
      caseSensitive: false,
    ).firstMatch(name);
    if (episode != null)
      return int.parse(episode[1] ?? episode[2]!) == query.episode ? 0 : 3;
    if (season != null &&
        RegExp(r'全集|整季|全季|complete|pack', caseSensitive: false).hasMatch(name))
      return 1;
    return 2;
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
