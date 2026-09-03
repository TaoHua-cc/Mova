# 映迹 v2.0.129 — Z 序修复（mpv 钉到 Electron 正后方）

## 发布日期
2026-08-30

## 目标用户
已安装 v2.0.128 且遇到「mpv 弹窗跑到控制台下面/左下角」问题的用户。

## 问题描述（v2.0.128 回归）
用户真机验收 v2.0.128 后反馈：
- mpv 确实弹出了自己的窗口并**出画**（--wid 黑屏根因已解决）
- 但 mpv 窗口显示在**控制台左下角**，Z 序在桌面层（被文件管理器等遮挡）
- 控制台与画面未重叠

根因分析：
1. **Z 序未设置**：`SetWindowPos` 使用了 `SWP_NOZORDER | SWP_NOACTIVATE`，其中 `SWP_NOZORDER`(0x0004) 导致完全忽略 Z 序参数 → mpv 窗口落到 Z 栈最底层
2. **缺少 Electron HWND 引用**：ps1 脚本不知道该把 mpv 放到哪个窗口后面

## 修复内容

### main.cjs
1. 新增 `getElectronHwnd(win)` 辅助函数：通过 `win.getNativeWindowHandle().readBigUInt64LE()` 取得Electron 原生 HWND（Windows x64 指针）
2. 新增 `electronOwnerHwnd` 模块变量，缓存当前 Electron 窗口句柄
3. `runMpvWin32()` 新增 `-OwnerHwnd` 参数传递给 ps1
4. `syncMpvOwnWindow()` 在每次同步前调用 `getElectronHwnd(win)` 刷新 owner 句柄
5. `cleanupMpv()` 重置 `electronOwnerHwnd = 0`

### app/mpv/win32-glue.ps1
1. 新增 `-OwnerHwnd` 参数（long 类型）
2. move 动作分支改为：
   - **有 OwnerHwnd**：`$after = [IntPtr]::new($OwnerHwnd)`, `$flags = 0x0010`（仅 SWP_NOACTIVATE）→ **mpv 钉到 Electron 正后方**
   - **无 OwnerHwnd**（降级）：保持原逻辑 `SWP_NOZORDER | SWP_NOACTIVATE`

### 关键行为变化
| 场景 | v2.0.128 | v2.0.129 |
|---|---|---|
| SetWindowPos Z 序参数 | `[IntPtr]::Zero` + `SWP_NOZORDER`（不设 Z 序） | `electronHwnd`（钉到 Electron 后方） |
| SWP_NOZORDER 标志 | ✅ 启用（忽略 Z 序） | ❌ 去掉（Z 序生效） |
| SWP_NOACTIVATE | ✅ 保留 | ✅ 保留 |

## 验证方式
```bash
node verify-asar.cjs dist/win-unpacked/resources/app.asar
```
预期：全 PASS（含新增的 `main[129]` / `ps1[129]` Z 序断言）。

## 用户验收步骤
1. 退出旧版映迹（单实例锁）
2. 安装 2.0.129
3. 播放一段视频
4. **预期现象**：
   - mpv 自有窗口出画（与 2.0.128 一致）
   - mpv 窗口**精确位于 Electron 控制台正后方**（不再跑到左下角）
   - V9 控制台浮层覆盖其上，控件经 IPC 遥控 mpv
   - 拖拽/缩放/移动控制台时 mpv 跟随对齐
5. 若仍有偏移：把现象和截图发回，可进一步调 `--geometry` 或 DPI 补偿

## 已知取舍
- 每次 `syncMpvOwnWindow` 都会 spawn 一个 `powershell.exe -File ps1` 子进程（~30-50ms），90ms 节流已内置
- 若 `getNativeWindowHandle()` 在某些极端窗口状态下抛异常（窗口销毁中），降级为 OwnerHwnd=0（走旧逻辑不设 Z 序）
