# 每次 main 推送更新 GitHub Release

## 基本信息

- 标题：持续更新 GitHub Release
- 日期：2026-09-14
- 状态：已完成（待 CI 验证）
- 影响平台：Windows、Android、GitHub 发布流程
- 关联 Issue、提交或版本：待提交

## 背景与问题

此前只有推送 `vX.Y.Z` 标签才会构建并发布 GitHub Release。普通的 `main` 推送仅产生 30 天保留的 Actions artifact，用户无法在 Releases 页面获取最新构建。

## 目标

- 每次推送 `main` 均重新构建双端并更新 GitHub Releases 中的 `Mova Continuous` 预发布条目。
- `Mova Continuous` 始终指向本次 `main` 提交，并替换同名安装包资产。
- 保留 `vX.Y.Z` 标签的正式 Release 流程及其“Latest”语义。

## 非目标

- 不为每次普通提交自动递增公开版本号或 Android `versionCode`。
- 不将持续构建宣称为可覆盖旧正式版的稳定更新。

## 技术方案

- `release.yml` 同时监听 `main` 与 `v*` 标签。
- `main` 事件使用可移动的 `continuous` 标签，发布为 `Mova Continuous` 且标记 prerelease；发布前用 GitHub API 将该标签强制更新到当前提交。
- 正式标签继续用原标签名发布，标记为 Latest。
- 启用资产覆盖，保证同版本名的持续构建能够替换旧文件。
- `main` 不再同时触发独立的 Windows Build 工作流；Release 的 Windows job 是唯一打包任务。

## 兼容与迁移

- 现有正式 Release、标签和安装包不变。
- 用户若安装正式 Android 版，只有持续构建的签名和 `versionCode` 均满足系统规则时才能覆盖；因此持续 Release 页面明确标记为测试预发布。
- 回滚只需恢复 `release.yml` 的 `main` 触发和 continuous 发布步骤。

## 验收标准

- [ ] 推送 `main` 后 `Mova Continuous` 的资产被更新。
- [ ] `continuous` 标签指向触发构建的提交。
- [ ] 推送 `vX.Y.Z` 仍产生正式 Latest Release。
- [ ] 正式历史 Release 不受影响。

## 验证计划

- [ ] 推送本提交后检查 Release 工作流成功。
- [ ] 检查 Releases 页面中的 `Mova Continuous` 资产更新时间和提交。
- [ ] 推送下一正式标签时检查 Latest 标识。
- [ ] main 不出现重复 Windows 打包。

## 风险与回滚

- 风险：持续构建使用与正式版相同版本号时，Android 可能拒绝覆盖安装；因此只作为预发布测试包。
- 回滚：移除 `main` 触发和 continuous 标签更新步骤。

## 实现记录

- 已配置持续预发布和正式标签发布的并行策略。首次运行发现 GitHub 创建不存在 ref 时返回 422 的兼容性问题，已改为先查询 ref 再创建；并移除了 main 的重复 Windows 构建，等待后续 CI 验证。
