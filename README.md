# Mova

[![Android Build](https://github.com/TaoHua-cc/Mova/actions/workflows/android-build.yml/badge.svg)](https://github.com/TaoHua-cc/Mova/actions/workflows/android-build.yml)

<p align="center">
  <img src="app/assets/mova-logo.png" alt="Mova" width="128" />
</p>

Mova 是一款沉浸式私人影音客户端，同时支持 **Windows** 与 **Android**。它把 TMDB 中文影视资料、Emby / Jellyfin / WebDAV 媒体来源、Trakt 观看记录与 libmpv 播放器整合到统一的海报背景界面中。

## 主要体验

- 以当前轮播海报贯穿首页、追剧、片单、服务器与设置页面。
- 首页支持海报轮播、观看进度和继续播放；向下滚动即接上发现栏目（可自定义顺序与卡片样式）。
- 搜索默认使用 TMDB，也可切换到已连接的媒体服务器。
- 详情页提供季与剧集、播放进度、资源筛选、音轨字幕、演职人员、艺术图和相似推荐。
- 资源可按服务器最优结果或全部资源版本浏览。
- 播放状态可与已连接服务器及 Trakt 联动。
- 追剧日历整合待看内容、Trakt 记录与剧集更新信息。
- 多站评分通过服务端 MDBList 聚合，按来源分别展示原始分制；缺失评分不展示，缓存后后台更新。各影片的评分来源覆盖可能不同。
- 详情页显示下一集播出安排，日历结合 Trakt、TMDB 和 TVmaze。精确时间转换为本地时区，只有日期时明确提示时分未公布；播出安排不代表私人服务器入库时间。
- 播放器基于 libmpv，支持硬件解码、字幕、音轨、弹幕、章节和播放位置记忆。

## 支持的媒体来源

- Emby
- Jellyfin
- WebDAV
- TMDB 中文元数据
- Trakt 观看记录与待看同步

## 下载与安装

请从 [GitHub Releases](https://github.com/TaoHua-cc/Mova/releases) 下载最新版本。

- **Windows**：下载 x64 安装程序，部署 Mova、Flutter Windows 运行组件和 libmpv 播放依赖。
- **Android**：下载对应架构的 APK（推荐 `arm64-v8a`，适用于绝大多数现代手机）。

服务器密码、访问令牌、个人 TMDB Key 与同步凭据只保存在本机。

## 系统要求

- **Windows**：Windows 10 或 Windows 11（64 位），支持 D3D11 的显卡驱动
- **Android**：Android 7.0（API 24）及以上，arm64-v8a / armeabi-v7a / x86_64
- 访问 TMDB、Trakt 或个人媒体服务器所需的网络连接

## 构建

```bash
# 桌面端（Windows）
flutter build windows --release

# 安卓：按 ABI 拆分，避免打出上百 MB 的单一大包
flutter build apk --split-per-abi --release
# 产物：build/app/outputs/flutter-apk/app-{arm64-v8a,armeabi-v7a,x86_64}-release.apk

# Play 商店
flutter build appbundle --release
```

安卓签名：复制 `android/key.properties.example` 为 `android/key.properties` 并填入真实口令。
密钥文件**不入库**，请自行妥善保管——丢失后无法为已发布的包名推送更新。

## 平台差异

桌面端与移动端共用同一套业务代码，差异集中在 `lib/src/platform/window_host.dart`：

| 能力 | 桌面端 | Android |
|---|---|---|
| 窗口控制（最小化/最大化/关闭/拖拽） | `window_manager` | 不渲染相关按钮 |
| 全屏 | 窗口全屏 | 系统沉浸式（隐藏状态栏/导航栏） |
| 播放时屏幕常亮 | 系统电源管理 | `wakelock_plus` |
| 凭据存储 | Windows DPAPI 加密 | 本地存储 |

> 注意：安卓上直接调用 `windowManager.*` 会抛 `MissingPluginException`，
> 所有窗口相关操作必须经由 `WindowHost`。

## 隐私与授权

Mova 不会将媒体服务器凭据提交到本仓库。服务器访问令牌使用 Windows 数据保护机制存储。

本仓库用于 Mova 产品发布与问题跟踪，不授予源代码开源许可。未经明确授权，不得复制、修改、再分发或将本项目代码用于派生产品。

第三方组件信息见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
