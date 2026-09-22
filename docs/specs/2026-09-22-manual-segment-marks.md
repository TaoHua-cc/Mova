# 播放器手动片头片尾

## 基本信息

- 标题：播放器手动片头片尾优先
- 日期：2026-09-22
- 状态：已完成
- 影响平台：Windows / Android

## 背景与问题

Android 播放页已有当前位置标记，但使用标题键；Windows 原生播放页没有设置入口，公共来源结果也不会被用户值覆盖。

## 目标

- 播放器片头片尾菜单可将当前位置设为片头结束或片尾开始，并可清除。
- 手动值按剧集保存，优先于服务器和公共数据库结果。
- Windows 与 Android 读取同一套新键，同时兼容 Android 旧键。

## 非目标

- 不修改公共片段服务协议，不跨设备同步手动标记。

## 用户流程与界面

打开播放器“片头片尾”，点“设为片头结束”或“设为片尾开始”；保存后菜单显示“手动设置”，自动跳过立即按该时间工作。已有手动值时提供清除入口。

## 数据与接口

- 新键：`yingji.segment.manual.<剧集标识>.intro|outro`，值为毫秒整数。
- 剧集标识优先使用 TMDB + 季集，缺失时使用来源和服务器条目 ID。
- Windows 原生进程通过 stdout 回传标记，Flutter 保存后重新下发片段。

## 兼容与迁移

- Android 继续读取旧标题键；用户重新设置时写入新键。
- Windows 与 Android 共用片段合并规则；回滚不影响旧数据。

## 验收标准

- [x] 两端均可设置和清除当前剧集的片头结束、片尾开始。
- [x] 手动值替换同类型自动结果，其余片段保留。
- [x] 换集后读取对应剧集的手动值。
- [x] 空数据和失败路径可恢复。
- [x] 不引入虚假生产数据或泄露敏感信息。

## 验证计划

- `dart format --output=none --set-exit-if-changed lib test`
- `flutter analyze --no-fatal-infos --no-fatal-warnings`
- `flutter test`
- MSVC `/W4 /WX` 与 Windows Release 构建。

## 风险与回滚

- 无身份的媒体无法稳定跨资源关联；这种情况只按来源条目保存。
- 删除新键及原生回传分支即可回滚。

## 实现记录

- Windows 原生菜单新增设置和清除入口，回传后按当前剧集保存并热重载；当前会话立即采用手动值。
- Android 改用同一身份键并保留旧键读取兼容。
- `flutter analyze --no-fatal-infos --no-fatal-warnings` 通过（18 条既有 info）；`flutter test` 98 项通过；MSVC `/W4 /WX` 通过。
