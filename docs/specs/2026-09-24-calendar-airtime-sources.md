# 追剧日历：精确播出时刻的可得性诊断

- 日期：2026-09-24
- 状态：诊断完成，**未改动生产代码**
- 触发：用户反馈「追剧日历的时间获取，很多剧获取不到具体时刻」
- 复现：`python tool/probe_calendar_airtime.py [--tvmaze]`

## 1. 结论（先说结果）

**25/53 条（47%）无时刻，根因是上游数据缺失，不是应用取不到。** 时刻在本应用里
只有**一个**来源 —— TVmaze 的集级 `airtime`；TMDB 从不提供播出时刻。TVmaze 在
三种情况下返回 `airtime: ""`，应用如实显示「时刻未公布」。

同时确认两件事：**日历覆盖没有缺失**（不进日历的剧确实没有已公布的未来集），
以及 **应用对 TVmaze 的占位时刻有正确防御**（见 §4）。

## 2. 数据链路

```
_CalendarPageState._load()
├─ TraktClient.calendar()  ← 需要 client-id + token；当前未配置 → 恒为空
├─ tracked = watchlist(kind=='剧集') ∪ watch-states(有 tmdbId 且 seasonNumber 非空)
└─ _localWatchlistEvents(tracked)
     └─ TmdbClient.upcomingEpisodes(item)          # horizon 90 天
          ├─ TMDB  /tv/{id}?append_to_response=external_ids
          │    ├─ seasons → season/{n} → episodes.air_date      ← 只有日期
          │    └─ next_episode_to_air                           ← 只有日期
          └─ TVmaze /lookup/shows?imdb=|thetvdb= → /shows/{id}/episodes
               └─ episodes[].airtime / airstamp                 ← 唯一精确时刻来源
     ↓ 按 `season:episode` 合并（TMDB 保中文标题与季集号，TVmaze 只补时刻）
   TraktEvent.timeKnown
```

`timeKnown` 的判定（`upcomingListFromTvmaze`）：

```dart
final known = '${row['airtime'] ?? ''}'.isNotEmpty        // ① 必须有 airtime
    && RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(stamp);   // ② airstamp 必须带时区
```

Trakt 侧的判定（`TraktClient.calendar`）只看 `first_aired` 是否带时区：

```dart
timeKnown: RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch('${item['first_aired']}'),
```

## 3. 实证（本机真实数据）

prefs：`%APPDATA%\Mova\Mova\shared_preferences.json` →
`flutter.yingji.tracking.calendar-cache`（53 条）。

| 剧名 | 有时刻 | 无时刻 | 无时刻日期范围 | 平台 |
|---|---|---|---|---|
| 兰香如故 | 19 | 0 | — | 腾讯视频 |
| 柯蒂斯总统 | 1 | 0 | — | Adult Swim |
| 凡人修仙传 | 8 | 5 | 2026-11-21 ~ 12-19 | bilibili |
| 择日飞升 | 0 | 13 | 2026-09-26 ~ 12-19 | iQiyi |
| Dark Matter | 0 | 6 | 2026-09-25 ~ 10-30 | Apple TV |
| 斯图尔特未能拯救宇宙 | 0 | 1 | 2026-09-24 | HBO Max |
| **合计** | **28** | **25** | | |

**平台字段的大小写即来源**（可作快速判别）：`Bilibili` / `Tencent QQ` 来自 TVmaze
（官方名，有时刻），`bilibili` / `iQiyi` / `Apple TV` 来自 TMDB（自己那套，无时刻）。

### 三类缺时刻的原因

**(1) 平台不公开时刻** —— `Dark Matter`(Apple TV+)、`Stuart`(HBO Max)。
TVmaze 有剧有集，但 `airtime=''`、`airstamp` 退化为 `T12:00:00+00:00` 占位：

```
61315  Dark Matter   schedule={'time':'','days':['Friday']}
   S2E5 2026-09-25  airtime=''  airstamp='2026-09-25T12:00:00+00:00'
83360  Stuart Fails to Save the Universe
   S1E10 2026-09-24  airtime=''  airstamp='2026-09-24T12:00:00+00:00'
```

**(2) TVmaze 未登记该剧的外部 ID** —— `择日飞升`（iQiyi）。TVmaze 有记录
（`93208 Zeri Feisheng`），但 `externals={'imdb': None, 'thetvdb': None}`，
而 lookup 只走 imdb/thetvdb 两条路 → **永远匹配不到**；即便匹配到，
`airtime` 也是空：

```
93208  Zeri Feisheng  schedule={'time':'','days':['Saturday']}
   S1E13 2026-09-26  airtime=''  airstamp='2026-09-26T12:00:00+00:00'
```

**(3) 该集尚未被 TVmaze 收录** —— `凡人修仙传` 11-21 起的 5 条。
TVmaze 只登记到 `S8E24 / 2026-11-14`，而 TMDB 已排到 `S1E201 / 2026-11-21`。
两套编号体系（TVmaze 按年分季「第 8 季 第 17 集」，TMDB 国漫统一「第 1 季
第 193 集」）**恰好接续**（E200 → E201），因此没有重复条目，只是远期集缺席时刻。

## 4. 应用侧行为评估

| 观察 | 判定 |
|---|---|
| 拒绝 TVmaze 的 12:00 UTC 占位时刻 | **正确且必要**。若采纳，Dark Matter 会显示「20:00」，纯属编造 —— 违反 AGENTS.md「不得加入虚假数据」 |
| 无时刻时显示「时刻未公布」（12px），时刻用 19px | 合理，两种状态可辨 |
| 无时刻条目 `airDate` 的时刻位恒为 `00:00:00`（0/25 例外） | 说明确实只拿到了日期，没有中间态被吞掉 |
| TMDB 与 TVmaze 的季集号不一致时按 `season:episode` 合并 | 未产生重复；且 `mergeCalendarEvents` 优先保留带时刻的一方 |

### 覆盖检查（12 部追剧表）

| 剧 | TMDB 未来集 | 在日历 | 说明 |
|---|---|---|---|
| 凡人修仙传 / Dark Matter / 择日飞升 / 斯图尔特 / 兰香如故 / 柯蒂斯总统 | 14 / 6 / 18 / 1 / 4 / 1 | ✅ | 有已公布的未来集 |
| 师兄太稳健 / 花开锦绣 / 鼠惑 / 怪物：莉齐·博登的故事 / 早春晴朗 / 侠探杰克 | 0 | — | TMDB `next_episode_to_air=null` 且季数据无未来集 → 合理不进日历 |

`兰香如故` 的 TMDB 侧只有 4 个未来集，TVmaze 侧有 19 个 → 合并后 19 条全带时刻，
说明 TVmaze 兜底在**有效放大**覆盖。

## 5. 可改进项（含收益评估）

| | 内容 | 增益 | 风险 |
|---|---|---|---|
| A | 文案：`时刻未公布` → 「该平台未公开时刻」/「仅公布日期」 | 只改善表述，**不改数据** | 无 |
| B | TVmaze lookup 加**剧名回退**（`/search/shows?q=`），用「剧名+首播年」去歧义 | **当前零收益**（`择日飞升` 的 `airtime` 本身是空），但消除机制缺口：TVmaze 后期补上 `airtime` 时能被采纳 | 同名剧误配 → 必须严格匹配 |
| C | 若 TVmaze 给了 `airtime` 但缺 `airstamp`，用 `airdate + airtime + show 时区` 重建时刻 | 预防性（当前缓存无此案例） | 时区推断可能错 |
| D | 连接 Trakt（当前未配置） | 覆盖更多剧、更早发现新集；**对上述三类无时刻无帮助**（Trakt 的 `first_aired` 同样源自 TVDB/TMDB） | ⚠️ **假时刻风险**：Trakt 对无时刻的集会给 `T00:00:00.000Z` 午夜占位，而现有 `timeKnown` 判定只认「带时区」→ 会当成真时刻显示成 08:00（北京）。连接前应先加「午夜占位」识别 |

**没有任何一项能显著降低当前 47%**：缺时刻来自数据源本身。若要提升，需要引入
新的时刻来源（如按平台更新惯例推断 —— 被 AGENTS.md 禁止）。

## 6. 复现与取证

```bash
python tool/probe_calendar_airtime.py            # 只读本地缓存，输出 §3 的统计
python tool/probe_calendar_airtime.py --tvmaze   # 额外复核 TVmaze 上游的 airtime/占位
```

脚本只读 `shared_preferences.json` 与 `metadata-cache-v1/`，不发凭据；
`--tvmaze` 只访问公开接口。
