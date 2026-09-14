# Windows 单引擎 Dolby Vision 稳定播放

## 基本信息

- 标题：Windows 单引擎 Dolby Vision 稳定播放
- 日期：2026-09-14
- 状态：已完成（待 CI 与样片验收）
- 影响平台：Windows；Android 原生 DV 路径保持不变
- 关联版本：3.1.100 之后的持续构建

## 背景与问题

Windows 双引擎方案把 DV 资源交给独立 WinUI / Media Foundation 播放器。用户实测该路径无法稳定播放，且它与 Mova 主播放器在鉴权、字幕、控件、进度和容器兼容性方面形成两套行为。

## 目标

- Windows 的 SDR、HDR10 和 Dolby Vision 全部使用同一个 Mova 播放页面与 libmpv 内核。
- 优先保证 DV Profile 5/7/8 有正确、稳定的可观看画面。
- 保留鉴权请求头、字幕、弹幕、选集、进度和现有快捷键。
- 删除 WinUI 辅助播放器和 .NET 发布依赖。

## 非目标

- 不宣称输出 Dolby 专有原生信号或触发电视的 Dolby Vision 标志。
- 不解析 Profile 7 FEL 增强层；兼容播放使用基础层与 RPU 信息。
- 不内置或分发 Dolby 专有解码器和许可证。

## 用户流程与界面

所有资源均进入现有 `PlayerPage`。DV 不再打开第二个窗口，也不再显示“原生失败、切换兼容模式”的中间提示。播放失败沿用播放器现有错误界面。

## 数据与接口

- 输入、鉴权和播放地址：沿用 `PlayerEpisode` / `Media`。
- 持久化：沿用 `WatchStateStore`，无迁移。
- 网络：继续把来源请求头直接传给 libmpv。
- 隐私：移除跨进程 URL 传输。

## 技术方案

- 保留 `PlayerConfiguration(vo: 'gpu-next')`，由 libplacebo 使用 DV RPU 做图像重塑。
- Windows 硬解从 `d3d11va` 改为 `d3d11va-copy`，降低 D3D11 解码表面与 Flutter ANGLE 纹理互操作导致的黑屏、绿紫和设备兼容问题。
- `target-colorspace-hint=auto` 与 `target-colorspace-hint-mode=target` 根据实际 swapchain/显示能力选择 HDR10 或 SDR 目标。
- 使用 `bt.2446a` 色调映射、perceptual 色域映射和自动抖动，避免无 HDR 输出能力时直接显示 PQ 画面。
- 删除 Windows DV 路由、WinUI 工程、构建脚本及 CI 的 .NET 步骤。

选择该方案的核心取舍是稳定性与完整 Mova 播放体验优先。mpv 官方明确说明其动态模式不会发送完整 Dolby Vision 元数据，而是利用这些信息产生可显示的 HDR 输出；因此产品文案必须称为“DV 兼容播放”，不能称为原生 DV 直通。

## 兼容与迁移

- 原观看记录与设置完全兼容。
- Windows 安装升级后不再携带 `native_dv_player`；Inno 安装器覆盖升级时，旧目录可能残留但不再被调用，卸载会随安装目录清理。
- Android 的 Media3 原生 DV 路由不变。
- 回滚可恢复 Windows 路由与辅助程序，但不建议。

## 验收标准

- [ ] Windows 点击 DV、HDR10、SDR 都只打开 Mova 播放页。
- [ ] DV Profile 5 不出现绿紫画面。
- [ ] DV Profile 7/8 能使用基础层稳定播放。
- [ ] HDR 屏幕输出 HDR10，SDR 屏幕得到正常亮度和色彩。
- [ ] 鉴权、字幕、弹幕、进度、选集和快捷键保持可用。
- [ ] Windows Release 不再下载 .NET/WinUI 依赖，且安装包不含辅助播放器。

## 验证计划

### 自动化

- [ ] `dart format --output=none --set-exit-if-changed lib test`
- [ ] `flutter analyze --no-fatal-infos --no-fatal-warnings`
- [ ] `flutter test`
- [ ] GitHub Actions `Release / Build Windows`

### 人工验证

| 平台 | 样片 | 预期结果 | 结果 |
|---|---|---|---|
| Windows 11 HDR 开启 | DV Profile 5 MP4 | 单窗口、色彩正常、HDR 输出 | 待验证 |
| Windows 11 HDR 开启 | DV Profile 7 MKV | 基础层 + RPU 可观看，无黑屏 | 待验证 |
| Windows 11 SDR | DV Profile 5/8 | 正常映射为 SDR，无绿紫 | 待验证 |
| Windows 10/11 | HDR10 / SDR | 与原播放器行为一致 | 待验证 |

## 风险与回滚

- `d3d11va-copy` 比零拷贝增加 GPU/内存带宽，但通常比软件解码更适合 4K HEVC。
- libmpv 包含的 FFmpeg/libplacebo 版本决定具体 Profile 支持；遇到样片问题需记录 MediaInfo 与播放日志后升级内核。
- 回滚为上一版 `d3d11va` 或恢复双引擎均可，无数据迁移。

## 实现记录

- 已移除 Windows 双播放器路由、WinUI 工程和 .NET 构建链路。
- 已统一并强化 libmpv 色彩管线；等待 CI 与用户 DV 样片验证。
