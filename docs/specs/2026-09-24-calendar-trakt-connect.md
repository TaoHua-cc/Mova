# 追剧日历：右上角 Trakt 连接入口

## 基本信息

- 标题：追剧日历右上角添加 Trakt 连接按钮（浏览器登录后自动连接）
- 日期：2026-09-24
- 状态：实现中（代码已完成，静态检查与测试因环境问题未执行 —— 见「验证计划」）
- 影响平台：两端共用 `lib/`（Windows 为主，Android 走同一套代码 + `WindowHost.openUrl` 平台通道）
- 关联：变更来源 = 用户要求「追剧日历右上角添加 trakt 连接按钮，点击以后弹出网页进行登录，
  登陆后连接软件」；前置诊断见 `2026-09-24-calendar-airtime-sources.md`

## 背景与问题

- 追剧日历的时刻与播出安排依赖 Trakt（`TraktClient.calendar`），但入口只在**设置页**：
  用户必须先切到设置 → 找到网络分区 → 手填 Client ID / Access Token / Client Secret →
  再点「浏览器授权 Trakt」。日历页本身只有一个「未连接 Trakt；已展示本地待看的更新信息。」的灰字。
- 结果是：**看到缺时刻的人，不知道去哪里连**；而 Trakt 恰恰是「播出时刻」与「观看记录」
  的唯一在线来源（TVmaze 只补时刻，TMDB 不给时刻）。
- 现状缺口用一句可观察事实概括：日历页没有任何可点的连接入口。

## 目标

- 追剧日历标题行右上角出现 Trakt 入口，**未连接**显示「连接 Trakt」、**已连接**显示
  「Trakt 已连接」（点亮），点击即可开始/管理授权。
- 点击后**打开系统浏览器**完成登录；登录期内应用自动等待，拿到令牌后**自动连接并刷新日历**
  （无需用户再回设置页点刷新）。
- 未配置应用凭据时，给出可执行的下一步（直达设置页），而不是一句「请先配置」。

## 非目标

本 次明确不处理：

- 不改设置页现有的 Client ID / Secret / Token 三输入框与「浏览器授权 Trakt」按钮（保持可用）。
- 不引入 Trakt 的「授权码 + 回调地址」流程：Trakt 要求 `redirect_uri` 与后台登记值逐字节一致，
  而登记值由用户自己填，客户端猜不出端口 → 会造成「点了报 invalid redirect_uri」的坏体验。
  设备码流程（OAuth Device Code）只依赖 client_id + client_secret，是唯一稳定可用的路。
- 不改 Trakt 同步的语义（观看记录、续播、scrobble 一条不动）。
- 不修 `TraktClient.calendar` 的**午夜占位误判**（`T00:00:00.000Z` 被当成真时刻）——
  那是连接之后才暴露的问题，单独处理（已记在 `MEMORY.md`）。

## 用户流程与界面

入口：`_CalendarPageState` 标题行（`追剧日历` 右侧），位于「刷新」按钮**左侧**，间隔 8px。

| 状态 | 文案（宽屏 / 窄屏） | 外观 | 点击行为 |
|---|---|---|---|
| 未连接 | 连接 Trakt / Trakt | 链环图标，常规玻璃 | 开始设备授权 |
| 授权中 | 等待授权… / 授权中 | 转圈，屏蔽重复点击 | 无（防重复授权） |
| 已连接 | Trakt 已连接 / 已连接 | 对勾图标，点亮（浓度 1.3、深色前景） | 打开账户对话框 |

- **授权对话框**（`TraktAuthDialog`，不可点背景关闭）：
  「正在向 Trakt 申请授权码…」→ 出码后展示**大号授权码** + 「复制授权码」+「打开登录页面」
  + 「等待浏览器中的登录结果…」。浏览器打开失败时把 `verificationUrl` 原样写在下面让用户自己复制。
  失败（取码失败 / 轮询超时 / HTTP 4xx）→ 同一位置换成琥珀色报错 + 「重新获取」按钮。
  底部：「打开登录页面」「取消」。
- **账户对话框**：已连接时点按钮进入，「断开连接」/「重新授权」。断开只清 access-token，
  Client ID / Secret 保留，下次一键重连。
- **缺凭据**（`TraktSetupDialog`）：说明去哪里拿 Client ID / Secret，「前往设置」直接
  `yingjiSectionRequest.value = 'settings'` 跳到设置分区。
- 加载/空/失败态：日历原有的 `_traktMessage` 文案不变，授权成功后写「Trakt 已连接」并重新 `_load()`。
- 极窄屏不溢出：标题在 `Expanded` 里可收缩；胶囊按钮在宽度 < 760 时换短文案
  （「Trakt」/「已连接」/「授权中」）。

## 数据与接口

- 输入：`SharedPreferences` 中的 `yingji.trakt.client-id` / `client-secret` / `access-token`。
- 输出：授权成功后写 `yingji.trakt.access-token`（断开时 `remove`）。
- 数据来源与接口：Trakt 官方设备码流程
  - `POST https://api.trakt.tv/oauth/device/code`（body: `client_id`）
  - 浏览器打开 `verification_url`（Trakt 返回，通常 `https://trakt.tv/activate`），用户输入 `user_code`
  - `POST https://api.trakt.tv/oauth/device/token`（`code` + `client_id` + `client_secret`），
    间隔 `interval` 秒轮询，`400`/`409` 表示"还没点确认"，其它非 2xx 直接失败
- 超时与错误处理：HTTP 15s（`TraktClient` 既有实现）；轮询上限 `expires_in`（默认 600s），
  超时报「Trakt 授权已超时，请重新开始」并可「重新获取」。
- 持久化键：**沿用既有键名，未新增、未修改、未迁移**（写入方式与设置页完全一致）。
- 隐私：令牌只落在本机 `shared_preferences`，不进日志；对话框不显示 Client Secret。

## 技术方案

| 模块 | 改动 |
|---|---|
| `lib/src/tracking/trakt_auth.dart`（新增） | `TraktPreferences`（三个键的唯一来源）、`TraktCredentials`（读取 / `isConnected` / `canAuthorize` / `saveAccessToken`）、`traktConnectButtonState()`（纯函数，按钮三态）、`TraktAuthDialog`（设备码 + 轮询 + 复制码 + 重试）、`TraktSetupDialog`（缺凭据提示 + 跳设置） |
| `lib/src/brand.dart` | 新增 `YingjiGlassPillButton`：胶囊形玻璃按钮，复用 `YingjiGlassSurface` + `YingjiGlassTooltip` + `MovaMotion` 的按下回弹，`sigma = blur*.55`、`strength` 随 hover/selected 分档，与 `YingjiMotionIconButton` 同源 |
| `lib/src/media_center.dart` | `_CalendarPageState` 加 `_traktConnected` / `_traktAuthorizing`；`_load()` 同步连接态；新增 `_connectTrakt` / `_showTraktAccount` / `_disconnectTrakt`；标题行插入胶囊按钮；日历页两处 prefs 读取改用 `TraktPreferences` 常量 |
| `test/trakt_auth_test.dart`（新增） | 按钮三态文案 / 图标 / selected、窄屏文案更短、凭据判定真值表、`read()` 去空白、`saveAccessToken` 只动 token 不动登记信息 |

关键取舍：

- **复用设备码流程而非回调流程**：见「非目标」。用户侧代价是要把 6–8 位码填进网页，换来的是
  不依赖任何回环端口与后台登记地址，任何一台机器都能连上。若用户希望"点一下即登录"，
  需要先在 Trakt 应用后台登记一个回环地址，再按该地址实现回调 —— 属独立工作。
- **按钮样式用新胶囊而不是复用圆形图标按钮**：连接状态必须用文字表达（「未连接/已连接」），
  纯图标靠 tooltip 说明不够；胶囊仍是同一套玻璃与动效令牌，没有另立风格。
- **状态判定抽成纯函数**：`traktConnectButtonState()` 不依赖 BuildContext，可直接单测，
  也避免以后有人把"授权中"错标成选中态。
- **测试文件不依赖 `media_center.dart` 的私有页面**：只测纯函数与凭据层，避免为测试暴露私有 State。

## 兼容与迁移

- 旧版本数据可继续读取：是。键名未变，设置页写入的令牌日历页照旧能读。
- Windows / Android 差异：桌面走 `cmd /c start` 打开浏览器，Android 走宿主
  `Intent.ACTION_VIEW`（`WindowHost.openUrl` 已分别处理），失败时对话框都会显示可复制的地址。
- 回滚是否安全：是。删除 `TraktAuthDialog` 调用与按钮即可；已写入的令牌本就是设置页可编辑的既有键。
- 无需迁移、清理或功能开关。

## 验收标准

- [x] 日历页标题行右侧出现 Trakt 入口，文案与点亮状态随连接态变化
- [x] 点击后打开浏览器，登录期内应用自动等待，成功即写令牌并刷新日历
- [x] 空数据和失败路径可恢复：缺凭据可直达设置；取码失败/超时可「重新获取」；取消不留残留
- [x] 不引入虚假生产数据：未连接时沿用既有「未连接 Trakt」文案，不伪造时刻或进度
- [x] 不泄露敏感信息：Client Secret 不进 UI、不进日志
- [x] Windows 与 Android 的预期差异已说明（仅"用哪个浏览器打开"不同）
- [ ] 人工双端验证：见下表（**未执行**）

## 验证计划

### 自动化

- [x] `dart format`（`D:\flutter\bin\cache\dart-sdk\bin\dart.exe format` 于 4 个改动文件，0 changed）
- [ ] `flutter analyze --no-fatal-infos --no-fatal-warnings` —— **未执行**（环境阻塞，见下）
- [ ] `flutter test test/trakt_auth_test.dart` —— **未执行**（同上）
- [ ] 其他针对性测试：`flutter test`（日历相关：`calendar_events_test.dart`）

⚠️ **本轮无法执行 analyze / test / build**：Dart 运行时无法派生任何子进程，全部命令报
`CreateFile failed 231 (所有的管道范例都在使用中。)` + `ProcessException ... process_win.cc:744`
（`dartaotruntime.exe` / `where.EXE aapt` 都起不来）。已确认与代码、与沙箱权限无关：
Bash 工具 / PowerShell 工具 / 关闭沙箱三种路一致失败，而**非 Dart** 的原生进程
（`python.exe` 派生带管道的子进程）完全正常 → 机器级管道实例耗尽。
**恢复方式**：重启 WorkBuddy 桌面端（或重启机器）后补跑上面两条命令。

### 人工验证

| 平台/尺寸 | 操作路径 | 预期结果 | 结果 |
|---|---|---|---|
| Windows 宽屏 | 日历页 → 未配置凭据时点「连接 Trakt」 | 弹提示，点「前往设置」切到设置 | 未执行 |
| Windows 宽屏 | 设置页填好 Client ID / Secret → 回日历点「连接 Trakt」 | 浏览器打开 trakt.tv/activate，对话框显示授权码 | 未执行 |
| Windows 宽屏 | 网页输入授权码并确认 | 对话框自动关闭，按钮变「Trakt 已连接」，日历刷新出 Trakt 条目 | 未执行 |
| Windows 宽屏 | 点「Trakt 已连接」→ 断开连接 | 按钮回到「连接 Trakt」，日历回到本地待看 | 未执行 |
| Android 窄屏 | 同流程 | 走系统浏览器打开同一地址；标题行不溢出（短文案） | 未执行 |

## 风险与回滚

- 主要风险 1：Trakt 应用后台未登记设备授权 → `oauth/device/code` 返回 4xx，对话框直接报错
  （不会静默失败），用户需在 trakt.tv 的应用设置里确认类型为「设备」或允许设备流程。
- 主要风险 2：轮询期间用户关掉对话框 → `dispose` 里 `TraktClient.dispose()` 关掉连接，
  在途请求立即失败退出，不会继续打 Trakt 接口；即使已授权，令牌也不会被写入（需重新点一次）。
- 主要风险 3：本轮**静态检查与测试未跑**，可能存在编译期错误（见「验证计划」），
  首次构建前应先补跑 `flutter analyze`。
- 监测方式：日历页 `_traktMessage` 文案 + 对话框内联报错。
- 回滚步骤：还原 `lib/src/media_center.dart` 的标题行与三个方法、删除
  `lib/src/tracking/trakt_auth.dart` 与 `test/trakt_auth_test.dart`（`YingjiGlassPillButton`
  可保留，属通用组件）。

## 实现记录

- 新增 `lib/src/tracking/trakt_auth.dart`（约 330 行）、`test/trakt_auth_test.dart`（6 个用例）；
  修改 `lib/src/brand.dart`（新增 `YingjiGlassPillButton`）、`lib/src/media_center.dart`
  （日历页状态 + 三个方法 + 标题行按钮 + 两处键名改常量）。
- 与原规格的偏差：增加「窄屏短文案」与「账户对话框（断开 / 重新授权）」两项 —— 前者为避免
  窄屏标题行被挤，后者为让「已连接」状态下的按钮仍然有明确动作。
- 测试结果：**未执行**（环境阻塞，原因见「验证计划」）。`dart format` 通过，
  可确认四个文件语法可解析、格式合规，但**类型错误未被检查**。
- 遗留事项：
  1. 环境恢复后补跑 `flutter analyze` + `flutter test`，并做双端人工验证；
  2. 连接成功后才暴露的 `TraktClient.calendar` 午夜占位误判（`T00:00:00.000Z` → 显示 08:00），
     需在真正连上后优先修；
  3. 设置页仍用字面量键名写 prefs，可择机改用 `TraktPreferences` 常量。
