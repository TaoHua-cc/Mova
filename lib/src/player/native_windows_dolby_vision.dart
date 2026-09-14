import 'dart:convert';
import 'dart:io';

import 'native_dolby_vision.dart';

/// Starts Mova's bundled WinUI 3 / Media Foundation player on Windows.
///
/// The request is sent over redirected stdin so authenticated media URLs never
/// appear in process arguments or temporary files.
class NativeWindowsDolbyVisionPlayer {
  NativeWindowsDolbyVisionPlayer._();

  static bool get isAvailablePlatform => Platform.isWindows;

  static Future<NativeDolbyVisionPlaybackResult> play({
    required String url,
    required String title,
    required Duration initialPosition,
    String? container,
  }) async {
    final executable = _findExecutable();
    if (executable == null) {
      throw const FileSystemException('Windows 原生 Dolby Vision 播放模块未安装');
    }

    final process = await Process.start(
      executable.path,
      const [],
      workingDirectory: executable.parent.path,
      mode: ProcessStartMode.normal,
    );
    process.stdin.writeln(
      jsonEncode({
        'url': url,
        'title': title,
        'positionMs': initialPosition.inMilliseconds,
        if (container != null) 'container': container,
        'expectedDolbyVision': true,
      }),
    );
    await process.stdin.close();

    final stdoutFuture = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.trim().isNotEmpty)
        .toList();
    // Drain stderr to avoid blocking, but never surface it because a platform
    // decoder may include the authenticated URL in diagnostic text.
    final stderrFuture = process.stderr.drain<void>();
    final exitCode = await process.exitCode;
    final lines = await stdoutFuture;
    await stderrFuture;
    if (lines.isEmpty) {
      throw ProcessException(
        executable.path,
        const [],
        '原生播放器未返回状态（退出码 $exitCode）',
        exitCode,
      );
    }
    final value = jsonDecode(lines.last);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('原生播放器返回了无效状态');
    }
    return NativeDolbyVisionPlaybackResult.fromMap(value);
  }

  static File? _findExecutable() {
    final appDirectory = File(Platform.resolvedExecutable).parent;
    final candidates = <File>[
      File(
        '${appDirectory.path}${Platform.pathSeparator}native_dv_player'
        '${Platform.pathSeparator}Mova.NativeDvPlayer.exe',
      ),
      // Makes `flutter run -d windows` usable after a local dotnet publish.
      File(
        '${Directory.current.path}${Platform.pathSeparator}windows'
        '${Platform.pathSeparator}native_dv_player${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}Release${Platform.pathSeparator}net8.0-windows10.0.19041.0'
        '${Platform.pathSeparator}win-x64${Platform.pathSeparator}publish'
        '${Platform.pathSeparator}Mova.NativeDvPlayer.exe',
      ),
    ];
    for (final candidate in candidates) {
      if (candidate.existsSync()) return candidate;
    }
    return null;
  }
}
