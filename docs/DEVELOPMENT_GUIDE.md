# Mova 开发规范与工作流程

本文是 Mova 的长期工程约定，供开发者、AI 编程工具和自动化代理共同使用。它描述“怎样改”；产品定位见 `PRODUCT.md`，视觉与交互规则见 `DESIGN.md`，发布细节见 `RELEASE.md`。

## 1. 项目概览

- 产品：Mova（映迹），私人媒体聚合与播放客户端。
- 技术栈：Flutter / Dart，播放器基于 `media_kit` / libmpv。
- 当前平台：Windows 10/11 与 Android 7.0+。
- 数据来源：TMDB、Emby、Jellyfin、WebDAV、Trakt，以及用户本机缓存。
- Dart 包名仍为 `yingji`，这是兼容性遗留约定，不要仅为改名而批量修改 import。

### 主要目录

| 路径 | 职责 |
|---|---|
| `lib/main.dart` | 应用启动、网络覆盖、播放器与窗口初始化 |
| `lib/src/app.dart` | 应用主题和顶层装配 |
| `lib/src/media_center.dart` | 首页、发现、搜索、服务器、片单、日历与设置主界面 |
| `lib/src/brand.dart` | 品牌令牌、玻璃材质、通用视觉组件与窗口控件 |
| `lib/src/motion.dart` | 动效、按压反馈、HUD 和页面转场 |
| `lib/src/player/` | 播放器、字幕偏好、弹幕和片段规则 |
| `lib/src/metadata/` | TMDB、评分、剧集信息与详情页 |
| `lib/src/sources/` | Emby、Jellyfin、WebDAV 与来源管理 |
| `lib/src/history/`、`playlists/` | 观看状态、待看与片单持久化 |
| `lib/src/cache/` | 元数据、图片、视频和弹幕缓存 |
| `lib/src/network/`、`security/` | 网络代理与敏感信息存储 |
| `lib/src/platform/` | 平台差异与 Windows 窗口行为 |
| `metadata-worker/` | 元数据/评分相关 JavaScript Worker 与测试 |
| `test/` | Dart 单元与 Widget 测试 |
| `.github/workflows/` | Android、Windows 和 Release CI |

`media_center.dart`、详情页和播放器目前较大。新增独立领域逻辑时优先放入对应子目录，避免继续扩大主页面文件；但不要为小改动做无关的大规模拆分。

## 2. 开工前

1. 阅读 `AGENTS.md`、本文件，以及与任务有关的 `DESIGN.md` / `RELEASE.md`。
2. 检查 `git status`，保留并避开用户已有改动。
3. 搜索现有实现、组件、持久化键和测试，优先沿用既有模式。
4. 明确改动是共享逻辑还是平台专属；共享逻辑默认同时影响 Windows 与 Android。
5. 遇到下列任一情况，在 `docs/specs/` 新建规格文档，再开始编码：
   - 新增完整功能或跨越两个以上领域目录；
   - 改变用户流程、数据模型、持久化格式、网络协议或权限；
   - 涉及缓存迁移、账户/凭据、更新、签名或发布；
   - 需求存在多个合理方案，需要记录取舍。

规格文件命名为 `YYYY-MM-DD-short-topic.md`，使用 `docs/CHANGE_SPEC_TEMPLATE.md`。小型、局部且行为明确的修复可直接实现，但交付时仍需说明验证结果。

## 3. 实现规范

### Dart 与代码组织

- 遵循 `analysis_options.yaml` 和 `flutter_lints`；提交前运行 `dart format`。
- 复用已有模型、客户端、Store 和通用组件，不复制相近实现。
- UI、网络、持久化与解析逻辑尽量分离。可独立验证的业务规则写成纯函数或小型类。
- 异步 UI 更新前检查生命周期；已有代码采用的 `mounted` 规则应继续保持。
- 用户可见错误要给出上下文和恢复入口，不能静默吞掉关键失败。
- 不无界重试，不在 build 方法中发起重复网络请求，不因页面反复进入制造请求风暴。

### 界面与交互

- `DESIGN.md` 是视觉与交互事实来源。
- 优先使用 `brand.dart`、`motion.dart` 中的令牌和组件；圆角、颜色、模糊、阴影、动画时长不得散落硬编码出新的体系。
- 内容卡悬停或获得焦点时不得引发布局位移。
- 宽屏与窄屏共享信息架构，但导航、排列和触控目标可按平台适配。
- 关键操作必须有清晰文本/Tooltip、键盘焦点和足够对比度，不得只靠颜色表达状态。
- 播放器改动要检查控件遮挡、字幕安全区、键盘快捷键、触控手势和屏幕常亮行为。

### 数据、网络与隐私

- 只展示真实来源返回或本机已保存的数据；测试数据只能存在测试代码中。
- Token、密码和签名材料使用现有安全存储与 CI Secrets，禁止写入源码、日志或普通偏好设置。
- 新网络请求应使用项目既有 HTTP/代理路径，遵守超时、失败恢复和服务器级代理设置。
- 修改 SharedPreferences 键、缓存文件名或 JSON 字段时默认保持向后兼容。无法兼容时，在规格中写明迁移、回滚和数据丢失风险。
- 外部数据可能缺字段、超时或返回非预期格式；解析与 UI 必须有空值和失败路径。

### 版本与依赖

- 普通开发不改版本号；仅准备发布时按 `RELEASE.md` 同步版本。
- `movaVersion` 只定义于 `lib/src/version.dart`，不要新增硬编码版本字符串。
- 新增依赖前先确认现有依赖或 Dart 标准库无法满足，并考虑 Windows/Android 支持、包体积、许可和维护状态。
- 更新依赖要保留 `pubspec.lock`，并执行相关双端构建验证。

## 4. 测试与验证

验证强度应与风险匹配。最低建议顺序：

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test
```

修改 `metadata-worker/` 时另执行：

```powershell
node --test metadata-worker/*.test.mjs
```

涉及平台构建时执行：

```powershell
flutter build windows --release
flutter build apk --split-per-abi --release
```

Windows 使用单一的 `MovaNativePlayer.exe` / libmpv 播放器，源码位于 `windows/native_player/`；不得重新引入独立 `mpv.exe`、Lua OSC 或 Flutter 播放页叠加。普通 Android 视频继续走 Flutter 纹理。Windows 发布必须执行 `tool/install_windows_gpu_next.ps1`，用受 SHA-256 校验、启用 libplacebo 的 libmpv 替换历史 DLL；`gpu-next` 才能应用 Dolby Vision 元数据并按实际显示能力输出。不要把该兼容播放路径描述成应用可保证的 Dolby Vision 信号直通。

如果本机缺少 SDK、平台工具、凭据或真机，不能把“未运行”写成“通过”。交付时明确列出未执行项及原因，依赖 GitHub Actions 的部分也要说明。

### 测试要求

- Bug 修复：先描述可复现条件，并添加能防止回归的测试（可自动化时）。
- 纯逻辑：优先单元测试，覆盖正常、空值、异常和边界输入。
- Widget/UI：覆盖核心操作、状态变化、滚动/布局和持久化副作用。
- 网络客户端：避免真实外网依赖，使用可控响应或现有注入方式。
- 设置项：验证只写目标偏好，不意外覆盖其他设置。
- UI 人工验证至少记录设备/窗口尺寸、操作路径和预期结果；共享 UI 应覆盖一个宽屏和一个窄屏场景。

## 5. 标准工作流

### 日常功能或修复

1. 定位相关模块、测试和既有约定。
2. 必要时建立规格，写清验收标准。
3. 做最小完整改动，同时补充测试和必要文档。
4. 格式化并运行针对性测试，再运行完整静态检查/测试。
5. 检查 diff，确认没有凭据、生成物和无关改动。
6. 汇报变更、验证、风险和后续事项。

### 发布

推送 `main` 会自动更新 GitHub Releases 中的 `Mova Continuous` 预发布。正式发版仍属于独立、显式操作：只有用户明确要求时，才按 `RELEASE.md` 修改版本、提交、推送 tag 并创建稳定 Release。开发任务完成不等于自动推送。

## 6. 提交与交付约定

推荐提交标题使用简洁的约定式前缀：

- `feat:` 新功能
- `fix:` 缺陷修复
- `refactor:` 不改变外部行为的重构
- `test:` 测试调整
- `docs:` 文档
- `build:` 构建或依赖
- `release:` 发布版本

提交、推送、创建 tag 或 Release 都需要用户明确授权。交付说明至少包含：

- 做了什么以及影响的平台；
- 执行了哪些命令、结果如何；
- 哪些检查未执行以及原因；
- 已知兼容性风险或需要真机复核的路径。

## 7. 文档维护

- 工程流程变化：更新本文。
- 产品范围变化：更新 `PRODUCT.md`。
- 视觉/交互体系变化：更新 `DESIGN.md`。
- 版本、构建、签名或发布变化：更新 `RELEASE.md`。
- 单项功能设计与决策：保存在 `docs/specs/`，实现完成后补上最终结果和偏差。
- 若代码与文档不一致，应在同一改动中修正文档，避免把过期说明留给下一个工具。
