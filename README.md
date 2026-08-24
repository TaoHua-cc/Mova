# 映迹

Windows Emby 观影客户端，整合 TMDB、Trakt、多个 Emby 服务器与 mpv 播放内核。

## 功能

- TMDB 中文影视资料、海报与热门榜单
- Trakt 设备授权、热门内容与追剧日历
- 多 Emby 服务器登录、媒体库读取及同名资源聚合
- mpv `gpu-next` / D3D11 / 自动硬件解码
- HDR、Dolby Vision 元数据、ASS/SSA 字幕和多音轨支持
- Emby 播放开始、进度与停止状态回传
- Windows 数据保护加密 API 密钥及访问令牌

## 本地构建

需要 Windows 10/11、Node.js 22+ 与 pnpm。

```powershell
pnpm install --config.blockExoticSubdeps=false
pnpm run fetch:mpv
pnpm run dist:installer
```

TMDB、Trakt 和 Emby 凭据均由用户在应用设置页填写，不应提交到仓库。

## 分发

- `nsis`：完整安装版
- `portable`：免安装便携版
- `appx`：Microsoft Store 包；提交前必须把 `package.json` 中的 AppX Identity 和 Publisher 替换为 Partner Center 提供的准确值

第三方组件信息见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。本仓库当前未授予额外源代码许可证。
