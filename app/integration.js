const readLocalJson = (key, fallback) => {
  try { const value = JSON.parse(localStorage.getItem(key)); return value ?? fallback; }
  catch { localStorage.removeItem(key); return fallback; }
};
const defaultUi = { calendarFilter: 'all', calendarDay: 2, searchFilter: 'all', recentSearches: ['群星','深海之门','逆时之焰','边境集'], hwdec: 'auto-safe', renderer: 'gpu-next', gpu: '', subtitleLanguage: 'auto', subtitleScale: '100', danmakuMode: 'smart', danmakuDensity: 'normal', toggles: { hardware: true, hdr: true, downmix: false, vocal: false, night: false, subtitleEnabled: true, danmakuEnabled: false, traktOnly: false, tmdb: true, emby: true, trakt: false, wifi: true } };
const storedUi = readLocalJson('yingji.ui', {});
const providerConfig = readLocalJson('yingji.providers', { emby: [] });
providerConfig.emby = Array.isArray(providerConfig.emby) ? providerConfig.emby : [];
providerConfig.files = Array.isArray(providerConfig.files) ? providerConfig.files : [];
providerConfig.emby.forEach(server => {
  server.addresses = [...new Set((Array.isArray(server.addresses) ? server.addresses : [server.url]).filter(Boolean))];
  server.activeAddress = Math.min(Number(server.activeAddress) || 0, Math.max(0, server.addresses.length - 1));
  server.url = server.addresses[server.activeAddress] || server.url;
});
const live = { rankings: null, library: [], active: null, heroIndex: 0, detail: null, watchlist: readLocalJson('yingji.live-watchlist', []), search: null, addingServer: false, returnToLibrary: false, sourceStats: {}, sourceIcons: {}, continueItems: [], calendarEvents: [], calendarPosters: {}, selectedSourceId: 'all',
  sourceKind: null, suppressedCalendar: readLocalJson('yingji.calendar-suppressed', []),
  ui: { ...defaultUi, ...storedUi, recentSearches: Array.isArray(storedUi.recentSearches) ? storedUi.recentSearches : defaultUi.recentSearches, toggles: { ...defaultUi.toggles, ...(storedUi.toggles || {}) } } };
live.fileItems = [];
if (!Array.isArray(live.watchlist)) live.watchlist = [];
const prototypeMode = !window.yingjiDesktop;
let discoverySyncing = false;
const discoveryCacheVersion = 5;
const discoveryCacheMeta = readLocalJson('yingji.discovery-meta', {});
const saveProviders = () => localStorage.setItem('yingji.providers', JSON.stringify(providerConfig));
const embyHeaders = token => ({ 'X-Emby-Token': token, Accept: 'application/json' });
const connectionBadge = connected => `<span class="connection ${connected ? 'connected' : ''}">${connected ? '已连接' : '未配置'}</span>`;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const metadataEndpoint = (window.YINGJI_CONFIG?.metadataEndpoint || '').replace(/\/$/, '');
const storedAppearance = localStorage.getItem('yingji.appearance') || 'system';
const resolveAppearance = (value) => value === 'system' ? (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light') : value;
document.documentElement.dataset.appearance = resolveAppearance(storedAppearance);
if (storedAppearance === 'system') {
  const darkMedia = window.matchMedia('(prefers-color-scheme: dark)');
  darkMedia.addEventListener('change', event => { document.documentElement.dataset.appearance = event.matches ? 'dark' : 'light'; });
}

// Product navigation groups supporting tools under the task they serve.
shell = function (body, active = 'home') {
  const section = active === 'search' ? 'discover' : active === 'calendar' || active === 'watchlist' ? 'tracking' : active === 'library' || active === 'downloads' ? 'library' : active;
  const nav = [
    ['home', 'home', '首页'],
    ['discover', 'search', '发现'],
    ['tracking', 'calendar', '追剧'],
    ['library', 'library', '资料库'],
    ['settings', 'settings', '设置']
  ].map(([id, route, label]) => `<button class="${section === id ? 'on' : ''}" data-go="${route}" aria-current="${section === id ? 'page' : 'false'}">${ico(id === 'discover' ? 'search' : id === 'tracking' ? 'calendar' : id)}<span>${label}</span></button>`).join('');
  const sourceCount = (providerConfig.emby?.length || 0) + (providerConfig.files?.length || 0);
  return `<header class="chrome"><b class="brand">映迹</b><div class="win"><span>—</span><span>□</span><span>×</span></div></header><nav class="bar" aria-label="主导航"><div class="sidebar-title"><b>映迹</b><small>私人影音库</small></div><div class="nav">${nav}</div><button class="sidebar-source" data-go="library"><span>${ico('plus')}</span><span><b>媒体来源</b><small>${sourceCount ? `${sourceCount} 个已连接` : '添加服务器或网盘'}</small></span></button><div class="nav-tools"><button data-go="search" aria-label="全局搜索" title="搜索（/）">${ico('search')}</button><button class="profile-button" data-go="settings" aria-label="账户与设置"><span>林</span><b>账户与设置</b></button></div></nav><div class="network-status" role="status" aria-live="polite">当前处于离线状态，已保留本机待看与缓存内容。</div>${body}`;
};
const request = async (url, options = {}) => {
  if (metadataEndpoint && url.startsWith(metadataEndpoint)) {
    const response = await fetch(url, { method: options.method || 'GET', headers: options.headers || {}, body: options.body ? JSON.stringify(options.body) : undefined });
    const text = await response.text();
    const data = text ? JSON.parse(text) : null;
    if (options.acceptErrors) return { status: response.status, data };
    if (!response.ok) throw new Error(`${response.status} ${text.slice(0, 180)}`);
    return data;
  }
  return window.yingjiDesktop.request({ url, ...options });
};
const tmdbRequest = async (path, key = '') => key
  ? request(`https://api.themoviedb.org/3${path}${path.includes('?') ? '&' : '?'}api_key=${encodeURIComponent(key)}&language=zh-CN`)
  : request(`${metadataEndpoint}/tmdb${path}${path.includes('?') ? '&' : '?'}client=yingji-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`);
const normalizeRankingItems = (items, fallbackKind) => {
  const seen = new Set();
  return (Array.isArray(items) ? items : []).reduce((rows, item) => {
    const kind = item.media_type === 'movie' || item.media_type === 'tv' ? item.media_type : fallbackKind;
    if (!item?.id || (kind !== 'movie' && kind !== 'tv') || !(item.title || item.name)) return rows;
    const key = `${kind}:${item.id}`;
    if (seen.has(key)) return rows;
    seen.add(key);
    rows.push({ ...item, kind });
    return rows;
  }, []);
};
const saveRankings = () => {
  localStorage.setItem('yingji.discovery-cache', JSON.stringify(live.rankings || []));
  localStorage.setItem('yingji.discovery-meta', JSON.stringify({ version: discoveryCacheVersion, updatedAt: new Date().toISOString(), shelfCount: live.rankings?.length || 0 }));
};
async function loadMoreRanking(index) {
  const ranking = live.rankings?.[Number(index)], meta = ranking?.[2];
  if (!ranking || meta?.source !== 'TMDB' || !meta.path || meta.loadingMore || Number(meta.page || 1) >= Number(meta.totalPages || 1)) return;
  meta.loadingMore = true; showLiveRanking(Number(index), { preserveScroll: true });
  try {
    let tmdbKey = ''; try { tmdbKey = await window.yingjiDesktop.getSecret('tmdb-key'); } catch {}
    const nextPage = Number(meta.page || 1) + 1, separator = meta.path.includes('?') ? '&' : '?';
    const data = await tmdbRequest(`${meta.path}${separator}page=${nextPage}`, tmdbKey);
    const known = new Set(ranking[1].map(item => `${item.kind || itemKind(item)}:${item.id}`));
    ranking[1].push(...normalizeRankingItems(data.results, meta.kind).filter(item => !known.has(`${item.kind}:${item.id}`)));
    meta.page = Number(data.page || nextPage); meta.totalPages = Number(data.total_pages || meta.totalPages || meta.page); meta.totalResults = Number(data.total_results || meta.totalResults || ranking[1].length);
    saveRankings();
  } catch (error) { meta.loadMoreFailed = true; meta.loadMoreError = error.message || '请检查网络'; notify(`加载更多失败：${meta.loadMoreError}`); }
  finally { meta.loadingMore = false; showLiveRanking(Number(index), { preserveScroll: true }); }
}
const saveLiveWatchlist = () => localStorage.setItem('yingji.live-watchlist', JSON.stringify(live.watchlist));
const saveSuppressedCalendar = () => localStorage.setItem('yingji.calendar-suppressed', JSON.stringify(live.suppressedCalendar));
const saveUi = () => localStorage.setItem('yingji.ui', JSON.stringify(live.ui));
const toggleControl = (key, label) => `<button class="switch ${live.ui.toggles[key] ? '' : 'off'}" type="button" role="switch" aria-checked="${!!live.ui.toggles[key]}" aria-label="${label}" data-toggle="${key}"></button>`;
const catalogItem = id => live.rankings?.flatMap(group => group[1]).find(entry => String(entry.id) === String(id));
const liveCard = (item, index = null) => {
  const title = item.title || item.name || item.original_title || item.original_name;
  const poster = image(item.poster_path, 'w500');
  return `<button class="live-card" data-live-detail="${item.id}" data-kind="${item.kind || itemKind(item)}"><span class="live-poster ${item.posterClass || ''}" ${poster ? `style="background-image:url('${poster}')"` : ''}>${index === null ? '' : `<i>${index + 1}</i>`}</span><b>${esc(title)}</b><small>TMDB ${(item.vote_average || 0).toFixed(1)}</small></button>`;
};

async function syncDiscovery() {
  if (discoverySyncing) return;
  discoverySyncing = true;
  notify('正在同步 TMDB 榜单…');
  try {
    let tmdbKey = '';
    try { tmdbKey = await window.yingjiDesktop.getSecret('tmdb-key'); } catch {}
    let traktId = '';
    try { traktId = await window.yingjiDesktop.getSecret('trakt-client-id'); } catch {}
    if (!tmdbKey && !metadataEndpoint) throw new Error('请先配置影视元数据服务');
    const tmdb = path => tmdbRequest(path, tmdbKey);
    // Every shelf is backed by a documented TMDB list or Discover query. Keep
    // its rule in the cache so the on-screen description remains traceable.
    const sources = [
      { name: '本周趋势', path: '/trending/all/week', kind: 'all', summary: 'TMDB · 近 7 天综合热度' },
      { name: '今日趋势', path: '/trending/all/day', kind: 'all', summary: 'TMDB · 近 24 小时综合热度' },
      { name: '热门国产电视剧', path: '/discover/tv?with_origin_country=CN&sort_by=popularity.desc&vote_count.gte=20', kind: 'tv', summary: 'TMDB · 中国出品剧集热度' },
      { name: '热门国产电影', path: '/discover/movie?with_origin_country=CN&region=CN&sort_by=popularity.desc&vote_count.gte=20', kind: 'movie', summary: 'TMDB · 中国出品电影热度' },
      { name: '热门电影', path: '/movie/popular?region=CN', kind: 'movie', summary: 'TMDB · 当前电影热度' },
      { name: '热门剧集', path: '/tv/popular', kind: 'tv', summary: 'TMDB · 当前剧集热度' },
      { name: '正在热映', path: '/movie/now_playing?region=CN', kind: 'movie', summary: 'TMDB · 中国地区院线档期' },
      { name: '即将上映', path: '/movie/upcoming?region=CN', kind: 'movie', summary: 'TMDB · 中国地区即将上映' },
      { name: '近期热播剧集', path: '/tv/on_the_air', kind: 'tv', summary: 'TMDB · 未来 7 天仍在播出' },
      { name: '今日更新剧集', path: '/tv/airing_today', kind: 'tv', summary: 'TMDB · 今日播出剧集' },
      { name: '全球高分电影', path: '/movie/top_rated?region=CN', kind: 'movie', summary: 'TMDB · 电影高分榜' },
      { name: '全球高分剧集', path: '/tv/top_rated', kind: 'tv', summary: 'TMDB · 剧集高分榜' },
      { name: '动作冒险电影', path: '/discover/movie?with_genres=28|12&sort_by=popularity.desc&vote_count.gte=30', kind: 'movie', summary: 'TMDB · 动作与冒险类型热度' },
      { name: '悬疑犯罪电影', path: '/discover/movie?with_genres=9648|80&sort_by=popularity.desc&vote_count.gte=30', kind: 'movie', summary: 'TMDB · 悬疑与犯罪类型热度' },
      { name: '动画精选', path: '/discover/tv?with_genres=16&sort_by=popularity.desc&vote_count.gte=20', kind: 'tv', summary: 'TMDB · 动画剧集热度' },
      { name: '科幻奇幻剧集', path: '/discover/tv?with_genres=10765&sort_by=popularity.desc&vote_count.gte=20', kind: 'tv', summary: 'TMDB · 科幻与奇幻类型热度' },
      { name: '热门韩剧', path: '/discover/tv?with_origin_country=KR&sort_by=popularity.desc&vote_count.gte=20', kind: 'tv', summary: 'TMDB · 韩国出品剧集热度' },
      { name: '热门日剧', path: '/discover/tv?with_origin_country=JP&sort_by=popularity.desc&vote_count.gte=20', kind: 'tv', summary: 'TMDB · 日本出品剧集热度' },
      { name: '美剧热门', path: '/discover/tv?with_origin_country=US&sort_by=popularity.desc&vote_count.gte=30', kind: 'tv', summary: 'TMDB · 美国出品剧集热度' },
      { name: '英剧热门', path: '/discover/tv?with_origin_country=GB&sort_by=popularity.desc&vote_count.gte=20', kind: 'tv', summary: 'TMDB · 英国出品剧集热度' },
      { name: '喜剧电影', path: '/discover/movie?with_genres=35&sort_by=popularity.desc&vote_count.gte=30', kind: 'movie', summary: 'TMDB · 喜剧类型热度' },
      { name: '爱情电影', path: '/discover/movie?with_genres=10749&sort_by=popularity.desc&vote_count.gte=30', kind: 'movie', summary: 'TMDB · 爱情类型热度' },
      { name: '恐怖惊悚电影', path: '/discover/movie?with_genres=27|53&sort_by=popularity.desc&vote_count.gte=30', kind: 'movie', summary: 'TMDB · 恐怖与惊悚类型热度' },
      { name: '纪录电影', path: '/discover/movie?with_genres=99&sort_by=popularity.desc&vote_count.gte=20', kind: 'movie', summary: 'TMDB · 纪录片热度' },
      { name: '战争历史电影', path: '/discover/movie?with_genres=10752|36&sort_by=popularity.desc&vote_count.gte=20', kind: 'movie', summary: 'TMDB · 战争与历史类型热度' },
      { name: '家庭奇幻电影', path: '/discover/movie?with_genres=14|10751&sort_by=popularity.desc&vote_count.gte=20', kind: 'movie', summary: 'TMDB · 奇幻与家庭类型热度' },
      { name: '悬疑犯罪剧集', path: '/discover/tv?with_genres=80|9648&sort_by=popularity.desc&vote_count.gte=20', kind: 'tv', summary: 'TMDB · 悬疑与犯罪剧集热度' },
      { name: '热门综艺', path: '/discover/tv?with_genres=10764&sort_by=popularity.desc&vote_count.gte=10', kind: 'tv', summary: 'TMDB · 综艺与真人秀热度' },
      { name: '今日热门电视剧', path: '/trending/tv/day', kind: 'tv', summary: 'TMDB · 近 24 小时剧集热度' },
      { name: '今日热门电影', path: '/trending/movie/day', kind: 'movie', summary: 'TMDB · 近 24 小时电影热度' },
      { name: '热门国产综艺', path: '/discover/tv?with_origin_country=CN&with_genres=10764&sort_by=popularity.desc&vote_count.gte=10', kind: 'tv', summary: 'TMDB · 国产综艺热度' },
      { name: '热门国产动漫', path: '/discover/tv?with_origin_country=CN&with_genres=16&sort_by=popularity.desc&vote_count.gte=10', kind: 'tv', summary: 'TMDB · 国产动画热度' },
      { name: '热门番剧', path: '/discover/tv?with_origin_country=JP&with_genres=16&sort_by=popularity.desc&vote_count.gte=10', kind: 'tv', summary: 'TMDB · 日本番剧热度' },
      { name: '热门台剧', path: '/discover/tv?with_origin_country=TW&sort_by=popularity.desc&vote_count.gte=10', kind: 'tv', summary: 'TMDB · 台湾剧集热度' },
      { name: '爱奇艺热播', path: '/discover/tv?with_networks=1330&sort_by=popularity.desc&vote_count.gte=10', kind: 'tv', summary: 'TMDB · 爱奇艺平台热播' },
      { name: '腾讯视频热播', path: '/discover/tv?with_networks=2008&sort_by=popularity.desc&vote_count.gte=10', kind: 'tv', summary: 'TMDB · 腾讯视频平台热播' },
      { name: '哔哩哔哩热播', path: '/discover/tv?with_networks=160&sort_by=popularity.desc&vote_count.gte=10', kind: 'tv', summary: 'TMDB · 哔哩哔哩平台热播' },
      { name: '优酷热播', path: '/discover/tv?with_networks=1419&sort_by=popularity.desc&vote_count.gte=10', kind: 'tv', summary: 'TMDB · 优酷平台热播' },
      { name: '芒果TV热播', path: '/discover/tv?with_networks=138&sort_by=popularity.desc&vote_count.gte=10', kind: 'tv', summary: 'TMDB · 芒果TV平台热播' }
    ];
    const rankingProfile = {
      '本周趋势':'热度', '今日趋势':'热度', '今日热门电视剧':'热度', '今日热门电影':'热度', '热门电影':'热度', '热门剧集':'热度',
      '热门国产电视剧':'地区', '热门国产电影':'地区', '热门韩剧':'地区', '热门日剧':'地区', '热门台剧':'地区', '美剧热门':'地区', '英剧热门':'地区',
      '热门综艺':'类型', '热门国产综艺':'类型', '热门国产动漫':'类型', '热门番剧':'类型', '动画精选':'类型', '动作冒险电影':'类型', '悬疑犯罪电影':'类型', '喜剧电影':'类型', '爱情电影':'类型', '恐怖惊悚电影':'类型', '纪录电影':'类型', '战争历史电影':'类型', '家庭奇幻电影':'类型', '悬疑犯罪剧集':'类型', '科幻奇幻剧集':'类型',
      '爱奇艺热播':'平台', '腾讯视频热播':'平台', '哔哩哔哩热播':'平台', '优酷热播':'平台', '芒果TV热播':'平台',
      '正在热映':'档期', '即将上映':'档期', '近期热播剧集':'档期', '今日更新剧集':'档期', '全球高分电影':'口碑', '全球高分剧集':'口碑'
    };
    // Every defined source is a selectable real-data module. The homepage
    // keeps the user's own ordering and visibility choices instead of dropping
    // regional, category, or platform shelves during sync.
    const activeSources = sources.map(source => ({ ...source, family: rankingProfile[source.name] || '分类', featured: true }));
    const settled = [];
    // Four concurrent requests avoid a burst against either TMDB or a private
    // metadata proxy while still refreshing the shelves quickly.
    for (let offset = 0; offset < activeSources.length; offset += 4) {
      const batch = await Promise.all(activeSources.slice(offset, offset + 4).map(async source => {
        try {
          const data = await tmdb(source.path);
          const items = normalizeRankingItems(data.results, source.kind);
          return items.length ? [source.name, items, { summary: source.summary, source: 'TMDB', family: source.family, featured: source.featured, path: source.path, kind: source.kind, page: Number(data.page || 1), totalPages: Number(data.total_pages || 1), totalResults: Number(data.total_results || items.length) }] : null;
        } catch { return null; }
      }));
      settled.push(...batch.filter(Boolean));
    }
    live.rankings = settled;
    if (!live.rankings.length) throw new Error('TMDB 暂时没有返回榜单，请稍后重试');
    if (traktId) try {
      const headers = { 'trakt-api-version': '2', 'trakt-api-key': traktId };
      const traktSources = [
        { name:'Trakt 热门电影', path:'movies/trending', field:'movie', kind:'movie' },
        { name:'Trakt 热门剧集', path:'shows/trending', field:'show', kind:'tv' }
      ];
      const traktShelves = [];
      for (const source of traktSources) {
        const rows = await request(`https://api.trakt.tv/${source.path}?limit=10&extended=full`, { headers });
        const ids = (Array.isArray(rows) ? rows : []).map(entry => entry?.[source.field]?.ids?.tmdb).filter(Boolean).slice(0, 10);
        const hydrated = [];
        for (let offset = 0; offset < ids.length; offset += 4) {
          const batch = await Promise.all(ids.slice(offset, offset + 4).map(async id => {
            try { return await tmdb(`/${source.kind}/${id}`); } catch { return null; }
          }));
          hydrated.push(...batch.filter(Boolean));
        }
        const items = normalizeRankingItems(hydrated, source.kind);
        if (items.length) traktShelves.push([source.name, items, { summary:'Trakt · 真实观看热度', source:'Trakt', family:'热度', featured:true }]);
      }
      live.rankings.splice(1, 0, ...traktShelves);
    } catch {}
    saveRankings();
    if (state.view === 'home') home();
    notify(`榜单同步完成：${live.rankings.length} 个真实数据榜单${live.rankings.length < activeSources.length ? '（部分模块稍后重试）' : ''}`);
  } catch (error) { notify(`榜单同步失败：${error.message || '请检查网络后重试'}`); } finally { discoverySyncing = false; }
}

const demoHome = home;
home = function () {
  live.rankings ||= readLocalJson('yingji.discovery-cache', null);
  const fallback = titles.map((title, index) => ({ id: index, title, vote_average: 8.9 - index * .2, posterClass: `p${index}`, kind: index % 3 ? 'movie' : 'tv' }));
  const groups = live.rankings?.length ? live.rankings : [['为你推荐', fallback]];
  const allItems = groups.flatMap(group => group[1]).filter(Boolean);
  const cards = items => items.map((item, index) => {
    const title = item.title || item.name || item.original_title || item.original_name;
    const poster = item.poster_path ? `https://image.tmdb.org/t/p/w500${item.poster_path}` : '';
    return `<button class="live-card" data-live-detail="${item.id}" data-kind="${item.kind || (item.title ? 'movie' : 'tv')}"><span class="live-poster ${item.posterClass || ''}" ${poster ? `style="background-image:url('${poster}')"` : ''}><i>${index + 1}</i></span><b>${esc(title)}</b><small>${item.posterClass ? '映迹推荐' : 'TMDB'} ${(item.vote_average || 0).toFixed(1)}</small></button>`;
  }).join('');
  const heroItems = allItems.filter(item => item.backdrop_path || item.poster_path).slice(0, 12);
  const heroCount = heroItems.length || 1;
  live.heroIndex = ((live.heroIndex % heroCount) + heroCount) % heroCount;
  const feature = heroItems[live.heroIndex] || allItems[0] || fallback[0];
  const title = feature?.title || feature?.name || '发现新片';
  const date = feature?.release_date || feature?.first_air_date || '';
  const heroBackdrop = feature?.backdrop_path || feature?.poster_path || '';
  const backdrop = heroBackdrop ? `url('https://image.tmdb.org/t/p/original${heroBackdrop}')` : `url('yingji-hero-original.png')`;
  const continueItems = live.watchlist.length ? live.watchlist : allItems.slice(0, 4);
  live.continueItems = continueItems;
  const updateItems = allItems.slice(1, 4);
  const continueCards = continueItems.map((item, index) => { const name = item.title || item.name; const imageUrl = item.backdrop_path ? `https://image.tmdb.org/t/p/w780${item.backdrop_path}` : item.poster_path ? `https://image.tmdb.org/t/p/w500${item.poster_path}` : ''; return `<button class="continue-card" data-live-detail="${item.id}" data-kind="${item.kind || (item.title ? 'movie' : 'tv')}"><span class="continue-thumb ${item.posterClass || ''}" ${imageUrl ? `style="background-image:url('${imageUrl}')"` : ''}></span><span class="continue-line"><i style="width:${32 + index * 13}%"></i></span><span class="continue-copy"><b>${esc(name)}</b><small>${item.title ? '电影' : `S${index + 1} E${index + 3}`} · 剩余 ${18 + index * 7} 分钟</small></span></button>`; }).join('');
  const updates = updateItems.map((item, index) => { const name = item.title || item.name; const imageUrl = item.backdrop_path ? `https://image.tmdb.org/t/p/w300${item.backdrop_path}` : item.poster_path ? `https://image.tmdb.org/t/p/w300${item.poster_path}` : ''; return `<button class="update-row" data-live-detail="${item.id}" data-kind="${item.kind || (item.title ? 'movie' : 'tv')}"><span class="update-thumb ${item.posterClass || ''}" ${imageUrl ? `style="background-image:url('${imageUrl}')"` : ''}></span><span class="update-copy"><b>${esc(name)}</b><small>S${index + 1} E${index + 4} · 今晚 ${20 + index}:00</small></span><span class="chevron">›</span></button>`; }).join('');
  const serverCount = providerConfig.emby?.length || 0;
  const overview = feature?.overview || '来自你的私人媒体库与全球影视榜单。选择作品后，映迹会自动匹配 Emby 中画质最佳的版本。';
  const trendGroups = groups.slice(0, 4).map(([name, items], groupIndex) => `<div class="shelf-title"><h2>${esc(name)}</h2><button class="shelf-link" data-live-more="${groupIndex}" aria-label="打开${esc(name)}完整列表">›</button></div><div class="wide-row">${items.slice(0, 6).map((entry, index) => { const entryTitle=entry.title||entry.name; const art=entry.backdrop_path?`https://image.tmdb.org/t/p/w780${entry.backdrop_path}`:''; return `<button class="wide-card" data-live-detail="${entry.id}" data-kind="${itemKind(entry)}"><span class="wide-art ${entry.posterClass||''}" ${art?`style="background-image:url('${art}')"`:''}></span><b>${esc(entryTitle)}</b><small>${entry.release_date?.slice(0,4)||entry.first_air_date?.slice(0,4)||'2026'} · ${(entry.vote_average||8.4).toFixed(1)}</small></button>`; }).join('')}</div>`).join('');
  app.innerHTML = shell(`<main class="home-shell reference-home"><section class="home-hero" style="--live-backdrop:${backdrop}"><button class="hero-arrow hero-arrow-left" data-hero-prev aria-label="上一部">${ico('chevron')}</button><div class="reference-hero-copy"><h1>${esc(title)}</h1><div class="hero-facts"><span>${date ? esc(date.slice(0,4)) : '2026'}</span><span>${feature?.title ? '电影' : '剧集'}</span><span>TMDB ${(feature?.vote_average || 8.9).toFixed(1)}</span></div><p>${esc(overview)}</p><div class="actions"><button class="primary" data-live-detail="${feature?.id}" data-kind="${feature?.kind || itemKind(feature)}">继续观看</button></div></div><button class="hero-arrow hero-arrow-right" data-hero-next aria-label="下一部">${ico('chevron')}</button><div class="hero-dots" aria-label="海报轮播位置">${Array.from({length:heroCount},(_,index)=>`<i class="${index === live.heroIndex ? 'on' : ''}"></i>`).join('')}</div></section><section class="reference-content"><div class="shelf-title"><h2>继续观看</h2><button class="shelf-link" data-open-shelf="continue" aria-label="打开继续观看列表">${continueItems.length} ›</button></div><div class="continue-row">${continueCards}</div>${trendGroups}</section></main>`, 'home');
};

home = function controlRoomHome() {
  live.rankings ||= readLocalJson('yingji.discovery-cache', null);
  const groups = live.rankings?.length ? live.rankings : [];
  const allItems = groups.flatMap(group => group[1]).filter(Boolean);
  if (!allItems.length) {
    const sources = [...(providerConfig.emby || []), ...(providerConfig.files || [])];
    app.innerHTML = shell(`<main class="source-home"><section class="source-welcome"><div><h1>你的私人影音空间</h1><p>连接媒体服务器或私人存储后，映迹会建立统一资料库并同步观看状态。</p><div class="control-actions"><button class="primary" data-go="library">${ico('plus')}<span><b>${sources.length ? '扫描资料库' : '添加媒体来源'}</b><small>${sources.length ? `${sources.length} 个来源已连接` : 'Emby · Jellyfin · WebDAV'}</small></span></button><button class="secondary" data-go="settings">${ico('settings')}<span>播放与同步设置</span></button></div></div><aside class="source-health"><h2>来源状态</h2>${sources.length ? sources.map(source => `<div class="source-health-row">${serverMark(source)}<span><b>${esc(source.name)}</b><small>${esc(source.kind || 'Emby')} · 已连接</small></span><strong>可用</strong></div>`).join('') : '<div class="empty">尚未添加来源</div>'}</aside></section><section class="source-start"><h2>开始使用</h2><div class="source-start-grid"><button data-go="library"><span>${ico('library')}</span><b>连接资料库</b><small>媒体服务器与私人存储</small></button><button data-go="search"><span>${ico('search')}</span><b>搜索</b><small>连接后搜索全部来源</small></button><button data-go="calendar"><span>${ico('calendar')}</span><b>追剧</b><small>同步 Trakt 观看状态</small></button></div></section></main>`, 'home');
    return;
  }
  const heroItems = allItems.filter(item => item.backdrop_path || item.poster_path || item.posterClass).slice(0, 8);
  live.heroIndex = ((live.heroIndex % Math.max(heroItems.length, 1)) + Math.max(heroItems.length, 1)) % Math.max(heroItems.length, 1);
  const feature = heroItems[live.heroIndex] || allItems[0];
  const title = feature.title || feature.name || '发现新片';
  const year = (feature.release_date || feature.first_air_date || '2026').slice(0, 4);
  const backdropPath = feature.backdrop_path || feature.poster_path;
  const backdrop = backdropPath ? `url('https://image.tmdb.org/t/p/original${backdropPath}')` : `url('yingji-hero-original.png')`;
  const overview = feature.overview || '来自你的私人媒体库与全球影视榜单。映迹会自动匹配 Emby 中画质最佳的可播放版本。';
  const continueItems = (live.watchlist.length ? live.watchlist : allItems).slice(0, 4);
  live.continueItems = continueItems;
  const updates = allItems.slice(1, 5);
  const recent = allItems.slice(5, 9).length ? allItems.slice(5, 9) : allItems.slice(0, 4);
  const art = (item, size = 'w780') => item.backdrop_path ? `https://image.tmdb.org/t/p/${size}${item.backdrop_path}` : item.poster_path ? `https://image.tmdb.org/t/p/${size}${item.poster_path}` : '';
  const mediaButton = (item, index, mode) => {
    const name = item.title || item.name || '未命名内容';
    const imageUrl = art(item);
    const meta = mode === 'continue' ? `${itemKind(item) === 'movie' ? '电影' : `S${index + 1} · E${index + 3}`} · 剩余 ${12 + index * 8} 分钟` : `${(item.release_date || item.first_air_date || '2026').slice(0,4)} · TMDB ${(item.vote_average || 8.4).toFixed(1)}`;
    return `<button class="control-media-card ${mode}" data-live-detail="${item.id}" data-kind="${item.kind || itemKind(item)}"><span class="control-media-art ${item.posterClass || ''}" ${imageUrl ? `style="background-image:url('${imageUrl}')"` : ''}><i>${mode === 'update' ? `${index ? index + 1 + ' 天后' : '今晚 20:00'}` : itemKind(item) === 'movie' ? '电影' : `S${index + 1} E${index + 3}`}</i>${mode === 'continue' ? `<span class="control-progress"><b style="width:${38 + index * 14}%"></b></span>` : ''}</span><span class="control-media-copy"><b>${esc(name)}</b><small>${meta}</small></span></button>`;
  };
  const continueCards = continueItems.map((item, index) => mediaButton(item, index, 'continue')).join('');
  const updateCards = updates.map((item, index) => mediaButton(item, index, 'update')).join('');
  const recentCards = recent.map((item, index) => mediaButton(item, index, 'recent')).join('');
  const featureId = feature.id;
  app.innerHTML = shell(`<main class="control-home" style="--control-backdrop:${backdrop}">
    <section class="control-hero">
      <div class="control-hero-content">
        <div class="control-copy">
          <h1>${esc(title)}</h1>
          <div class="control-facts"><span>${esc(year)}</span><span>${itemKind(feature) === 'movie' ? '电影' : '科幻悬疑'}</span><span>TMDB ${(feature.vote_average || 8.8).toFixed(1)}</span></div>
          <p>${esc(overview)}</p>
          <div class="control-actions"><button class="primary control-play" data-live-detail="${featureId}" data-kind="${feature.kind || itemKind(feature)}">${ico('play')}<span><b>继续播放</b><small>S01 · E05</small></span></button><button class="secondary control-detail" data-live-detail="${featureId}" data-kind="${feature.kind || itemKind(feature)}">${ico('more')}<span>详情</span></button></div>
        </div>
        <aside class="next-episode" aria-label="下一集与播放资源">
          <div class="next-heading"><span>${ico('calendar')}</span><b>下一集</b><time>周五 20:00</time></div>
          <div class="next-content"><span class="next-art ${feature.posterClass || ''}" ${art(feature, 'w500') ? `style="background-image:url('${art(feature, 'w500')}')"` : ''}></span><div><h2>第 6 集 · 失重讯号</h2><p>本季进度 5 / 10</p><span class="next-progress"><i></i></span></div></div>
          <div class="source-brief"><span><b>4K</b> · HEVC · Dolby Vision</span><strong>18 ms</strong></div>
          <button class="source-switch" data-live-detail="${featureId}" data-kind="${feature.kind || itemKind(feature)}"><span>${ico('library')} 自动选择最佳资源</span><b>切换 ›</b></button>
        </aside>
      </div>
      <div class="control-dots">${heroItems.map((_, index) => `<button class="${index === live.heroIndex ? 'on' : ''}" data-hero-dot="${index}" aria-label="切换到第 ${index + 1} 部"></button>`).join('')}</div>
    </section>
    <section class="control-content">
      <div class="control-section-heading"><h2>继续观看</h2><button data-open-shelf="continue">查看全部 ${continueItems.length} ›</button></div>
      <div class="control-grid continue-grid">${continueCards}</div>
      <div class="control-split"><section><div class="control-section-heading"><h2>即将更新</h2><button data-go="calendar">追剧日历 ›</button></div><div class="control-grid compact-grid">${updateCards}</div></section><section><div class="control-section-heading"><h2>最近入库</h2><button data-go="library">媒体库 ›</button></div><div class="control-grid compact-grid">${recentCards}</div></section></div>
    </section>
  </main>`, 'home');
};

function showLiveRanking(index) {
  const ranking = live.rankings?.[Number(index)];
  if (!ranking) return;
  state.view = 'ranking';
  const [name, items] = ranking;
  const cards = items.map((item, itemIndex) => {
    const title = item.title || item.name || item.original_title || item.original_name;
    const poster = item.poster_path ? `https://image.tmdb.org/t/p/w500${item.poster_path}` : '';
    return `<button class="live-card" data-live-detail="${item.id}" data-kind="${item.title ? 'movie' : 'tv'}"><span class="live-poster" style="background-image:url('${poster}')"><i>${itemIndex + 1}</i></span><b>${esc(title)}</b><small>TMDB ${(item.vote_average || 0).toFixed(1)}</small></button>`;
  }).join('');
  app.innerHTML = shell(`<main class="ranking-page"><div class="page-heading"><div><button class="back" data-go="home">← 返回首页</button><h1>${esc(name)}</h1><p>来自 TMDB 的完整实时榜单</p></div><span class="page-stat">${items.length} 部作品</span></div><div class="ranking-grid">${cards}</div></main>`, 'home');
  scrollTo(0, 0);
}

function showLiveCollection(kind) {
  if (kind !== 'continue') return;
  const items = live.continueItems || live.watchlist || [];
  const cards = items.map((item, itemIndex) => {
    const title = item.title || item.name || item.original_title || item.original_name;
    const poster = item.poster_path ? `https://image.tmdb.org/t/p/w500${item.poster_path}` : '';
    const progress = 28 + itemIndex * 14;
    return `<article class="continue-list-card"><button class="continue-list-art ${item.posterClass || ''}" data-live-detail="${item.id}" data-kind="${item.kind || itemKind(item)}" ${poster ? `style="background-image:url('${poster}')"` : ''} aria-label="打开${esc(title)}"><i>${itemIndex + 1}</i></button><div class="continue-list-copy"><b>${esc(title)}</b><small>${item.kind === 'movie' ? '电影' : `第 ${itemIndex + 1} 季 · 第 ${itemIndex + 3} 集`} · 剩余 ${18 + itemIndex * 7} 分钟</small><span class="continue-list-progress"><i style="width:${progress}%"></i></span><em>已观看 ${progress}%</em></div><button class="continue-list-play" data-live-detail="${item.id}" data-kind="${item.kind || itemKind(item)}">继续播放</button></article>`;
  }).join('');
  app.innerHTML = shell(`<main class="ranking-page continue-list-page"><div class="page-heading"><div><button class="back" data-go="home">← 返回首页</button><h1>继续观看</h1><p>从上次进度继续播放</p></div><span class="page-stat">${items.length} 部剧</span></div>${cards ? `<section class="continue-list-grid">${cards}</section>` : '<div class="empty-state"><b>还没有继续观看的内容</b><span>开始播放一部电影或剧集后，它会出现在这里。</span></div>'}</main>`, 'home');
  scrollTo(0, 0);
}

async function loadLibraryLegacy() {
  const target = document.querySelector('[data-live-library]');
  if (!target) return;
  if (!(providerConfig.emby || []).length && !(providerConfig.files || []).length) {
    target.innerHTML = '<section class="empty-state compact"><b>添加你的第一个媒体来源</b><span>可连接 Emby、Jellyfin 或 WebDAV 私人存储。</span><button class="primary" data-toggle-library-server>添加来源</button></section>';
    return;
  }
  target.innerHTML = '<div class="empty">正在读取 Emby 媒体库…</div>';
  try {
    const groups = await Promise.all((providerConfig.emby || []).map(async server => {
      const token = await window.yingjiDesktop.getSecret(`emby-${server.id}`);
      const data = await request(`${server.url}/Users/${server.userId}/Items?Recursive=true&IncludeItemTypes=Movie,Series,Episode&Fields=Overview,ProviderIds,MediaSources,DateCreated,PremiereDate&Limit=300`, { headers: embyHeaders(token) });
      const items = (data.Items || []).map(item => ({ ...item, server, token }));
      live.sourceStats[server.id] = { total: items.length, movies: items.filter(item => item.Type === 'Movie').length, series: items.filter(item => item.Type === 'Series').length, episodes: items.filter(item => item.Type === 'Episode').length };
      return items;
    }));
    live.library = groups.flat();
    const webdavGroups = await Promise.all((providerConfig.files || []).map(async source => {
      const password = await window.yingjiDesktop.getSecret(`source-${source.id}`);
      const authorization = `Basic ${btoa(`${source.username}:${password}`)}`;
      const xml = await request(source.url, { method: 'PROPFIND', headers: { Depth: '1', Authorization: authorization, 'Content-Type': 'application/xml' }, rawBody: '<?xml version="1.0"?><propfind xmlns="DAV:"><prop><displayname/><getcontentlength/><resourcetype/></prop></propfind>', responseType: 'text' });
      const doc = new DOMParser().parseFromString(xml, 'application/xml');
      return [...doc.querySelectorAll('response')].slice(1).map(node => {
        const href = node.querySelector('href')?.textContent || '';
        const name = node.querySelector('displayname')?.textContent || decodeURIComponent(href.split('/').filter(Boolean).at(-1) || '未命名');
        const folder = !!node.querySelector('collection');
        return { name, folder, url: new URL(href, source.url).href, source, authorization };
      }).filter(item => !item.folder && /\.(mkv|mp4|avi|mov|m4v|ts|webm)$/i.test(item.name));
    }));
    live.fileItems = webdavGroups.flat();
    (providerConfig.files || []).forEach(source => { const count = live.fileItems.filter(item => item.source.id === source.id).length; live.sourceStats[source.id] = { total: count, movies: 0, series: 0, files: count }; });
    live.continueItems = live.library.filter(item => item.UserData?.PlaybackPositionTicks > 0 && !item.UserData?.Played).sort((a,b) => new Date(b.UserData?.LastPlayedDate || 0) - new Date(a.UserData?.LastPlayedDate || 0));
    const serverRows = live.library.map((item, index) => `<article class="media-row"><div class="media-thumb" style="background-image:url('${item.server.url}/Items/${item.Id}/Images/Primary?maxWidth=220&quality=85&api_key=${encodeURIComponent(item.token)}')"></div><div><b>${esc(item.SeriesName ? `${item.SeriesName} · ${item.Name}` : item.Name)}</b><small>${esc(item.Type)} · ${esc(item.server.name)}</small></div><button class="primary" data-emby-play="${index}">播放</button></article>`).join('');
    const fileRows = live.fileItems.map((item, index) => `<article class="media-row file-row"><div class="file-mark">${ico('play')}</div><div><b>${esc(item.name)}</b><small>WebDAV · ${esc(item.source.name)}</small></div><button class="primary" data-url-play="${index}">播放</button></article>`).join('');
    if (typeof library === 'function' && document.body.classList.contains('yj-ui')) library();
    else target.innerHTML = serverRows || fileRows ? serverRows + fileRows : '<div class="empty">来源已连接，但没有找到可播放的视频。</div>';
  } catch (error) { target.innerHTML = `<div class="error-state"><b>媒体库读取失败</b><span>${esc(error.message)}</span><button class="secondary" data-load-library>重试</button></div>`; }
}

library = function () {
  live.returnToLibrary = true;
  const mediaServers = (providerConfig.emby || []).map(server => `<div class="config server-card">${serverMark(server)}<div class="server-copy"><b>${esc(server.name || '媒体服务器')}</b><small>${esc(server.url)}</small><span>${esc(server.kind || 'Emby')} · ${esc(server.userName || '家庭账户')}</span></div><div class="server-actions">${connectionBadge(true)}<button class="secondary" data-edit-server="${esc(server.id)}">修改</button></div></div>`).join('');
  const fileSources = (providerConfig.files || []).map(source => `<div class="config server-card">${serverMark(source)}<div class="server-copy"><b>${esc(source.name || 'WebDAV')}</b><small>${esc(source.url)}</small><span>WebDAV · ${esc(source.username || '私人存储')}</span></div><div class="server-actions">${connectionBadge(true)}</div></div>`).join('');
  const servers = mediaServers + fileSources || '<div class="empty">连接媒体服务器或私人存储后，影片会进入统一资料库。</div>';
  const editing = live.editingServerId ? (providerConfig.emby || []).find(server => String(server.id) === String(live.editingServerId)) : null;
  const addServer = live.addingServer ? `<section class="source-connect"><div class="source-connect-heading"><div><h2>添加媒体来源</h2><p>凭据使用 Windows 安全存储加密，仅连接你授权的私人内容。</p></div><button class="secondary" data-toggle-library-server>完成</button></div><div class="source-connect-grid"><section class="panel"><h3>Emby / Jellyfin</h3><form data-provider="emby" ${editing ? `data-edit-id="${esc(editing.id)}"` : ''}><select name="kind"><option>Emby</option><option>Jellyfin</option></select><input name="name" value="${editing ? esc(editing.name || '') : ''}" placeholder="显示名称（可选）"><input name="url" type="url" required value="${editing ? esc(editing.url || '') : ''}" placeholder="https://media.example.com"><input name="username" ${editing ? '' : 'required'} placeholder="用户名"><input name="password" type="password" ${editing ? '' : 'required'} placeholder="密码"><button>${editing ? '保存修改' : '连接服务器'}</button></form></section><section class="panel"><h3>WebDAV / 私人网盘</h3><form data-provider="webdav"><input name="name" placeholder="显示名称，例如：家庭网盘"><input name="url" type="url" required placeholder="https://dav.example.com/videos/"><input name="username" required placeholder="用户名"><input name="password" type="password" required placeholder="密码或应用专用密码"><button>连接 WebDAV</button></form></section></div></section>` : '';
  app.innerHTML = shell(`<main class="simple-page library-page"><div class="page-heading"><div><h1>资料库</h1><p>聚合媒体服务器、私人存储与网盘中的影视内容。</p></div><div class="page-actions"><button class="secondary" data-toggle-library-server>＋ 添加来源</button><button class="primary" data-load-library>扫描资料库</button></div></div><div class="workspace-tabs"><button class="on">资料库</button><button data-toggle-library-server>来源</button><button data-go="downloads">下载</button></div><section class="panel server-summary">${servers}</section>${addServer}<section class="live-library" data-live-library><div class="empty">点击“扫描资料库”读取已连接来源中的真实内容。</div></section></main>`, 'library');
};

const image = (path, size = 'w500') => path ? `https://image.tmdb.org/t/p/${size}${path}` : '';
const itemKind = item => item?.title ? 'movie' : 'tv';
const serverMark = server => `<span class="server-mark" aria-hidden="true">${esc((server.name || 'E').trim().slice(0, 1).toUpperCase())}</span>`;
const sourceVideo = source => source?.MediaStreams?.find(stream => stream.Type === 'Video' && (stream.IsDefault || stream.Index === 0)) || source?.MediaStreams?.find(stream => stream.Type === 'Video') || source?.VideoStream || {};
const sourceAudio = source => source?.MediaStreams?.find(stream => stream.Type === 'Audio' && stream.IsDefault) || source?.MediaStreams?.find(stream => stream.Type === 'Audio') || {};
const sourceQuality = source => {
  const video = sourceVideo(source);
  const height = Number(video.Height || source?.Height || 0);
  const width = Number(video.Width || source?.Width || 0);
  const hint = [source?.Name, source?.Path, video.DisplayTitle, video.Title].filter(Boolean).join(' ').toLowerCase();
  if (height >= 4000 || width >= 7600 || /(?:^|\W)(?:4320p?|8k)(?:\W|$)/i.test(hint)) return '8K';
  if (height >= 2000 || width >= 3800 || /(?:^|\W)(?:2160p?|4k|uhd)(?:\W|$)/i.test(hint)) return '4K';
  if (height >= 1400 || width >= 2500 || /(?:^|\W)1440p?(?:\W|$)/i.test(hint)) return '1440P';
  if (height >= 1000 || width >= 1900 || /(?:^|\W)1080[pi]?(?:\W|$)/i.test(hint)) return '1080P';
  if (height >= 700 || width >= 1200 || /(?:^|\W)720[pi]?(?:\W|$)/i.test(hint)) return '720P';
  if (height >= 560 || /(?:^|\W)576[pi]?(?:\W|$)/i.test(hint)) return '576P';
  if (height >= 460 || /(?:^|\W)480[pi]?(?:\W|$)/i.test(hint)) return '480P';
  return height ? `${height}P` : '规格未知';
};
const qualityRank = quality => ({ '8K': 8000, '4K': 4000, '1440P': 1440, '1080P': 1080, '720P': 720, '576P': 576, '480P': 480, '规格未知': 0 }[quality] ?? (Number.parseInt(quality, 10) || 0));
const sourceRange = source => {
  const video = sourceVideo(source);
  const hint = [video.VideoRangeType, video.VideoRange, video.DisplayTitle, video.Title, source?.Name, source?.Path].filter(Boolean).join(' ').toLowerCase();
  if (/dolby[ ._-]?vision|dovi|\bdv\b/.test(hint)) return 'Dolby Vision';
  if (/hdr10\+|hdr10plus/.test(hint)) return 'HDR10+';
  if (/hdr10|\bhdr\b/.test(hint)) return 'HDR10';
  if (/\bhlg\b/.test(hint)) return 'HLG';
  return 'SDR';
};
const sourceVideoCodec = source => {
  const value = String(sourceVideo(source).Codec || '').toLowerCase();
  if (value === 'hevc' || value === 'h265') return 'HEVC';
  if (value === 'h264' || value === 'avc') return 'H.264';
  if (value === 'av1') return 'AV1';
  if (value === 'vp9') return 'VP9';
  return value ? value.toUpperCase() : '视频编码未知';
};
const sourceAudioLabel = source => sourceAudio(source).DisplayTitle || sourceAudio(source).Title || sourceAudio(source).Codec?.toUpperCase() || '音轨未知';
const sourceVersion = source => [sourceQuality(source), sourceVideoCodec(source), String(source?.Container || '').toUpperCase()].filter(Boolean).join(' · ');
const sourceCodec = source => {
  const video = sourceVideo(source);
  const audio = sourceAudio(source);
  return [video.DisplayTitle || video.Codec, audio.DisplayTitle || audio.Codec].filter(Boolean).join(' · ') || '媒体信息待读取';
};
const sourceSize = source => source?.Size ? `${(source.Size / 1073741824).toFixed(1)} GB` : '大小未知';
const sourceBitrate = source => source?.Bitrate ? `${(source.Bitrate / 1000000).toFixed(2)} Mbps` : '码率未知';
const episodeLabel = episode => episode.movie ? '正片' : `S${String(episode.season).padStart(2, '0')} · E${String(episode.number).padStart(2, '0')}`;

function renderLiveDetail() {
  const context = live.detail;
  if (!context) return;
  document.body.classList.add('detail-mode');
  const { item, detail, kind, episodes, resources, selectedEpisode, selectedResolution, selectedResource, resourceError } = context;
  const title = detail.name || detail.title || item.name || item.title;
  const backdrop = image(detail.backdrop_path || item.backdrop_path, 'original') || 'yingji-hero-original.png';
  const poster = image(detail.poster_path || item.poster_path) || 'yingji-posters-original.png';
  const posterMarkup = prototypeMode ? `<span class="detail-poster detail-poster-fallback ${item.posterClass || 'p0'}" role="img" aria-label="${esc(title)}海报"></span>` : `<img class="detail-poster" src="${poster}" alt="${esc(title)}海报">`;
  const date = detail.first_air_date || detail.release_date || item.first_air_date || item.release_date;
  const year = date ? date.slice(0, 4) : '日期未知';
  const genres = (detail.genres || []).map(genre => genre.name).join(' · ');
  const runtime = kind === 'movie' ? detail.runtime : (episodes.find(ep => ep.number === selectedEpisode)?.runtime || detail.episode_run_time?.[0]);
  const selected = episodes.find(ep => ep.number === selectedEpisode) || episodes[0];
  const resolutions = ['全部', ...new Set(resources.map(resource => sourceQuality(resource.MediaSources?.[0])))];
  const shownResources = resources.filter(resource => selectedResolution === '全部' || sourceQuality(resource.MediaSources?.[0]) === selectedResolution);
  const selectedMatch = shownResources[selectedResource] || shownResources[0];
  const cast = (detail.credits?.cast || []).slice(0, 12);
  const trailer = (detail.videos?.results || []).find(video => video.site === 'YouTube' && (video.type === 'Trailer' || video.type === 'Teaser'));
  const posters = (detail.images?.posters || []).slice(0, 8);
  const visibleEpisodes = episodes.slice(0, 40);
  const episodeCards = visibleEpisodes.map(episode => `<button class="live-episode ${episode.number === selectedEpisode ? 'on' : ''}" data-select-episode="${episode.number}"><span class="episode-thumb" style="background-image:url('${image(episode.still_path, 'w500') || 'yingji-hero-original.png'}')"><i>${episodeLabel(episode)}</i></span><span class="episode-body"><b>${esc(episode.name || episodeLabel(episode))}</b><small>${esc(episode.air_date || '播出日期待定')} · ${episode.runtime ? `${episode.runtime} 分钟` : '时长待定'}</small><em>${esc(episode.overview || 'TMDB 暂无本集简介。')}</em></span></button>`).join('');
  const resourceCards = shownResources.map((resource, index) => {
    const source = resource.MediaSources?.[0] || {};
    const libraryIndex = live.library.indexOf(resource);
    return `<button class="resource-option ${resource === selectedMatch ? 'on' : ''}" data-select-resource="${index}"><span><b>${esc(sourceQuality(source))}</b><small>${sourceSize(source)} · ${sourceBitrate(source)}</small><small>${esc(resource.server.name)} · ${source.SupportsDirectPlay === false ? '需要转码' : '可直连'}</small></span><strong>${resource === selectedMatch ? '✓' : '○'}</strong></button>${resource === selectedMatch ? `<div class="resource-inspector"><div><small>视频 / 音频</small><b>${esc(sourceCodec(source))}</b></div><div><small>资源规格</small><b>${esc(source.Container || source.VideoType || 'Emby')}</b></div><button class="primary" data-emby-play="${libraryIndex}">播放此资源</button></div>` : ''}`;
  }).join('');
  const resourceState = resources.length
    ? (shownResources.length ? resourceCards : '<div class="empty">这个清晰度暂无资源，请切换筛选。</div>')
    : resourceError
      ? `<div class="error-state"><b>资源搜索失败</b><span>${esc(resourceError)}</span><button class="secondary" data-select-episode="${selected?.number || 1}">重试</button></div>`
      : '<div class="empty">尚未找到可播放资源，请先连接 Emby 服务器或稍后重试。</div>';
  const providerRows = [
    ['TMDB', '影片资料 · 海报 · 演职员', true],
    ['Trakt', '观看记录 · 收藏 · 评论', !!providerConfig.traktAuthorized],
    ['Emby', '媒体信息 · 封面 · 演职员', !!providerConfig.emby?.length]
  ].map(([name, copy, connected]) => `<div class="provider-row"><span class="provider-mark">${name.slice(0, 1)}</span><span><b>${name}</b><small>${copy}</small></span><i class="${connected ? 'connected' : ''}">${connected ? '✓' : '—'}</i></div>`).join('');
  app.innerHTML = shell(`<main class="live-detail design-detail" style="--detail-backdrop:url('${backdrop}')">
    <div class="detail-canvas">
      <section class="detail-main">
        <button class="back detail-back" data-go="home" aria-label="返回首页">${ico('chevron')}</button>
        <div class="detail-hero-copy">
          ${posterMarkup}
          <div class="detail-summary">
            <h1>${esc(title)}</h1>
            <p class="original-title">${esc(detail.original_name || detail.original_title || '')}</p>
            <div class="meta"><b>${(detail.vote_average || item.vote_average || 0).toFixed(1)}</b><span>${esc(year)}</span><span>${esc(genres || (kind === 'movie' ? '电影' : '剧集'))}</span>${kind === 'tv' ? `<span>共 ${detail.number_of_seasons || context.seasonNumber} 季</span>` : ''}</div>
            <p class="detail-overview">${esc(detail.overview || item.overview || 'TMDB 暂无中文简介。')}</p>
            <div class="detail-actions"><button class="primary" data-scroll-episodes>${ico('play')}<span><b>播放</b><small>${kind === 'movie' ? '正片' : selected ? episodeLabel(selected) : '第一集'}</small></span></button><div class="detail-icon-actions"><button class="round-action" data-live-watch="${item.id}" aria-label="加入待看">${ico('watch')}</button><button class="round-action" data-scroll-people aria-label="演员与主创">${ico('smart')}</button><button class="round-action" data-scroll-extras aria-label="预告与画廊">${ico('more')}</button></div></div>
            <div class="detail-progress"><span><i style="width:48%"></i></span><small>${selected ? episodeLabel(selected) : '正片'} · 已观看 48% · 剩余 ${selected?.runtime || runtime || '—'} 分钟</small><em>${providerConfig.traktAuthorized ? '✓ 已与 Trakt 同步' : 'Trakt 未连接'}</em></div>
          </div>
        </div>
        <nav class="detail-tabs" aria-label="详情分类"><button data-scroll-top>概览</button><button class="on" data-scroll-episodes>剧集</button><button data-scroll-people>演职员</button><button data-scroll-extras>预告与画廊</button></nav>
        <section class="detail-episodes" id="episode-section"><div class="episode-heading"><span class="season-picker">第 ${context.seasonNumber} 季</span>${episodes.length > visibleEpisodes.length ? `<small>显示前 ${visibleEpisodes.length} 集 · 本季共 ${episodes.length} 集</small>` : ''}</div><div class="episode-rail">${episodeCards || '<div class="empty">剧集资料加载中…</div>'}</div></section>
      </section>
      <aside class="detail-side">
        <section class="detail-panel resource-panel"><h2>播放资源</h2><div class="resolution-filter">${resolutions.map(resolution => `<button class="${resolution === selectedResolution ? 'on' : ''}" data-resolution="${esc(resolution)}">${esc(resolution)}</button>`).join('')}</div><div class="resource-list">${resourceState}</div>${selectedMatch ? `<button class="primary side-play" data-emby-play="${live.library.indexOf(selectedMatch)}">${ico('play')} 使用 mpv 播放</button>` : '<button class="primary side-play" data-go="library">连接 Emby 服务器</button>'}</section>
        <section class="detail-panel media-panel"><h2>媒体信息</h2>${providerRows}</section>
      </aside>
    </div>
    <div class="detail-flow"><section class="detail-section people-section"><div class="section-title"><div><h2>演员与主创</h2></div><p>${cast.length ? `${cast.length} 位主要演职员` : 'TMDB 暂无演职员资料'}</p></div><div class="cast-strip">${cast.map(person => `<article class="cast-person"><img src="${image(person.profile_path, 'w185')}" alt=""><b>${esc(person.name)}</b><small>${esc(person.character || person.job || '')}</small></article>`).join('') || '<div class="empty">暂无资料</div>'}</div></section><section class="detail-section extras-section"><div class="section-title"><div><h2>预告片与海报</h2></div><p>来自 TMDB 的官方媒体资料</p></div><div class="extras-grid">${trailer ? `<a class="trailer-card" href="https://www.youtube.com/watch?v=${encodeURIComponent(trailer.key)}" target="_blank" rel="noreferrer"><span style="background-image:url('https://img.youtube.com/vi/${trailer.key}/hqdefault.jpg')"></span><b>▶ ${esc(trailer.name || '官方预告片')}</b><small>YouTube · ${esc(trailer.type || 'Trailer')}</small></a>` : '<div class="empty">暂无官方预告片</div>'}<div class="poster-gallery">${posters.map(entry => `<img src="${image(entry.file_path, 'w342')}" alt="${esc(title)} 海报">`).join('') || `<img src="${poster}" alt="${esc(title)} 海报">`}</div></div></section></div>
  </main>`, 'home');
}

async function loadConnectedSourceData() {
  const servers = providerConfig.emby || [];
  if (!servers.length || prototypeMode) return;
  const results = await Promise.all(servers.map(async server => {
    try {
      const token = await window.yingjiDesktop.getSecret(`emby-${server.id}`);
      const base = `${server.url}/Users/${server.userId}/Items`;
      const query = async type => request(`${base}?Recursive=true&IncludeItemTypes=${type}&Limit=0&EnableTotalRecordCount=true`, { headers: embyHeaders(token) });
      const [movies, series, resume] = await Promise.all([
        query('Movie'), query('Series'),
        request(`${base}?Recursive=true&IncludeItemTypes=Movie,Episode&Filters=IsResumable&SortBy=DatePlayed,DateLastSaved&SortOrder=Descending&Fields=Overview,SeriesName,SeriesId,IndexNumber,ParentIndexNumber,ParentThumbItemId,ParentThumbImageTag,SeriesPrimaryImageTag,RunTimeTicks,UserData,DateLastSaved&Limit=40`, { headers: embyHeaders(token) })
      ]);
      const iconUrl = `${server.url}/Branding/Splashscreen?api_key=${encodeURIComponent(token)}`;
      return { server: { ...server, iconUrl }, stats: { total: Number(movies.TotalRecordCount || 0) + Number(series.TotalRecordCount || 0), movies: Number(movies.TotalRecordCount || 0), series: Number(series.TotalRecordCount || 0), episodes: 0, state:'connected' }, continueItems: (resume.Items || []).map(item => ({ ...item, server, token })) };
    } catch (error) { return { server, stats: { total: 0, movies: 0, series: 0, episodes: 0, error: error.message, state:'error' }, continueItems: [] }; }
  }));
  results.forEach(result => { live.sourceStats[result.server.id] = result.stats; live.sourceIcons[result.server.id] = result.server.iconUrl; });
  live.library = results.flatMap(result => result.continueItems);
  const unique = new Map();
  live.library.forEach(item => { const key = item.SeriesId || item.SeriesName || item.Id; const previous = unique.get(key); const date = new Date(item.UserData?.LastPlayedDate || item.DateLastSaved || 0); const prevDate = previous ? new Date(previous.UserData?.LastPlayedDate || previous.DateLastSaved || 0) : 0; if (!previous || date > prevDate) unique.set(key, item); });
  live.continueItems = [...unique.values()].sort((a,b) => new Date(b.UserData?.LastPlayedDate || b.DateLastSaved || 0) - new Date(a.UserData?.LastPlayedDate || a.DateLastSaved || 0));
  if (typeof home === 'function' && state.view === 'home') home();
  if (typeof library === 'function' && state.view === 'library') library();
}

async function loadLibrary() { return loadConnectedSourceData(); }
async function refreshSource(sourceId) {
  await loadConnectedSourceData();
  if (String(live.openSourceId) === String(sourceId) && typeof yjLoadSourceContent === 'function') await yjLoadSourceContent(sourceId);
}
const addressUrlsFromForm = form => [...form.querySelectorAll('[data-address-row]')].map(row => {
  const protocol = row.querySelector('[data-address-protocol].is-active')?.dataset.addressProtocol || 'https';
  const host = row.querySelector('[name="hosts"]')?.value.trim();
  const rawPort = row.querySelector('[name="ports"]')?.value.trim();
  const path = row.querySelector('[name="paths"]')?.value.trim().replace(/^\/*/, '/');
  if (!host) return '';
  const port = rawPort || (protocol === 'https' ? '8096' : '443');
  return `${protocol}://${host}${port ? `:${port}` : ''}${path === '/' ? '' : path}`.replace(/\/$/, '');
}).filter(Boolean);
const sourceAddressRowMarkup = () => `<div class="yj-address-row" data-address-row><div class="yj-address-protocol"><button type="button" class="is-active" data-address-protocol="https">HTTPS</button><button type="button" data-address-protocol="http">HTTP</button></div><input name="hosts" required placeholder="media.example.com" aria-label="服务器地址"><input name="ports" inputmode="numeric" value="8096" placeholder="端口" aria-label="端口"><input name="paths" placeholder="路径（可选，例如 /emby）" aria-label="路径"><button type="button" data-remove-address aria-label="移除地址">×</button></div>`;

async function loadDetailResources(context) {
  const selected = context.episodes.find(episode => episode.number === context.selectedEpisode) || context.episodes[0];
  const title = context.detail.name || context.detail.title || context.item.name || context.item.title;
  const tmdbId = context.tmdbId;
  try {
    const groups = await Promise.all((providerConfig.emby || []).filter(server => server.aggregate !== false).map(async server => {
      const token = await window.yingjiDesktop.getSecret(`emby-${server.id}`);
      const base = `${server.url}/Users/${server.userId}/Items`;
      const headers = embyHeaders(token);
      let found = [];
      /* 1) 优先按 TMDB 编号精确匹配已添加服务器 */
      if (tmdbId) {
        try {
          if (context.kind === 'movie') {
            const data = await request(`${base}?Recursive=true&IncludeItemTypes=Movie&AnyProviderIdEquals=tmdb.${tmdbId}&Fields=Overview,ProviderIds,MediaSources,RunTimeTicks&Limit=20`, { headers });
            found = data.Items || [];
          } else {
            const seriesData = await request(`${base}?Recursive=true&IncludeItemTypes=Series&AnyProviderIdEquals=tmdb.${tmdbId}&Fields=ProviderIds&Limit=5`, { headers });
            const series = (seriesData.Items || [])[0];
            if (series?.Id) {
              const epsData = await request(`${base}?Recursive=true&IncludeItemTypes=Episode&ParentId=${series.Id}&Fields=Overview,ProviderIds,MediaSources,ParentIndexNumber,IndexNumber,RunTimeTicks,UserData&Limit=500`, { headers });
              const seasonEpisodes = (epsData.Items || []).filter(ep => Number(ep.ParentIndexNumber) === Number(context.seasonNumber));
              context.playedEpisodes = [...new Set([...(context.playedEpisodes || []), ...seasonEpisodes.filter(ep => ep.UserData?.Played || Number(ep.UserData?.PlayedPercentage || 0) >= 90).map(ep => Number(ep.IndexNumber))])];
              found = seasonEpisodes.filter(ep => Number(ep.IndexNumber) === Number(selected.number));
            }
          }
        } catch {}
      }
      /* 2) 兜底：按标题模糊搜索 */
      if (!found.length) {
        const type = context.kind === 'movie' ? 'Movie' : 'Episode';
        const data = await request(`${base}?Recursive=true&IncludeItemTypes=${type}&SearchTerm=${encodeURIComponent(title)}&Fields=Overview,ProviderIds,MediaSources,ParentIndexNumber,IndexNumber,RunTimeTicks&Limit=100`, { headers });
        found = (data.Items || []).filter(found => context.kind === 'movie' || (Number(found.ParentIndexNumber) === Number(context.seasonNumber) && Number(found.IndexNumber) === Number(selected.number)));
      }
      const hydrated = await Promise.all(found.map(async foundItem => {
        let sources = foundItem.MediaSources || [];
        try {
          const playback = await request(`${server.url}/Items/${foundItem.Id}/PlaybackInfo?UserId=${server.userId}`, { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: { UserId: server.userId, AutoOpenLiveStream: false } });
          if (playback.MediaSources?.length) sources = playback.MediaSources;
        } catch {}
        if (!sources.length) sources = [null];
        return sources.map(source => ({ ...foundItem, server, token, selectedMediaSourceId: source?.Id || '', MediaStreams: source?.MediaStreams || foundItem.MediaStreams || [], Container: source?.Container || foundItem.Container, Path: source?.Path || foundItem.Path, Size: source?.Size || foundItem.Size, Bitrate: source?.Bitrate || foundItem.Bitrate, Name: source?.Name || foundItem.Name, SupportsDirectPlay: source?.SupportsDirectPlay, SupportsDirectStream: source?.SupportsDirectStream, SupportsTranscoding: source?.SupportsTranscoding }));
      }));
      return hydrated.flat();
    }));
    if (live.detail !== context || context.detailLoadKey !== live.detailLoadKey || state.view !== 'detail') return;
    context.resources = groups.flat().sort((a, b) => qualityRank(sourceQuality(b)) - qualityRank(sourceQuality(a)) || Number(b.Bitrate || 0) - Number(a.Bitrate || 0));
    context.resources.forEach(found => {
      const exists = live.library.some(item => String(item.Id) === String(found.Id) && String(item.server?.id) === String(found.server.id) && String(item.selectedMediaSourceId || '') === String(found.selectedMediaSourceId || ''));
      if (!exists) live.library.push(found);
    });
    const qualities = [...new Set(context.resources.map(sourceQuality))].filter(Boolean).sort((a, b) => qualityRank(b) - qualityRank(a));
    if (!qualities.includes(context.selectedResolution)) context.selectedResolution = qualities[0] || '';
  } catch (error) {
    if (live.detail !== context || context.detailLoadKey !== live.detailLoadKey || state.view !== 'detail') return;
    context.resourceError = error.message || '资源读取失败';
  }
  if (live.detail !== context || context.detailLoadKey !== live.detailLoadKey || state.view !== 'detail') return;
  renderLiveDetail();
}
async function showLiveDetail(subject, preferredKind) {
  if (state.view !== 'detail') yjRememberRoute();
  const detailLoadKey = (live.detailLoadKey || 0) + 1;
  live.detailLoadKey = detailLoadKey;
  const directItem = subject && typeof subject === 'object' ? subject : null;
  const id = directItem?.Id ?? directItem?.id ?? subject;
  const continueItem = live.continueItems.find(entry => String(entry.Id || entry.id) === String(id));
  const item = directItem || continueItem || catalogItem(id) || live.search?.results.find(entry => String(entry.id) === String(id)) || live.watchlist.find(entry => String(entry.id) === String(id)) || { id };
  if (!item) return;
  state.view = 'detail';
  const kind = preferredKind || itemKind(item) || (Number(id) ? 'tv' : 'movie');
  const requestedSeason = kind === 'tv' ? Number(item.ParentIndexNumber || item.SeasonIndex || 0) : 0;
  const requestedEpisode = kind === 'tv' ? Number(item.IndexNumber || item.EpisodeIndex || 0) : 0;
  const isEmbyItem = !!(item?.server?.url && item?.Id);
  let tmdbId = isEmbyItem ? null : (item.id ?? item.ProviderIds?.Tmdb ?? (Number.isFinite(Number(id)) ? id : null));
  /* Emby 的条目 ID 不是 TMDB ID。电影查自身；剧集单集必须查所属 Series。 */
  if (isEmbyItem) {
    try {
      const token = item.token || (await window.yingjiDesktop.getSecret(`emby-${item.server.id}`));
      const queryInfo = async itemId => {
        if (!itemId) return null;
        return request(`${item.server.url}/Users/${item.server.userId}/Items/${itemId}?Fields=ProviderIds,SeriesId`, { headers: embyHeaders(token) });
      };
      const ownInfo = item.ProviderIds?.Tmdb && item.SeriesId ? item : await queryInfo(item.Id);
      if (kind === 'movie') tmdbId = ownInfo?.ProviderIds?.Tmdb || item.ProviderIds?.Tmdb || null;
      else {
        const seriesId = item.Type === 'Series' ? item.Id : (item.SeriesId || ownInfo?.SeriesId);
        const seriesInfo = seriesId && String(seriesId) === String(item.Id) ? ownInfo : await queryInfo(seriesId);
        tmdbId = seriesInfo?.ProviderIds?.Tmdb || null;
      }
    } catch {}
  }
  if (live.detailLoadKey !== detailLoadKey || state.view !== 'detail') return;
  if (!tmdbId) {
    const lookupTitle = item.SeriesName || item.Name || item.title || item.name;
    if (lookupTitle) {
      try {
        const results = await tmdbRequest(`/search/${kind}?query=${encodeURIComponent(lookupTitle)}&language=zh-CN`);
        tmdbId = results.results?.[0]?.id || null;
      } catch {}
    }
  }
  if (live.detailLoadKey !== detailLoadKey || state.view !== 'detail') return;
  if (!tmdbId) {
    app.innerHTML = yjShell(`<main class="yj-page yj-list-page"><button class="yj-page-back" data-go="home">${ico('chevron')} 返回首页</button>${yjEmpty('详情加载失败','服务器没有提供 TMDB 编号，且无法按片名匹配影视资料。','<button class="secondary" data-go="library">返回资料库</button>')}</main>`, 'home', { title:'详情加载失败' });
    return;
  }
  const cacheKey = `yingji.detail-cache-${kind}-${tmdbId}`;
  const cached = readLocalJson(cacheKey, null);
  if (cached?.context && Date.now() - (cached.savedAt || 0) < 7 * 86400000 && (!requestedSeason || Number(cached.context.seasonNumber) === requestedSeason)) {
    const cachedEpisodes = cached.context.episodes || [];
    const selectedEpisode = cachedEpisodes.some(episode => Number(episode.number) === requestedEpisode) ? requestedEpisode : (cached.context.selectedEpisode || cachedEpisodes[0]?.number || 1);
    const context = { ...cached.context, item, kind, tmdbId, selectedEpisode, resources: [], selectedResolution: '全部', selectedResource: 0, detailLoadKey };
    live.detail = context;
    renderLiveDetail();
    loadDetailResources(context);
    return;
  }
  app.innerHTML = yjShell(`<main class="yj-page">${yjEmpty(`正在加载《${esc(item.title || item.name || item.Name || id)}》`,'正在读取作品资料与可播放资源。')}</main>`, 'home', { title:'加载详情' });
  try {
    let tmdbKey = '';
    try { tmdbKey = await window.yingjiDesktop.getSecret('tmdb-key'); } catch {}
    const detail = await tmdbRequest(`/${kind}/${tmdbId}?append_to_response=credits,videos,images&include_image_language=zh,en,null&include_video_language=zh,en,null`, tmdbKey);
    if (live.detailLoadKey !== detailLoadKey || state.view !== 'detail') return;
    let seasonNumber = 1;
    let episodes = [];
    if (kind === 'tv') {
      const regular = (detail.seasons || []).filter(season => season.season_number > 0 && season.episode_count > 0);
      seasonNumber = regular.some(season => Number(season.season_number) === requestedSeason) ? requestedSeason : (regular[0]?.season_number || 1);
      const season = await tmdbRequest(`/tv/${tmdbId}/season/${seasonNumber}`, tmdbKey);
      episodes = (season.episodes || []).map(episode => ({ ...episode, season: seasonNumber, number: episode.episode_number }));
    } else {
      episodes = [{ movie: true, number: 1, season: 0, name: '正片', overview: detail.overview, air_date: detail.release_date, runtime: detail.runtime, still_path: detail.backdrop_path }];
    }
    try { localStorage.setItem(cacheKey, JSON.stringify({ savedAt: Date.now(), context: { detail, seasonNumber, episodes } })); } catch {}
    if (live.detailLoadKey !== detailLoadKey || state.view !== 'detail') return;
    const selectedEpisode = episodes.some(episode => Number(episode.number) === requestedEpisode) ? requestedEpisode : (episodes[0]?.number || 1);
    const context = { item, detail, kind, seasonNumber, episodes, tmdbId, selectedEpisode, resources: [], selectedResolution: '全部', selectedResource: 0, detailLoadKey };
    live.detail = context;
    renderLiveDetail();
    loadDetailResources(context);
  } catch (error) {
    if (live.detailLoadKey !== detailLoadKey || state.view !== 'detail') return;
    const lookupTitle = item.SeriesName || item.Name || item.title || item.name;
    if (lookupTitle) {
      try {
        const results = await tmdbRequest(`/search/${kind}?query=${encodeURIComponent(lookupTitle)}&language=zh-CN`);
        const recoveredId = results.results?.[0]?.id;
        if (recoveredId && String(recoveredId) !== String(tmdbId)) {
          const stored = live.watchlist.find(entry => entry === item || String(entry.id) === String(item.id));
          if (stored) { stored.id = recoveredId; stored.calendarResolved = false; saveLiveWatchlist(); }
          return showLiveDetail({ ...item, id: recoveredId }, kind);
        }
      } catch {}
    }
    app.innerHTML = yjShell(`<main class="yj-page yj-list-page"><button class="yj-page-back" data-go="home">${ico('chevron')} 返回首页</button>${yjEmpty('详情加载失败',esc(error.message || '请检查网络后重试'),`<button class="secondary" data-live-detail="${esc(id)}" data-kind="${kind}">重试</button>`)}</main>`, 'home', { title:'详情加载失败' });
  }
}

settingsV2 = function () {
  live.returnToLibrary = false;
  const servers = (providerConfig.emby || []).map(server => `<div class="config server-card">${serverMark(server)}<div class="server-copy"><b>${esc(server.name || 'Emby 服务器')}</b><small>${esc(server.url)} · ${esc(server.userName || '家庭账户')}</small></div><div class="server-actions">${connectionBadge(true)}<button class="secondary" data-edit-server="${esc(server.id)}">修改</button></div></div>`).join('') || '<div class="empty">尚未连接服务器。</div>';
  app.innerHTML = shell(`<main class="settings ios-settings"><div class="page-heading"><div><h1>设置</h1><p>连接服务、播放偏好与本机安全设置。</p></div></div><div class="provider-grid"><section class="panel provider"><div class="provider-title"><h2>TMDB</h2>${connectionBadge(!!metadataEndpoint || !!providerConfig.tmdb)}</div><p>${metadataEndpoint ? '默认由映迹元数据服务提供中文资料、海报和榜单。' : '中文资料、海报、演职员与热门榜单。'}</p>${metadataEndpoint ? '<div class="managed-source">托管模式已启用 · 可选填入自己的 Key 覆盖使用</div>' : ''}<form data-provider="tmdb"><input name="key" type="password" required placeholder="TMDB API Key（可选覆盖托管模式）"><button>保存并测试</button></form></section><section class="panel provider"><div class="provider-title"><h2>Trakt</h2>${connectionBadge(!!providerConfig.traktAuthorized)}</div><p>热门趋势、观看记录与追剧日历。</p><form data-provider="trakt"><input name="key" type="password" required placeholder="Trakt Client ID"><input name="secret" type="password" required placeholder="Trakt Client Secret"><button>保存应用凭据</button></form>${providerConfig.trakt ? `<button class="secondary authorize" data-trakt-auth>${providerConfig.traktAuthorized ? '重新授权 Trakt' : '授权 Trakt 账户'}</button>` : ''}<div data-trakt-device></div></section><section class="panel provider emby-provider"><div class="provider-title"><h2>Emby 服务器</h2>${connectionBadge((providerConfig.emby || []).length > 0)}</div>${servers}<form data-provider="emby"><input name="name" placeholder="服务器名称（可选，留空自动获取）"><input name="url" type="url" required placeholder="https://emby.example.com"><input name="username" required placeholder="用户名"><input name="password" type="password" required placeholder="密码"><button>登录并添加</button></form></section><section class="panel provider player-provider"><div class="provider-title"><h2>播放器</h2><span class="status connected">mpv</span></div><div class="setting-row"><span><b>硬件解码</b><small>自动选择 D3D11 / gpu-next</small></span>${toggleControl('hardware','硬件解码')}</div><div class="setting-row"><span><b>HDR 与 Dolby Vision</b><small>跟随显示器能力自动切换</small></span>${toggleControl('hdr','HDR 与 Dolby Vision')}</div><button class="setting-row setting-action" data-preference="subtitle"><span><b>字幕优先语言</b><small>简体中文 · ASS 样式保留</small></span><span class="chevron">›</span></button></section></div></main>`, 'settings');
};

async function authorizeTrakt() {
  document.querySelector('[data-trakt-dialog]')?.remove();
  document.body.insertAdjacentHTML('beforeend', `<section class="yj-trakt-dialog" data-trakt-dialog role="dialog" aria-modal="true" aria-labelledby="trakt-title"><header><div><h2 id="trakt-title">连接 Trakt</h2><p>使用设备授权安全连接观看记录。</p></div><button data-close-trakt aria-label="关闭">${ico('close')}</button></header><div data-trakt-device><div class="yj-auth-loading">正在获取授权码…</div></div></section>`);
  const box = document.querySelector('[data-trakt-dialog] [data-trakt-device]');
  try {
    const [clientId, clientSecret] = await Promise.all([window.yingjiDesktop.getSecret('trakt-client-id'), window.yingjiDesktop.getSecret('trakt-client-secret')]);
    const device = await request('https://api.trakt.tv/oauth/device/code', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: { client_id: clientId } });
    box.innerHTML = `<div class="device-code"><span>在浏览器打开</span><a href="${esc(device.verification_url)}" target="_blank">${esc(device.verification_url)}</a><strong>${esc(device.user_code)}</strong><small>输入代码并允许访问，完成后本弹窗会自动关闭。</small></div>`;
    const expires = Date.now() + device.expires_in * 1000;
    while (Date.now() < expires) {
      await sleep(device.interval * 1000);
      const result = await request('https://api.trakt.tv/oauth/device/token', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: { code: device.device_code, client_id: clientId, client_secret: clientSecret }, acceptErrors: true });
      if (result.status === 200) {
        await Promise.all([window.yingjiDesktop.setSecret('trakt-access-token', result.data.access_token), window.yingjiDesktop.setSecret('trakt-refresh-token', result.data.refresh_token)]);
        providerConfig.traktAuthorized = true; saveProviders(); document.querySelector('[data-trakt-dialog]')?.remove(); settingsV2(); notify('Trakt 账户授权成功'); return;
      }
      if (![400, 404].includes(result.status)) throw new Error(`Trakt 授权失败（${result.status}）`);
    }
    throw new Error('Trakt 授权码已过期，请重试');
  } catch (error) { if (box) box.innerHTML = `<div class="error-state"><span>${esc(error.message)}</span></div>`; }
}

async function syncTraktCalendar() {
  const target = document.querySelector('[data-trakt-calendar]');
  try {
    const [clientId, token, tmdbKey] = await Promise.all([window.yingjiDesktop.getSecret('trakt-client-id'), window.yingjiDesktop.getSecret('trakt-access-token'), window.yingjiDesktop.getSecret('tmdb-key')]);
    if (!token) throw new Error('请先在设置中授权 Trakt 账户');
    const start = new Date(); start.setDate(start.getDate() - 2);
    const date = start.toISOString().slice(0, 10);
    const events = await request(`https://api.trakt.tv/calendars/my/shows/${date}/10?extended=full`, { headers: { Authorization: `Bearer ${token}`, 'trakt-api-version': '2', 'trakt-api-key': clientId } });
    const posters = {};
    if (tmdbKey || metadataEndpoint) await Promise.all(events.map(async event => { const id = event.show?.ids?.tmdb; if (!id || posters[id]) return; try { const info = await tmdbRequest(`/tv/${id}?language=zh-CN`, tmdbKey); posters[id] = info.poster_path; } catch {} }));
    live.calendarEvents = events.filter(event => !live.suppressedCalendar.includes(String(event.show?.ids?.tmdb)));
    live.calendarPosters = posters;
    calendar();
  } catch (error) { target.innerHTML = `<div class="error-state"><b>Trakt 日历同步失败</b><span>${esc(error.message)}</span></div>`; }
}

calendar = function () {
  const start = new Date(); start.setDate(start.getDate() - 2);
  const dates = Array.from({length:9},(_,index)=>{const day=new Date(start);day.setDate(day.getDate()+index);return `<button class="date-chip ${index===live.ui.calendarDay?'on':''}" data-calendar-day="${index}"><b>${index===2?'今天':new Intl.DateTimeFormat('zh-CN',{month:'numeric',day:'numeric'}).format(day)}</b><small>${new Intl.DateTimeFormat('zh-CN',{weekday:'short'}).format(day)}</small></button>`}).join('');
  const calendarState = providerConfig.traktAuthorized
    ? '<section class="empty-state compact"><b>等待同步追剧日历</b><span>点击“立即同步”读取你的 Trakt 更新。</span><button class="primary" data-sync-calendar>立即同步</button></section>'
    : '<section class="empty-state compact"><b>连接 Trakt 查看追剧日历</b><span>授权后这里会显示真实剧集更新时间。</span><button class="primary" data-go="settings">前往设置</button></section>';
  const filters=`<button data-calendar-filter="all">在看</button><button class="on" data-calendar-filter="calendar">日历</button><button data-go="watchlist">待看</button>`;
  app.innerHTML = shell(`<main class="calendar-page ios-calendar"><header class="page-heading"><div><h1>日历</h1><p>前两天至未来一周的真实追剧安排</p></div><div class="segmented">${filters}</div></header><div class="date-strip">${dates}</div><div class="calendar-layout"><section class="calendar-events" data-trakt-calendar><div class="calendar-day-title">${live.ui.calendarDay===2?'今天':'所选日期'} · ${new Intl.DateTimeFormat('zh-CN',{month:'long',day:'numeric',weekday:'long'}).format(new Date(start.getTime()+live.ui.calendarDay*86400000))}</div>${calendarState}</section><aside class="calendar-side"><section class="ios-card side-card"><div class="side-heading"><h2>Trakt 同步</h2><em>${providerConfig.traktAuthorized?'已连接':'未连接'}</em></div><p>同步观看记录和我的追剧日历。</p><div class="setting-row"><span>仅显示我的追剧</span>${toggleControl('traktOnly','仅显示我的追剧')}</div><button class="calendar-sync" data-sync-calendar ${providerConfig.traktAuthorized?'':'disabled'}>立即同步</button></section></aside></div></main>`, 'calendar');
};

watchlist = function () {
  const cards = live.watchlist.map(item => { const poster = image(item.poster_path, 'w500'); return `<article class="watch-card live-watch-card"><button class="watch-poster ${item.posterClass || ''}" data-live-detail="${item.id}" data-kind="${item.kind}" ${poster ? `style="background-image:url('${poster}')"` : ''}></button><div class="watch-copy"><div><small>${item.kind === 'movie' ? '电影' : '剧集'} · TMDB ${(item.vote_average || 0).toFixed(1)}</small><h2>${esc(item.title || item.name)}</h2></div><button class="secondary" data-live-unwatch="${item.id}">移出待看</button></div></article>`; }).join('');
  app.innerHTML = shell(`<main class="simple-page watchlist-page"><div class="page-heading"><div><h1>待看</h1><p>加入待看的电影和剧集会保存在本机，并可与 Trakt 追剧记录一起查看。</p></div><span class="page-stat">${live.watchlist.length} 部待看</span></div><div class="workspace-tabs"><button data-go="calendar">在看</button><button data-go="calendar">日历</button><button class="on">待看</button></div>${cards ? `<section class="watch-grid">${cards}</section>` : `<section class="empty-state"><b>待看列表还是空的</b><span>在首页或详情页点击“加入待看”，想看的内容就会放在这里。</span><button class="primary" data-go="home">去发现内容</button></section>`}</main>`, 'watchlist');
};

downloads = function () {
  app.innerHTML = shell(`<main class="simple-page downloads-page ios-downloads"><div class="page-heading"><div><h1>下载</h1><p>离线任务与本机空间管理</p></div><span class="page-stat">暂未开放</span></div><div class="workspace-tabs"><button data-go="library">全部内容</button><button data-go="library">服务器</button><button class="on">下载</button></div><div class="downloads-layout"><section class="panel download-queue"><div class="provider-title"><h2>下载队列</h2><div class="segmented"><button class="on" disabled>全部</button><button disabled>进行中</button><button disabled>已完成</button></div></div><div class="download-placeholder"><span>↓</span><b>离线下载尚未开放</b><small>当前版本不会创建虚假的下载任务。你仍可从媒体库直接播放已连接服务器中的内容。</small><button class="primary" data-go="library">前往媒体库</button></div></section><aside class="downloads-side"><section class="ios-card side-card"><h2>本机空间</h2><div class="storage-ring unavailable"><b>—</b><small>等待启用</small></div><p>启用下载引擎后，这里会显示真实空间与缓存占用。</p></section><section class="ios-card side-card"><h2>下载偏好</h2><div class="setting-row"><span><b>仅 Wi-Fi</b><small>偏好已保存，功能开放后生效</small></span>${toggleControl('wifi','下载仅使用 Wi-Fi')}</div><button class="setting-row setting-action" data-preference="quality"><span><b>自动选择清晰度</b><small>${live.ui.downloadQuality || '优先 1080p'}</small></span><span class="chevron">›</span></button></section></aside></div></main>`, 'downloads');
};

searchPage = function () {
  const results = live.search?.results || [];
  const fallback = live.rankings?.flatMap(group=>group[1]).slice(0,10) || [];
  const base = results.length ? results : fallback;
  const shown = live.ui.searchFilter === 'movie' ? base.filter(item=>itemKind(item)==='movie') : live.ui.searchFilter === 'tv' ? base.filter(item=>itemKind(item)==='tv') : base;
  const cards = shown.map(item => liveCard(item)).join('');
  const best = shown[0]; const bestTitle=best?.title||best?.name; const bestBackdrop=image(best?.backdrop_path||best?.poster_path,'w780');
  const tabs=[['all','全部'],['movie','电影'],['tv','剧集']].map(([id,label])=>`<button class="${live.ui.searchFilter===id?'on':''}" data-search-filter="${id}">${label}</button>`).join('');
  const recent=live.ui.recentSearches.map(text=>`<div class="recent-row"><span>◷</span><button data-recent-search="${esc(text)}">${esc(text)}</button><button data-remove-recent="${esc(text)}" aria-label="移除${esc(text)}">×</button></div>`).join('')||'<div class="empty compact">暂无搜索记录</div>';
  app.innerHTML = shell(`<main class="search-page live-search-page ios-search"><h1>搜索</h1><form class="search-form" data-live-search><span>${ico('search')}</span><input name="query" required autofocus value="${esc(live.search?.query || '')}" placeholder="搜索电影、剧集、演员或服务器资源"><button class="primary">搜索</button></form><div class="segmented search-tabs">${tabs}</div><div class="search-layout"><section class="search-main">${best?`<h2>最佳匹配</h2><article class="best-match ios-card"><span class="best-image ${best.posterClass || ''}" ${bestBackdrop ? `style="background-image:url('${bestBackdrop}')"` : ''}></span><div><h2>${esc(bestTitle)}</h2><p>${best.release_date?.slice(0,4)||best.first_air_date?.slice(0,4)||'最新'} · ${(best.vote_average||0).toFixed(1)}</p><small>${esc(best.overview||'进入详情后会自动匹配你的 Emby 资源。')}</small><div class="actions"><button class="secondary" data-live-detail="${best.id}" data-kind="${itemKind(best)}">查看详情</button></div></div></article>`:''}<h2>电影与剧集</h2>${live.search?.loading?'<div class="empty">正在搜索 TMDB…</div>':shown.length?`<div class="search-results">${cards}</div>`:`<section class="empty-state"><b>没有符合筛选条件的结果</b><span>换一个分类或搜索词试试。</span></section>`}</section><aside class="search-side"><section class="ios-card side-card"><h2>搜索范围</h2>${[['tmdb','TMDB','电影与剧集信息'],['emby','Emby','本地媒体库匹配'],['trakt','Trakt','观看记录与收藏']].map(([id,name,desc])=>`<div class="setting-row"><span><b>${name}</b><small>${desc}</small></span>${toggleControl(id,`${name} 搜索范围`)}</div>`).join('')}</section><section class="ios-card side-card"><div class="side-heading"><h2>最近搜索</h2><button data-clear-recent>清除</button></div>${recent}</section></aside></div></main>`, 'search');
};

const renderSearchPage = searchPage;
searchPage = function () {
  renderSearchPage();
  const main = document.querySelector('.search-main');
  if (main && live.search?.error) main.insertAdjacentHTML('afterbegin', `<section class="error-state inline"><b>搜索暂时不可用</b><span>${esc(live.search.error)}</span><button class="secondary" data-retry-search>重新搜索</button></section>`);
  if (live.search?.loading) document.querySelector('.search-main .empty')?.classList.add('loading-state');
};

async function searchDiscovery(query) {
  if (query && !live.ui.recentSearches.includes(query)) { live.ui.recentSearches.unshift(query); live.ui.recentSearches = live.ui.recentSearches.slice(0, 6); saveUi(); }
  live.search = { query, loading: true, results: [] };
  searchPage();
  if (prototypeMode) {
    const all = live.rankings?.flatMap(group => group[1]) || [];
    live.search = { query, results: all.filter(item => (item.title || item.name || '').includes(query)).concat(all).filter((item, index, list) => list.findIndex(entry => entry.id === item.id) === index).slice(0, 8) };
    searchPage();
    notify(`找到 ${live.search.results.length} 条演示结果`);
    return;
  }
  try {
    let tmdbKey = '';
    try { tmdbKey = await window.yingjiDesktop.getSecret('tmdb-key'); } catch {}
    const data = await tmdbRequest(`/search/multi?query=${encodeURIComponent(query)}&include_adult=false`, tmdbKey);
    live.search = { query, results: (data.results || []).filter(item => item.media_type === 'movie' || item.media_type === 'tv') };
  } catch (error) {
    live.search = { query, results: [], error: error.message || '搜索失败' };
    notify(`搜索失败：${error.message || '请检查网络'}`);
  }
  searchPage();
}

async function playEmby(item) {
  if (!item?.Id || !item?.server?.url || !item?.token) throw new Error('当前播放资源已失效，请重新选择版本后再试');
  live.active = item;
  const info = await request(`${item.server.url}/Items/${item.Id}/PlaybackInfo?UserId=${item.server.userId}`, { method: 'POST', headers: { ...embyHeaders(item.token), 'Content-Type': 'application/json' }, body: { UserId: item.server.userId, AutoOpenLiveStream: true } });
  const source = info.MediaSources?.find(entry => String(entry.Id) === String(item.selectedMediaSourceId)) || info.MediaSources?.[0];
  if (!source) throw new Error('Emby 没有返回可播放媒体源');
  const title = item.SeriesName ? `${item.SeriesName} · ${item.Name}` : item.Name;
  const url = new URL(`${item.server.url.replace(/\/$/, '')}/Videos/${item.Id}/stream`);
  url.searchParams.set('Static', 'true');
  url.searchParams.set('MediaSourceId', source.Id);
  url.searchParams.set('api_key', item.token);
  if (info.PlaySessionId) url.searchParams.set('PlaySessionId', info.PlaySessionId);
  let danmaku = '';
  const template = String(providerConfig.danmaku?.urlTemplate || '').trim();
  if (live.ui.toggles.danmakuEnabled && template) {
    const endpoint = template
      .replaceAll('{tmdbId}', encodeURIComponent(item.ProviderIds?.Tmdb || item.tmdbId || ''))
      .replaceAll('{season}', encodeURIComponent(item.ParentIndexNumber || '0'))
      .replaceAll('{episode}', encodeURIComponent(item.IndexNumber || '0'))
      .replaceAll('{title}', encodeURIComponent(item.SeriesName || item.Name || ''));
    try {
      danmaku = await request(endpoint, { responseType:'text', headers: providerConfig.danmaku?.token ? { Authorization:`Bearer ${providerConfig.danmaku.token}` } : {} });
    } catch (error) { notify(`弹幕加载失败：${error.message || '请检查 API 设置'}`); }
  }
  await window.yingjiDesktop.playMpv({
    url: url.href, title, token: item.token, serverUrl: item.server.url, userId: item.server.userId,
    itemId: item.Id, mediaSourceId: source.Id, playSessionId: info.PlaySessionId,
    position: (item.UserData?.PlaybackPositionTicks || 0) / 10000000,
    bitrate: Number(source.Bitrate || 0),
    hwdec: live.ui.hwdec, renderer: live.ui.renderer, gpu: live.ui.gpu,
    downmix: live.ui.toggles.downmix, vocal: live.ui.toggles.vocal, night: live.ui.toggles.night,
    subtitleEnabled: live.ui.toggles.subtitleEnabled, subtitleLanguage: live.ui.subtitleLanguage, subtitleScale: live.ui.subtitleScale,
    danmakuEnabled: live.ui.toggles.danmakuEnabled, danmakuDensity: live.ui.danmakuDensity, danmaku
  });
}

const runBusy = async (button, task) => {
  if (button.disabled) return;
  button.disabled = true;
  button.setAttribute('aria-busy', 'true');
  try { await task(); } finally {
    if (button.isConnected) { button.disabled = false; button.removeAttribute('aria-busy'); }
  }
};

let yjShelfPress;
const yjClearShelfPress = commit => {
  const press = yjShelfPress;
  if (!press) return;
  clearTimeout(press.timer);
  press.option.classList.remove('is-holding', 'is-dragging');
  press.option.style.removeProperty('transform');
  press.target?.classList.remove('is-drop-target');
  if (commit && press.dragging) {
    if (press.target) press.root.insertBefore(press.option, press.after ? press.target.nextSibling : press.target);
    yjCommitShelfOrder([...press.root.querySelectorAll('[data-shelf-option]')].map(item => item.dataset.shelfOption));
  }
  yjShelfPress = null;
};
document.addEventListener('pointerdown', event => {
  const option = event.target.closest('[data-shelf-option]');
  if (!option || event.button !== 0 || event.target.closest('button, a, input')) return;
  const root = option.closest('.yj-atv-rank-options');
  if (!root) return;
  const press = yjShelfPress = { option, root, pointerId:event.pointerId, startX:event.clientX, startY:event.clientY, target:null, after:false, dragging:false };
  option.classList.add('is-holding');
  press.timer = setTimeout(() => {
    if (yjShelfPress !== press) return;
    press.dragging = true;
    option.classList.remove('is-holding');
    option.classList.add('is-dragging');
    navigator.vibrate?.(10);
  }, 360);
});
document.addEventListener('pointermove', event => {
  const press = yjShelfPress;
  if (!press || event.pointerId !== press.pointerId) return;
  const deltaX = event.clientX - press.startX, deltaY = event.clientY - press.startY;
  if (!press.dragging) {
    if (Math.hypot(deltaX, deltaY) > 8) yjClearShelfPress(false);
    return;
  }
  event.preventDefault();
  press.option.style.transform = `translateY(${deltaY}px) scale(1.015)`;
  const candidate = document.elementFromPoint(event.clientX, event.clientY)?.closest('[data-shelf-option]');
  const target = candidate && candidate !== press.option && candidate.parentElement === press.root ? candidate : null;
  if (target === press.target) { if (target) press.after = event.clientY > target.getBoundingClientRect().top + target.offsetHeight / 2; return; }
  press.target?.classList.remove('is-drop-target');
  press.target = target;
  press.after = target ? event.clientY > target.getBoundingClientRect().top + target.offsetHeight / 2 : false;
  target?.classList.add('is-drop-target');
});
document.addEventListener('pointerup', event => { if (yjShelfPress?.pointerId === event.pointerId) yjClearShelfPress(true); });
document.addEventListener('pointercancel', event => { if (yjShelfPress?.pointerId === event.pointerId) yjClearShelfPress(false); });

document.addEventListener('click', async event => {
  const target = event.target.closest('[data-yj-back],[data-shelf-panel],[data-shelf-panel-close],[data-shelf-toggle],[data-shelf-filter],[data-load-ranking-more],[data-sync-discovery],[data-load-library],[data-detail-play],[data-continue-play],[data-emby-play],[data-url-play],[data-live-detail],[data-live-more],[data-open-shelf],[data-edit-server],[data-edit-file],[data-trakt-auth],[data-sync-calendar],[data-retry-search],[data-hero-prev],[data-hero-next],[data-hero-dot],[data-select-episode],[data-resolution],[data-select-resource],[data-resource-view],[data-open-server-versions],[data-close-server-versions],[data-scroll-top],[data-scroll-episodes],[data-scroll-people],[data-scroll-extras],[data-live-watch],[data-live-unwatch],[data-calendar-remove],[data-toggle-library-server],[data-source-kind],[data-add-address],[data-remove-address],[data-address-protocol],[data-server-line],[data-close-trakt],[data-toggle],[data-calendar-filter],[data-calendar-day],[data-search-filter],[data-recent-search],[data-remove-recent],[data-clear-recent],[data-preference],button[data-appearance]');
  if (!target) return;
  if (target.dataset.loadRankingMore !== undefined) return runBusy(target, () => loadMoreRanking(Number(target.dataset.loadRankingMore)));
  if (target.hasAttribute('data-yj-back')) { if (typeof yjBack === 'function') yjBack(); else { state.view = 'home'; if (typeof live !== 'undefined') live.detail = null; render(); } return; }
  if (target.hasAttribute('data-sync-discovery')) return runBusy(target, syncDiscovery);
  if (target.dataset.appearance) { localStorage.setItem('yingji.appearance', target.dataset.appearance); document.documentElement.dataset.appearance = target.dataset.appearance; settingsV2(); notify(`外观已切换为${target.dataset.appearance === 'light' ? '浅色' : target.dataset.appearance === 'dark' ? '深色' : '跟随系统'}`); return; }
  if (target.hasAttribute('data-load-library')) return runBusy(target, loadLibrary);
  if (target.hasAttribute('data-retry-search')) return runBusy(target, () => searchDiscovery(live.search?.query || ''));
  if (target.hasAttribute('data-detail-play') && live.detail) {
    const matches = (live.detail.resources || []).filter(source => sourceQuality(source) === live.detail.selectedResolution).sort((a,b) => Number(b.Bitrate || 0) - Number(a.Bitrate || 0));
    const item = matches[live.detail.selectedResource] || matches[0];
    if (!item) return notify('当前没有可播放版本');
    return runBusy(target, () => playEmby(item).catch(error => notify(`播放失败：${error.message}`)));
  }
  if (target.dataset.continuePlay !== undefined) {
    const item = live.continueItems[Number(target.dataset.continuePlay)];
    if (!item) return notify('继续观看记录已失效，请刷新服务器');
    showLiveDetail(item, item.Type === 'Movie' ? 'movie' : 'tv');
    return playEmby(item).catch(error => notify(`播放失败：${error.message}`));
  }
  if (target.dataset.embyPlay !== undefined) return runBusy(target, () => playEmby(live.library[Number(target.dataset.embyPlay)]).catch(error => notify(`播放失败：${error.message}`)));
  if (target.dataset.urlPlay !== undefined) {
    const item = live.fileItems[Number(target.dataset.urlPlay)];
    return runBusy(target, () => window.yingjiDesktop.openUrl({ url: item.url, title: item.name, authorization: item.authorization, hwdec: live.ui.hwdec, renderer: live.ui.renderer, gpu: live.ui.gpu, downmix: live.ui.toggles.downmix, vocal: live.ui.toggles.vocal, night: live.ui.toggles.night }).catch(error => notify(`播放失败：${error.message}`)));
  }
  if (target.dataset.liveDetail !== undefined) showLiveDetail(target.dataset.liveDetail, target.dataset.kind);
  if (target.dataset.liveMore !== undefined) return showLiveRanking(target.dataset.liveMore);
  if (target.dataset.openShelf) return showLiveCollection(target.dataset.openShelf);
  if (target.dataset.editServer !== undefined) { live.editingServerId = target.dataset.editServer; live.addingServer = true; library(); }
  if (target.dataset.editFile !== undefined) { live.editingFileId = target.dataset.editFile; live.editingServerId = null; live.addingServer = true; library(); }
  if (target.hasAttribute('data-trakt-auth')) return runBusy(target, authorizeTrakt);
  if (target.hasAttribute('data-close-trakt')) { document.querySelector('[data-trakt-dialog]')?.remove(); return; }
  if (target.hasAttribute('data-sync-calendar')) return runBusy(target, syncTraktCalendar);
  if (target.dataset.toggle) {
    const key = target.dataset.toggle;
    live.ui.toggles[key] = !live.ui.toggles[key]; saveUi();
    target.classList.toggle('off', !live.ui.toggles[key]); target.setAttribute('aria-checked', String(live.ui.toggles[key]));
    notify(`${target.getAttribute('aria-label')}已${live.ui.toggles[key] ? '开启' : '关闭'}`); return;
  }
  if (target.dataset.calendarFilter) { live.preserveCalendarScroll = window.scrollY; live.ui.calendarFilter = target.dataset.calendarFilter; saveUi(); calendar(); return; }
  if (target.dataset.calendarDay !== undefined) { live.preserveCalendarScroll = window.scrollY; live.ui.calendarDay = Number(target.dataset.calendarDay); saveUi(); calendar(); return; }
  if (target.dataset.searchFilter) { live.ui.searchFilter = target.dataset.searchFilter; saveUi(); searchPage(); return; }
  if (target.dataset.recentSearch) return searchDiscovery(target.dataset.recentSearch);
  if (target.dataset.removeRecent) { live.ui.recentSearches = live.ui.recentSearches.filter(text => text !== target.dataset.removeRecent); saveUi(); searchPage(); return; }
  if (target.hasAttribute('data-clear-recent')) { live.ui.recentSearches = []; saveUi(); searchPage(); notify('最近搜索已清除'); return; }
  if (target.dataset.preference === 'quality') { live.ui.downloadQuality = live.ui.downloadQuality === '优先 1080p' ? '保持原画' : '优先 1080p'; saveUi(); downloads(); notify(`下载清晰度：${live.ui.downloadQuality}`); return; }
  if (target.dataset.preference === 'subtitle') { notify('字幕优先语言将在播放器语言设置中开放'); return; }
  if (target.hasAttribute('data-shelf-panel')) { live.shelfPanelOpen = true; renderShelfPanel(); return; }
  if (target.hasAttribute('data-shelf-panel-close')) {
    const explicitClose = event.target.closest('.yj-panel-close');
    if (!explicitClose && event.target !== target) return;
    const scrollTop = window.scrollY;
    live.shelfPanelOpen = false;
    renderShelfPanel();
    yjApplyShelfOrder(readLocalJson('yingji.shelf-order', []));
    requestAnimationFrame(() => window.scrollTo({ top:scrollTop, behavior:'instant' }));
    return;
  }
  if (target.dataset.shelfFilter) { live.shelfFilter = target.dataset.shelfFilter; renderShelfPanel(); return; }
  if (target.dataset.shelfToggle !== undefined) {
    const toggles = readLocalJson('yingji.shelf-toggles', {});
    const enabled = target.matches('input') ? target.checked : target.getAttribute('aria-checked') !== 'true';
    toggles[target.dataset.shelfToggle] = enabled;
    localStorage.setItem('yingji.shelf-toggles', JSON.stringify(toggles));
    target.setAttribute('aria-checked', String(enabled));
    target.querySelector('em').textContent = enabled ? '显示' : '隐藏';
    const option = target.closest('[data-shelf-option]');
    option?.classList.toggle('is-enabled', enabled);
    const options = option?.parentElement;
    if (option && options?.classList.contains('yj-atv-rank-options')) {
      if (enabled) {
        const firstHidden = [...options.children].find(node => node !== option && !node.classList.contains('is-enabled'));
        options.insertBefore(option, firstHidden || null);
      } else {
        options.append(option);
      }
      localStorage.setItem('yingji.shelf-order', JSON.stringify([...options.querySelectorAll('[data-shelf-option]')].map(node => node.dataset.shelfOption)));
    }
    const row = [...document.querySelectorAll('.yj-atv-rank-row')].find(node => node.dataset.shelfName === target.dataset.shelfToggle);
    if (row) row.hidden = !enabled;
    const count = document.querySelector('[data-shelf-count]');
    if (count) count.textContent = `${document.querySelectorAll('.yj-atv-rank-row:not([hidden])').length} 个轨道`;
    return;
  }
  if (target.hasAttribute('data-hero-prev')) { live.heroIndex--; updateHero(); return; }
  if (target.hasAttribute('data-hero-next')) { live.heroIndex++; updateHero(); return; }
  if (target.dataset.heroDot !== undefined) { live.heroIndex = Number(target.dataset.heroDot); updateHero(); return; }
  if (target.hasAttribute('data-scroll-top')) window.scrollTo({ top: 0, behavior: 'smooth' });
  if (target.hasAttribute('data-scroll-episodes')) document.querySelector('#episode-section')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  if (target.hasAttribute('data-scroll-people')) document.querySelector('.people-section')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  if (target.hasAttribute('data-scroll-extras')) document.querySelector('.extras-section')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  if (target.dataset.liveWatch !== undefined) {
    const item = catalogItem(target.dataset.liveWatch) || live.detail?.item;
    if (item && !live.watchlist.some(entry => String(entry.id) === String(item.id))) {
      const addedAt = new Date().toISOString();
      const nextEpisode = live.detail?.detail?.next_episode_to_air;
      const tmdbId = live.detail?.tmdbId || item.id;
      live.watchlist.push({ id: tmdbId, kind: live.detail?.kind || itemKind(item), title: live.detail?.detail?.title || item.title || item.name, name: live.detail?.detail?.name || item.name, poster_path: live.detail?.detail?.poster_path || item.poster_path, vote_average: live.detail?.detail?.vote_average || item.vote_average, addedAt, calendarDate: nextEpisode?.air_date ? `${nextEpisode.air_date}T12:00:00` : addedAt, calendarSeason: nextEpisode?.season_number || null, calendarEpisode: nextEpisode?.episode_number || null, calendarEpisodeTitle: nextEpisode?.name || '' });
      live.suppressedCalendar = live.suppressedCalendar.filter(id => id !== String(tmdbId)); saveSuppressedCalendar();
      saveLiveWatchlist();
      notify('已加入待看');
    } else notify('这部作品已经在待看中');
  }
  if (target.dataset.liveUnwatch !== undefined) {
    live.watchlist = live.watchlist.filter(item => String(item.id) !== String(target.dataset.liveUnwatch));
    saveLiveWatchlist();
    watchlist();
    notify('已移出待看');
  }
  if (target.dataset.calendarRemove !== undefined) {
    const removeKey = String(target.dataset.calendarRemove);
    if (removeKey.startsWith('local:')) live.watchlist.splice(Number(removeKey.slice(6)), 1);
    else {
      const id = removeKey.startsWith('trakt:') ? removeKey.slice(6) : removeKey;
      live.watchlist = live.watchlist.filter(item => String(item.id) !== id);
      if (id && !live.suppressedCalendar.includes(id)) live.suppressedCalendar.push(id);
    }
    saveLiveWatchlist(); saveSuppressedCalendar(); calendar(); notify('已从日历和待看中移除'); return;
  }
  if (target.hasAttribute('data-toggle-library-server')) { live.preserveLibraryScroll = window.scrollY; live.addingServer = !live.addingServer; live.sourceKind = null; if (!live.addingServer) { live.editingServerId = null; live.editingFileId = null; } library(); return; }
  if (target.dataset.sourceKind) { live.sourceKind = target.dataset.sourceKind; library(); return; }
  if (target.hasAttribute('data-add-address')) { document.querySelector('[data-address-list]')?.insertAdjacentHTML('beforeend', sourceAddressRowMarkup()); return; }
  if (target.dataset.addressProtocol) { const row=target.closest('[data-address-row]'); row?.querySelectorAll('[data-address-protocol]').forEach(button => button.classList.toggle('is-active', button === target)); const port=row?.querySelector('[name="ports"]'); if (port) port.value=target.dataset.addressProtocol === 'https' ? '8096' : '443'; return; }
  if (target.hasAttribute('data-remove-address')) { if (document.querySelectorAll('.yj-address-row').length > 1) target.closest('.yj-address-row')?.remove(); return; }
  if (target.dataset.serverLine !== undefined) { const server = providerConfig.emby.find(item => String(item.id) === String(target.dataset.serverLine)); if (server) { server.activeAddress = Number(target.value); server.url = server.addresses[server.activeAddress]; saveProviders(); library(); notify(`已切换到线路 ${server.activeAddress + 1}`); } return; }
  if (target.dataset.selectEpisode !== undefined && live.detail) {
    const episode = Number(target.dataset.selectEpisode);
    if (episode === Number(live.detail.selectedEpisode) && live.detail.resources?.length) {
      const matches = live.detail.resources.filter(source => sourceQuality(source) === live.detail.selectedResolution).sort((a,b) => Number(b.Bitrate || 0) - Number(a.Bitrate || 0));
      const item = matches[live.detail.selectedResource] || matches[0];
      if (item) return playEmby(item).catch(error => notify(`播放失败：${error.message}`));
    }
    live.detail.selectedEpisode = episode;
    live.detail.resources = [];
    live.detail.selectedResolution = '';
    live.detail.selectedResource = 0;
    renderLiveDetail();
    loadDetailResources(live.detail);
  }
  if (target.dataset.resolution !== undefined && live.detail) {
    live.detail.selectedResolution = target.dataset.resolution;
    live.detail.selectedResource = 0;
    live.detail.resourceServerPicker = null;
    renderLiveDetail();
  }
  if (target.dataset.resourceView !== undefined && live.detail) {
    live.detail.resourceView = target.dataset.resourceView === 'server' ? 'server' : 'resource';
    localStorage.setItem('yingji.resource-view', live.detail.resourceView);
    live.detail.resourceServerPicker = null;
    renderLiveDetail(); return;
  }
  if (target.dataset.openServerVersions !== undefined && live.detail) {
    live.detail.resourceServerPicker = Number(target.dataset.openServerVersions);
    renderLiveDetail(); return;
  }
  if (target.hasAttribute('data-close-server-versions') && live.detail) {
    live.detail.resourceServerPicker = null;
    renderLiveDetail(); return;
  }
  if (target.dataset.selectResource !== undefined && live.detail) {
    live.detail.selectedResource = Number(target.dataset.selectResource);
    live.detail.resourceServerPicker = null;
    renderLiveDetail();
  }
});

// Settings selects (hardware decoder / renderer / GPU) persist to live.ui.
document.addEventListener('change', event => {
  const select = event.target.closest('select[data-setting]');
  if (!select) return;
  const key = select.dataset.setting;
  const value = select.value;
  if (['hwdec', 'renderer', 'gpu', 'subtitleLanguage', 'subtitleScale', 'danmakuMode', 'danmakuDensity'].includes(key)) {
    live.ui[key] = value; saveUi();
    const label = { hwdec:'硬解模式', renderer:'渲染器', gpu:'GPU', subtitleLanguage:'字幕语言', subtitleScale:'字幕大小', danmakuMode:'弹幕模式', danmakuDensity:'弹幕密度' }[key];
    notify(`${label}已更新，下次播放生效`);
  }
});

let heroTouchX = null;
document.addEventListener('touchstart', event => {
  if (event.target.closest('.home-hero, .yj-hero-wrap')) heroTouchX = event.changedTouches[0].clientX;
}, { passive: true });
document.addEventListener('touchend', event => {
  if (heroTouchX === null || !event.target.closest('.home-hero, .yj-hero-wrap')) return;
  const delta = event.changedTouches[0].clientX - heroTouchX;
  heroTouchX = null;
  if (Math.abs(delta) > 45) { live.heroIndex += delta < 0 ? 1 : -1; updateHero(); }
}, { passive: true });

/* ===== hero 局部更新（不重建整页，避免闪烁） ===== */
function updateHero() {
  const items = live.rankings?.flatMap(group => group[1] || []) || [];
  const heroes = items.filter(item => item.backdrop_path).slice(0, 8);
  const len = Math.max(heroes.length, 1);
  live.heroIndex = ((live.heroIndex % len) + len) % len;
  const feature = heroes[live.heroIndex] || items[0];
  const wrap = document.querySelector('.yj-hero-wrap');
  if (!wrap || !feature) return;
  wrap.classList.add('yj-no-anim');
  wrap.innerHTML = heroMarkup(feature, itemKind(feature), heroes, live.heroIndex);
  yjApplyPosterTheme(feature);
}

document.addEventListener('submit', async event => {
  const type = event.target.dataset.provider;
  if (!type) return;
  event.preventDefault(); event.stopImmediatePropagation();
  const form = new FormData(event.target);
  if (prototypeMode) {
    if (type === 'trakt') providerConfig.traktAuthorized = providerConfig.trakt = true;
    if (type === 'tmdb') providerConfig.tmdb = true;
    if (type === 'emby') {
      const editId = event.target.dataset.editId;
      const server = editId && providerConfig.emby.find(item => String(item.id) === String(editId));
      const addresses = addressUrlsFromForm(event.target);
      const url = addresses[0] || 'http://192.168.1.10';
      if (server) Object.assign(server, { name: String(form.get('name') || '').trim() || server.name || '家庭 NAS', url, addresses, activeAddress: 0 });
      else providerConfig.emby = [{ id: 'prototype', name: String(form.get('name') || '').trim() || '家庭 NAS', url, addresses, activeAddress: 0, userName: form.get('username') || '林先生', kind:String(form.get('kind') || 'Emby') }];
    }
    if (type === 'webdav') {
      const editId = event.target.dataset.editId;
      const source = editId && providerConfig.files.find(item => String(item.id) === String(editId));
      const next = { name:String(form.get('name')||'家庭网盘'), url:String(form.get('url')||'https://dav.example.com/videos/'), username:String(form.get('username')||'user'), kind:'WebDAV' };
      if (source) Object.assign(source, next); else providerConfig.files = [{ id:'prototype-dav', ...next }];
    }
    saveProviders(); type === 'emby' || type === 'webdav' ? library() : settingsV2(); notify('原型模式：连接状态已更新'); return;
  }
  try {
    if (type === 'tmdb') {
      const key = form.get('key').trim();
      await request(`https://api.themoviedb.org/3/configuration?api_key=${encodeURIComponent(key)}`);
      await window.yingjiDesktop.setSecret('tmdb-key', key); providerConfig.tmdb = true;
    } else if (type === 'trakt') {
      const key = form.get('key').trim();
      await request('https://api.trakt.tv/shows/trending?limit=1', { headers: { 'trakt-api-version': '2', 'trakt-api-key': key } });
      await Promise.all([window.yingjiDesktop.setSecret('trakt-client-id', key), window.yingjiDesktop.setSecret('trakt-client-secret', form.get('secret').trim())]); providerConfig.trakt = true;
    } else if (type === 'webdav') {
      const url = String(form.get('url')).trim().replace(/\/?$/, '/');
      const username = String(form.get('username')).trim();
      const editId = event.target.dataset.editId;
      const existing = editId && (providerConfig.files || []).find(item => String(item.id) === String(editId));
      const password = String(form.get('password') || '') || (existing ? await window.yingjiDesktop.getSecret(`source-${existing.id}`) : '');
      if (!password) throw new Error('请输入 WebDAV 密码');
      const authorization = `Basic ${btoa(`${username}:${password}`)}`;
      await request(url, { method: 'PROPFIND', headers: { Depth: '0', Authorization: authorization }, responseType: 'text' });
      const id = existing?.id || crypto.randomUUID();
      await window.yingjiDesktop.setSecret(`source-${id}`, password);
      const next = { id, name: String(form.get('name')).trim() || new URL(url).hostname, url, username, kind: 'WebDAV' };
      if (existing) Object.assign(existing, next); else providerConfig.files.push(next);
    } else {
      const addresses = [...new Set(addressUrlsFromForm(event.target).map(value => value.replace(/\/$/, '')).filter(Boolean))];
      const url = addresses[0];
      if (!url) throw new Error('请至少填写一个服务器地址');
      const editId = event.target.dataset.editId;
      const existing = editId && (providerConfig.emby || []).find(item => String(item.id) === String(editId));
      const username = String(form.get('username') || '').trim();
      const password = String(form.get('password') || '');
      const customName = String(form.get('name') || '').trim();
      if (existing && !username && !password) {
        existing.addresses = addresses; existing.activeAddress = 0; existing.url = url;
        existing.name = customName || existing.name || new URL(url).hostname;
      } else {
        const id = existing?.id || crypto.randomUUID();
        const auth = await request(`${url}/Users/AuthenticateByName`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'X-Emby-Authorization': 'MediaBrowser Client="Yingji", Device="Windows", DeviceId="yingji-desktop", Version="0.2.0"' },
          body: { Username: username, Pw: password }
        });
        await window.yingjiDesktop.setSecret(`emby-${id}`, auth.AccessToken);
        let autoName = auth.ServerName || auth.Server?.Name || '';
        let publicInfo = null;
        try { publicInfo = await request(`${url}/System/Info/Public`); autoName = publicInfo.ServerName || publicInfo.ProductName || autoName; } catch {}
        const discovered = [auth.Server?.LocalAddress, auth.Server?.WanAddress, auth.Server?.RemoteAddress, publicInfo?.LocalAddress, publicInfo?.WanAddress, publicInfo?.RemoteAddress].filter(value => /^https?:\/\//i.test(String(value || '')));
        const allAddresses = [...new Set([...addresses, ...discovered].map(value => String(value).replace(/\/$/, '')))];
        const iconUrl = `${url}/Branding/Splashscreen?api_key=${encodeURIComponent(auth.AccessToken)}`;
        const next = { id, name: customName || autoName || new URL(url).hostname, url, addresses:allAddresses, activeAddress: 0, userId: auth.User.Id, userName: auth.User.Name, kind: String(form.get('kind') || 'Emby'), iconUrl };
        live.sourceIcons[id] = iconUrl;
        if (existing) Object.assign(existing, next); else { providerConfig.emby ||= []; providerConfig.emby.push(next); }
      }
    }
    saveProviders();
    if (type === 'emby') await loadConnectedSourceData().catch(() => {});
    if ((type === 'emby' || type === 'webdav') && live.returnToLibrary) { live.addingServer = false; live.editingServerId = null; live.editingFileId = null; library(); }
    else settingsV2();
    notify('连接成功，配置已安全保存');
  } catch (error) { notify(`连接失败：${error.message}`); }
}, true);

document.addEventListener('submit', event => {
  const form = event.target.closest('[data-live-search]');
  if (!form) return;
  event.preventDefault();
  searchDiscovery(new FormData(form).get('query').trim());
});

render();
// Refresh older caches once for a configured desktop client; cached shelves
// remain visible until the refreshed real-data result is available.
if (metadataEndpoint || (!prototypeMode && discoveryCacheMeta.version !== discoveryCacheVersion)) syncDiscovery();
if (!prototypeMode) loadConnectedSourceData().catch(() => {});
if (prototypeMode) {
  const prototypePage = location.hash.slice(1) || new URLSearchParams(location.search).get('page');
  ({ home, search: searchPage, calendar, watchlist, library, downloads, settings: settingsV2 }[prototypePage] || home)();
  document.addEventListener('click', event => {
    const segmented = event.target.closest('.segmented button');
    if (segmented) { segmented.parentElement.querySelectorAll('button').forEach(button => button.classList.toggle('on', button === segmented)); }
    const toggle = event.target.closest('.switch');
    if (toggle) toggle.classList.toggle('off');
  });
}

const updateNetworkStatus = () => document.body.classList.toggle('is-offline', !navigator.onLine);
window.addEventListener('online', () => { updateNetworkStatus(); notify('网络已恢复'); });
window.addEventListener('offline', updateNetworkStatus);
updateNetworkStatus();

const decorateInterfaceIcons = () => {
  const set = (selector, name) => document.querySelectorAll(`${selector}:not([data-icon-ready])`).forEach(element => {
    element.innerHTML = ico(name);
    element.dataset.iconReady = 'true';
  });
  set('.home-tools button:first-child', 'refresh');
  set('.hero-sync', 'more');
  ['smart', 'direct', 'retry'].forEach((name, index) => {
    const element = document.querySelectorAll('.home-side .setting-icon')[index];
    if (element && !element.dataset.iconReady) { element.innerHTML = ico(name); element.dataset.iconReady = 'true'; }
  });
  set('.download-row>span:last-child', 'pause');
  set('.download-placeholder>span', 'download');
  set('.recent-row>span:first-child', 'history');
  set('.recent-row>span:last-child', 'close');
  set('.chevron', 'chevron');
  document.querySelectorAll('button:not([data-text-icon-ready])').forEach(button => {
    const text = button.textContent.trim();
    const match = text.match(/^([▶＋+])\s*(.*)$/);
    if (!match) return;
    button.innerHTML = `${ico(match[1] === '▶' ? 'play' : 'plus')}${match[2] ? `<span>${esc(match[2])}</span>` : ''}`;
    button.dataset.textIconReady = 'true';
  });
};
decorateInterfaceIcons();
new MutationObserver(decorateInterfaceIcons).observe(app, { childList: true, subtree: true });

// Directional focus keeps the Windows app comfortable from a sofa keyboard or remote.
document.addEventListener('keydown', event => {
  if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return;
  const editing = event.target.matches('input,textarea,[contenteditable="true"]');
  if (event.key === '/' && !editing) {
    event.preventDefault();
    const search = document.querySelector('.home-search,[data-go="search"]');
    search?.click();
    requestAnimationFrame(() => document.querySelector('[data-live-search] input')?.focus());
    return;
  }
  if (event.key === 'Escape' && editing) { event.target.blur(); return; }
  if (!['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'].includes(event.key) || editing) return;
  const candidates = [...document.querySelectorAll('button:not(:disabled),a[href],input:not(:disabled)')].filter(element => {
    const box = element.getBoundingClientRect();
    return box.width > 0 && box.height > 0;
  });
  const current = document.activeElement;
  if (!candidates.includes(current)) { candidates[0]?.focus(); return; }
  const from = current.getBoundingClientRect();
  const x = from.left + from.width / 2, y = from.top + from.height / 2;
  const horizontal = event.key === 'ArrowLeft' || event.key === 'ArrowRight';
  const sign = event.key === 'ArrowLeft' || event.key === 'ArrowUp' ? -1 : 1;
  const next = candidates.map(element => {
    const box = element.getBoundingClientRect();
    const dx = box.left + box.width / 2 - x, dy = box.top + box.height / 2 - y;
    const primary = horizontal ? dx : dy, secondary = horizontal ? dy : dx;
    return { element, score: Math.abs(primary) + Math.abs(secondary) * 2.4, primary };
  }).filter(item => item.primary * sign > 4).sort((a, b) => a.score - b.score)[0]?.element;
  if (next) { event.preventDefault(); next.focus({ preventScroll: true }); next.scrollIntoView({ block: 'nearest', inline: 'nearest' }); }
});
