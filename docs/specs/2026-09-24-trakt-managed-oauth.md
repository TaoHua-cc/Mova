# Mova 托管 Trakt 网页授权

## 基本信息

- 标题：Mova 托管 Trakt 网页授权
- 日期：2026-09-24
- 状态：实现中
- 影响平台：Windows / Android
- 关联 Issue、提交或版本：无

## 背景与目标

普通用户不应注册 Trakt API App、手填 Client ID / Secret 或访问令牌。用户在 Mova 点击连接后，应在 Trakt 网页登录并授权，Mova 自动完成令牌交换与刷新。

## 技术与安全约束

- Mova Client ID 是公开标识，可随客户端分发；Client Secret 仅保存在 Worker Secret `TRAKT_CLIENT_SECRET`。
- Worker 代理授权码交换、设备码令牌轮询及刷新，不在客户端源码、偏好设置或日志中持有 Client Secret。
- 用户 access/refresh token 仍按现有偏好键读取，以保持旧版本兼容；不得回传给 Worker 日志或缓存。
- 授权码回调继续校验 loopback、路径与随机 state；固定回调 URI 必须与 Trakt App 配置一致。
- Worker 仅转发固定 Trakt OAuth upstream，严格校验 method、grant type、redirect URI 和请求体大小；不缓存令牌响应。

## 兼容与验收

- 删除设置页手工 Client ID、Secret、Access Token 输入项，保留网页登录/授权状态与断开操作。
- 已保存的旧 token 可继续读取；旧的用户 Client ID/Secret 不再用于请求，Secret 可安全删除。
- Windows 浏览器回调和 Android 设备授权均通过 Worker 换取令牌。
- Worker 未配置 Secret 时返回明确的未配置状态，不泄露环境变量或 upstream 错误正文。

## 验证

- Worker Node tests 覆盖授权码交换、刷新、非法 grant、redirect 不匹配、未配置 Secret 与上游失败。
- Flutter tests 覆盖凭据固定、网页登录流程与旧 token 兼容。
- 本地 Worker/客户端测试完成后，仍需维护者在 Cloudflare 配置 Secret 并部署 Worker，再进行真实 Trakt 登录验证。
