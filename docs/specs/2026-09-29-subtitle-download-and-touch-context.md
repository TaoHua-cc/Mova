# Mova 改动规格：字幕下载错误与剧集触控菜单

## 基本信息

- 标题：修复 SubHD 下载域名与剧集右键操作触控入口
- 日期：2026-09-29
- 状态：回归修正中（用户复测仍失败）
- 影响平台：Windows / Android
- 关联 Issue、提交或版本：无

## 背景与问题

在线字幕结果能够显示，但点击下载/应用时可能收到 SubHD 404。当前搜索和 SubHD 下载接口都固定使用 `subhd.tv`，并把该域名的 404 一律显示成“没有找到匹配内容”，无法区分下载接口无此记录和字幕文件链接失效。

剧集卡片的已播放/未播放操作仍存在，但入口仅为鼠标右键；Android 触控没有对应长按入口。通用右键菜单组件也仅支持鼠标右键。

## 目标

- SubHD 搜索使用官网规范主机 `www.subhd.me`；下载 API 与字幕详情结果保持同源。
- 对下载 API 404 与实际字幕文件 404 提供可辨认且可恢复的错误信息。
- 保留 Windows 右键，在 Android 以长按打开相同的已播放/未播放菜单。
- 为共享的“仅右键打开”玻璃菜单补齐长按入口。

## 非目标

- 不增加新的字幕来源、账号或 Token。
- 不改变观看状态持久化、服务器同步及已下载字幕的生命周期。
- 不改造播放器字幕菜单或重新设计剧集卡片。

## 用户流程与界面

- 在线字幕结果仍在播放器字幕搜索子菜单内显示。选择 SubHD 结果后，若下载接口返回 404，显示“下载接口未找到该字幕记录”；若下载文件链接返回 404，显示“字幕文件链接已失效或文件已被移除”。
- Windows 用户右键剧集卡片，Android 用户长按剧集卡片，打开同一浮动菜单并选择“标记为已播放 / 未播放”。横向预览与“全部剧集”均支持。
- 全部剧集提示文字同时注明长按和右键。
- 桌面菜单保留鼠标定位；移动端菜单用长按点位定位，并遵循现有玻璃材质和安全边距。

## 数据与接口

- 输入与输出：SubHD 字幕结果 ID -> 站点 AJAX 下载地址 -> 临时字幕文件。
- 数据来源：SubHD 当前官网列出的可用镜像；Gestdown 不变。
- 新增/修改字段：无。
- 持久化键或缓存格式：无变化。
- 网络接口、超时与错误处理：请求超时仍为 18 秒、单响应限制仍为 20 MB；下载 API 请求按结果详情所在域名发送；区分两个下载阶段的 HTTP 404。
- 隐私与敏感信息：不增加凭据，不记录字幕下载 URL。

## 技术方案

- `subtitle_search_service.dart`：搜索使用 `www.subhd.me`；下载接口按结果详情页生成同域 `/ajax/down_ajax`，携带网页 AJAX 请求头，相对下载地址相对 AJAX 地址解析，并区分 API / 文件的 404 错误。
- `metadata_detail_page.dart`：预览集卡和全部剧集卡的右键与长按识别器放在外层 `GestureDetector`，复用 `_showMarkMenu`。
- `brand.dart`：`YingjiGlassMenu(secondaryOnly: true)` 在外层同时监听长按与右键。
- `test/`：覆盖下载请求头和 404 提示、模拟 Windows 鼠标次键展开菜单、长按展开，以及剧集列表输入契约。

## 兼容与迁移

- 旧版本数据是否可继续读取：是，无数据格式变化。
- Windows / Android 差异：Windows 保留右键；Android 使用长按；两者执行同一观看状态操作。
- 回滚后是否安全：是，无数据迁移。
- 是否需要迁移、清理或功能开关：否。

## 验收标准

- [x] SubHD 使用官网规范主机 `www.subhd.me`，下载接口同源且携带网页 AJAX 请求头。
- [x] 下载接口 404 与字幕文件 404 显示不同错误原因。
- [x] Windows 右键与 Android 长按均可显示剧集观看状态菜单。
- [x] 标记为已播放/未播放仍复用原有状态更新逻辑。
- [x] 不引入虚假生产数据或泄露敏感信息。
- [x] Windows 与 Android 使用相同观看状态回调。

## 验证计划

### 自动化

- [x] `dart format` 修改文件；格式检查 0 项待改
- [x] `flutter analyze --no-fatal-infos --no-fatal-warnings`（成功；19 条既有 info 级提示）
- [x] `flutter test test/subtitle_search_service_test.dart test/subtitle_search_dialog_test.dart test/glass_menu_test.dart test/detail_origin_transition_test.dart`（24 项通过）
- [x] 前一轮 Windows Release 已部署；该部署不包含本轮后续修正
- [x] 本轮 Windows Release 构建成功并部署到 `D:\Mova`；`mova.exe`、`MovaNativePlayer.exe`、`libmpv-2.dll` 与构建产物 SHA-256 一致
- [ ] Android APK / 真机验证：本轮未执行；当前 Android SDK 配置指向临时空 SDK 目录

### 人工验证

| 平台/尺寸 | 操作路径 | 预期结果 | 结果 |
|---|---|---|---|
| Windows / 桌面 | 详情页剧集卡右键 | 显示已播放/未播放操作 | 待人工验证 |
| Android / 触控 | 详情页剧集卡长按 | 显示同一菜单，选择后状态更新 | 待人工验证 |
| Windows / 播放器 | 字幕搜索结果选择 SubHD 条目 | 下载成功，或具体显示接口/文件阶段错误 | 待人工验证 |

## 风险与回滚

- SubHD 是网页集成，镜像域名、下载页面和接口可能变化；如果 `.me` 停用，需要切换到官网当前列出的其他可用镜像。
- 长按手势要与横向/垂直滚动竞争；拖动应继续交给滚动容器，只有按住达到长按时长才打开菜单。
- 回滚代码不涉及用户数据。

## 实现记录

- SubHD 搜索域名统一为官网规范主机 `www.subhd.me`；下载 AJAX 端点由结果详情所在 host 生成，避免搜索与下载跨镜像。
- 下载 POST 增加网页 AJAX 所需的 `Origin`、`X-Requested-With`、JSON `Accept` 请求头；相对下载地址改为相对 `/ajax/down_ajax` 解析。
- SubHD 下载流程的两个 HTTP 404 分别提示“下载接口未找到记录”与“文件链接已失效/移除”。
- 横向剧集预览、全部剧集以及通用 `secondaryOnly` 玻璃菜单均保留 Windows 右键并新增长按；模拟 Windows 鼠标次键的 Widget 测试验证菜单会打开。
- 定向测试 22 项通过；Flutter analyze 成功，仓库报告 19 条既有 info 级提示。
- 本轮 Windows Release 已重新构建并安装 GPU-next libmpv；用户授权正常关闭运行中的 Mova 后部署成功，三个关键二进制的 SHA-256 均与构建目录一致。
- 未执行真实站点下载或设备人工验证；本机 Android SDK 配置仍为临时空目录，SubHD 网页接口可能继续变化。

## 2026-09-29 回归修正规格

用户在本地安装版复测确认：SubHD 字幕下载仍失败，详情页和 Windows 原生播放器的剧集右键均未弹出菜单；详情页“全部剧集”希望每行一集，左侧有预览图。

- 已定位旧版修复的遗漏：详情页通常渲染 `_CatalogEpisodeRail`，旧补丁只覆盖了备用的 `_EpisodePreviewRail`；原生播放器 `PanelProc` 没有处理 `WM_RBUTTONDOWN`。
- 下载仍向旧的 `/ajax/down_ajax` 发送表单。近期公开客户端的实现（`jun9100/moviepilot-subtitle-agent/app/chinese_provider.py`）先访问 `/a/{sid}` 与 `/down/{sid}`，再向 `/api/sub/down` 发送 JSON `{"sid": sid, "cap": ""}`；本次按该实际请求链修正，并把站点的验证码或失败消息明确反馈给用户。
- 详情页目录剧集和“全部剧集”使用同一个已播放/未播放菜单；真实 TMDB 剧照优先，缺图时使用现有占位，不生成假图。全部剧集改为纵向一行一集，左侧缩略图。
- Windows 原生选集面板处理鼠标右键，显示已播放/未播放操作，并把选择送回 Flutter 保存；详情页调用继续复用现有服务器与 Trakt 同步逻辑。
- 验收：主目录剧集、全部剧集和原生播放器三个入口都能右键标记；长按仍可用；标记状态重新打开后仍可读取；SubHD 成功链路和验证/失败链路有针对性测试；Windows 本地部署后核对二进制。
- 兼容：不修改现有持久化键或服务端协议。Android 保留长按语义。真实网站可能要求用户自行完成验证；不得绕过站点验证。

### 本轮实现与验证

- SubHD 下载改用详情页/下载页预取、同站 Cookie、`/api/sub/down` JSON 请求及返回文件地址。模拟测试覆盖成功、站点挑战、接口 404、文件 404；真实站点下载尚未确认。
- 主 TMDB 剧集目录和“全部剧集”均处理鼠标次键与触控长按；两种全部剧集布局改为一行一集、左侧真实剧照。没有对应服务器资源时，标记保存在现有观看记录结构中，并在允许远端同步时更新 Trakt。
- 原生播放器剧集面板新增右键状态菜单；退出时把手动标记最后写入，避免播放进度保存覆盖手动“未播放”。
- `dart analyze` 相关文件无问题；`flutter test test/detail_full_series_test.dart test/subtitle_search_service_test.dart` 通过；Windows Release 编译通过。Android 与站点真实下载仍待人工验证。
