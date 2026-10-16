import 'dart:io';

import 'package:yingji/src/player/native_launch_arguments.dart';

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('mova-launch-check-');
  Process? process;
  try {
    final file = File('${directory.path}/arguments.txt');
    final args = [
      '--config=no',
      '--vo=null',
      '--ao=null',
      '--idle=yes',
      ...List.generate(1000, (i) => '--mova-playlist-title=测试第 $i 集'),
    ];
    final payload = encodeNativeLaunchArguments(args);
    if (payload.length <= 32767) {
      throw StateError('Probe must exceed old limit');
    }
    await file.writeAsString(payload, flush: true);
    process = await Process.start(
      'build/windows/x64/runner/Release/MovaNativePlayer.exe',
      ['--mova-args-file=${file.path}'],
    );
    process.stdout.drain<void>();
    process.stderr.drain<void>();
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (await file.exists() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (await file.exists()) {
      throw StateError('Native argument file was not consumed');
    }
    stdout.writeln(
      'Native consumed >32K Unicode arguments; payload file removed.',
    );
  } finally {
    process?.kill();
    if (process != null) await process.exitCode;
    await directory.delete(recursive: true);
  }
}
