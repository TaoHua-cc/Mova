import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../brand.dart';
import '../motion.dart';
import '../network/network_http_client.dart';
import '../platform/window_host.dart';
import '../version.dart';
import 'update_checker.dart';

/// 启动时 / 手动触发的新版本检查。
///
/// 行为分三种情况，和 [UpdateChecker] 的分层一一对应：
///
/// - **本地已知有更新的版本**：立刻弹窗提示，不等网络（断网也能提醒），
///   同时在后台按节流补一次网络查询，好发现更新的版本。
/// - **本地不知道或已知的版本已被更新**：这次真的要联网查，查完再决定。
/// - [manual] 为 true（用户点了「检查更新」）：无视节流强制查，并且**一定有反馈**
///   —— 已是最新、检查失败都会弹一条提示，不能点了没反应。
Future<void> checkMovaUpdate(
  BuildContext context, {
  bool manual = false,
}) async {
  if (_prompting) return;
  if (manual) {
    MovaToast.show(
      context,
      message: '正在检查新版本…',
      icon: YingjiIcons.cloud,
    );
  }
  if (!manual) {
    final cached = await UpdateChecker.cached();
    if (cached != null &&
        UpdateChecker.isNewer(cached) &&
        !await UpdateChecker.isSkipped(cached)) {
      if (!context.mounted) return;
      // 后台补一次查询（受节流限制），查到更新的版本会写进本地，
      // 下一次打开就会提示那个更新的版本 —— 不打断眼前这一次提示。
      unawaited(UpdateChecker.fetch());
      await _present(context, cached);
      return;
    }
  }
  final release = await UpdateChecker.fetch(force: manual);
  if (!context.mounted) return;
  if (release == null) {
    if (manual) {
      MovaToast.show(
        context,
        message: '检查更新失败，请检查网络后重试',
        icon: YingjiIcons.exclamationmark_triangle,
      );
    }
    return;
  }
  if (!UpdateChecker.isNewer(release)) {
    if (manual) {
      MovaToast.show(
        context,
        message: '已是最新版本 $movaVersion',
        icon: YingjiIcons.checkmark_circle_fill,
      );
    }
    return;
  }
  if (!manual && await UpdateChecker.isSkipped(release)) return;
  if (!context.mounted) return;
  await _present(context, release);
}

/// 同一时刻只允许一个更新弹窗（启动提示与手动检查可能碰在一起）。
bool _prompting = false;

Future<void> _present(
  BuildContext context,
  UpdateRelease release,
) async {
  if (_prompting) return;
  _prompting = true;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => MovaUpdateDialog(release: release),
    );
  } finally {
    _prompting = false;
  }
}

/// 更新弹窗：说明 + 下载进度 + 安装指引。
class MovaUpdateDialog extends StatefulWidget {
  const MovaUpdateDialog({super.key, required this.release});

  final UpdateRelease release;

  @override
  State<MovaUpdateDialog> createState() => _MovaUpdateDialogState();
}

enum _Stage { prompt, downloading, installing, permission, done, failed }

class _MovaUpdateDialogState extends State<MovaUpdateDialog>
    with WidgetsBindingObserver {
  late final UpdatePlan _plan = UpdateChecker.planFor(widget.release);

  _Stage _stage = _Stage.prompt;
  String _message = '';
  int _received = 0;
  int _total = 0;
  bool _cancelled = false;
  File? _downloaded;
  DateTime _lastProgressPaint = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从「安装未知应用」授权页回来后自动接着装 —— 否则用户点完授权还得
  /// 自己想起来再点一次「立即更新」。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_stage != _Stage.permission) return;
    unawaited(_installAndroid(_downloaded));
  }

  double? get _progress => _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;

  String get _progressLabel {
    final received = (_received / 1048576).toStringAsFixed(1);
    if (_total > 0) {
      return '$received MB / ${(_total / 1048576).toStringAsFixed(1)} MB'
          '  ·  ${(_progress! * 100).toStringAsFixed(0)}%';
    }
    return '$received MB';
  }

  // ── 动作 ──────────────────────────────────────────────────────────────

  Future<void> _start() async {
    if (!_plan.canDownload) {
      await WindowHost.openUrl(widget.release.pageUrl.toString());
      return;
    }
    _cancelled = false;
    setState(() {
      _stage = _Stage.downloading;
      _message = '';
      _received = 0;
      _total = _plan.size;
      _lastProgressPaint = DateTime.fromMillisecondsSinceEpoch(0);
    });
    final target = await _targetFile();
    if (target == null) {
      if (mounted) {
        setState(() {
          _stage = _Stage.failed;
          _message = '无法创建下载目录';
        });
      }
      return;
    }
    final ok = await _download(target);
    if (!mounted || _cancelled) return;
    if (!ok) {
      setState(() {
        _stage = _Stage.failed;
        _message = '下载失败，可能是网络中断';
      });
      return;
    }
    _downloaded = target;
    switch (_plan.kind) {
      case UpdateKind.windowsSetup:
        await _installWindowsSetup(target);
      case UpdateKind.windowsPortable:
        await _revealPortable(target);
      case UpdateKind.androidApk:
        await _installAndroid(target);
      case UpdateKind.pageOnly:
        await WindowHost.openUrl(widget.release.pageUrl.toString());
    }
  }

  Future<void> _cancel() async {
    setState(() {
      _cancelled = true;
      _stage = _Stage.prompt;
      _message = '已取消下载';
    });
  }

  Future<void> _skip() async {
    await UpdateChecker.skip(widget.release);
    if (mounted) Navigator.of(context).pop();
  }

  // ── 下载 ──────────────────────────────────────────────────────────────

  Future<File?> _targetFile() async {
    try {
      final Directory directory;
      if (Platform.isAndroid) {
        // 必须是应用缓存目录下的 update/：FileProvider 的 file_paths.xml
        // 只放开了这一个子目录，放到别处系统安装器读不到这个文件。
        final base = await getTemporaryDirectory();
        directory = Directory(
          '${base.path}${Platform.pathSeparator}update',
        );
      } else {
        final downloads = await getDownloadsDirectory();
        final base = downloads ?? Directory.systemTemp;
        directory = Directory(
          '${base.path}${Platform.pathSeparator}Mova-update',
        );
      }
      await directory.create(recursive: true);
      final file = File(
        '${directory.path}${Platform.pathSeparator}${_plan.name}',
      );
      if (await file.exists()) await file.delete();
      return file;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _download(File target) async {
    final client = createNetworkHttpClient();
    IOSink? sink;
    try {
      final request = http.Request('GET', _plan.url);
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) return false;
      if (_total <= 0) _total = response.contentLength ?? 0;
      final writer = target.openWrite();
      sink = writer;
      var received = 0;
      // 这里给的是**每块之间的**等待上限：整个文件很大，卡住的是「很久没有
      // 新数据」而不是总时长，所以用 stream 上的 timeout 而不是整趟的超时。
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        if (_cancelled) break;
        writer.add(chunk);
        received += chunk.length;
        _paintProgress(received);
      }
      await writer.flush();
      await writer.close();
      sink = null;
      if (_cancelled) {
        await target.delete();
        return false;
      }
      _received = received;
      return received > 0;
    } catch (_) {
      return false;
    } finally {
      try {
        await sink?.close();
      } catch (_) {
        // 上面已经处理过失败路径了。
      }
      client.close();
    }
  }

  /// 进度条按 60ms 一帧刷：每个数据块都 setState 会把大文件下载变成
  /// 一场没必要的重绘风暴。
  void _paintProgress(int received) {
    final now = DateTime.now();
    if (now.difference(_lastProgressPaint).inMilliseconds < 60) return;
    _lastProgressPaint = now;
    if (!mounted) return;
    setState(() => _received = received);
  }

  // ── 安装 ──────────────────────────────────────────────────────────────

  Future<void> _installWindowsSetup(File setup) async {
    if (!mounted) return;
    setState(() {
      _stage = _Stage.installing;
      _message = '正在安装更新，软件会自动重启…';
    });
    try {
      // 静默安装。安装器自己的 PrepareToInstall 会先 taskkill 掉 mova.exe
      // （installer/Mova.iss），所以这里不需要先退出；装完由 iss 里那条
      // `skipifnotsilent` 的 [Run] 重新拉起新版。
      await Process.start(
        setup.path,
        const [
          '/VERYSILENT',
          '/SUPPRESSMSGBOXES',
          '/NORESTART',
          '/CLOSEAPPLICATIONS',
        ],
        mode: ProcessStartMode.detached,
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _stage = _Stage.failed;
          _message = '无法启动安装程序：$error';
        });
      }
      return;
    }
    // 留一点时间让安装程序真的起来，再把自己结束掉，免得和它在文件替换上打架。
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    exit(0);
  }

  Future<void> _revealPortable(File archive) async {
    final revealed = await WindowHost.revealInFileManager(archive.path);
    if (!mounted) return;
    setState(() {
      _stage = _Stage.done;
      _message = revealed
          ? '免安装版已下载到 ${archive.parent.path}，解压后覆盖原来的文件夹即可。'
          : '免安装版已下载到 ${archive.path}，解压后覆盖原来的文件夹即可。';
    });
  }

  Future<void> _installAndroid(File? apk) async {
    if (apk == null) return;
    if (!await WindowHost.canInstallApk()) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.permission;
        _message = '系统要求先允许 Mova 安装应用：打开「允许安装未知应用」后返回，会自动继续。';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _stage = _Stage.installing;
      _message = '正在调起系统安装器…';
    });
    final launched = await WindowHost.installApk(apk.path);
    if (!mounted) return;
    if (launched) {
      setState(() {
        _stage = _Stage.done;
        _message = '已交给系统安装。装好后 Mova 会被系统关闭，重新打开即是新版本。';
      });
      return;
    }
    // 调不起安装器（个别 ROM 没有对应的 Activity）时退回浏览器下载。
    final opened = await WindowHost.openUrl(_plan.url.toString());
    if (!mounted) return;
    setState(() {
      _stage = _Stage.failed;
      _message = opened
          ? '无法调起系统安装器，已改用浏览器下载。'
          : '无法调起系统安装器，请到 Releases 页面手动下载。';
    });
    if (!opened) await WindowHost.openUrl(widget.release.pageUrl.toString());
  }

  // ── 界面 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final notes = widget.release.body.trim();
    return AlertDialog(
      title: Text(_title),
      content: SizedBox(
        width: math.max(
          240.0,
          math.min(468.0, MediaQuery.sizeOf(context).width - 88),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前版本 $movaVersion（$movaPlatform）'
              '${widget.release.publishedAt == null ? '' : '  ·  发布于 ${_date(widget.release.publishedAt!)}'}',
              style: const TextStyle(
                fontSize: 12.5,
                color: YingjiColors.muted,
              ),
            ),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 208),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: YingjiGlass.chrome(strength: .62),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: YingjiGlass.line()),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: SingleChildScrollView(
                      child: Text(
                        notes,
                        style: const TextStyle(
                          fontSize: 12.5,
                          height: 1.55,
                          color: YingjiColors.muted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            ..._status(),
          ],
        ),
      ),
      actions: _actions(),
    );
  }

  String get _title => switch (_stage) {
    _Stage.downloading => '正在下载 ${widget.release.version}',
    _Stage.installing => '正在安装 ${widget.release.version}',
    _Stage.permission => '需要授权',
    _Stage.done => '已准备好 ${widget.release.version}',
    _Stage.failed => '更新未完成',
    _Stage.prompt => '发现新版本 ${widget.release.version}',
  };

  List<Widget> _status() => switch (_stage) {
    _Stage.downloading => [
      LinearProgressIndicator(
        value: _progress,
        minHeight: 6,
        borderRadius: BorderRadius.circular(99),
        backgroundColor: YingjiGlass.chrome(strength: .5),
        color: YingjiGlass.accent,
      ),
      const SizedBox(height: 10),
      Text(
        _progressLabel,
        style: const TextStyle(fontSize: 12, color: YingjiColors.muted),
      ),
    ],
    _Stage.installing => [
      const LinearProgressIndicator(
        minHeight: 6,
        borderRadius: BorderRadius.all(Radius.circular(99)),
      ),
      const SizedBox(height: 10),
      Text(_message),
    ],
    _Stage.prompt => [
      Text(
        _plan.canDownload
            ? '将下载 ${_plan.name}'
                  '${_plan.sizeLabel.isEmpty ? '' : '（约 ${_plan.sizeLabel}）'}'
            : '这个平台没有可直接安装的包，点「立即更新」会打开发布页。',
        style: const TextStyle(fontSize: 12.5, color: YingjiColors.muted),
      ),
      if (_message.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(_message, style: const TextStyle(fontSize: 12.5)),
      ],
    ],
    _ => [Text(_message)],
  };

  List<Widget> _actions() {
    switch (_stage) {
      case _Stage.prompt:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('稍后'),
          ),
          TextButton(
            onPressed: () => unawaited(_skip()),
            child: const Text('跳过此版本'),
          ),
          FilledButton(
            onPressed: () => unawaited(_start()),
            child: Text(_plan.canDownload ? '立即更新' : '打开发布页'),
          ),
        ];
      case _Stage.downloading:
        return [
          TextButton(
            onPressed: () => unawaited(_cancel()),
            child: const Text('取消下载'),
          ),
        ];
      case _Stage.installing:
        return const [];
      case _Stage.permission:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => unawaited(WindowHost.requestInstallApk()),
            child: const Text('去授权'),
          ),
        ];
      case _Stage.done:
        return [
          TextButton(
            onPressed: () => unawaited(
              WindowHost.openUrl(widget.release.pageUrl.toString()),
            ),
            child: const Text('查看发布页'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成'),
          ),
        ];
      case _Stage.failed:
        return [
          TextButton(
            onPressed: () => unawaited(
              WindowHost.openUrl(widget.release.pageUrl.toString()),
            ),
            child: const Text('手动下载'),
          ),
          FilledButton(
            onPressed: () => unawaited(_start()),
            child: const Text('重试'),
          ),
        ];
    }
  }

  static String _date(DateTime value) {
    final local = value.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}'
        '-${local.day.toString().padLeft(2, '0')}';
  }
}
