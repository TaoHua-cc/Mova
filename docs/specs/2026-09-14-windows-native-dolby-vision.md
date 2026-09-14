# Windows 原生 Dolby Vision 播放

## 基本信息

- 标题：Windows 原生 Dolby Vision 双引擎播放
- 日期：2026-09-14
- 状态：已搁置（被 Windows 单引擎稳定 DV 方案取代）
- 影响平台：Windows（Android 原生路径保持不变）
- 关联 Issue、提交或版本：待提交

## 背景与问题

Mova 的 Windows 播放器当前使用 libmpv 与 Flutter 纹理输出。该链路可以解码部分 Dolby Vision 片源或回退为 HDR10/SDR，但不能保证把 Dolby Vision 动态元数据交给 Windows 的认证显示链路，因此不能作为 Windows 原生 Dolby Vision 输出路径。

## 目标

- Windows 中标记为 Dolby Vision 的资源优先使用系统 `MediaPlayerElement` / Media Foundation 播放。
- 原生播放器随官网/GitHub 的安装包和便携包分发，不依赖 Microsoft Store 上架。
- 原生模块不可用或打开失败时，明确提示并回退到现有兼容播放器。
- 播放结束后把进度和完成状态返回 Mova。
- 播放地址和认证信息不进入命令行、临时文件或日志。

## 非目标

- 不内置、破解或再分发 Dolby 专有解码器及许可证。
- 不承诺未认证的 GPU、驱动、显示器或线缆能够进入 Dolby Vision 模式。
- 第一阶段不在原生窗口中复刻弹幕、自定义字幕样式、剧集切换和 mpv 滤镜。
- 不把 Profile 7 双层 FEL/MEL 的 MKV 兼容性表述为系统保证；优先支持 Windows 解码器可接受的 MP4 Profile 5/8。

## 用户流程与界面

1. 用户从详情页播放服务端标记为 DV/DOVI/Dolby Vision 的资源。
2. Windows 启动随 Mova 安装的原生播放器窗口，并从上次进度开始播放。
3. 关闭窗口或播放结束后，Mova 保存返回的播放进度。
4. 若模块缺失、系统拒绝媒体或播放失败，Mova 显示原因并自动进入现有播放器。

原生窗口使用 Windows 标准媒体控制，支持键盘、鼠标和触控。显示器是否真正切换为 Dolby Vision，以 Windows/显示器的状态提示为最终依据。

## 数据与接口

- 输入：媒体 URL、标题、起播毫秒数、容器类型、DV 预期标记。
- 输出：当前位置、时长、是否播完、是否成功进入 Windows 原生媒体管线、错误信息。
- 数据来源：现有 `MediaItem`，不新增服务端请求。
- 新增/修改字段：无持久化模型变化。
- 持久化键或缓存格式：沿用 `WatchStateStore`。
- 网络接口、超时与错误处理：系统播放器直接打开现有播放 URL；失败即回退 libmpv。
- 隐私与敏感信息：Dart 与原生播放器通过重定向标准输入/输出传递一行 JSON；URL 不放入启动参数、不落盘，错误输出不得包含 URL 或请求头。

## 技术方案

- 新增 unpackaged、自包含的 WinUI 3 辅助程序 `windows/native_dv_player/`，使用 `MediaPlayerElement`。
- 新增 Dart Windows 桥接层，定位随包分发的 EXE、管理生命周期并解析结果。
- 详情页只对 Windows 且服务端明确标记为 DV 的资源启用原生路径；Android 继续使用既有 Media3 路径。
- GitHub Actions 和本地发布脚本先构建 Flutter，再发布 WinUI 辅助程序并复制到 Release 目录，Inno Setup 现有递归规则会自动收录。

未选择把 libmpv 的纹理输出改造成 DV 路径，因为公开 DXGI HDR 元数据接口不提供完整 Dolby Vision RPU 注入能力。未选择跳转系统“媒体播放器”应用，因为无法形成内置体验和可靠回传进度。

## 兼容与迁移

- 旧版本数据是否可继续读取：是，无格式变化。
- Windows / Android 差异：Windows 使用 WinUI 3/Media Foundation；Android 使用 Media3/MediaCodec。
- 回滚后是否安全：是，删除 Windows 路由与辅助程序即可恢复 libmpv。
- 是否需要迁移、清理或功能开关：不需要。

## 验收标准

- [ ] Windows DV 资源优先启动随包内置的原生播放器。
- [ ] 非 DV 资源仍进入现有播放器。
- [ ] 原生模块缺失或媒体失败时可自动回退。
- [ ] 关闭原生窗口后观看进度被保存。
- [ ] 安装包和便携包均包含原生播放器。
- [ ] URL、Token 和请求头不进入命令行、临时文件或日志。
- [ ] Windows 原生解码与显示认证限制在用户提示及文档中说明。

## 验证计划

### 自动化

- [ ] `dart format --output=none --set-exit-if-changed lib test`
- [ ] `flutter analyze --no-fatal-infos --no-fatal-warnings`
- [ ] `flutter test`
- [ ] `dotnet publish windows/native_dv_player/Mova.NativeDvPlayer.csproj -c Release -r win-x64`
- [ ] `flutter build windows --release`

### 人工验证

| 平台/尺寸 | 操作路径 | 预期结果 | 结果 |
|---|---|---|---|
| Windows 11 / 1920×1080 | 详情页播放 DV MP4 Profile 5/8 | 原生窗口打开，系统/显示器显示 DV，关闭后保存进度 | 待认证设备验证 |
| Windows 11 / 1920×1080 | 播放普通 SDR/HDR10 | 仍使用 Mova 现有播放器 | 待验证 |
| Windows 10/11 / 模块缺失 | 播放 DV | 提示并自动进入兼容播放器 | 待验证 |

## 风险与回滚

- 主要风险：Windows/OEM 解码器支持的 DV Profile 与容器不一致；带仅 Header 认证的远程 URL 可能无法由系统 URI 源直接打开；原生窗口第一阶段缺少 Mova 高级播放功能。
- 监测方式：原生播放器返回不含敏感数据的错误类别；在认证设备上观察 Windows/显示器 DV 标志。
- 回滚步骤：移除 Windows DV 分支及 CI 原生模块构建，资源会全部回到 libmpv。

## 实现记录

- 已新增 WinUI 3 / Media Foundation 自包含播放器和无落盘 JSON IPC。
- 已在详情页加入 Windows DV 优先路由、进度回传与失败回退；Android 路由未改变。
- 已接入 Windows Build、Release 和本地 Inno 打包流程。
- 当前开发机未安装 Flutter、Dart 与 .NET SDK，因此仅完成脚本/XML/diff 静态检查；完整构建由 GitHub Actions 执行，实际 DV 输出仍需认证设备验证。
- 2026-09-14 用户实测 Windows 系统播放器路径无法稳定播放，并明确要求取消双播放器。本规格停止实施；后续方案见 `2026-09-14-windows-single-engine-dolby-vision.md`。
