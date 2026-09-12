# Mova 改动与发布流程

## 核心约定

**先改要改的那一端，验证通过后再同步到其他端，最后发版。**

Windows 与 Android 共用同一套业务源码（`lib/`），所以绝大多数改动天然是双端生效的；
平台专属的部分（窗口控制、签名、图标、ABI 拆分）各自独立。

| 改动类型 | 涉及位置 | 是否需要同步 |
|---|---|---|
| 界面、播放、数据逻辑 | `lib/` | 两端自动生效，**但两端都要重新构建验证** |
| 窗口 / 沉浸式 / 屏幕常亮 | `lib/src/platform/window_host.dart` | 需分别在两端验证行为 |
| 安卓包名、图标、ABI、签名 | `android/` | 只影响安卓 |
| Windows 安装器、图标 | `windows/`、`installer/` | 只影响 Windows |

> 关键区别：**改共享代码时，"同步"不是改代码，而是"重新构建另一端并验证"。**
> GitHub 上的源码永远是最新的，但 Release 里的安装包不会自己更新 —— 必须重新打包。

## 版本号约定

版本号有**两个地方**要同步，另有**一个 tag**：

| 位置 | 作用 | 示例 |
|---|---|---|
| `pubspec.yaml` 的 `version:` | 前后段分别是 版本名 和 build 号 | `3.1.80+87` |
| `installer/Mova.iss` 的 `AppVersion` | Windows 安装器显示版本；CI 会覆盖它 | `3.1.80` |
| Git tag | 触发发版流水线 | `v3.1.80` |

- `+` 后面的 build 号就是安卓 `versionCode`，**每次发版必须递增**，否则手机不接受覆盖更新
- tag 必须带 `v` 前缀，格式 `vX.Y.Z`
- CI 以 **tag 为准**；若 pubspec 与 tag 不一致会给出警告

## 日常改动（不发布）

```bash
# 1. 改代码
# 2. 提交并推送 —— 两个工作流会并行跑，等于双端编译验证
git add -A && git commit -m "feat: ..." && git push origin main
```

推送后 GitHub Actions 会自动：

- `Android Build` → `flutter analyze` + 按 ABI 拆分的三个 APK
- `Windows Build` → `flutter analyze` + Windows 程序 + Inno Setup 安装器 + 免安装压缩包

两个都绿了，说明双端都能编译。**再分别在真机上验证行为**（尤其是布局与交互类改动），
然后才进入发版。

## 发版（打 tag 自动发布）

```bash
# 1. 递增版本号
#    pubspec.yaml:  3.1.80+87  ->  3.1.81+88
# 2. 提交
git add pubspec.yaml && git commit -m "release: Mova 3.1.81" && git push origin main
# 3. 打 tag 并推送（这一步触发发版）
git tag v3.1.81 && git push origin v3.1.81
# 4. 等 Actions 里的 Release 工作流跑完，Releases 页面会自动出现新版本
```

也可以用 `scripts/cut-release.ps1` 一步完成版本号递增 + 提交 + 打 tag + 推送：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\cut-release.ps1 -Version 3.1.81
```

想只构建、不发布时，到 Actions 页面手动触发 `Release` 工作流，**tag 留空**即可。

### 发版产物命名

| 平台 | 文件 |
|---|---|
| Windows | `Mova-3.1.81-Windows-x64-Setup.exe`（安装器） |
| Windows | `Mova-3.1.81-Windows-x64-Portable.zip`（免安装） |
| Android | `Mova-3.1.81-android-arm64-v8a.apk`（推荐） |
| Android | `Mova-3.1.81-android-armeabi-v7a.apk` |
| Android | `Mova-3.1.81-android-x86_64.apk` |

## 工作流一览

| 工作流 | 触发 | 作用 |
|---|---|---|
| `android-build.yml` | push 到 main、PR | 安卓编译验证 + 上传 APK 产物（不发版） |
| `windows-build.yml` | push 到 main、PR | Windows 编译验证 + 上传安装器产物（不发版） |
| `release.yml` | 推送 `v*` tag、手动触发 | 双端构建 → 创建 GitHub Release 并挂上全部安装包 |

## 一次性配置：安卓发布签名

**这一步不做完，安卓包只能用 debug 签名**——别人第一次能装，但装过旧版的用户无法覆盖更新。

1. 把密钥库转成 base64：

   ```bash
   base64 -w0 android/mova-signing.jks > keystore.b64     # Linux / Git Bash
   # PowerShell: [Convert]::ToBase64String([IO.File]::ReadAllBytes("android\mova-signing.jks")) | Set-Content keystore.b64
   ```

2. 到仓库 `Settings → Secrets and variables → Actions → New repository secret` 添加：

   | Secret | 值 |
   |---|---|
   | `ANDROID_KEYSTORE_BASE64` | `keystore.b64` 的全部内容（单行） |
   | `ANDROID_KEYSTORE_PASSWORD` | 密钥库口令 |
   | `ANDROID_KEY_ALIAS` | `mova` |
   | `ANDROID_KEY_PASSWORD` | 密钥口令 |

3. 删掉本地的 `keystore.b64`，别留在磁盘上。

配置好后，`release.yml` 会自动还原密钥并给 APK 签名，无需再手工重签名。

> 安全提醒：密钥库（`.jks`）是发布包的更新凭证。丢了就无法给已安装的用户推送更新；
> 泄露则别人能伪造你的更新包。请离线备份，且**永远不要提交到仓库**
> （`.gitignore` 已忽略 `*.jks` / `key.properties`）。

## 本地构建（需要本机有 Flutter SDK）

```bash
# 安卓
flutter build apk --split-per-abi --release
# 产物：build/app/outputs/flutter-apk/app-{arm64-v8a,armeabi-v7a,x86_64}-release.apk

# Windows 程序
flutter build windows --release

# Windows 安装器（需先装 Inno Setup 6）
ISCC.exe /DAppVersion=3.1.81 installer\Mova.iss
# 产物：dist-installer\Mova-3.1.81-Windows-x64-Setup.exe

# 或者直接跑现成脚本（内含 Flutter 与 ISCC 路径）
build-release.cmd
```

## 遗留事项

- `pubspec.yaml` 的 `name` 仍是 `yingji`（刻意未改，避免全量 import 变更）；安卓 `applicationId` 是 `com.taohua.mova`
- 中文字体约 42MB，尚未子集化
- 旧包 `com.example.yingji` 的观看记录不会自动迁移到新包名
