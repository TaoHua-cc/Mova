import 'dart:io';

/// One percent-encoded UTF-8 argument per line; preserves empty values/newlines.
String encodeNativeLaunchArguments(List<String> arguments) =>
    'MOVA_ARGS_V1\n${arguments.map(Uri.encodeComponent).join('\n')}\n';

String nativeLaunchFailure(ProcessException error) =>
    '无法启动原生播放器（系统错误 ${error.errorCode}），请重试或重新安装。';
