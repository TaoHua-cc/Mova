import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../network/network_http_client.dart';
import '../platform/window_host.dart';

const int _kb = 1024;
const int _mb = 1024 * _kb;
const int _gb = 1024 * _mb;

/// 视频缓存的上限策略。
///
/// 桌面端只有一份上限；安卓分「无线局域网」和「移动数据」两份 —— 移动数据
/// 是计量网络，默认关掉，用户想缓存再自己开。当前用哪一份取决于
/// [WindowHost.networkType] 的实时结果，所以切换网络不用重启应用。
class VideoCachePolicy {
  VideoCachePolicy._();

  static const String desktopKey = 'yingji.cache.video.limit';
  static const String wifiKey = 'yingji.cache.video.limit.wifi';
  static const String mobileKey = 'yingji.cache.video.limit.mobile';

  /// 可选档位（字节）。0 = 不缓存。
  static const List<int> steps = <int>[
    0,
    1 * _gb,
    2 * _gb,
    5 * _gb,
    10 * _gb,
    20 * _gb,
    50 * _gb,
  ];

  static const int defaultDesktop = 5 * _gb;
  static const int defaultWifi = 2 * _gb;
  static const int defaultMobile = 0;

  static int readDesktop(SharedPreferences prefs) =>
      prefs.getInt(desktopKey) ?? defaultDesktop;

  static int readWifi(SharedPreferences prefs) =>
      prefs.getInt(wifiKey) ?? defaultWifi;

  static int readMobile(SharedPreferences prefs) =>
      prefs.getInt(mobileKey) ?? defaultMobile;

  /// 当前网络下实际生效的上限（字节）。0 表示这次不要缓存。
  static Future<int> current([SharedPreferences? prefs]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    if (WindowHost.isDesktop) return readDesktop(store);
    final type = await WindowHost.networkType();
    return type == 'mobile' ? readMobile(store) : readWifi(store);
  }

  static Future<void> saveDesktop(int bytes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(desktopKey, bytes);
  }

  static Future<void> saveWifi(int bytes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(wifiKey, bytes);
  }

  static Future<void> saveMobile(int bytes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(mobileKey, bytes);
  }

  /// 「2 GB」这样的档位文案；0 显示为「不缓存」。
  static String label(int bytes) {
    if (bytes <= 0) return '不缓存';
    if (bytes >= _gb) return '${bytes ~/ _gb} GB';
    return '${(bytes / _mb).round()} MB';
  }
}

/// 一次后台缓存任务的句柄。
///
/// 任务本身由 [VideoCacheStore] 持有并推进，这里只暴露「等它结束」和
/// 「打断它」。打断时**保留**已下载的分片（`.part`），下次接着断点续传 ——
/// 看两分钟就退出也能留下前两分钟，而不是白下一遍。
class VideoCacheDownload {
  VideoCacheDownload._();

  final Completer<void> _completer = Completer<void>();
  final StreamController<VideoCacheProgress> _progressController =
      StreamController<VideoCacheProgress>.broadcast();
  VideoCacheProgress _state = const VideoCacheProgress();
  bool _cancelled = false;
  HttpClientRequest? _request;

  Future<void> get done => _completer.future;
  Stream<VideoCacheProgress> get progress => _progressController.stream;
  VideoCacheProgress get state => _state;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    try {
      _request?.abort();
    } catch (_) {
      // 请求可能已经结束，abort 会抛；打断只是尽力而为。
    }
  }

  void _update(VideoCacheProgress value) {
    _state = value;
    if (!_progressController.isClosed) _progressController.add(value);
  }
}

enum VideoCacheStatus { idle, downloading, buffered, complete, unavailable }

class VideoCacheProgress {
  const VideoCacheProgress({
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.mediaTotalBytes = 0,
    this.status = VideoCacheStatus.idle,
  });

  final int receivedBytes;
  final int totalBytes;
  final int mediaTotalBytes;
  final VideoCacheStatus status;

  double? get fraction =>
      totalBytes <= 0 ? null : (receivedBytes / totalBytes).clamp(0.0, 1.0);
}

/// 视频缓存：持久保存可复用的前向分段，并通过本机 Range 代理供 mpv 播放。
///
/// 为什么不用 mpv 自带的磁盘缓冲：那份缓冲由播放器自己管，应用**读得到但管
/// 不了** —— 清不掉、上限不可控、设置页也给不出占用。这里自己落一份，才能
/// 回答「占了多少 / 怎么清 / 最多存多少」这三个用户一定会问的问题。
///
/// 目录放在应用支持目录（`getApplicationSupportDirectory`）而不是临时目录：
/// 临时目录会被系统回收，缓存就没意义了。
class VideoCacheStore {
  VideoCacheStore._(this._root);

  static const String _folder = 'mova-video-cache';

  final Directory _root;
  HttpServer? _proxy;
  final Map<String, _ProxySource> _proxySources = <String, _ProxySource>{};

  /// 建好目录并返回实例；拿不到目录时返回 null（调用方按「没有缓存」处理）。
  static Future<VideoCacheStore?> tryCreate() async {
    try {
      final base = await getApplicationSupportDirectory();
      final root = Directory('${base.path}${Platform.pathSeparator}$_folder');
      if (!await root.exists()) {
        await root.create(recursive: true);
      }
      return VideoCacheStore._(root);
    } catch (_) {
      return null;
    }
  }

  String _path(String key) => '${_root.path}${Platform.pathSeparator}$key.bin';

  /// A loopback URL which gives mpv a single seekable stream backed by the
  /// persistent prefix on disk and the origin server for cache misses.
  Future<String> playbackUrl(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    final server = _proxy ??= await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    if (_proxySources.isEmpty) unawaited(_serveProxy(server));
    final key = _keyFor(url);
    _proxySources[key] = _ProxySource(url, headers);
    return 'http://${server.address.address}:${server.port}/media/$key';
  }

  Future<void> _serveProxy(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handleProxy(request));
    }
  }

  Future<void> _handleProxy(HttpRequest request) async {
    HttpClient? client;
    try {
      final key =
          request.uri.pathSegments.length == 2 &&
              request.uri.pathSegments.first == 'media'
          ? request.uri.pathSegments.last
          : '';
      final source = _proxySources[key];
      if (source == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final range = _parseRange(request.headers.value(HttpHeaders.rangeHeader));
      final part = File('${_path(key)}.part');
      final cached = await _lengthOf(part);
      final meta = await _readMeta(key);
      final total = (meta?['totalBytes'] as num?)?.toInt() ?? 0;
      final start = range?.$1 ?? 0;
      if (request.method == 'GET' && cached > start) {
        final requestedEnd = range?.$2;
        final end =
            (requestedEnd == null
                    ? cached - 1
                    : requestedEnd.clamp(start, cached - 1))
                .toInt();
        final length = end - start + 1;
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${total > 0 ? total : '*'}',
        );
        request.response.contentLength = length;
        await request.response.addStream(part.openRead(start, end + 1));
        await request.response.close();
        return;
      }

      client = HttpClient()..findProxy = findNetworkProxy;
      final origin = await client.openUrl(
        request.method,
        Uri.parse(source.url),
      );
      for (final entry in source.headers.entries) {
        origin.headers.set(entry.key, entry.value);
      }
      final incomingRange = request.headers.value(HttpHeaders.rangeHeader);
      if (incomingRange != null) {
        origin.headers.set(HttpHeaders.rangeHeader, incomingRange);
      }
      final response = await origin.close();
      request.response.statusCode = response.statusCode;
      for (final name in <String>[
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.etagHeader,
        HttpHeaders.lastModifiedHeader,
      ]) {
        final value = response.headers.value(name);
        if (value != null) request.response.headers.set(name, value);
      }
      if (response.contentLength >= 0) {
        request.response.contentLength = response.contentLength;
      }
      if (request.method != 'HEAD') await request.response.addStream(response);
      await request.response.close();
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {}
    } finally {
      client?.close(force: true);
    }
  }

  static (int, int?)? _parseRange(String? value) {
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(value ?? '');
    if (match == null) return null;
    return (int.parse(match.group(1)!), int.tryParse(match.group(2) ?? ''));
  }

  /// 文件名用 URL 的 FNV-1a 散列：URL 里常带 token 之类的长查询串，
  /// 直接拿来当文件名既超长又把凭据写进磁盘。
  static String _keyFor(String url) {
    var hash = 0x811c9dc5;
    for (final unit in url.codeUnits) {
      hash = (hash ^ unit) & 0xFFFFFFFF;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// 已完整缓存的本地文件；没有就返回 null。命中会顺带刷新「最近使用」，
  /// 让 LRU 裁剪不会把刚看过的删掉。
  Future<File?> cachedFile(String url) async {
    final file = File(_path(_keyFor(url)));
    if (!await file.exists()) return null;
    await _touch(url, await file.length());
    return file;
  }

  /// 总占用（含未下完的分片）。
  Future<int> usageBytes() async {
    var total = 0;
    await for (final entity in _root.list(followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {}
      }
    }
    return total;
  }

  /// 已完整缓存的份数。
  Future<int> count() async {
    var total = 0;
    await for (final entity in _root.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.bin')) total++;
    }
    return total;
  }

  /// 清空全部缓存（含分片与元信息），返回删掉的正片份数。
  Future<int> clear() async {
    var removed = 0;
    await for (final entity in _root.list(followLinks: false)) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.bin')) removed++;
      await _delete(entity);
    }
    return removed;
  }

  /// 按「最久没用」裁剪到 [limitBytes] 以内。
  ///
  /// 分片（`.part`）也参与计数，否则用户看两分钟就退出的那些碎片会堆成
  /// 看不见的占用。
  Future<void> prune(int limitBytes) async {
    if (limitBytes <= 0) {
      await clear();
      return;
    }
    final files = <_CacheFile>[];
    var total = 0;
    await for (final entity in _root.list(followLinks: false)) {
      if (entity is! File) continue;
      final isMedia =
          entity.path.endsWith('.bin') || entity.path.endsWith('.part');
      if (isMedia) {
        final length = await _lengthOf(entity);
        total += length;
        files.add(_CacheFile(entity, length, await _lastUsed(entity)));
      }
    }
    if (total <= limitBytes) return;
    files.sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
    for (final entry in files) {
      if (total <= limitBytes) break;
      await _delete(entry.file);
      total -= entry.length;
    }
  }

  /// 后台为 [url] 预读至所选容量。返回句柄，调用方可以取消且保留分片。
  ///
  /// [limitBytes] is the reusable read-ahead window, not a maximum media size.
  /// A large movie therefore keeps a persistent prefix up to this size.
  VideoCacheDownload download({
    required String url,
    required int limitBytes,
    Map<String, String> headers = const {},
    String title = '',
  }) {
    final job = VideoCacheDownload._();
    if (limitBytes <= 0) {
      job._completer.complete();
      return job;
    }
    unawaited(
      _run(
        job,
        url: url,
        limitBytes: limitBytes,
        headers: headers,
        title: title,
      ),
    );
    return job;
  }

  Future<void> _run(
    VideoCacheDownload job, {
    required String url,
    required int limitBytes,
    required Map<String, String> headers,
    required String title,
  }) async {
    HttpClient? client;
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https'))
        return;
      final key = _keyFor(url);
      final target = File(_path(key));
      if (await target.exists()) return;
      final part = File('${target.path}.part');
      var offset = 0;
      if (await part.exists()) {
        try {
          offset = await part.length();
        } catch (_) {
          offset = 0;
        }
      }
      job._update(
        VideoCacheProgress(
          receivedBytes: offset,
          status: VideoCacheStatus.downloading,
        ),
      );
      client = HttpClient()..findProxy = findNetworkProxy;
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      if (job._cancelled) return;
      job._request = request;
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      if (offset > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      // 416：分片比服务端现在的文件还新（资源换过了）。留着也续不上，删掉重来。
      if (response.statusCode == 416) {
        await _delete(part);
        return;
      }
      if (response.statusCode != 200 && response.statusCode != 206) return;
      // 200 说明服务端没接 Range，分片对不上号，只能从头重写。
      if (response.statusCode == 200) offset = 0;
      final remaining = response.contentLength;
      final total = remaining > 0 ? offset + remaining : 0;
      final targetBytes = total > 0 && total < limitBytes ? total : limitBytes;
      await _writeMeta(
        key,
        url: url,
        title: title,
        bytes: offset,
        totalBytes: total,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      if (offset >= targetBytes) {
        job._update(
          VideoCacheProgress(
            receivedBytes: offset,
            totalBytes: targetBytes,
            mediaTotalBytes: total,
            status: total > 0 && offset >= total
                ? VideoCacheStatus.complete
                : VideoCacheStatus.buffered,
          ),
        );
        return;
      }
      var completed = false;
      final sink = part.openWrite(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      try {
        var written = offset;
        var lastReported = offset;
        await for (final chunk in response) {
          if (job._cancelled) break;
          sink.add(chunk);
          written += chunk.length;
          if (written - lastReported >= _mb) {
            lastReported = written;
            job._update(
              VideoCacheProgress(
                receivedBytes: written,
                totalBytes: targetBytes,
                mediaTotalBytes: total,
                status: VideoCacheStatus.downloading,
              ),
            );
          }
          if (written >= targetBytes) {
            break;
          }
        }
        await sink.flush();
        completed = !job._cancelled && total > 0 && written >= total;
      } catch (_) {
        // 网络中断或被打断：分片留在磁盘上，下次续传。
        completed = false;
      } finally {
        try {
          await sink.close();
        } catch (_) {}
      }
      final size = await _lengthOf(part);
      if (size <= 0) {
        await _delete(part);
        return;
      }
      if (completed) await part.rename(target.path);
      await _writeMeta(
        key,
        url: url,
        title: title,
        bytes: size,
        totalBytes: total,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      job._update(
        VideoCacheProgress(
          receivedBytes: size,
          totalBytes: completed ? size : targetBytes,
          mediaTotalBytes: total,
          status: completed
              ? VideoCacheStatus.complete
              : VideoCacheStatus.buffered,
        ),
      );
      await prune(limitBytes);
    } catch (_) {
      // 缓存失败不影响播放，但向播放器暴露真实状态。
      job._update(
        VideoCacheProgress(
          receivedBytes: job.state.receivedBytes,
          totalBytes: job.state.totalBytes,
          status: VideoCacheStatus.unavailable,
        ),
      );
    } finally {
      client?.close(force: true);
      if (!job._completer.isCompleted) job._completer.complete();
      await job._progressController.close();
    }
  }

  Future<void> _touch(String url, int bytes) async {
    final key = _keyFor(url);
    final meta = File('${_root.path}${Platform.pathSeparator}$key.json');
    var createdAt = DateTime.now().millisecondsSinceEpoch;
    var title = '';
    var totalBytes = 0;
    if (await meta.exists()) {
      try {
        final data = jsonDecode(await meta.readAsString());
        if (data is Map) {
          createdAt = (data['createdAt'] as int?) ?? createdAt;
          title = '${data['title'] ?? ''}';
          totalBytes = (data['totalBytes'] as num?)?.toInt() ?? 0;
        }
      } catch (_) {}
    }
    await _writeMeta(
      key,
      url: url,
      title: title,
      bytes: bytes,
      totalBytes: totalBytes,
      createdAt: createdAt,
    );
  }

  Future<void> _writeMeta(
    String key, {
    required String url,
    required String title,
    required int bytes,
    required int totalBytes,
    required int createdAt,
  }) async {
    final meta = File('${_root.path}${Platform.pathSeparator}$key.json');
    try {
      await meta.writeAsString(
        jsonEncode(<String, dynamic>{
          'url': url,
          'title': title,
          'bytes': bytes,
          'totalBytes': totalBytes,
          'createdAt': createdAt,
          'lastUsedAt': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> _readMeta(String key) async {
    final file = File('${_root.path}${Platform.pathSeparator}$key.json');
    if (!await file.exists()) return null;
    try {
      final value = jsonDecode(await file.readAsString());
      return value is Map ? value.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  Future<int> _lastUsed(File file) async {
    final path = file.path;
    if (path.endsWith('.bin')) {
      final meta = File('${path.substring(0, path.length - 4)}.json');
      if (await meta.exists()) {
        try {
          final data = jsonDecode(await meta.readAsString());
          if (data is Map && data['lastUsedAt'] is int) {
            return data['lastUsedAt'] as int;
          }
        } catch (_) {}
      }
    }
    try {
      return (await file.lastModified()).millisecondsSinceEpoch;
    } catch (_) {
      return 0;
    }
  }

  static Future<int> _lengthOf(File file) async {
    try {
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  /// 删掉缓存文件，连它的元信息一起；`.part` 与 `.bin` 共用同一份元信息。
  Future<void> _delete(File file) async {
    final path = file.path;
    final String metaPath;
    if (path.endsWith('.part')) {
      metaPath = '${path.substring(0, path.length - 5)}.json';
    } else if (path.endsWith('.bin')) {
      metaPath = '${path.substring(0, path.length - 4)}.json';
    } else {
      metaPath = '$path.json';
    }
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
    try {
      final meta = File(metaPath);
      if (await meta.exists()) await meta.delete();
    } catch (_) {}
  }
}

class _ProxySource {
  const _ProxySource(this.url, this.headers);
  final String url;
  final Map<String, String> headers;
}

class _CacheFile {
  _CacheFile(this.file, this.length, this.lastUsed);
  final File file;
  final int length;
  final int lastUsed;
}
