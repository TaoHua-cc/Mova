# 在线搜索并应用字幕

## 基本信息

- 标题：播放器在线搜索并应用字幕
- 日期：2026-09-28
- 状态：菜单内搜索已实现；自动化验证与本地部署待完成
- 影响平台：Windows / Android
- 关联 Issue、提交或版本：无

## 背景与目标

播放器的字幕菜单目前只能切换内嵌字幕。用户希望在播放过程中按当前片名和季/集搜索外部字幕，选中后下载并立即应用，且不填写 API Token 或账号。

本次目标：

- Windows 原生播放器与 Flutter 播放器均提供在线搜索入口。
- 用正在播放的具体剧集作为搜索范围；缺少季/集时仍可按片名搜索支持该方式的来源。
- 提供免用户凭据的字幕来源，不嵌入共享密钥，不自动绕过验证码或反爬机制。
- 只接受 SRT、ASS、SSA、VTT；支持从 ZIP 中提取可用字幕，并校验大小和格式。
- 显示来源状态、无结果、网络/限频/验证提示和可恢复操作。

## 非目标

- 自动搜索后直接切换字幕；字幕同步/编辑；影片资源搜索。
- 绕过登录、验证码、反爬校验、访问限制或来源网站规则。
- 依赖公开仓库中暴露的共享 API Token。
- 在本次实现中声称覆盖所有动漫来源；来源索引能力不完整时诚实显示无结果。

## 用户流程与界面

从字幕菜单进入“在线字幕”二级菜单后自动查询并直接展示字幕文件列表，不打开覆盖详情页或播放器的弹窗。默认使用当前剧名、季/集和当前字幕偏好语言；来源并行返回，任一来源先完成就先显示结果；每个来源单独展示状态，失败的一方不阻塞另一方结果。用户在列表中选择条目后下载并立即加载，二级菜单保持打开；结果行就地显示“下载中 / 已下载 / 已下载 · 已应用”，允许再次应用而不重复下载。下载失败、文件不是字幕、压缩包无可用字幕或来源需要验证时，在同一菜单显示说明而不误加载。SubHD 无结果时可打开其网页检查；不自动解验证码。

## 数据源与请求

- **SubHD**：免用户 Token。通过其网页搜索结果和下载流程获取字幕；这是易受网页改版、访问限制或站点规则影响的网页集成，不视为稳定官方 API。
- **Gestdown**：免用户 Token。使用其公开剧集搜索、指定季/集/语言查询和下载接口，主要覆盖国际电视剧。
- Anime 专用来源未接入：Mova 现有播放数据没有可可靠映射到 Anime-specific 字幕库的外部 ID；不以模糊标题匹配冒充可靠覆盖。来源验证/不可访问时给出来源状态与网页恢复入口。

接口概览：

- Gestdown: `/shows/search/{title}` -> `/subtitles/get/{showUniqueId}/{season}/{episode}/{language}` -> `/subtitles/download/{subtitleId}`。
- SubHD: 网页 `/search/{title + SxxExx}`；解析 `/a/{id}` 结果。ID 必须支持网站当前使用的字母数字形式（例如 `pQULiK`）以及旧数字形式，并通过网站提供的下载流程获取文件。
- 参考：[Gestdown 搜索剧集接口](https://gestdown.readme.io/reference/get_shows-search-search)、[查询单集字幕接口](https://gestdown.readme.io/reference/get_subtitles-get-showuniqueid-season-episode-language)、[下载字幕接口](https://gestdown.readme.io/reference/downloadsubtitle)；SubHD 网页流程参考 [社区维护的实现](https://github.com/pa4373/subhd.py/blob/master/subhd_py/core.py)，该流程非 SubHD 官方稳定 API。
- 网络超时 18 秒；单个 HTTP 响应最大 20 MB；结果数限制；只写应用临时目录，不缓存临时下载地址或字幕文件到用户资料目录。
- ZIP 最多 100 个成员，仅挑选允许格式，拒绝 RAR、HTML 验证页、非字幕文件和空文件。
- 下载文件只在当前播放会话保留，播放流程退出后清理。原生播放器需将路径通过本机进程管道传递，再由 mpv 添加外部字幕轨。

## 隐私与兼容

- 不收集或存储来源站点凭据、Token。
- 不记录用户搜索文本、完整下载 URL 或凭据日志。
- 不改变持久化键、缓存格式或服务端协议。
- Windows 原生 mpv 的搜索结果与状态通过既有 stdin/stdout 控制通道传输，在播放器原生字幕子菜单中绘制；选择结果后将临时文件路径回传给原生播放器加载。Android/Flutter 播放器也在播放器内二级面板显示结果，并直接加载本地临时文件。
- 回滚只需删除搜索入口、服务和 Windows 原生消息分支；没有数据迁移。

## 验收标准

- [x] Windows 与 Flutter 播放器均可从字幕入口发起当前集搜索。
- [x] 用户无需填写 Token/账号；没有嵌入共享密钥。
- [x] 可下载并加载受支持的字幕文件，ZIP 字幕可解包。
- [x] 当前季/集进入来源查询；各来源可部分成功并独立显示状态。
- [x] 字幕来源结果按完成顺序增量显示；字母数字 SubHD 条目可解析。
- [x] Windows / Flutter 播放器在字幕二级菜单内直接展示搜索结果，不弹出详情页模态窗。
- [x] 下载并应用后搜索菜单保持打开，结果显示下载/应用状态，并可再次应用本地文件。
- [x] 无结果、超时、限频、验证页、失效下载和不支持格式给出可恢复提示。
- [x] 自动测试覆盖来源响应解析、季集请求范围、ZIP 下载/提取和验证页拒绝。
- [ ] Windows Release 已构建并部署到 `D:\Mova`；构建产物与安装目录可执行文件 SHA-256 一致。
- [ ] Windows 与 Android UI/播放验证完成。

## 验证计划

### 自动化

- [x] 修改文件 Dart 格式检查
- [x] Flutter 静态分析（无 error；仓库仍有信息级 lint）
- [x] 字幕来源解析/下载离线测试（6 项通过）
- [x] Windows Release 构建
- [ ] 完整测试集全绿：当前有 1 项既有失败 `test/glass_uniformity_test.dart`，其余 219 项通过；该测试文件在本任务开始前已处于工作区修改状态，本次未改动。失败项断言原生播放器必须含 `constexpr ULONGLONG kGlassBackdropRefreshMs = 16;`，当前 `main.cpp` 不含该字面量。
- [ ] Android 构建/设备验证：当前 `android/local.properties` 指向临时空 SDK 目录；未改写用户本机 SDK 配置。

### 人工

| 平台/尺寸 | 操作路径 | 预期结果 | 结果 |
|---|---|---|---|
| Windows / 桌面 | 原生播放器 > 字幕 > 在线搜索 | 原生二级菜单内显示当前集来源状态与字幕条目；点击后菜单不关闭且 mpv 新增字幕轨 | 待测 |
| Android / 窄屏 | 播放页 > 字幕 > 在线搜索 | 播放器内二级面板适配触控；结果下载后 media_kit 加载，不弹模态窗 | 待测 |
| 两端 | 无结果/来源限频/验证页/坏文件 | 显示来源级错误且不破坏当前播放 | 待测 |

## 风险与回滚

- SubHD 网页结构和非稳定网页流程可能变化、被限频或需要人工验证；Gestdown 可能不覆盖目标片名、语言或地区版本。
- 上游可能提供不兼容的字幕编码/时间轴；播放器加载失败时现有内嵌字幕轨仍保留。
- 临时文件清理取决于播放流程正常退出；系统临时目录也会由操作系统回收。
- 回滚不涉及数据库或配置迁移。

## 实现记录

- 已增加共享搜索服务与播放器内在线字幕面板，接入 SubHD 和 Gestdown。
- 已接入 Flutter 播放页、详情页启动的 Windows 原生播放及媒体中心续播。
- 六项字幕搜索离线测试通过，覆盖解析、季集限定、ZIP 提取和验证页面拒绝。
- Flutter 静态分析无 errors；仅保留仓库已有信息级提示。
- 完整测试集 219 项通过、1 项失败：`test/glass_uniformity_test.dart` 的 “player dock draws a full-bleed progress bar without a backdrop plate”。该文件为任务开始前已有的未提交修改，本次未触碰。
- Windows Release 构建成功，并部署至 `D:\Mova`；部署目录的 171 个构建文件全部与构建产物 SHA-256 一致。
- 尚未在真实 Windows/Android 播放会话中人工验证在线来源可用性、下载字幕的解码兼容性与视觉布局。
- Flutter analyze 覆盖了共享代码；Android APK 未构建，因为 `android/local.properties` 当前指向 `C:\Users\gctyk\AppData\Local\Temp\yj-dummy-android-sdk`，此目录只有临时许可文件而非完整 Android SDK。

## 2026-09-29 增量修复

- 修复 SubHD 搜索结果 ID 解析：兼容截图中的 `/a/pQULiK` 字母数字 ID；下载请求仍将 ID 原样作为字符串提交。
- 来源结果按各自完成时机增量展示，不等待较慢来源完整结束。
- 搜索面板在下载并应用后保持打开，并记录本次会话的下载状态；再次点击可直接应用本地已下载文件。
- 新增解析、增量到达和面板下载/重复应用状态测试。Windows 本地部署已完成，真实播放器会话的在线检索与应用仍待人工验证。
- 字幕服务与播放器内面板共 7 项自动测试通过；Flutter analyze 无 error（保留仓库 info 级提示）；Windows Release 曾成功部署到 `D:\Mova`。Android APK 未构建，沿用当前临时 Android SDK 配置限制。

## 2026-09-29 菜单内结果视图

- Windows 原生播放器改为在“字幕 → 在线字幕”原生子菜单中直接显示搜索来源状态和结果，不再通过详情页回调显示 Flutter 弹窗；选择结果后原生子菜单保持打开，并显示下载/应用状态。
- Android / Flutter 播放器将搜索结果面板作为字幕菜单的二级视图呈现；测试覆盖内嵌面板显示、下载应用及重复应用，不创建 `Dialog`。
- Windows stdin/stdout 搜索快照协议只传输行内菜单需要的状态、标题、来源/语言/文件名和索引；字幕文件仍以临时路径回传给原生播放器，播放退出时清理。
- 本轮验证：字幕面板与搜索服务定向测试 7 项通过；Flutter analyze 无 error（仓库保留既有 info 提示）；Windows Release 构建通过，并由 `scripts/dev-verify.ps1 -Deploy -SkipChecks` 安装到 `D:\Mova`。`mova.exe`、`MovaNativePlayer.exe` 与 `libmpv-2.dll` 的构建目录和部署目录 SHA-256 一致。Android APK 与真实播放会话未在本轮验证。
