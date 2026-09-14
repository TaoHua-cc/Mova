# 本地 Windows 构建直传 Continuous Release

## 基本信息

- 标题：本地 Windows 包直传并保留 GitHub Android 构建
- 日期：2026-09-14
- 状态：已搁置
- 影响平台：Windows / Android

## 背景与问题

每次推送 `main` 后，GitHub Actions 会重新构建 Windows 和 Android。Windows 包已经在开发机本地构建完成，云端再次构建 Windows 产生重复等待。

## 目标

- 该方案已搁置。日常推送恢复由 GitHub Actions 完整构建 Windows 与 Android，并更新 `Mova Continuous`。

## 非目标

- 不将 GitHub Token 写入仓库、脚本或普通配置文件。
- 不改变 Android 签名、版本号或正式发版语义。

## 用户流程与界面

开发机首次执行 `gh auth login` 授权 GitHub CLI。日常 Windows 改动完成后：本地构建、运行上传脚本、推送 main；Release 中 Windows 附件来自本机，Android APK 稍后由 GitHub workflow 补齐。

## 数据与接口

- 使用 GitHub CLI 的安全凭据存储和 GitHub Release API。
- Release tag：`continuous`。
- 本地产物：`dist-installer/Mova-<version>-Windows-x64-Setup.exe` 与 `...-Portable.zip`。

## 技术方案

- 新增本地上传 PowerShell 脚本，要求已登录的 GitHub CLI。
- Release 工作流在 branch push 时跳过 Windows job；tag 和手动构建保持原 Windows job。
- 发布 job 在 branch push 时等待 Android job；Windows 附件由本地上传脚本维护。

## 兼容与迁移

- 已存在的 `continuous` tag/Release 继续使用。
- 未配置 GitHub CLI 时本地上传会明确失败，不会泄露令牌。
- 没有本地 Windows 环境时，仍可用 tag 或手动 workflow 构建 Windows。

## 验收标准

- [ ] 该方案不再作为日常发布流程。

## 验证计划

### 自动化

- [ ] PowerShell 脚本参数与文件检查
- [ ] 工作流 YAML 静态检查

### 人工验证

| 平台 | 操作 | 预期结果 | 结果 |
|---|---|---|---|
| Windows | 构建后运行上传脚本 | Continuous Release 更新两个 Windows 附件 | 通过（3.1.101） |
| GitHub Actions | 推送 main | Android job 运行，Windows job 跳过 | 待验证（本次工作流启动早于策略切换） |

## 风险与回滚

- 风险：本机未认证或网络代理不可用时上传失败。
- 回滚：恢复 workflow 的 Windows job 条件，继续完全使用 GitHub 构建。

## 实现记录

- 已安装并用 GitHub CLI 安全凭据完成 `TaoHua-cc` 授权。
- 已新增 `scripts/upload-continuous-windows.ps1`，上传前检查授权、版本与两个本地产物。
- `main` 工作流跳过 Windows job；tag 和 workflow_dispatch 保留 Windows job。publish job 接受 Windows job 的 skipped 状态。
- 本次旧工作流在策略切换前已完成，Continuous Release 中已存在 3.1.101 Windows 与 Android 附件。后续推送需用新脚本验证直传流程。
- 已实际验证过本地直传，但用户选择以“推送即 GitHub 完整构建并发布”为唯一日常流程，因此已恢复完整云端构建；本规格保留为已搁置的决策记录。
