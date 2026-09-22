# 观看记录服务器同步修复

## 范围

- Windows 与 Android 共享的 Emby / Jellyfin 继续观看读取。
- Windows 原生播放器结束后的最终进度回传。
- 服务器页观看记录同步开关文案与交互。

## 行为

- 本机观看记录始终保存，不由同步开关控制。
- “同步观看记录到服务器”默认开启；关闭时沿用既有
  `yingji.history.local-only=true`，不改变持久化格式。
- 继续观看优先读取 `Users/{userId}/Items/Resume`；服务器返回 404/405 时兼容回退
  到旧的 `Items?Filters=IsResumable` 请求。
- Flutter 播放器维持播放中上报；Windows 原生播放器退出后向对应 Emby/Jellyfin
  上报开始与停止状态，并在完成时标记已看。服务器离线不能阻止播放器退出。

## 验收

- 已连接服务器的续播项目能合并到首页继续观看。
- 默认开关呈开启状态，文案明确本机始终保存。
- Windows 原生播放退出后服务器收到最终播放位置。
- WebDAV 与缺少服务器项目 ID 的记录仅保存在本机。
