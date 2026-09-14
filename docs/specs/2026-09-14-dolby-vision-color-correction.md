## 基本信息

- 标题：Windows Dolby Vision 色彩校正
- 日期：2026-09-14
- 状态：已完成
- 影响平台：Windows；Android 原生 DV 路径保持不变

## 背景与问题

播放器虽使用 `gpu-next`，但资源的 `videoRange` 没有传入播放器，且 `HDR10+DV` 会被漏判。Windows 硬件解码在部分驱动上不会稳定地把 Dolby Vision RPU 帧侧数据交给 libplacebo，Profile 5 基层未经重塑时会出现绿紫或明显偏色。

## 目标

- 正确识别服务端常见 DV 标记，并在选集、换源时同步更新播放链路。
- Windows DV 以颜色正确和稳定优先，确保 RPU 可供 `gpu-next` 重塑。
- 根据实际显示目标输出 HDR10 或 SDR，普通视频继续使用硬件解码。

## 非目标

- 不宣称 Windows Flutter 纹理能够输出经过 Dolby 授权的原生 DV 信号。
- 不改变 Android 已有的系统原生 Dolby Vision 播放路径。

## 数据与接口

- 为播放器内存模型增加可空 `videoRange`；不改变持久化格式和服务器协议。
- 数据来自 Emby/Jellyfin 已返回的 `MediaItem.videoRange`。

## 技术方案

- Windows DV 使用软件解码，避免 D3D11VA 丢失 RPU；普通内容仍用 `d3d11va-copy`。
- `gpu-next` 使用显示色彩提示、BT.2446A 色调映射、感知色域映射和场景峰值计算。
- 每次打开选集或切换资源前重新应用解码和色彩属性。

## 兼容与迁移

- 字段仅存在于运行时且可空，旧数据无需迁移，回滚安全。
- Android 原生 DV 优先逻辑不变；进入兼容播放器时沿用现有 MediaCodec 策略。

## 验收标准

- [x] `HDR10+DV` 等标记能被识别。
- [x] Windows DV 使用保留 RPU 的软件解码链路，避免已知绿紫偏色原因。
- [x] 换源和换集后重新应用正确链路。
- [x] 普通 Windows 视频仍走硬件解码。
- [x] 静态检查、针对性测试和 Windows Release 构建通过。

## 验证计划

- 自动化：DV 识别、解码选择、色彩属性单元测试；Flutter analyze/test；Windows Release 构建。
- 人工：分别在 SDR 与 HDR Windows 显示器播放 Profile 5/8 样片，核对肤色、黑位和高光；任务环境无对应显示器时记录为待真机复核。

## 风险与回滚

- 4K DV 软件解码会提高 CPU 占用，这是为稳定保留 RPU 作出的取舍；普通内容性能不变。
- 可回滚本规格对应的播放器链路改动，不涉及用户数据。

## 实现记录

- 已把 `videoRange` 从详情资源贯穿到播放器、选集和换源模型。
- 已修复 `HDR10+DV` 识别，并增加解码策略与色彩属性单元测试。
- `flutter analyze --no-fatal-infos --no-fatal-warnings` 退出码为 0，保留 21 条既有 info。
- DV 针对性测试 5 项全部通过；完整测试 61 项通过，1 项既有的发现栏目空态测试失败，与本改动无关。
- `flutter build windows --release` 成功；实际 DV 显示效果仍需在 SDR/HDR 真机分别复核。
