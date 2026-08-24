# Microsoft Store 提交清单

## 必须从 Partner Center 获取

- 保留的产品名称
- Package/Identity/Name
- Package/Identity/Publisher
- Publisher display name
- 开发者支持邮箱或网页
- 隐私政策公开网址

把前三项准确填入 `package.json` 的 `build.appx`，大小写与标点必须完全一致，再重新构建 AppX/MSIX 包。

## 建议提交路线

使用 MSIX/AppX。商店会在认证通过后重新签名；相比 EXE 路线，无需自行购买 CA 代码签名证书。

## 上架素材

- 应用名称：映迹
- 简短说明：连接多个 Emby 服务器，以 TMDB 与 Trakt 发现内容，并使用 mpv 高品质播放。
- 分类建议：娱乐
- 年龄分级：根据所展示影视内容及目标市场在 Partner Center 完成问卷
- 截图：至少准备首页、媒体库、详情页、追剧日历和连接设置

提交前运行 Windows App Certification Kit，并在 HDR 与 SDR 显示器、不同 DPI、无网络和服务器断开状态下测试。
