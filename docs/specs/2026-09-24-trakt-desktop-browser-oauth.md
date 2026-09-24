# Windows Trakt 浏览器回调授权

## 基本信息

- 标题：Windows Trakt 浏览器回调授权
- 日期：2026-09-24
- 状态：已完成
- 影响平台：Windows（Android 保持设备码流程）
- 关联 Issue、提交或版本：无

## 背景与问题

Windows 上连接 Trakt 目前打开浏览器后仍要求用户手工输入设备码，不符合常见桌面应用的网页登录并自动返回体验。

## 目标

- Windows 点击授权后打开 Trakt 标准 OAuth 授权页面，授权完成经 loopback 回调自动回到 Mova。
- 使用随机 `state` 防止伪造回调；仅监听 IPv4 loopback，并验证回调路径、state 和 code。
- 保存 access/refresh token，并在过期前旋转刷新 token；断开连接清除令牌。
- 保留 Android 的现有设备码授权。

## 非目标

- 不实现自定义 URL scheme 注册，不引入回调代理/云服务，不改服务端协议。
- 不更换用户自建 Trakt API App 的 Client ID/Secret 配置方式。

## 用户流程与界面

用户在 Trakt API App 设置中登记 Mova 显示的精确回调地址，然后在设置里填 Client ID 和 Client Secret。点击授权后，Mova 只绑定 `127.0.0.1` 临时接收一次回调；浏览器打开 Trakt 登录与授权，成功后本地确认页提示授权完成，Mova 自动回到前台、交换并保存令牌并刷新日历。取消、超时、端口冲突、浏览器无法打开、state 不匹配和令牌交换失败均展示错误/重试入口。

## 数据与接口

- 新增 preferences：`yingji.trakt.refresh-token` 与 `yingji.trakt.expires-at`；既有 access token 键保持不变。
- OAuth 使用 `auth.trakt.tv/oauth/authorize` 与 `/oauth/token`，授权码与 refresh token grant。
- 回调登记地址：`http://127.0.0.1:43829/trakt/callback`，必须在 Trakt App 后台精确登记。
- 令牌仅存现有 SharedPreferences 配置体系；不记录在日志。

## 技术方案

使用 Dart `HttpServer` 只绑定 `InternetAddress.loopbackIPv4` 固定端口，使用 256-bit secure random state，校验回调来源、path 和 state。授权码交换与 refresh token 请求复用 TraktClient。Windows/Desktop 用授权码回调；Android 保留设备授权。重复认证请求共用单例刷新 Future，避免并发旋转 refresh token。

## 兼容与迁移

- 旧版 access token 仍可读取；因设备码流程不持有 refresh token，现有 token 过期后需重新授权。
- 新版安装后用户需要在 Trakt API App 中登记上述 redirect URI。旧应用注册值不匹配时，授权会被 Trakt 拒绝，并需更新应用设置。
- 共享 token 存储与 refresh helper 对两端可用；仅 Windows/Desktop 改为回调授权，Android 保持设备码。
- 回滚安全：新增偏好键可以忽略，不清理旧 access token。

## 验收标准

- [x] 浏览器授权后自动返回桌面回调并连接，无需手输设备码。
- [x] 错误 state、非 loopback 或错误 path 不会交换 token；用户取消/超时/端口冲突可恢复。
- [x] token 与 refresh token 保存；临近过期后 refresh token 轮转保存。
- [x] Android 原设备码流程仍可工作。
- [x] 不记录凭据或授权码。

## 验证计划

### 自动化

- [x] Dart format、flutter analyze、全量 flutter test。
- [x] 回调 state 校验、授权码交换、令牌保存和刷新请求测试。
- [x] Windows Release 与 GPU-next libmpv 构建并部署至 `D:\Mova`。

### 人工验证

| 平台/尺寸 | 操作路径 | 预期结果 | 结果 |
|---|---|---|---|
| Windows | Trakt 日历 → 连接 Trakt → 浏览器授权 | 浏览器提示授权完成，Mova 自动回到前台、连接并刷新 | 未使用真实账号验证 |
| Windows | 错误 Redirect URI / 取消授权 | 错误清晰可恢复，不保存令牌 | 自动化覆盖 state 错误；未跑真实 Trakt 拒绝流程 |
| Android | 设置 → Trakt → 设备授权 | 设备码流程保持可用 | 共享构建外未做 Android 设备验证 |

## 风险与回滚

- 风险：固定本机端口被占用或 Trakt 应用登记地址不匹配；提示精确配置地址，失败显示可操作信息。
- 监测：授权 UI、回调/令牌单测和用户登录验证。
- 回滚：恢复设备码入口，保留已有 access token 与新字段。

## 实现记录

Windows/Desktop 已改成授权码回调，绑定固定 IPv4 loopback 端口，只接受正确路径及随机 state；换 token 与轮转 refresh token 使用 Trakt `auth.trakt.tv` OAuth endpoint。新增过期时间与 refresh token 偏好，继续观看进度、日历、详情标记和播放器 scrobble 在 token 临近过期时共用单飞刷新。Android 保持旧 device-code 授权。完整 178 项测试通过，静态分析无 error，Windows Release/libmpv 构建及 `D:\Mova` 部署成功。真实账号授权尚未实测；用户需先在自己的 Trakt API App 登记精确 Redirect URI `http://127.0.0.1:43829/trakt/callback`。
