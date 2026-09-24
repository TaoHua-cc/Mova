# Trakt 待看同步与追剧日历

## 基本信息

- 日期：2026-09-24
- 状态：已实现并部署 Windows 本地版
- 影响平台：Windows / Android（共享逻辑）

## 背景与目标

Mova 日历必须以 Mova 本地待看为过滤范围查询 Trakt 全站播出日历；连接 Trakt 后，同时并入用户个人日历。Trakt Watchlist 的影视应导入 Mova，Mova 新增待看也加入已授权的 Trakt Watchlist。日历卡片的播出时刻融入海报，不显示独立黑底；平台 Logo 放大并透明呈现。

## 数据与接口

- Trakt 全站播出安排：`GET /calendars/all/shows/{start_date}/31?extended=full`，使用应用 Client ID；按 Mova 待看剧集的 TMDB ID 过滤。
- 个人播出安排：已连接时请求 `GET /calendars/my/shows/{start_date}/31?extended=full` 并合并。
- 待看同步：已连接时读取 Trakt `/sync/watchlist/shows` 与 `/sync/watchlist/movies`，对比本地与最后同步快照；向 `/sync/watchlist` / `/sync/watchlist/remove` 提交两侧新增/移除项。
- 双向增删：用户已确认在一边移出待看时同步从另一边删除。首次同步按合并处理，不因没有历史快照而批量删除任何一侧数据。
- 全站/个人日历使用独立缓存，失败时保留缓存与现有 TMDB/TVmaze 备用安排；不改变现有本地持久化格式。

## 技术方案与安全

- 使用现有 TraktClient、OAuth 凭据、WatchlistStore 与日历合并逻辑。
- 只同步含有效 TMDB ID 的剧集/电影；远端新增项导入时不覆盖 Mova 本地已有元数据。
- 同步快照使用独立 SharedPreferences 键；只有双侧读取和远端写入成功后才更新，避免单边失败导致误删。
- 所有外部请求使用短超时、可恢复错误，并保留离线缓存。

## 验收标准

- [x] 未连接时从 Trakt 全站日历中筛选 Mova 待看，API 失败回退到 TMDB/TVmaze 与缓存。
- [x] 已连接时额外并入 Trakt 个人日历，重复集去重。
- [x] Trakt Watchlist 导入 Mova；Mova 待看仅将缺失项加入 Trakt。
- [x] 卡片时刻无黑底，平台 Logo 更大、透明并融入海报。
- [x] 同步失败不清空任何一侧的既有本地数据。
- [x] 有历史共同快照后，两边移除都会同步删除；首次同步仍只合并，不执行删除。

## 验证

- [x] MockClient 覆盖全站日历过滤、待看上传/导入和删除同步；纯逻辑测试覆盖两侧删除与首次合并。
- [x] 全量 Flutter 测试通过（186 项）；静态分析通过（19 条既有 info）；Windows Release 构建成功并部署至 `D:\Mova`。
- [ ] Windows 宽/窄窗口人工检查（本轮未执行）。

## 风险与后续

- Trakt 全站日历接口受服务端可用性影响，遇到超时/错误时使用已有缓存与 TMDB/TVmaze 安排，不将暂时空响应解释为删除事件。
- 两端共享业务代码；本轮按用户范围只构建和部署 Windows，Android 未单独构建验证。
