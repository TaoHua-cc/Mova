# Windows 播放中断脱敏诊断

- 日期：2026-10-10
- 状态：实现中
- 平台：仅 Windows；不改变 Android、取流、重试或解码策略。
- 基线：播放器仍在运行，黑屏停在 1:38/40:07；现有结束协议未保存，stderr 被丢弃，不能确定网络根因。历史崩溃另案，不混为同一次中断。

## 方案与隐私

订阅 libmpv warning/error 日志，只输出固定错误分类及合法 HTTP 状态码，不输出原文、URL、媒体标题或鉴权。Flutter 仅接收严格白名单数字协议，记录本机临时目录 `mova-playback-diagnostic.log`；每次启动播放覆盖上一会话，最多 256 条。写入失败不影响播放，不上传。

## 验收与回滚

- 测试凭据及任意尾随文字不能进入日志。
- 构建 Windows，正常退出后覆盖 exe/data，保留用户数据。
- 复现同资源，读取 END_FILE、重试、错误分类；未复现前不宣称已确定或修复根因。
- 无 UI 改动；Android 不部署。撤销本次日志代码即可回滚，无持久化迁移。
- 长测、实际复现与正式上架验收待完成；本次不提交、不发布。

## 实现与验证记录

### 第二轮定位

- 第一轮实际日志：切到索引 4 后，在 43/2831.859 秒发生提前 EOF（error=0），一次重试后仍提前 EOF 并 FAILED。不是进程崩溃；尚不能确定源站根因。
- 同资源独立小 Range：无 UA / 测试 Lavf 身份出现 403；libmpv 与 Dart 测试身份均有正常 206。不能将身份差异当已确认根因。
- 同资源有 32 MiB 缓存前缀；本机桥跨此前缀的 64 KiB Range 读取完整，直接起播未再次记录 EOF。短测不能排除长流或间歇性断流。
- 第二轮只增加 native 路由标志与缓存补流 begin/status/end/io/timeout 数字事件；缓存回调仅 Windows 播放会话绑定，Android 默认未绑定，无行为修改。
- 第二轮验证：脱敏白名单、缓存实际日志成功/失败输出与原有取流测试共 16 项通过；针对性 analyze 无 error/warning，2 项既有 info；diff check 通过。Windows release 构建成功。全量测试、Android 构建与长测未执行，实际复现待用户操作。
- 第二轮部署：用户正常退出后覆盖 D:/Mova，原生 exe、app.so、受校验 libmpv DLL 均与构建哈希一致；保留数据，安卓不部署，未提交或发布。

- 已修改：原生订阅 warning/error，仅固定分类输出，连续相同分类合并；Flutter 保存白名单结束/重试/失败协议。原始 stderr 仍丢弃，无后台上传。
- 已测试：`playback_diagnostic_test.dart` 与 `windows_native_transfer_test.dart` 共 6 项通过；针对性 Dart analyze 无错误/警告，有 2 项既有括号风格 info；diff check 通过。
- 已构建：Windows release 成功；初次 C++ 字符转换告警已修正后重建通过。
- 已部署：用户正常退出后覆盖 `D:/Mova` exe/data/libmpv，原生 exe 与 app.so 哈希和构建一致；执行受校验 gpu-next DLL 安装脚本，保留用户数据。Android 未改动、未构建、未部署。
- 未完成：同一资源实际复现、日志根因判定、30/60 分钟长测及全量测试。不能称播放中断已修复；近期原生崩溃仍是独立未关闭风险。
