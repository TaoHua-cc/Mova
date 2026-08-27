# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

拥有私人影视内容的家庭用户是核心用户：内容可能来自 Emby、Jellyfin、NAS、WebDAV、私人服务器、网盘或本地文件。用户希望在 Windows、macOS、iPhone、iPad 和 Apple TV 上拥有统一资料库、观看进度和播放体验。

## Product Purpose

映迹是跨平台私人媒体聚合与追剧播放器。它连接用户授权的服务器和存储来源，识别影视内容、统一元数据与观看状态，并选择适合当前设备的版本播放。成功意味着用户能在任意设备快速回到内容、理解来源状态并可靠开始播放。

## Positioning

把多来源连接、统一资料库、追剧状态、字幕与高质量播放汇到同一条路径中；不托管或出售用户的私人媒体。

## Operating Context

首个实现运行于 Windows 桌面和客厅显示器。后续使用同一信息架构与设计令牌适配 macOS、iPhone、iPad 和 Apple TV，并根据鼠标键盘、触控和遥控器采用各平台原生导航与焦点行为。

## Capabilities and Constraints

Windows 当前支持 Emby、Jellyfin 和 WebDAV 私人来源，支持资料库扫描、TMDB 资料、Trakt 追剧、资源选择和 mpv 播放。SMB、本地目录及各网盘 OAuth 连接按来源适配器扩展。服务器令牌与密码仅保存在系统安全凭据存储中。

## Brand Commitments

产品名称为“映迹”。设计语言以 Apple 平台的内容优先、材质层级、清晰焦点和平台自适应为基础。Windows、macOS 和 iPad 使用宽屏资料库结构；iPhone 使用标签栏；Apple TV 使用焦点导航、远距可读排版和沉浸式画面。

## Evidence on Hand

已有 Electron Windows 客户端、TMDB 托管元数据服务、Emby 连接、Trakt 授权流程及 mpv 播放内核。影视海报、剧照、演员照片和预告片来自 TMDB；不存在可公开使用的品牌摄影资产。

## Product Principles

- 私有媒体库必须被表达为用户掌控的空间，而不是内容平台。
- 从发现、确认资源到播放的路径必须短且可解释。
- 高规格资源、字幕和播放能力要清晰可见，但不能压过影视内容。
- 大量用户使用时，首次配置、空状态与失败恢复必须可信而克制。

## Accessibility & Inclusion

核心文本和控件需具备可读对比度、键盘焦点和清晰文字标签；不得仅以颜色传达服务器连接、播放或失败状态。
