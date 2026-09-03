# 映迹 v2.0.128 发布说明

## 核心变更：放弃 `--wid` 嵌入，改为 mpv 自有窗口 + 浮层控制台
- 之前的黑屏/无画面问题根因是 `--wid` 嵌入路线在部分 Windows 机器上结构性不稳定（2.0.124→2.0.127 多轮修复仍无效）。
- 本版 mpv 改为**弹出自己的窗口**放画面（`--force-window=yes` + `--no-border`），V9 控制台作为 `setAlwaysOnTop` 透明浮层盖在 mpv 窗口之上，通过 IPC 遥控 mpv，**完全替换 mpv 原生 OSC**（`yj-headless=yes` 关闭原生控件）。

## 关键技术点
- 窗口对齐：新增 `app/mpv/win32-glue.ps1`（P/Invoke `EnumWindows`/`SetWindowPos`/`ShowWindow`），按唯一标题 `YINGJI_MPV_<pid>-<ts>` 定位 mpv 窗口并实时对齐到 App 浮层；节流 90ms，HWND 缓存复用。
- 窗口态：全屏/置顶改回驱动 mpv 自有窗口（`set_property fullscreen` / `ontop`，仍在白名单内）；App 浮层在播放期间常驻置顶，退出播放自动解除。
- 画中画：App 浮层缩小到右下 + 置顶，mpv 跟随，保持一致性。

## 验证
- `verify-asar.cjs` 53/53 PASS（基础 + 透明化 + 窗口态 + [127]headless + [128] 自有窗口）。
- 打包 `CODEBUDDY_SAFE_DELETE_ENABLED=0 npm run dist:installer` → `Yingji-2.0.128-Windows-x64.exe`。

## 用户验收步骤
1. 退出 `D:\yingji` 旧实例（单实例锁会导致新包启动即退出）。
2. 安装 2.0.128，播放一段视频。
3. 应看到 mpv 自有窗口出画 + V9 控制台浮层覆盖其上；控制台控件经 IPC 遥控 mpv（声画同步、轨道/字幕/画面/音量等）。
4. 若控制台与画面未精确重叠（Win32 胶水异常），视频仍会出画，属可降级，请把现象反馈给我。
