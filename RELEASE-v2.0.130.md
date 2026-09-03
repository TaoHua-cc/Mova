# Yingji 2.0.130 — mpv 窗口即播放器

> 2026-08-30  ·  v2.0.129 -> v2.0.130  ·  NSIS / Windows x64

## 一句话总结

彻底抛弃 Electron 浮层控制台，**mpv 自有窗口即是播放器**，由 `yingji-osc.lua` 直接在视频上绘制完整的 V9 控件（进度条 / 播放控制 / 音量 / 7 个设置面板 / 选集）。点播放直接弹出独立 mpv 窗口，Electron 应用窗口在播放期间自动隐藏；mpv 关闭/退出后应用窗口自动恢复。

---

## 用户视角的变化

| 旧版本 (v2.0.129) | 新版本 (v2.0.130) |
|---|---|
| 点击播放 -> Electron 应用窗口变成全屏播放器，浮层 UI 覆盖在 mpv 视频上 | 点击播放 -> 应用窗口**自动隐藏**，独立的 mpv 窗口接管整块屏幕 |
| 所有控件（进度条/按钮/面板）在 Electron 浮层中（HTML/CSS） | **全部控件在 mpv 窗口内**（`yingji-osc.lua` 自绘 ASS 覆盖层） |
| 关闭 mpv 窗口 -> 需要切回应用窗口 | 关闭 mpv 窗口 -> **应用窗口自动恢复**，停在原页面（首页/详情） |
| 浮层与视频的 Z 序曾多次返工（v2.0.128/129） | 浮层不存在 -> 彻底没有 Z 序问题 |

---

## 关键改动

### 1. `main.cjs` — 主进程把控制台交给 mpv

* **播放连接成功后**隐藏 Electron 窗口：
  ```js
  try { if (owner && !owner.isDestroyed()) owner.hide(); } catch {}
  syncMpvOwnWindow(owner);
  ```
* **mpv 退出 handler** 中恢复 Electron 窗口（替代旧的 `setAlwaysOnTop(false)`）：
  ```js
  if (mainWindow && !mainWindow.isDestroyed()) {
    try { mainWindow.setAlwaysOnTop(false); } catch {}
    try { mainWindow.show(); } catch {}
  }
  ```
* **mpv 启动参数** 翻转 `yj-headless`：
  ```
  --script-opts=yj-state-file=${playerStateFile},yj-headless=no
  ```
  `yj-headless=no` 意味着 `yingji-osc.lua` 的 `render()` 走完整分支（行 502-514），绘制完整 V9 控件。
* 顶部注释更新：mpv 自有窗口 + 自绘 OSC 是唯一播放器，Electron 窗口在播放时隐藏、退出时恢复。

### 2. `app/integration.js` — 播放后不切换路由

* `playEmby` 末尾**去掉** `yjNavigate('player')`，直接调用 `render()` 刷新当前页面（首页/详情）。
* `live.player` / `live.playerState` 上下文仍保留，供诊断订阅使用。

### 3. `app/mpv/portable_config/mpv.conf` — 允许拖动无边框窗口

```ini
osc=no              # 禁用原生 OSC（lua 自绘接管）
osd-level=1         # 仅字幕 + lua 自绘，避免原生媒体 OSD 冲突
input-default-bindings=no
window-dragging=yes # 无边框窗口可拖动
```

### 4. `app/mpv/portable_config/scripts/yingji-osc.lua` — 无改动

完整的 597 行 V9 控件实现（`yj-headless=no` 时自动恢复渲染）：
* 进度条 + 时间码
* 传输控制（播放/暂停/快退/快进）
* 音量条（鼠标拖动 + 滚轮）
* 顶部按钮（置顶 / 最小化 / 关闭）
* 7 个设置面板：声音 / 字幕 / 弹幕 / 播放 / 视频 / 选集 / 诊断
* 选集面板（cover flow + 键盘焦点导航）
* 键盘与鼠标交互（鼠标移动显示、点击穿透、自动隐藏）

### 5. `verify-asar.cjs` — 新增 v2.0.130 断言

* main.cjs: `yj-headless=no` / `owner.hide()` / exit handler 中 `mainWindow.show()`
* mpv.conf: `osc=no` / `window-dragging=yes`
* integration.js: 移除 `yjNavigate('player')`，保留 `live.player` 上下文

---

## 验证结果

* `verify-asar.cjs` 对 `dist/win-unpacked/resources/app.asar` 断言 **72/72 PASS，0 失败**（含 v2.0.127–130 全部架构断言：headless 翻转 / hide / show / mpv.conf / integration.js）。
* 构建期间第 4 次命中 `app-builder.exe unpack-electron` 死锁（packaging 卡 10 分钟），`taskkill /F /PID` 后重跑 **44 秒 BUILD_EXIT=0** —— 与代码无关，杀进程重跑即可。
* 产物：`dist/Yingji-2.0.130-Windows-x64.exe`（138,166,863 bytes）+ blockmap。

---

## 用户安装/验证

1. **关闭所有 2.0.129 实例**（残留 mpv 进程会占 app.asar.unpacked/app/mpv/mpv.exe）。
2. 安装 `dist/Yingji-2.0.130-Windows-x64.exe`（约 138 MB）。
3. 启动应用 -> 选择剧集 -> 点击播放。
4. **预期**：
   * Electron 应用窗口**消失**（不是最小化，是 hide）。
   * 弹出**独立 mpv 窗口**（无边框），位置与原应用窗口一致。
   * 鼠标移动到窗口底部 -> 进度条 / 时间码 / 播放控件渐入显示。
   * 点击设置按钮 -> 7 个设置面板可在视频上弹出。
   * 关闭窗口（mpv 标题栏 X 或 OSC 顶部关闭按钮）-> mpv 进程退出 -> **应用窗口自动恢复**并显示原页面。
5. 拖动 mpv 窗口（视频空白处）-> 应能移动整个窗口（`window-dragging=yes`）。

---

## 已知边界

* **最小化按钮**：OSC 顶部"最小化"按钮调用 mpv 自身最小化（不会让 Electron 窗口显示）。如需恢复 Electron，可点击任务栏 mpv 图标或关闭 mpv。
* **Electron 窗口恢复时位置**：若用户拖动了 mpv 窗口，mpv 退出后 Electron 窗口回到 hide 前的原位置（不变）。这是合理的——应用窗口位置应独立于播放器窗口。
* **多视频切换**：连续点不同视频时，旧 mpv 进程被 kill -> 触发 exit handler -> mainWindow.show() 短暂闪一下 -> 紧接着新 mpv 启动 -> mainWindow.hide() 再次隐藏。可接受（百毫秒级）。如不可接受可在 v2.0.131 进一步去抖。
* **快捷键冲突**：OSC 用 add_forced_key_binding 强制接管部分按键（空格暂停/方向键），与 mpv 默认绑定一致。

---

## 升级方式

* 卸载旧版（如需干净安装）-> 装 2.0.130。
* 或直接覆盖安装（NSIS 配置 `oneClick: false, allowToChangeInstallationDirectory: true`）。
