import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

import '../network/network_http_client.dart';
import '../network/proxy_routing.dart';
import '../platform/window_host.dart';

const int _kb = 1024;
const int _mb = 1024 * _kb;
const int _gb = 1024 * _mb;

// Temporary opt-in diagnostics: numeric counters only, never URLs or headers.
const _transferTraceEnabled = bool.fromEnvironment('MOVA_TRANSFER_TRACE');
int _transferTraceSequence = 0;

class _TransferTrace {
  _TransferTrace(this.phase, {this.file, this.initialBytes = 0}) {
    if (_transferTraceEnabled) {
      _clock.start();
      _timer = Timer.periodic(const Duration(seconds: 5), (_) => _report());
      debugPrint('MovaTransfer id=$id phase=$phase event=start');
    }
  }

  final String phase;
  final File? file;
  final int initialBytes;
  final int id = ++_transferTraceSequence;
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  bool _reporting = false;
  int bytes = 0;
  int readUs = 0;
  int deliveryUs = 0;
  int waitMs = 0;
  int reads = 0;

  Future<void> _report() async {
    if (!_transferTraceEnabled || _reporting) return;
    _reporting = true;
    try {
      final disk = file == null ? -1 : await file!.length();
      debugPrint(
        'MovaTransfer id=$id phase=$phase '
        'elapsedMs=${_clock.elapsedMilliseconds} bytes=$bytes '
        'readUs=$readUs deliveryUs=$deliveryUs waitMs=$waitMs '
        'diskBytes=$disk enqueuedBytes=${initialBytes + bytes} reads=$reads',
      );
    } on FileSystemException {
      debugPrint('MovaTransfer id=$id phase=$phase event=fileChanged');
    } finally {
      _reporting = false;
    }
  }

  void close() {
    _timer?.cancel();
    unawaited(_report());
  }
}

int cacheDownloadTargetBytes({
  required int retainLimitBytes,
  int? requestedBytes,
  int mediaTotalBytes = 0,
}) {
  if (retainLimitBytes <= 0) return 0;
  final requested = (requestedBytes ?? retainLimitBytes)
      .clamp(1, retainLimitBytes)
      .toInt();
  return mediaTotalBytes > 0 && mediaTotalBytes < requested
      ? mediaTotalBytes
      : requested;
}

int cacheChunkBytesToWrite({
  required int writtenBytes,
  required int targetBytes,
  required int chunkBytes,
}) => (targetBytes - writtenBytes).clamp(0, chunkBytes).toInt();

int videoCacheByteOffsetForPosition({
  required Duration position,
  required Duration duration,
  required int mediaTotalBytes,
}) {
  if (mediaTotalBytes <= 0 || duration <= Duration.zero) return 0;
  final ratio = (position.inMicroseconds / duration.inMicroseconds).clamp(
    0.0,
    1.0,
  );
  return (mediaTotalBytes * ratio)
      .floor()
      .clamp(0, mediaTotalBytes - 1)
      .toInt();
}

bool videoCacheShouldAdvanceWindow({
  required int playheadByte,
  required int windowStartByte,
  required int windowBytes,
}) => windowBytes > 0 && playheadByte >= windowStartByte + windowBytes ~/ 2;

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
  static const int nextEpisodePreheatBytes = 2 * _mb;

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
/// 「打断它」。打断时**保留**已下载的窗口分片，同一窗口下次可以续传。
class VideoCacheDownload {
  VideoCacheDownload._();

  final Completer<void> _completer = Completer<void>();
  final StreamController<VideoCacheProgress> _progressController =
      StreamController<VideoCacheProgress>.broadcast();
  VideoCacheProgress _state = const VideoCacheProgress();
  bool _cancelled = false;
  HttpClientRequest? _request;
  int? _redirectStartBytes;

  void _prioritize(int offset) {
    if (_cancelled || _completer.isCompleted || _redirectStartBytes != null) {
      return;
    }
    _redirectStartBytes = offset;
    _request?.abort();
  }

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
    this.startBytes = 0,
    this.supportsRange = true,
    this.status = VideoCacheStatus.idle,
  });

  final int receivedBytes;
  final int totalBytes;
  final int mediaTotalBytes;
  final int startBytes;
  final bool supportsRange;
  final VideoCacheStatus status;

  int get cachedEndBytes => startBytes + receivedBytes;

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

  @visibleForTesting
  factory VideoCacheStore.forDirectory(Directory root) =>
      VideoCacheStore._(root);

  static const String _folder = 'mova-video-cache';

  final Directory _root;
  HttpServer? _proxy;
  final Map<String, _ProxySource> _proxySources = <String, _ProxySource>{};
  final Map<String, VideoCacheDownload> _downloads = {};
  final Map<String, int> _playbackBytes = {};
  int playbackBytesRead(String url) => _playbackBytes[_keyFor(url)] ?? 0;
  final Map<String, String> _contentTypes = {};

  HttpClient _mediaClient(String? sourceId) =>
      HttpClient()
        ..findProxy = sourceId != null && ProxyRouting.serverUsesProxy(sourceId)
            ? findNetworkProxy
            : (_) => 'DIRECT';

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

  String _windowPath(String key) =>
      '${_root.path}${Platform.pathSeparator}$key.window.part';

  /// A loopback URL which gives mpv a single seekable stream backed by the
  /// persistent prefix on disk and the origin server for cache misses.
  Future<String> playbackUrl(
    String url, {
    Map<String, String> headers = const {},
    String? sourceId,
  }) async {
    final server = _proxy ??= await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    if (_proxySources.isEmpty) unawaited(_serveProxy(server));
    final key = _keyFor(url);
    _proxySources[key] = _ProxySource(url, headers, sourceId);
    return 'http://${server.address.address}:${server.port}/media/$key';
  }

  /// Only close a proxy owned by the finished playback session.
  Future<void> closePlaybackProxy() async {
    await _proxy?.close(force: true);
    _proxy = null;
    _proxySources.clear();
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
      final window = File(_windowPath(key));
      final windowMeta = await _readWindowMeta(key);
      final legacyPart = File('${_path(key)}.part');
      final legacyMeta = await _readMeta(key);
      final full = File(_path(key));
      final cachedRanges = <_CachedRange>[];
      if (await window.exists()) {
        cachedRanges.add(
          _CachedRange(
            window,
            await _lengthOf(window),
            (windowMeta?['startBytes'] as num?)?.toInt() ?? 0,
            (windowMeta?['totalBytes'] as num?)?.toInt() ?? 0,
          ),
        );
      }
      if (await legacyPart.exists()) {
        cachedRanges.add(
          _CachedRange(
            legacyPart,
            await _lengthOf(legacyPart),
            (legacyMeta?['startBytes'] as num?)?.toInt() ?? 0,
            (legacyMeta?['totalBytes'] as num?)?.toInt() ?? 0,
          ),
        );
      }
      if (await full.exists()) {
        cachedRanges.add(
          _CachedRange(
            full,
            await _lengthOf(full),
            0,
            (legacyMeta?['totalBytes'] as num?)?.toInt() ??
                await _lengthOf(full),
          ),
        );
      }
      final localRange = request.method == 'GET'
          ? _findCachedRange(cachedRanges, range)
          : null;
      final total =
          localRange?.totalBytes ??
          (windowMeta?['totalBytes'] as num?)?.toInt() ??
          (legacyMeta?['totalBytes'] as num?)?.toInt() ??
          0;
      final start = range?.$1 ?? 0;
      if (request.method == 'GET' &&
          await _serveSharedCache(request, key, source, range, cachedRanges)) {
        return;
      }
      // A growing prefix is not a complete HTTP response. Returning `0-N` for
      // an open-ended `bytes=0-` request makes mpv treat the current end of the
      // .part file as end-of-media while the downloader is still appending.
      // Only answer from the partial file when it fully covers a bounded range;
      // otherwise let the origin provide one continuous response.
      if (localRange != null) {
        final end = range!.$2!;
        final length = end - start + 1;
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${total > 0 ? total : '*'}',
        );
        request.response.contentLength = length;
        final localStart = start - localRange.startBytes;
        await request.response.addStream(
          localRange.file.openRead(localStart, localStart + length).map((
            block,
          ) {
            _playbackBytes[key] = (_playbackBytes[key] ?? 0) + block.length;
            return block;
          }),
        );
        await request.response.close();
        return;
      }

      // 源站这一步正是「卡顿之后跳下一集」「跳转之后播放失败」的来源：一次瞬时
      // 抖动就让 mpv 收到错误码，把当前集判成结束。自动跳片头/片尾会让播放器去
      // 要一段新的字节区间（新建连接），撞上抖动的概率比顺放时高得多。响应头还
      // 没写出去之前可以放心重试，代价只是几次建连；一旦把错误码写给 mpv，它就
      // 直接 end-file 了，后面再怎么补救都晚了一步。
      //
      // 408（请求超时）/ 429（限流）与 5xx 一样属于「等一会儿再来」的瞬时故障，
      // 一并重试；403/404 这类多半是 URL 过期或资源没了，重试没有意义，直接透传。
      const int attemptLimit = 3;
      bool transient(int status) =>
          status >= 500 || status == 408 || status == 429;
      HttpClientResponse? origin;
      for (
        var attempt = 0;
        attempt < attemptLimit && origin == null;
        attempt++
      ) {
        final probe = _mediaClient(source.sourceId);
        try {
          final opened = await probe.openUrl(
            request.method,
            Uri.parse(source.url),
          );
          for (final entry in source.headers.entries) {
            opened.headers.set(entry.key, entry.value);
          }
          final incomingRange = request.headers.value(HttpHeaders.rangeHeader);
          if (incomingRange != null) {
            opened.headers.set(HttpHeaders.rangeHeader, incomingRange);
          }
          final response = await opened.close();
          if (transient(response.statusCode) && attempt < attemptLimit - 1) {
            await response.drain<void>();
            probe.close(force: true);
            await Future<void>.delayed(
              Duration(milliseconds: 300 * (attempt + 1)),
            );
            continue;
          }
          origin = response;
          client = probe;
        } catch (_) {
          probe.close(force: true);
          if (attempt < attemptLimit - 1) {
            await Future<void>.delayed(
              Duration(milliseconds: 300 * (attempt + 1)),
            );
          }
        }
      }
      if (origin == null) {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
        return;
      }
      request.response.statusCode = origin.statusCode;
      for (final name in <String>[
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.etagHeader,
        HttpHeaders.lastModifiedHeader,
      ]) {
        final value = origin.headers.value(name);
        if (value != null) request.response.headers.set(name, value);
      }
      if (origin.contentLength >= 0) {
        request.response.contentLength = origin.contentLength;
      }
      if (request.method != 'HEAD') {
        final trace = _TransferTrace('originProxy');
        try {
          await request.response.addStream(
            origin.map((chunk) {
              trace.bytes += chunk.length;
              _playbackBytes[key] = (_playbackBytes[key] ?? 0) + chunk.length;
              return chunk;
            }),
          );
        } finally {
          trace.close();
        }
      }
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

  /// Read the downloader's growing file rather than opening a second origin
  /// response. The HTTP response still describes the whole requested range.
  /// Once the retained window ends, the origin supplies only the missing tail.
  Future<bool> _serveSharedCache(
    HttpRequest request,
    String key,
    _ProxySource source,
    (int, int?)? range,
    List<_CachedRange> cached,
  ) async {
    final start = range?.$1 ?? 0;
    var job = _downloads[key];
    final metadataDeadline = DateTime.now().add(const Duration(seconds: 30));
    while (job != null &&
        !job.isCancelled &&
        !job._completer.isCompleted &&
        (job.state.mediaTotalBytes <= 0 || job.state.totalBytes <= 0) &&
        DateTime.now().isBefore(metadataDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      job = _downloads[key];
    }
    final total = (job?.state.mediaTotalBytes ?? 0) > 0
        ? job!.state.mediaTotalBytes
        : (cached.isEmpty ? 0 : cached.first.totalBytes);
    if (range != null &&
        range.$2 == null &&
        start > 0 &&
        start < total - _mb &&
        job != null &&
        (start < job.state.startBytes ||
            start > job.state.startBytes + job.state.receivedBytes + _mb)) {
      job._prioritize(start);
    }
    final cachedStart = cached.any(
      (row) => start >= row.startBytes && start < row.startBytes + row.bytes,
    );
    final downloadingStart =
        job != null &&
        !job.isCancelled &&
        job.state.totalBytes > 0 &&
        (job._redirectStartBytes == start ||
            (start >= job.state.startBytes &&
                start < job.state.startBytes + job.state.totalBytes));
    if (total <= start || (!cachedStart && !downloadingStart)) return false;
    final end = (range?.$2 ?? total - 1).clamp(start, total - 1);
    request.response.statusCode = range == null
        ? HttpStatus.ok
        : HttpStatus.partialContent;
    request.response.contentLength = end - start + 1;
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers.set(
      HttpHeaders.contentTypeHeader,
      _contentTypes[key] ?? 'application/octet-stream',
    );
    if (range != null) {
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$total',
      );
    }
    var offset = start;
    var stalledSince = DateTime.now();
    final trace = _TransferTrace('cacheProxy');
    RandomAccessFile? cachedInput;
    String? inputPath;
    int? inputStart;
    VideoCacheDownload? inputJob;
    try {
      while (offset <= end) {
        job = _downloads[key];
        final candidates = <_CachedRange>[
          if (job != null)
            _CachedRange(
              File(_windowPath(key)),
              0,
              job.state.startBytes,
              total,
            ),
          ...cached.where(
            (row) => job == null || row.file.path != _windowPath(key),
          ),
          _CachedRange(File(_path(key)), 0, 0, total),
        ];
        Uint8List? block;
        for (final candidate in candidates) {
          if (offset < candidate.startBytes) continue;
          final readClock = Stopwatch()..start();
          try {
            // Keep the descriptor while this response reads the same window.
            // Android async open/close per tiny growing block is expensive.
            if (cachedInput == null ||
                inputPath != candidate.file.path ||
                inputStart != candidate.startBytes ||
                (candidate.file.path == _windowPath(key) && inputJob != job)) {
              await cachedInput?.close();
              cachedInput = null;
              cachedInput = await candidate.file.open();
              inputPath = candidate.file.path;
              inputStart = candidate.startBytes;
              inputJob = job;
            }
            final input = cachedInput;
            final localOffset = offset - candidate.startBytes;
            final available = await input.length() - localOffset;
            // Coalesce small writer chunks on Android, but bound the added
            // latency for slow sources and short metadata requests.
            if (Platform.isAndroid &&
                available < 256 * _kb &&
                end - offset + 1 > 256 * _kb &&
                candidate.file.path == _windowPath(key) &&
                job != null &&
                !job._completer.isCompleted &&
                !job.isCancelled &&
                DateTime.now().difference(stalledSince).inMilliseconds < 200) {
              break;
            }
            if (available <= 0 &&
                candidate.file.path == _windowPath(key) &&
                job != null &&
                !job._completer.isCompleted &&
                !job.isCancelled) {
              // No other candidate can cover this still-growing window yet.
              break;
            }
            if (available <= 0) continue;
            await input.setPosition(localOffset);
            block = await input.read(
              (end - offset + 1).clamp(0, available).clamp(0, 512 * _kb),
            );
            trace.reads++;
            if (candidate.file.path == _windowPath(key) &&
                (_downloads[key] != job ||
                    (job != null &&
                        job.state.startBytes != candidate.startBytes))) {
              block = null;
              continue;
            }
            if (block.isNotEmpty) break;
          } on FileSystemException {
            // A window may have been replaced between selecting and opening it.
            try {
              await cachedInput?.close();
            } catch (_) {}
            cachedInput = null;
          } finally {
            // Windows prevents the downloader renaming an open cache file.
            if (Platform.isWindows) {
              await cachedInput?.close();
              cachedInput = null;
            }
            trace.readUs += readClock.elapsedMicroseconds;
          }
        }
        if (block != null && block.isNotEmpty) {
          request.response.add(block);
          _playbackBytes[key] = (_playbackBytes[key] ?? 0) + block.length;
          final deliveryClock = Stopwatch()..start();
          await request.response.flush();
          trace.deliveryUs += deliveryClock.elapsedMicroseconds;
          trace.bytes += block.length;
          offset += block.length;
          stalledSince = DateTime.now();
          continue;
        }
        if (_downloads[key] != job) continue;
        final stillDownloading =
            job != null &&
            !job.isCancelled &&
            !job._completer.isCompleted &&
            (job._redirectStartBytes != null ||
                job.state.totalBytes <= 0 ||
                (offset >= job.state.startBytes &&
                    offset < job.state.startBytes + job.state.totalBytes));
        if (stillDownloading &&
            DateTime.now().difference(stalledSince) <
                const Duration(seconds: 30)) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          trace.waitMs += 25;
          continue;
        }
        final client = _mediaClient(source.sourceId);
        final tailTrace = _TransferTrace('originTail');
        try {
          final tail = await client
              .getUrl(Uri.parse(source.url))
              .timeout(const Duration(seconds: 20));
          source.headers.forEach(tail.headers.set);
          tail.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-$end');
          final response = await tail.close().timeout(
            const Duration(seconds: 30),
          );
          final partial = response.statusCode == HttpStatus.partialContent;
          if ((!partial && response.statusCode != HttpStatus.ok) ||
              (partial &&
                  _contentRangeStart(
                        response.headers.value(HttpHeaders.contentRangeHeader),
                      ) !=
                      offset)) {
            throw const HttpException('Playback cache tail unavailable');
          }
          var skip = partial ? 0 : offset;
          var remaining = end - offset + 1;
          await for (final chunk in response) {
            if (skip >= chunk.length) {
              skip -= chunk.length;
              continue;
            }
            final count = (chunk.length - skip).clamp(0, remaining);
            request.response.add(chunk.sublist(skip, skip + count));
            _playbackBytes[key] = (_playbackBytes[key] ?? 0) + count;
            final deliveryClock = Stopwatch()..start();
            await request.response.flush();
            tailTrace.deliveryUs += deliveryClock.elapsedMicroseconds;
            tailTrace.bytes += count;
            trace.bytes += count;
            skip = 0;
            remaining -= count;
            if (remaining == 0) break;
          }
          if (remaining != 0) {
            throw const HttpException('Playback cache tail ended early');
          }
          offset = end + 1;
        } finally {
          tailTrace.close();
          client.close(force: true);
        }
      }
      await request.response.close();
      return true;
    } finally {
      trace.close();
      await cachedInput?.close();
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

  /// 删除一个剧集的旧完整缓存、旧前缀以及当前滚动窗口。
  Future<void> deleteEpisode(String url) async {
    final key = _keyFor(url);
    for (final path in <String>[
      _path(key),
      '${_path(key)}.part',
      _windowPath(key),
      '${_root.path}${Platform.pathSeparator}$key.json',
      _windowMetaPath(key),
    ]) {
      await _delete(File(path));
    }
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

  /// 后台缓存从当前位置向前的有界窗口。调用方在播放消耗约一半窗口后，
  /// 取消本任务并以新的播放字节位置发起下一窗口。
  VideoCacheDownload download({
    required String url,
    required int limitBytes,
    int? targetBytes,
    int? startBytes,
    Duration startPosition = Duration.zero,
    Duration mediaDuration = Duration.zero,
    Map<String, String> headers = const {},
    String? sourceId,
    String title = '',
  }) {
    final job = VideoCacheDownload._();
    if (limitBytes <= 0) {
      job._completer.complete();
      return job;
    }
    _downloads[_keyFor(url)] = job;
    unawaited(
      _run(
        job,
        url: url,
        limitBytes: limitBytes,
        targetBytes: targetBytes,
        startBytes: startBytes,
        startPosition: startPosition,
        mediaDuration: mediaDuration,
        headers: headers,
        sourceId: sourceId,
        title: title,
      ),
    );
    return job;
  }

  Future<void> _run(
    VideoCacheDownload job, {
    required String url,
    required int limitBytes,
    required int? targetBytes,
    required int? startBytes,
    required Duration startPosition,
    required Duration mediaDuration,
    required Map<String, String> headers,
    required String? sourceId,
    required String title,
  }) async {
    var nextStart = startBytes;
    try {
      do {
        job._redirectStartBytes = null;
        await _runWindow(
          job,
          url: url,
          limitBytes: limitBytes,
          targetBytes: targetBytes,
          startBytes: nextStart,
          startPosition: startPosition,
          mediaDuration: mediaDuration,
          headers: headers,
          sourceId: sourceId,
          title: title,
        );
        nextStart = job._redirectStartBytes;
      } while (nextStart != null && !job._cancelled);
    } finally {
      if (!job._completer.isCompleted) job._completer.complete();
      await job._progressController.close();
    }
  }

  Future<void> _runWindow(
    VideoCacheDownload job, {
    required String url,
    required int limitBytes,
    required int? targetBytes,
    required int? startBytes,
    required Duration startPosition,
    required Duration mediaDuration,
    required Map<String, String> headers,
    required String? sourceId,
    required String title,
  }) async {
    HttpClient? client;
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return;
      }
      final key = _keyFor(url);
      final target = File(_path(key));
      if (await target.exists()) {
        final size = await _lengthOf(target);
        job._update(
          VideoCacheProgress(
            receivedBytes: size,
            totalBytes: size,
            mediaTotalBytes: size,
            status: VideoCacheStatus.complete,
          ),
        );
        return;
      }
      final part = File(_windowPath(key));
      final windowMeta = await _readWindowMeta(key);
      var windowStart = startBytes ?? 0;
      var supportsRange = true;
      var mediaTotalBytes = (windowMeta?['totalBytes'] as num?)?.toInt() ?? 0;
      if (startBytes == null &&
          startPosition > Duration.zero &&
          mediaDuration > Duration.zero) {
        mediaTotalBytes = await _probeMediaTotal(uri, headers, sourceId);
        if (job._cancelled) return;
        windowStart = videoCacheByteOffsetForPosition(
          position: startPosition,
          duration: mediaDuration,
          mediaTotalBytes: mediaTotalBytes,
        );
      }
      var offset = 0;
      if (await part.exists() &&
          (windowMeta?['startBytes'] as num?)?.toInt() == windowStart) {
        offset = await _lengthOf(part);
      } else {
        await _delete(part);
      }
      job._update(
        VideoCacheProgress(
          receivedBytes: offset,
          mediaTotalBytes: mediaTotalBytes,
          startBytes: windowStart,
          status: VideoCacheStatus.downloading,
        ),
      );
      client = _mediaClient(sourceId);
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      if (job._cancelled || job._redirectStartBytes != null) return;
      job._request = request;
      if (job._redirectStartBytes != null) return;
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      final requestStart = windowStart + offset;
      if (requestStart > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$requestStart-');
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
      // 服务端忽略 Range 时回到从头开始的有界窗口，不能把片头字节误记成
      // 非零播放位置处的缓存。
      if (response.statusCode == 200 && requestStart > 0) {
        windowStart = 0;
        offset = 0;
        supportsRange = false;
        await _delete(part);
      }
      final responseStart = _contentRangeStart(
        response.headers.value(HttpHeaders.contentRangeHeader),
      );
      if (response.statusCode == 206 &&
          responseStart != null &&
          responseStart != requestStart) {
        await _delete(part);
        return;
      }
      final remaining = response.contentLength;
      final contentType = response.headers.value(HttpHeaders.contentTypeHeader);
      if (contentType != null) _contentTypes[key] = contentType;
      final total =
          _contentRangeTotal(
            response.headers.value(HttpHeaders.contentRangeHeader),
          ) ??
          (remaining > 0
              ? (response.statusCode == HttpStatus.partialContent
                    ? requestStart + remaining
                    : remaining)
              : mediaTotalBytes);
      mediaTotalBytes = total;
      final downloadTargetBytes = cacheDownloadTargetBytes(
        retainLimitBytes: limitBytes,
        requestedBytes: targetBytes,
        mediaTotalBytes: total > 0 ? total - windowStart : 0,
      );
      await _writeWindowMeta(
        key,
        title: title,
        bytes: offset,
        totalBytes: total,
        startBytes: windowStart,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      if (offset >= downloadTargetBytes) {
        final fullMedia = windowStart == 0 && total > 0 && offset >= total;
        job._update(
          VideoCacheProgress(
            receivedBytes: offset,
            totalBytes: downloadTargetBytes,
            mediaTotalBytes: total,
            startBytes: windowStart,
            supportsRange: supportsRange,
            status: fullMedia
                ? VideoCacheStatus.complete
                : VideoCacheStatus.buffered,
          ),
        );
        return;
      }
      var completed = false;
      job._update(
        VideoCacheProgress(
          receivedBytes: offset,
          totalBytes: downloadTargetBytes,
          mediaTotalBytes: total,
          startBytes: windowStart,
          supportsRange: supportsRange,
          status: VideoCacheStatus.downloading,
        ),
      );
      final sink = part.openWrite(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      final trace = _TransferTrace(
        'originCache',
        file: part,
        initialBytes: offset,
      );
      try {
        var written = offset;
        var lastReported = offset;
        await for (final chunk in response) {
          if (job._cancelled || job._redirectStartBytes != null) break;
          final bytesToWrite = cacheChunkBytesToWrite(
            writtenBytes: written,
            targetBytes: downloadTargetBytes,
            chunkBytes: chunk.length,
          );
          if (bytesToWrite <= 0) break;
          sink.add(
            bytesToWrite == chunk.length
                ? chunk
                : chunk.sublist(0, bytesToWrite),
          );
          written += bytesToWrite;
          trace.bytes += bytesToWrite;
          if (written - lastReported >= _mb) {
            lastReported = written;
            job._update(
              VideoCacheProgress(
                receivedBytes: written,
                totalBytes: downloadTargetBytes,
                mediaTotalBytes: total,
                startBytes: windowStart,
                supportsRange: supportsRange,
                status: VideoCacheStatus.downloading,
              ),
            );
          }
          if (written >= downloadTargetBytes) {
            break;
          }
        }
        await sink.flush();
        completed =
            !job._cancelled &&
            windowStart == 0 &&
            total > 0 &&
            written >= total;
      } catch (_) {
        // 网络中断或被打断：分片留在磁盘上，下次续传。
        completed = false;
      } finally {
        try {
          await sink.close();
        } catch (_) {}
        trace.close();
      }
      final size = await _lengthOf(part);
      if (size <= 0) {
        await _delete(part);
        return;
      }
      if (completed) {
        await part.rename(target.path);
        await _deleteWindowMeta(key);
        await _writeMeta(
          key,
          url: url,
          title: title,
          bytes: size,
          totalBytes: total,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
      } else {
        await _writeWindowMeta(
          key,
          title: title,
          bytes: size,
          totalBytes: total,
          startBytes: windowStart,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
      }
      job._update(
        VideoCacheProgress(
          receivedBytes: size,
          totalBytes: completed ? size : downloadTargetBytes,
          mediaTotalBytes: total,
          startBytes: windowStart,
          supportsRange: supportsRange,
          status: completed
              ? VideoCacheStatus.complete
              : VideoCacheStatus.buffered,
        ),
      );
      await prune(limitBytes);
    } catch (_) {
      // 缓存失败不影响播放，但向播放器暴露真实状态。
      if (job._redirectStartBytes == null) {
        job._update(
          VideoCacheProgress(
            receivedBytes: job.state.receivedBytes,
            totalBytes: job.state.totalBytes,
            mediaTotalBytes: job.state.mediaTotalBytes,
            startBytes: job.state.startBytes,
            supportsRange: job.state.supportsRange,
            status: VideoCacheStatus.unavailable,
          ),
        );
      }
    } finally {
      client?.close(force: true);
      job._request = null;
    }
  }

  Future<int> _probeMediaTotal(
    Uri uri,
    Map<String, String> headers,
    String? sourceId,
  ) async {
    final client = _mediaClient(sourceId);
    try {
      final head = await client
          .openUrl('HEAD', uri)
          .timeout(const Duration(seconds: 12));
      for (final entry in headers.entries) {
        head.headers.set(entry.key, entry.value);
      }
      final response = await head.close().timeout(const Duration(seconds: 20));
      final total = response.statusCode >= 200 && response.statusCode < 300
          ? _contentRangeTotal(
                  response.headers.value(HttpHeaders.contentRangeHeader),
                ) ??
                (response.contentLength > 0 ? response.contentLength : 0)
          : 0;
      if (total > 0) return total;
    } catch (_) {
      // Some media servers do not implement HEAD; probe one ranged byte below.
    } finally {
      client.close(force: true);
    }

    final probe = _mediaClient(sourceId);
    try {
      final request = await probe
          .getUrl(uri)
          .timeout(const Duration(seconds: 12));
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        return 0;
      }
      final rangeTotal = _contentRangeTotal(
        response.headers.value(HttpHeaders.contentRangeHeader),
      );
      if (rangeTotal != null) return rangeTotal;
      return response.statusCode == HttpStatus.ok && response.contentLength > 0
          ? response.contentLength
          : 0;
    } catch (_) {
      return 0;
    } finally {
      probe.close(force: true);
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

  String _windowMetaPath(String key) =>
      '${_root.path}${Platform.pathSeparator}$key.window.json';

  Future<void> _writeWindowMeta(
    String key, {
    required String title,
    required int bytes,
    required int totalBytes,
    required int startBytes,
    required int createdAt,
  }) async {
    try {
      await File(_windowMetaPath(key)).writeAsString(
        jsonEncode(<String, dynamic>{
          'title': title,
          'bytes': bytes,
          'totalBytes': totalBytes,
          'startBytes': startBytes,
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

  Future<Map<String, dynamic>?> _readWindowMeta(String key) async {
    final file = File(_windowMetaPath(key));
    if (!await file.exists()) return null;
    try {
      final value = jsonDecode(await file.readAsString());
      return value is Map ? value.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteWindowMeta(String key) async {
    try {
      final file = File(_windowMetaPath(key));
      if (await file.exists()) await file.delete();
    } catch (_) {}
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

bool videoCacheCoversRange({
  required int cachedBytes,
  int startBytes = 0,
  required (int, int?)? range,
}) {
  final start = range?.$1;
  final end = range?.$2;
  return start != null &&
      end != null &&
      start >= startBytes &&
      end < startBytes + cachedBytes;
}

_CachedRange? _findCachedRange(
  List<_CachedRange> ranges,
  (int, int?)? requested,
) {
  for (final candidate in ranges) {
    if (videoCacheCoversRange(
      cachedBytes: candidate.bytes,
      startBytes: candidate.startBytes,
      range: requested,
    )) {
      return candidate;
    }
  }
  return null;
}

int? _contentRangeStart(String? value) {
  final match = RegExp(r'^bytes\s+(\d+)-\d+/(?:\d+|\*)$')
      .firstMatch(value?.trim() ?? '');
  return int.tryParse(match?.group(1) ?? '');
}

int? _contentRangeTotal(String? value) {
  final match = RegExp(r'^bytes\s+\d+-\d+/(\d+)$')
      .firstMatch(value?.trim() ?? '');
  return int.tryParse(match?.group(1) ?? '');
}

class _ProxySource {
  const _ProxySource(this.url, this.headers, this.sourceId);
  final String url;
  final Map<String, String> headers;
  final String? sourceId;
}

class _CacheFile {
  _CacheFile(this.file, this.length, this.lastUsed);
  final File file;
  final int length;
  final int lastUsed;
}

class _CachedRange {
  const _CachedRange(this.file, this.bytes, this.startBytes, this.totalBytes);

  final File file;
  final int bytes;
  final int startBytes;
  final int totalBytes;
}
