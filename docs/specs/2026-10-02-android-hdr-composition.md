# 安卓 HDR 视频合成修复

日期：2026-10-02；平台：Android；状态：实现中。

## 背景与证据

OPPO OPD2401 / Android 16，绿灯军团 S01E06 3840×1920 杜比视界。SurfaceFlinger 视频层 BT2020_ITU_PQ、HDR metadata types=11，但最终 Dynamic_range SDR，视频层 UNSUPPORTDATASPACE / forceClientComposition=true。Exo 的 AndroidView 内 SurfaceView 被引擎放入 flutter-vd#0，该虚拟显示 hdrCapabilities=null。不能据此证明杜比解码器已选中，也不能证明 OEM 白名单是唯一原因。

## 目标与方案

使用 PlatformViewLink + AndroidViewSurface + initExpensiveAndroidView 强制原生混合合成，避免 SurfaceView 进入无 HDR 能力的虚拟显示。保留现有 Flutter 控件、字幕、弹幕、进度与平台通道。保持进出场黑底遮盖，不缩放原生视频层。Windows 与 mpv 路径不变。

不改系统白名单、设备全局亮度或显示设置，不伪装 HDR，不承诺通过应用改动绕过 OEM 限制。

## 兼容与验证

不改变持久化或服务端接口。回滚只恢复原 AndroidView 嵌入。混合合成可能影响弹幕/控制层帧率和转场，需平板实测；低版本 Android 仍支持，但暂未实测。

执行静态检查、Flutter 测试和 Android Release 构建；安装后用户播放同资源，读取视频是否仍挂载虚拟显示、屏幕实际动态范围、视频 dataspace、控件叠加和退出状态。若仍 SDR，继续分辨 OEM 输出策略与 DV 解码路径，不以构建成功认定 HDR 修复成功。

## 实现记录

已替换 Exo 的 AndroidView 为强制 HC 的 PlatformViewLink，保留参数及原事件/方法通道、视图创建回调、手势隔离和转场遮盖。319 项测试通过；静态分析无错误/警告，20 项既存 info；Android Release 构建成功。用户退出播放器后保留数据覆盖安装 Success。等待同集真机重播，尚未验证亮度恢复、硬件合成或杜比输出激发。未修改 Windows 路径。

### 重播实测

用户反馈同资源仍很黑。重播后 flutter-vd 虚拟显示消失，视频层 BT2020_ITU_PQ / metadata types=11；forceClientComposition=false，未再出现 UNSUPPORTDATASPACE；屏幕 ColorMode DISPLAY_P3，OEM 明确报告 Dynamic_range HDR。media.resource_manager 当前 PID 787 的解码器为 c2.qti.dv.decoder，3840×1920，高通硬件 DV 解码路径已确认。

同时屏幕 displayBrightnessNits / sdrWhitePointNits 均约 167.113，手动亮度模式（screen_brightness_mode=0），mHbmMode=off。用户主观过黑仍未解决；不能仅凭 headroom 或 HBM off 判定白名单。下一步用户将播放器窗口亮度调至约 80% 做同片对照，区分屏幕亮度限制、影片映射和暗场内容；不修改系统全局亮度，不以加亮冒充 HDR 修复。

### 亮度对照结果

窗口亮度提高后实测 displayBrightnessNits / sdrWhitePointNits 均约 349.305，仍为 DISPLAY_P3 / Dynamic_range HDR，BT2020 PQ 视频层保持 forceClientComposition=false。用户确认暗部仍看不清。提高亮度未解决主观暗部问题，不能将 HDR 通路恢复等同于色调映射正确；尚未证明 OPPO 白名单或具体 DV profile 是原因。现有日志未获取到 DV profile，下一步需要同资源、同时间点的 Exo / mpv 对照，区分系统 DV 路径与素材本身。未新增强制提亮或 HDR headroom 覆盖。
