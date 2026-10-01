# Exo HTTP 片源播放失败

- 日期：2026-09-30
- 状态：实现并待平板复测
- 平台：Android

## 原因与方案

真机绿灯军团 S1E1 日志明确为 CleartextNotPermittedException。原生 Exo 直接访问 HTTP 片源受网络安全配置阻止，而 mpv 已通过 VideoCacheStore 的回环 Range 代理播放。复用相同代理，把鉴权留在应用网络层；不修改全局网络安全策略。每次原生播放退出或启动失败均关闭该播放拥有的回环服务。

## 验收与兼容

后续真机确认视频恢复但无声：诊断识别 audio/eac3、6 声道、48000 Hz，Media3 支持状态为 1、未选中。给 Media3 Exo 接入 FFmpeg 的 E-AC-3 软件解码扩展；播放器继续留在 Exo，不自动切换引擎。FFmpeg 仅启用 E-AC-3 并按 LGPL 2.1-or-later 配置；APK assets/licenses 内附 Media3 与 FFmpeg 许可和对应源码标识。

- Exo 访问 127.0.0.1，真实片源和鉴权由代理读取；观看记录仍以原始 URL 保存。
- HTTPS 可在缓存目录不可用时直连；HTTP 则明确报代理不可用，不再走必然被拦截的请求。
- 新增回归测试：鉴权 Range 代理可读取，播放后关闭，记录不写入回环 URL。
- 不更改键、缓存格式、版本、正式签名；Android AOT 测试包和 Windows 本地部署。
- 真机复测同片源；报告后续不同的网络或解码错误，不将构建成功等同播放成功。

## 验证结果

- 针对性 Dart 测试 12 项通过；静态分析无错误/警告，19 项既有 info。
- Android arm64 Release AOT 构建通过，已安装到连接平板的 `Mova · 测试`，保留用户数据。用户确认 HTTP 修复后有画面；音轨回退后的声音恢复仍待真机确认。
- Windows Release 构建通过并部署到 D:\Mova；不提交、不推送、不改变版本。未执行全量测试或 Windows 播放人工复测。
