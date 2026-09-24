# Mova 待看与 Trakt 个人日历合并

## 背景与目标

连接 Trakt 后，日历只显示 Trakt 个人日历，导致只加入 Mova 本地待看、没有加入 Trakt 的剧集没有播出安排。日历应始终覆盖 Mova 本地待看的剧集；Trakt 已连接时，再把 Trakt 个人日历作为额外来源合并。

## 数据与行为

- Mova 本地追剧项继续通过现有 TMDB/TVmaze 播出安排路径查询，不写入或删除 Trakt 账号数据。
- Trakt 已连接且个人日历请求成功时，将个人日历与 Mova 本地结果合并去重。
- Trakt 请求失败时保留本地 Mova 日历和上次成功缓存；断开时仍只显示本地 Mova 日历。
- 本地播出安排缓存与 Trakt 个人日历缓存继续分开保存，旧缓存格式不变。

## 验收

- 仅存在于 Mova 待看的剧，连接 Trakt 后仍显示其已公布播出安排。
- Trakt 个人日历中额外的剧集也显示，重复集只保留一张卡。
- 网络失败或未连接 Trakt 时不丢失 Mova 本地播出安排。
- 不向 Trakt 账号写入 Mova 本地待看条目。

## 验证记录

- 全量 Flutter 测试：181 项通过；静态分析无 error/warning，保留 19 条既有 info。
- Windows Release 构建及 GPU-next libmpv 替换成功，并部署到 `D:\Mova`。
- `mova.exe` 与 `data/app.so` 的安装文件哈希均与构建产物一致。
- 单元测试覆盖 Mova 本地与 Trakt 个人日历的并集。
