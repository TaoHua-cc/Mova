/* Complete UI layer. Data, authentication and playback stay in integration.js. */
const yjSources = () => [...(providerConfig.emby || []), ...(providerConfig.files || [])];
const yjTitle = item => item?.title || item?.name || item?.original_title || item?.original_name || '未命名内容';
const yjYear = item => (item?.release_date || item?.first_air_date || '').slice(0, 4);
const yjDateKey = value => new Intl.DateTimeFormat('en-CA', { year:'numeric', month:'2-digit', day:'2-digit' }).format(value instanceof Date ? value : new Date(value));
const yjAddressParts = value => {
  try { const url = new URL(value); return { protocol: url.protocol.replace(':','') || 'https', host:url.hostname, port:url.port, path:url.pathname === '/' ? '' : url.pathname }; }
  catch { return { protocol:'https', host:'', port:'', path:'' }; }
};
const yjAddressRow = value => { const part = yjAddressParts(value); const port = part.port || (part.protocol === 'https' ? '8096' : '443'); return `<div class="yj-address-row" data-address-row><div class="yj-address-protocol"><button type="button" class="${part.protocol === 'https' ? 'is-active' : ''}" data-address-protocol="https">HTTPS</button><button type="button" class="${part.protocol === 'http' ? 'is-active' : ''}" data-address-protocol="http">HTTP</button></div><input name="hosts" required value="${esc(part.host)}" placeholder="media.example.com" aria-label="服务器地址"><input name="ports" inputmode="numeric" value="${esc(port)}" placeholder="端口" aria-label="端口"><input name="paths" value="${esc(part.path)}" placeholder="路径（可选，例如 /emby）" aria-label="路径"><button type="button" data-remove-address aria-label="移除地址">×</button></div>`; };
const yjArt = (item, type = 'backdrop', size = 'w780') => {
  const path = type === 'poster' ? item?.poster_path : item?.backdrop_path || item?.poster_path;
  return path ? `https://image.tmdb.org/t/p/${size}${path}` : '';
};
const yjContinueImages = (item, width = 640) => {
  const base = item?.server?.url, token = item?.token;
  if (!base || !token) return [];
  const ids = [item.Id].filter(Boolean);
  return ids.map(id => `${base}/Items/${id}/Images/Primary?maxWidth=${width}&quality=88&api_key=${encodeURIComponent(token)}`);
};
const yjWarmContinueArt = () => document.querySelectorAll('[data-continue-art]').forEach(node => {
  const urls = (node.dataset.continueArt || '').split('|').filter(Boolean); let index = 0;
  node.classList.add('is-loading');
  const tryNext = () => {
    const url = urls[index++]; if (!url) { node.classList.remove('is-loading'); return; }
    const image = new Image();
    image.onload = () => { node.style.setProperty('--yj-continue-image', `url('${url}')`); node.classList.remove('is-loading'); node.classList.add('is-ready'); };
    image.onerror = tryNext; image.src = url;
  };
  tryNext();
});
const yjRestoreScroll = value => {
  if (!Number.isFinite(value)) return;
  requestAnimationFrame(() => window.scrollTo({ top:value, behavior:'instant' }));
};
const yjApplyPosterTheme = (item, selector = '.yj-home') => {
  const url = yjArt(item, 'poster', 'w185');
  if (!url) return;
  const cacheKey = `yingji.poster-color-${item.id}`, cached = localStorage.getItem(cacheKey);
  if (cached) { document.querySelector(selector)?.style.setProperty('--poster-rgb', cached); document.documentElement.style.setProperty('--yj-page-rgb', cached); return; }
  const img = new Image(); img.crossOrigin = 'anonymous'; img.src = url;
  img.onload = () => { try { const canvas = document.createElement('canvas'); canvas.width = canvas.height = 24; const context = canvas.getContext('2d',{willReadFrequently:true}); context.drawImage(img,0,0,24,24); const pixels=context.getImageData(0,0,24,24).data; let r=0,g=0,b=0,count=0; for(let i=0;i<pixels.length;i+=16){if(pixels[i+3]<128)continue;r+=pixels[i];g+=pixels[i+1];b+=pixels[i+2];count++;} const color=`${Math.round(r/count)},${Math.round(g/count)},${Math.round(b/count)}`; localStorage.setItem(cacheKey,color); document.querySelector(selector)?.style.setProperty('--poster-rgb',color); document.documentElement.style.setProperty('--yj-page-rgb',color); } catch {} };
};
const yjEnrichCalendar = async () => {
  const pending = live.watchlist.filter(item => item.kind === 'tv' && !item.calendarResolved);
  if (!pending.length || live.calendarEnriching) return;
  live.calendarEnriching = true;
  try {
    await Promise.all(pending.map(async item => { item.calendarResolved = true; try { let id=item.id, detail=null; if(id){try{detail=await tmdbRequest(`/tv/${id}?language=zh-CN`);}catch{}} if(!detail && yjTitle(item) !== '未命名内容'){const found=await tmdbRequest(`/search/tv?query=${encodeURIComponent(yjTitle(item))}&language=zh-CN`);id=found.results?.[0]?.id;if(id){item.id=id;detail=await tmdbRequest(`/tv/${id}?language=zh-CN`);}} if(!detail)return; item.name=detail.name || item.name; item.poster_path=detail.poster_path || item.poster_path; const episode = detail.next_episode_to_air || detail.last_episode_to_air; if (!episode) return; item.calendarSeason = episode.season_number; item.calendarEpisode = episode.episode_number; item.calendarEpisodeTitle = episode.name || ''; if (detail.next_episode_to_air?.air_date) item.calendarDate = `${detail.next_episode_to_air.air_date}T12:00:00`; } catch {} }));
    saveLiveWatchlist();
  } finally { live.calendarEnriching = false; if (state.view === 'calendar') calendar(); }
};
const yjNav = [
  ['home', 'home', '首页'], ['search', 'search', '发现'], ['calendar', 'calendar', '追剧'],
  ['library', 'library', '资料库'], ['settings', 'settings', '设置']
];
const yjShell = (content, active = 'home', options = {}) => {
  const sources = yjSources();
  const nav = yjNav.map(([route, icon, label]) => `<button class="yj-nav-item ${active === route ? 'is-active' : ''}" data-go="${route}" aria-current="${active === route ? 'page' : 'false'}">${ico(icon)}<span>${label}</span></button>`).join('');
  return `<header class="yj-titlebar"><b>映迹</b><span>${options.title || '私人媒体库'}</span><div class="win"><span>—</span><span>□</span><span>×</span></div></header>
    <aside class="yj-sidebar"><div class="yj-brand"><span class="yj-brandmark">映</span><span><b>映迹</b><small>MEDIA SPACE</small></span></div><nav class="yj-nav" aria-label="主导航">${nav}</nav>
      <section class="yj-source-dock"><header><span>媒体来源</span><button data-go="library" aria-label="添加来源">${ico('plus')}</button></header>${sources.length ? sources.slice(0, 3).map(source => { const status=live.sourceStats[source.id]?.state || 'pending'; return `<button data-open-source="${esc(source.id)}"><i class="yj-dock-logo" ${source.customIcon || live.sourceIcons[source.id] ? `style="background-image:url('${esc(source.customIcon || live.sourceIcons[source.id])}')"` : ''}>${source.customIcon || live.sourceIcons[source.id] ? '' : esc((source.name || '源')[0])}</i><span><b>${esc(source.name)}</b><small>${esc(source.kind || 'Emby')} · ${status === 'connected' ? '已连接' : status === 'error' ? '连接异常' : '等待连接'}</small></span><em class="is-${status}" aria-label="${status === 'connected' ? '已连接' : status === 'error' ? '连接异常' : '等待连接'}"></em></button>`; }).join('') : '<button data-go="library" class="is-empty"><i>＋</i><span><b>连接来源</b><small>Emby · Jellyfin · WebDAV</small></span></button>'}</section>
      </aside>
    <div class="network-status">当前离线，保留本机内容与配置。</div>${content}`;
};
const yjEmpty = (title, text, action = '') => `<section class="yj-empty"><span>${ico('library')}</span><h2>${title}</h2><p>${text}</p>${action}</section>`;
const yjPoster = (item, index = 0) => {
  const epBadge = (item.season != null && item.number != null) ? `S${item.season}E${String(item.number).padStart(2,'0')}` : (item.kind === 'tv' && item.episode_count ? `全${item.episode_count}集` : '');
  return `<button class="yj-poster-card" data-live-detail="${item.id}" data-kind="${item.kind || itemKind(item)}"><span class="yj-poster" ${yjArt(item, 'poster', 'w500') ? `style="background-image:url('${yjArt(item, 'poster', 'w500')}')"` : ''}>${epBadge ? `<em class="yj-poster-badge">${epBadge}</em>` : ''}</span><span><b>${esc(yjTitle(item))}</b><small>${esc(yjYear(item) || '年份未知')} · TMDB ${(item.vote_average || 0).toFixed(1)}</small></span></button>`;
};
// Rank has its own hierarchy: the order is content, while each card remains
// one accessible route into the same real detail data used elsewhere.
const yjRankingCard = (item, position, meta = {}, variant = 'rail') => {
  const kind = item.kind || itemKind(item), art = yjArt(item, 'poster', 'w500');
  const source = meta.source === 'Trakt' ? 'Trakt 热度' : `TMDB ${(item.vote_average || 0).toFixed(1)}`;
  const type = kind === 'movie' ? '电影' : '剧集';
  return `<button class="yj-atv-rank-card yj-atv-rank-card--${variant}" data-live-detail="${esc(item.id)}" data-kind="${kind}" aria-label="第 ${position} 名，${esc(yjTitle(item))}"><span class="yj-atv-rank-art" ${art ? `style="background-image:url('${art}')"` : ''}><i class="yj-atv-rank-no">${String(position).padStart(2, '0')}</i><span class="yj-atv-rank-sheen" aria-hidden="true"></span></span><span class="yj-atv-rank-copy"><b>${esc(yjTitle(item))}</b><small>${esc(yjYear(item) || type)} · ${esc(source)}</small></span></button>`;
};
const yjWideCard = (item, label = '') => `<button class="yj-wide-card" data-live-detail="${item.id}" data-kind="${item.kind || itemKind(item)}"><span class="yj-wide-art" ${yjArt(item) ? `style="background-image:url('${yjArt(item)}')"` : ''}>${label ? `<em>${esc(label)}</em>` : ''}</span><span><b>${esc(yjTitle(item))}</b><small>${esc(yjYear(item) || (itemKind(item) === 'movie' ? '电影' : '剧集'))}</small></span></button>`;
const heroMarkup = (feature, featureKind, heroes, heroIndex) => `<section class="yj-feature yj-tv-hero" data-live-detail="${esc(feature.id)}" data-kind="${featureKind}" style="--art:url('${yjArt(feature, 'backdrop', 'original')}')"><button class="yj-hero-arrow is-prev" data-hero-prev aria-label="上一部作品">${ico('chevron')}</button><div class="yj-feature-copy"><h1>${esc(yjTitle(feature))}</h1><div class="yj-feature-meta"><b>${esc(yjYear(feature) || '最新')}</b><span>${featureKind === 'movie' ? '电影' : '剧集'}</span><span>TMDB ${(feature.vote_average || 0).toFixed(1)}</span></div><p>${esc(feature.overview || '查看作品资料并匹配你的私人媒体来源。')}</p><small class="yj-hero-hint">点击主视觉查看详情</small></div><button class="yj-hero-arrow is-next" data-hero-next aria-label="下一部作品">${ico('chevron')}</button><div class="yj-feature-switch">${heroes.map((_, index) => `<button class="${index === heroIndex ? 'is-active' : ''}" data-hero-dot="${index}" aria-label="第 ${index + 1} 项"></button>`).join('')}</div></section>`;

const yjRankingsForHome = groups => {
  const toggles = readLocalJson('yingji.shelf-toggles', {});
  return groups.map((group, index) => {
    const [name, items, meta = {}, sourceIndex = index] = group;
    const enabled = Object.hasOwn(toggles, name) ? toggles[name] : meta.featured !== false;
    if (!enabled) return null;
    const preview = (items || []).slice(0, 10);
    return preview.length ? { index: sourceIndex, name, items: preview, meta } : null;
  }).filter(Boolean);
};

// The settings sheet controls homepage placement only. It never claims a
// scraped provider, and each grouping remains traceable to its real source.
renderShelfPanel = function yjRankingShelfPanel() {
  let root = document.getElementById('yj-shelf-panel-root');
  if (!live.shelfPanelOpen) { root?.remove(); return; }
  const groups = (live.rankings || []).reduce((rows, group, index) => {
    if (group?.[1]?.length && !['IMDb', '豆瓣'].includes(group[2]?.source)) rows.push([...group, index]);
    return rows;
  }, []);
  const toggles = readLocalJson('yingji.shelf-toggles', {});
  const filters = ['all', '热度', '地区', '类型', '平台', '档期', '口碑', 'Trakt'];
  const activeFilter = filters.includes(live.shelfFilter) ? live.shelfFilter : 'all';
  const shown = groups.filter(([, , meta = {}]) => activeFilter === 'all' || meta.family === activeFilter || meta.source === activeFilter);
  if (!root) { root = document.createElement('div'); root.id = 'yj-shelf-panel-root'; document.body.appendChild(root); }
  root.innerHTML = `<section class="yj-atv-rank-sheet-backdrop" data-shelf-panel-close><section class="yj-atv-rank-sheet" role="dialog" aria-modal="true" aria-label="定制首页榜单"><header><div><h2>定制首页榜单</h2><p>选择要出现在首页的真实数据轨道；不会改变数据源本身。</p></div><button class="yj-panel-close" data-shelf-panel-close aria-label="关闭">${ico('close')}</button></header><nav class="yj-atv-rank-filter" aria-label="榜单分类">${filters.map(filter => `<button class="${activeFilter === filter ? 'on' : ''}" data-shelf-filter="${filter}">${filter === 'all' ? `全部 ${groups.length}` : `${filter} ${groups.filter(([, , meta = {}]) => meta.family === filter || meta.source === filter).length}`}</button>`).join('')}</nav><div class="yj-atv-rank-options">${shown.map(([name, , meta = {}]) => { const checked = Object.hasOwn(toggles, name) ? toggles[name] : meta.featured !== false; return `<article class="${checked ? 'is-enabled' : ''}"><span><b>${esc(name)}</b><small>${esc(meta.source || 'TMDB')} · ${esc(meta.summary || '实时影视榜单')}</small></span><button type="button" class="yj-atv-rank-toggle" role="switch" aria-checked="${checked}" data-shelf-toggle="${esc(name)}"><i></i><em>${checked ? '显示' : '隐藏'}</em></button></article>`; }).join('')}</div></section></section>`;
};

home = function yjHome() {
  const sameView = !!document.querySelector('.yj-home');
  live.rankings ||= readLocalJson('yingji.discovery-cache', null);
  const groups = (live.rankings || []).reduce((rows, group, index) => {
    if (group?.[1]?.length && !['IMDb', '豆瓣'].includes(group[2]?.source)) rows.push([...group, index]);
    return rows;
  }, []);
  const visibleShelves = yjRankingsForHome(groups);
  const items = groups.flatMap(group => group[1]);
  if (!items.length) {
    const sources = yjSources();
    app.innerHTML = yjShell(`<main class="yj-page yj-onboarding"><section class="yj-onboarding-copy"><span class="yj-eyebrow">PRIVATE MEDIA, UNIFIED</span><h1>把你的影音内容<br>带到同一个空间。</h1><p>连接私人服务器或存储后，映迹会读取真实资料库、统一搜索并交给 mpv 播放。</p><div class="yj-actions"><button class="primary" data-go="library">${ico('plus')} 添加媒体来源</button><button class="secondary" data-go="settings">配置元数据服务</button></div></section><aside class="yj-onboarding-status"><header><b>来源概览</b><span>${sources.length} 个来源</span></header>${sources.length ? sources.map(source => `<div><i>${esc((source.name || '源')[0])}</i><span><b>${esc(source.name)}</b><small>${esc(source.kind || 'Emby')}</small></span><em>已连接</em></div>`).join('') : yjEmpty('尚未连接来源', '从 Emby、Jellyfin 或 WebDAV 开始。')}</aside></main>`, 'home', { hideSearch:true });
    return;
  }
  const heroes = items.filter(item => item.backdrop_path).slice(0, 8);
  live.heroIndex = ((live.heroIndex % Math.max(heroes.length, 1)) + Math.max(heroes.length, 1)) % Math.max(heroes.length, 1);
  const feature = heroes[live.heroIndex] || items[0];
  const featureKind = itemKind(feature);
  const continueItems = (live.continueItems || []).filter(item => item?.server?.url && item?.token && item?.Id).slice(0, 6);
  const continueCards = continueItems.map((item, index) => {
    const progress = Math.min(100, Math.round((item.UserData?.PlaybackPositionTicks || 0) / Math.max(item.RunTimeTicks || 1, 1) * 100));
    const last = item.UserData?.LastPlayedDate ? new Intl.RelativeTimeFormat('zh-CN',{numeric:'auto'}).format(-Math.max(1,Math.round((Date.now()-new Date(item.UserData.LastPlayedDate))/86400000)),'day') : '最近播放';
    const detailId = esc(item.Id), kind = item.Type === 'Movie' ? 'movie' : 'tv', images = yjContinueImages(item);
    return `<article class="yj-continue-card" style="--yj-continue-delay:${index * 55}ms"><div class="yj-continue-art" data-live-detail="${detailId}" data-kind="${kind}"><span class="yj-wide-art" data-continue-art="${esc(images.join('|'))}" ${images[0] ? `style="--yj-continue-fallback:url('${images[0]}')"` : ''}>${item.ParentIndexNumber ? `<em class="yj-cont-episode-tag">第 ${item.IndexNumber || '—'} 集</em>` : ''}<em class="yj-cont-progress">${progress}%</em><i class="yj-continue-progress" style="--yj-progress:${progress}%"></i><button class="yj-continue-play" data-continue-play="${index}" aria-label="继续播放 ${esc(item.Name || item.SeriesName || '当前内容')}">${ico('play')}</button></span></div><button class="yj-continue-copy" data-live-detail="${detailId}" data-kind="${kind}"><b>${esc(item.SeriesName ? `${item.SeriesName} · ${item.Name}` : item.Name)}</b><small>${esc(last)} · ${esc(item.server.name)}</small></button></article>`;
  }).join('');
  app.innerHTML = yjShell(`<main class="yj-home ${sameView ? 'yj-no-anim' : ''}" style="--home-art:url('${yjArt(feature, 'backdrop', 'original')}')"><div class="yj-hero-wrap">${heroMarkup(feature, featureKind, heroes, live.heroIndex)}</div>
    <section class="yj-home-content yj-tv-home-content">${continueItems.length ? `<section class="yj-home-shelf yj-home-continue"><header class="yj-section-head"><h2>继续观看</h2><button data-open-shelf="continue">查看全部 ${ico('chevron')}</button></header><div class="yj-shelf-viewport yj-continue-viewport"><button class="yj-shelf-arrow is-prev" data-shelf-scroll="-1" aria-label="向左浏览继续观看">${ico('chevron')}</button><div class="yj-wide-rail" data-shelf-rail>${continueCards}</div><button class="yj-shelf-arrow is-next" data-shelf-scroll="1" aria-label="向右浏览继续观看">${ico('chevron')}</button></div></section>` : ''}
    <section class="yj-atv-rank-hub"><div><h2>影视榜单</h2><p>以真实热度、播出档期与口碑整理，随时回到正在发生的影视世界。</p></div><div class="yj-atv-rank-hub-actions"><span>${visibleShelves.length} 个轨道</span><button class="yj-atv-rank-manage" data-shelf-panel>${ico('settings')} 定制</button></div></section>
    ${visibleShelves.map(({index, name, items: group, meta}, groupIndex) => `<section class="yj-atv-rank-row" style="--yj-shelf-delay:${Math.min(220, groupIndex * 45)}ms"><header><div><h2>${esc(name)}</h2><p>${esc(meta?.summary || 'TMDB · 实时影视榜单')}</p></div><button class="yj-atv-rank-more" data-live-more="${index}">查看全部 ${ico('chevron')}</button></header><div class="yj-shelf-viewport yj-atv-rank-viewport"><button class="yj-shelf-arrow is-prev" data-shelf-scroll="-1" aria-label="向左浏览 ${esc(name)}">${ico('chevron')}</button><div class="yj-atv-rank-rail" data-shelf-rail>${group.map((item, position) => yjRankingCard(item, position + 1, meta)).join('')}</div><button class="yj-shelf-arrow is-next" data-shelf-scroll="1" aria-label="向右浏览 ${esc(name)}">${ico('chevron')}</button></div></section>`).join('')}
    </section></main>`, 'home', { hideSearch:true });
  yjApplyPosterTheme(feature); yjWarmContinueArt(); renderShelfPanel();
};

searchPage = function yjSearch() {
  const fallback = live.rankings?.flatMap(group => group[1]) || [];
  const results = live.search?.results || fallback;
  const query = live.search?.query || '';
  const filter = live.ui.searchFilter || 'all';
  const shown = results.filter(item => filter === 'all' || itemKind(item) === filter);
  app.innerHTML = yjShell(`<main class="yj-page yj-discovery"><header class="yj-page-head"><span class="yj-eyebrow">DISCOVER</span><h1>发现</h1><p>同时搜索 TMDB 资料与已连接的私人媒体来源。</p></header><form class="yj-searchbox" data-live-search>${ico('search')}<input name="query" required autofocus value="${esc(query)}" placeholder="输入电影、剧集或演员名称"><button>搜索</button></form><div class="yj-filterbar"><button class="${filter === 'all' ? 'is-active' : ''}" data-search-filter="all">全部</button><button class="${filter === 'movie' ? 'is-active' : ''}" data-search-filter="movie">电影</button><button class="${filter === 'tv' ? 'is-active' : ''}" data-search-filter="tv">剧集</button></div>${live.search?.loading ? yjEmpty('正在搜索', '正在读取真实元数据结果。') : shown.length ? `<section class="yj-result-grid">${shown.slice(0, 20).map(yjPoster).join('')}</section>` : yjEmpty(query ? '没有搜索结果' : '开始搜索', query ? '尝试更换关键词或检查元数据服务。' : '输入片名即可搜索全部来源。')}</main>`, 'search', { title: '发现' });
};

watchlist = function yjWatchlist() {
  const cards = live.watchlist.map(item => `<article class="yj-watch-item">${yjWideCard(item, item.kind === 'movie' ? '电影' : '剧集')}<button data-live-unwatch="${esc(item.id)}">移出待看</button></article>`).join('');
  app.innerHTML = yjShell(`<main class="yj-page yj-list-page"><button class="yj-page-back" data-go="calendar">${ico('chevron')} 返回追剧</button><header class="yj-page-head yj-page-head-row"><div><span class="yj-eyebrow">TRACKING</span><h1>待看清单</h1><p>保存在本机并可与 Trakt 观看记录结合。</p></div><b class="yj-count">${live.watchlist.length}</b></header><div class="yj-track-tabs"><button data-go="calendar">追剧日历</button><button class="is-active">待看</button></div>${cards ? `<section class="yj-wide-grid">${cards}</section>` : yjEmpty('待看清单是空的', '在作品详情中点击“加入待看”。', '<button class="primary" data-go="search">发现内容</button>')}</main>`, 'calendar', { title: '待看' });
};

const yjLoadSourceContent = async sourceId => {
  const source = yjSources().find(item => String(item.id) === String(sourceId));
  if (!source || source.kind === 'WebDAV') return;
  live.serverLoadingId = source.id; library();
  try {
    if (live.serverErrors) delete live.serverErrors[source.id];
    const token = await window.yingjiDesktop.getSecret(`emby-${source.id}`);
    const views = await request(`${source.url}/Users/${source.userId}/Views`, { headers:embyHeaders(token) });
    const libraries = await Promise.all((views.Items || []).map(async view => {
      const data = await request(`${source.url}/Users/${source.userId}/Items?ParentId=${encodeURIComponent(view.Id)}&Recursive=true&IncludeItemTypes=Movie,Series&Fields=Overview,ProviderIds,ProductionYear,CommunityRating,PremiereDate&SortBy=SortName&Limit=300`, { headers:embyHeaders(token) });
      return { id:view.Id, name:view.Name, type:view.CollectionType || 'mixed', items:(data.Items || []).map(item => ({...item,server:source,token,libraryId:view.Id,libraryName:view.Name})) };
    }));
    live.serverLibraries ||= {}; live.serverLibraries[source.id] = libraries.filter(group => group.items.length);
    live.serverItems ||= {}; live.serverItems[source.id] = libraries.flatMap(group => group.items).filter((item,index,list) => list.findIndex(row => String(row.Id) === String(item.Id)) === index);
  } catch (error) { live.serverErrors ||= {}; live.serverErrors[source.id] = error.message || '服务器资源读取失败'; }
  finally { live.serverLoadingId = null; if (String(live.openSourceId) === String(source.id)) library(); }
};

calendar = function yjCalendar() {
  const restoreScroll = live.preserveCalendarScroll;
  delete live.preserveCalendarScroll;
  const start = new Date(); start.setDate(start.getDate() - 2);
  const selectedDate = new Date(start); selectedDate.setDate(selectedDate.getDate() + live.ui.calendarDay);
  const selectedKey = yjDateKey(selectedDate);
  const traktEvents = live.calendarEvents.filter(event => event.first_aired && !live.suppressedCalendar.includes(String(event.show?.ids?.tmdb)) && yjDateKey(event.first_aired) === selectedKey).map(event => ({ id:event.show?.ids?.tmdb, removeKey:`trakt:${event.show?.ids?.tmdb || ''}`, title:event.show?.title, poster:live.calendarPosters[event.show?.ids?.tmdb], time:event.first_aired, meta:`第 ${event.episode.season} 季 · 第 ${event.episode.number} 集`, note:event.episode.title || '新一集', source:'Trakt' }));
  const localEvents = live.watchlist.map((item, watchIndex) => ({ item, watchIndex })).filter(({item}) => item.kind === 'tv' && (item.calendarDate || item.addedAt) && yjDateKey(item.calendarDate || item.addedAt) === selectedKey).map(({item,watchIndex}) => ({ id:item.id, removeKey:`local:${watchIndex}`, title:yjTitle(item), poster:item.poster_path, time:item.calendarDate || item.addedAt, meta:item.calendarSeason && item.calendarEpisode ? `第 ${item.calendarSeason} 季 · 第 ${item.calendarEpisode} 集` : '已加入待看', note:item.calendarEpisodeTitle || '等待同步具体剧集', source:'待看' }));
  const selectedEvents = [...traktEvents, ...localEvents].filter((event,index,list) => list.findIndex(row => String(row.id) === String(event.id)) === index);
  const allEventDates = [...live.calendarEvents.map(event => event.first_aired), ...live.watchlist.filter(item => item.kind === 'tv').map(item => item.calendarDate || item.addedAt)].filter(Boolean);
  const days = Array.from({ length: 9 }, (_, index) => { const day = new Date(start); day.setDate(day.getDate() + index); const key = yjDateKey(day); const count = allEventDates.filter(date => yjDateKey(date) === key).length; return `<button class="${index === live.ui.calendarDay ? 'is-active' : ''}" data-calendar-day="${index}"><span>${new Intl.DateTimeFormat('zh-CN',{weekday:'short'}).format(day)}</span><b>${index === 2 ? '今天' : new Intl.DateTimeFormat('zh-CN',{day:'2-digit'}).format(day)}</b><small>${count ? `${count} 项` : '无更新'}</small></button>`; }).join('');
  const rows = selectedEvents.map(event => { const eventTime = new Date(event.time); const poster = event.poster ? `style="background-image:url('${event.poster.startsWith('/') ? `https://image.tmdb.org/t/p/w300${event.poster}` : event.poster}')"` : ''; return `<article class="yj-calendar-row"><time class="yj-calendar-time" datetime="${esc(eventTime.toISOString())}"><b>${eventTime.toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit'})}</b><small>${esc(event.source)}</small></time><span class="yj-calendar-art" ${poster}></span><button class="yj-calendar-copy" data-live-detail="${esc(event.id)}" data-kind="tv" aria-label="查看 ${esc(event.title || '剧集')} 详情"><b>${esc(event.title || '剧集资料补全中')}</b><small>${esc(event.meta)}</small><em>${esc(event.note)}</em></button><button class="yj-calendar-remove" data-calendar-remove="${esc(event.removeKey)}" aria-label="从日历移除 ${esc(event.title || '剧集')}">${ico('close')}</button></article>`; }).join('');
  const content = rows || yjEmpty('这一天没有安排', providerConfig.traktAuthorized ? '选择其他日期，或把剧集加入待看。' : '加入待看的剧会显示在这里；连接 Trakt 后还会同步观看记录。', providerConfig.traktAuthorized ? '' : '<button class="primary" data-trakt-auth>连接 Trakt</button>');
  app.innerHTML = yjShell(`<main class="yj-page yj-calendar-page"><header class="yj-page-head yj-page-head-row"><div><span class="yj-eyebrow">UPCOMING</span><h1>追剧日历</h1><p>按播出时间整理的真实 Trakt 剧集更新。</p></div><button class="primary" data-sync-calendar ${providerConfig.traktAuthorized ? '' : 'disabled'}>${ico('refresh')} 同步日历</button></header><div class="yj-track-tabs"><button class="is-active">日历</button><button data-go="watchlist">待看</button></div><section class="yj-calendar-board"><aside class="yj-date-column">${days}</aside><div class="yj-calendar-main"><header><span><b>${new Intl.DateTimeFormat('zh-CN',{month:'long',day:'numeric'}).format(selectedDate)}</b><small>${new Intl.DateTimeFormat('zh-CN',{weekday:'long'}).format(selectedDate)}</small></span><em>${selectedEvents.length} 集</em></header><div class="yj-calendar" data-trakt-calendar>${content}</div></div></section></main>`, 'calendar', { title: '追剧日历' });
  if (document.documentElement.dataset.appearance === 'light') {
    const activeDay = document.querySelector('.yj-calendar-page .yj-date-column button.is-active');
    if (activeDay) { activeDay.style.setProperty('background','#dceaff','important'); activeDay.style.setProperty('border-color','#a8c8f6','important'); activeDay.style.setProperty('color','#183a66','important'); [...activeDay.children].forEach(node => node.style.setProperty('color','#183a66','important')); }
  }
  yjRestoreScroll(restoreScroll);
  yjEnrichCalendar();
};

library = function yjLibrary() {
  const restoreScroll = live.preserveLibraryScroll;
  delete live.preserveLibraryScroll;
  live.returnToLibrary = true;
  const emby = providerConfig.emby || [], files = providerConfig.files || [], sources = [...emby, ...files];
  const editing = live.editingServerId ? emby.find(source => String(source.id) === String(live.editingServerId)) : null;
  const editingFile = live.editingFileId ? files.find(source => String(source.id) === String(live.editingFileId)) : null;
  const selectedId = sources.some(source => String(source.id) === String(live.selectedSourceId)) ? live.selectedSourceId : (sources[0]?.id || '');
  live.selectedSourceId = selectedId;
  const visibleSources = live.openSourceId ? sources.filter(source => String(source.id) === String(live.openSourceId)) : sources;
  const sourceList = visibleSources.map(source => { const sourceStats = live.sourceStats[source.id] || {}; const isFile = source.kind === 'WebDAV'; const iconUrl = source.customIcon || live.sourceIcons[source.id]; const addresses = source.addresses || [source.url]; const state=sourceStats.state || 'pending'; const stateLabel=state === 'connected' ? '已连接' : state === 'error' ? '连接异常' : '等待连接'; return `<article class="yj-server-card ${String(selectedId) === String(source.id) ? 'is-active' : ''}" data-server-card="${esc(source.id)}"><button data-library-source="${esc(source.id)}"><i class="yj-server-logo ${String(source.kind || 'Emby').toLowerCase()}" ${iconUrl ? `style="background-image:url('${esc(iconUrl)}')"` : ''}>${iconUrl ? '' : source.kind === 'Jellyfin' ? 'J' : isFile ? 'W' : 'E'}</i><span><b>${esc(source.name)}</b><small>${esc(source.kind || 'Emby')} · ${sourceStats.total ?? '未同步'} 项</small></span><em class="is-${state}"><i></i>${stateLabel}</em></button><div><span>${sourceStats.movies || 0}<small>电影</small></span><span>${sourceStats.series || 0}<small>剧集</small></span>${!isFile && addresses.length > 1 ? `<select data-server-line="${esc(source.id)}" aria-label="切换 ${esc(source.name)} 线路">${addresses.map((address,index) => `<option value="${index}" ${index === source.activeAddress ? 'selected' : ''}>线路 ${index + 1}</option>`).join('')}</select>` : ''}<button aria-label="编辑 ${esc(source.name)}" ${isFile ? `data-edit-file="${esc(source.id)}"` : `data-edit-server="${esc(source.id)}"`}>${ico('settings')} 编辑</button></div></article>`; }).join('') + (live.openSourceId ? '' : `<button class="yj-add-server" data-toggle-library-server>${ico('plus')}<span><b>添加服务器</b><small>选择资源库来源</small></span></button>`);
  const chosenKind = editing ? (editing.kind?.toLowerCase() || 'emby') : (editingFile ? 'webdav' : live.sourceKind);
  const addresses = editing?.addresses || (editing?.url ? [editing.url] : ['']);
  const choice = `<div class="yj-source-choice"><button data-source-kind="emby"><i>E</i><span><b>Emby</b><small>私人影视服务器</small></span></button><button data-source-kind="jellyfin"><i>J</i><span><b>Jellyfin</b><small>开源媒体服务器</small></span></button><button data-source-kind="webdav"><i>W</i><span><b>WebDAV</b><small>网盘与私人存储</small></span></button></div>`;
  const embyForm = `<form class="yj-source-form" data-provider="emby" ${editing ? `data-edit-id="${esc(editing.id)}"` : ''}><input type="hidden" name="kind" value="${chosenKind === 'jellyfin' ? 'Jellyfin' : 'Emby'}"><div class="yj-source-icon">${chosenKind === 'jellyfin' ? 'J' : 'E'}</div><h3>${chosenKind === 'jellyfin' ? 'Jellyfin' : 'Emby'} 服务器</h3><input name="name" value="${esc(editing?.name || '')}" placeholder="自定义名称（留空使用服务器名称）"><div class="yj-addresses" data-address-list>${addresses.map(yjAddressRow).join('')}</div><button class="yj-add-address" type="button" data-add-address>${ico('plus')} 添加线路地址</button><div class="yj-source-login"><input name="username" ${editing ? '' : 'required'} placeholder="${editing ? '留空保持当前账户' : '用户名'}"><input name="password" type="password" ${editing ? '' : 'required'} placeholder="${editing ? '留空保持当前令牌' : '密码'}"></div><button>${editing ? '保存服务器' : '连接服务器'}</button></form>`;
  const webdavForm = `<form class="yj-source-form" data-provider="webdav" ${editingFile ? `data-edit-id="${esc(editingFile.id)}"` : ''}><div class="yj-source-icon">W</div><h3>WebDAV</h3><input name="name" value="${esc(editingFile?.name || '')}" placeholder="来源名称（可选）"><input name="url" type="url" required value="${esc(editingFile?.url || '')}" placeholder="https://dav.example.com/videos/"><input name="username" required value="${esc(editingFile?.username || '')}" placeholder="用户名"><input name="password" type="password" ${editingFile ? '' : 'required'} placeholder="${editingFile ? '留空保持当前密码' : '密码或应用密码'}"><button>${editingFile ? '保存修改' : '连接 WebDAV'}</button></form>`;
  const sheetTitle = editing ? `编辑服务器 · ${editing.name || '未命名服务器'}` : editingFile ? `编辑 WebDAV 来源 · ${editingFile.name || '未命名来源'}` : chosenKind ? '填写连接信息' : '选择资源库来源';
  const sheetCopy = editing ? '仅修改当前服务器的名称、线路、账户与图标，不影响其他媒体来源。' : editingFile ? '仅修改当前 WebDAV 来源，不影响其他已连接服务器。' : chosenKind ? '同一服务器可保存多个域名地址，并随时切换线路。' : '先选择你要连接的服务器类型。';
  const addPanel = live.addingServer ? `<section class="yj-source-sheet"><header><div><h2>${esc(sheetTitle)}</h2><p>${esc(sheetCopy)}</p></div><button class="yj-close" data-toggle-library-server>${ico('close')}</button></header><div class="yj-source-options">${!chosenKind ? choice : chosenKind === 'webdav' ? webdavForm : embyForm}</div></section>` : '';
  const opened = visibleSources[0], openedItems = opened ? (live.serverItems?.[opened.id] || []) : [], openedLibraries = opened ? (live.serverLibraries?.[opened.id] || []) : [];
  const openedSections = openedLibraries.map(group => { const cards=group.items.map(item => {const index=openedItems.findIndex(row => String(row.Id) === String(item.Id));return `<button class="yj-poster-card" data-server-media="${index}"><span class="yj-poster" style="background-image:url('${opened.url}/Items/${item.Id}/Images/Primary?maxWidth=420&quality=88&api_key=${encodeURIComponent(item.token)}')"></span><span><b>${esc(item.Name)}</b><small>${item.Type === 'Movie' ? '电影' : '剧集'} · ${esc(item.ProductionYear || '')}</small></span></button>`;}).join(''); return `<section class="yj-server-library"><header class="yj-section-head"><div><h2>${esc(group.name)}</h2><small>${group.type === 'movies' ? '电影媒体库' : group.type === 'tvshows' ? '剧集媒体库' : '媒体库'}</small></div><span>${group.items.length} 项</span></header><div class="yj-server-media-grid">${cards}</div></section>`; }).join('');
  const openedContent = live.openSourceId ? `<section class="yj-server-content">${live.serverLoadingId ? yjEmpty('正在读取服务器', '正在获取媒体库分类与真实资源。') : live.serverErrors?.[live.openSourceId] ? yjEmpty('服务器读取失败', live.serverErrors[live.openSourceId], '<button class="primary" data-reload-source>重新加载</button>') : openedSections || yjEmpty('服务器暂无资源', '服务器没有返回可浏览的电影或剧集媒体库。')}</section>` : '';
  app.innerHTML = yjShell(`<main class="yj-page yj-library-page ${live.openSourceId ? 'yj-server-page' : ''}">${live.openSourceId ? `<button class="yj-page-back" data-library-home>${ico('chevron')} 返回资料库</button>` : ''}<header class="yj-page-head yj-page-head-row"><div><h1>${live.openSourceId ? esc(visibleSources[0]?.name || '服务器') : '资料库'}</h1><p>${live.openSourceId ? '按照服务器中的真实媒体库分类浏览资源。' : '管理服务器、连接状态和访问线路。'}</p></div><div class="yj-actions">${live.openSourceId ? '<button class="primary" data-reload-source>'+ico('refresh')+' 重新读取</button>' : '<button class="primary" data-load-library>'+ico('refresh')+' 刷新服务器</button>'}</div></header>${live.openSourceId ? '' : `<section class="yj-server-section"><header><h2>媒体服务器</h2><span>${visibleSources.length} 个</span></header><div class="yj-server-rail">${sourceList}</div>${sources.length ? '' : yjEmpty('还没有媒体服务器', '添加 Emby、Jellyfin 或 WebDAV 后开始使用。', '<button class="primary" data-toggle-library-server>添加服务器</button>')}</section>`}${addPanel}${openedContent}</main>`, 'library', { title: live.openSourceId ? visibleSources[0]?.name : '资料库' });
  const refreshButton = document.querySelector('[data-load-library]');
  if (refreshButton) refreshButton.innerHTML = `${ico('refresh')} 刷新统计`;
  const serverRail = document.querySelector('.yj-server-rail');
  const addServer = serverRail?.querySelector('.yj-add-server');
  const allServer = serverRail?.querySelector('[data-library-source="all"]')?.closest('.yj-server-card');
  if (allServer) allServer.remove();
  const headerActions = document.querySelector('.yj-library-page .yj-page-head .yj-actions');
  if (serverRail && addServer && headerActions) { headerActions.append(addServer); addServer.classList.add('yj-add-server-visible'); }
  document.querySelectorAll('.yj-server-card [data-library-source]').forEach(button => { const source = yjSources().find(item => String(item.id) === String(button.dataset.librarySource)); const icon = source?.customIcon || live.sourceIcons[button.dataset.librarySource]; const mark = button.querySelector('.yj-server-logo'); if (icon && mark) { mark.textContent = ''; mark.style.backgroundImage = `url("${icon}")`; } });
  yjRestoreScroll(restoreScroll);
};

settingsV2 = function yjSettings() {
  const servers = providerConfig.emby || [];
  app.innerHTML = yjShell(`<main class="yj-page"><header class="yj-page-head"><span class="yj-eyebrow">PREFERENCES</span><h1>设置</h1><p>连接服务、播放器和本机隐私选项。</p></header><div class="yj-settings-layout"><nav class="yj-settings-nav"><button class="is-active">账户与服务</button><button>播放</button><button>字幕</button><button>网络与缓存</button><button>关于映迹</button></nav><section class="yj-settings-content"><section class="yj-setting-group"><header><h2>元数据与追剧</h2></header><article><span class="yj-service-badge">T</span><span><b>TMDB</b><small>中文资料、海报与搜索</small></span>${connectionBadge(!!metadataEndpoint || !!providerConfig.tmdb)}</article><form data-provider="tmdb"><input name="key" type="password" required placeholder="TMDB API Key（托管模式可选）"><button>保存并测试</button></form><article><span class="yj-service-badge">Tr</span><span><b>Trakt</b><small>观看记录与追剧日历</small></span>${connectionBadge(!!providerConfig.traktAuthorized)}</article><form data-provider="trakt"><input name="key" type="password" required placeholder="Trakt Client ID"><input name="secret" type="password" required placeholder="Trakt Client Secret"><button>保存凭据</button></form>${providerConfig.trakt ? `<button class="secondary" data-trakt-auth>${providerConfig.traktAuthorized ? '重新授权 Trakt' : '授权 Trakt 账户'}</button><div data-trakt-device></div>` : ''}</section><section class="yj-setting-group"><header><h2>播放器</h2><span>mpv</span></header><article><span>${ico('smart')}</span><span><b>硬件解码</b><small>D3D11 与 gpu-next</small></span>${toggleControl('hardware','硬件解码')}</article><article><span>${ico('play')}</span><span><b>HDR 与 Dolby Vision</b><small>跟随显示器能力</small></span>${toggleControl('hdr','HDR 与 Dolby Vision')}</article><article><span>${ico('library')}</span><span><b>已连接服务器</b><small>${servers.length} 个 Emby / Jellyfin 来源</small></span><button class="yj-inline" data-go="library">管理 ${ico('chevron')}</button></article></section></section></div></main>`, 'settings', { title: '设置' });
};

const yjSettingsWithAppearance = settingsV2;
settingsV2 = function yjSettingsAppearance() {
  yjSettingsWithAppearance();
  const content = document.querySelector('.yj-settings-content');
  if (!content) return;
  content.closest('main')?.classList.add('yj-settings-page');
  const sections = [...content.querySelectorAll('.yj-setting-group')];
  sections[0]?.setAttribute('id', 'settings-services');
  sections[1]?.setAttribute('id', 'settings-playback');
  const current = localStorage.getItem('yingji.appearance') || 'system';
  content.insertAdjacentHTML('beforeend', `<section id="settings-appearance" class="yj-setting-group yj-appearance-group"><header><h2>外观</h2><span>界面材质与明暗</span></header><div class="yj-appearance-options"><button class="${current === 'light' ? 'is-active' : ''}" data-appearance="light"><i>${ico('sun')}</i><span><b>浅色</b><small>明亮工作环境</small></span></button><button class="${current === 'dark' ? 'is-active' : ''}" data-appearance="dark"><i>${ico('moon')}</i><span><b>深色</b><small>影院观影环境</small></span></button><button class="${current === 'system' ? 'is-active' : ''}" data-appearance="system"><i>${ico('display')}</i><span><b>跟随系统</b><small>自动适配 Windows</small></span></button></div></section>`);
  const nav = document.querySelector('.yj-settings-nav');
  if (nav) nav.innerHTML = `<button class="is-active" data-settings-section="settings-services">账户与服务</button><button data-settings-section="settings-playback">播放</button><button data-settings-section="settings-appearance">外观</button>`;
  if (document.documentElement.dataset.appearance === 'light') nav?.querySelector('.is-active')?.style.setProperty('color','#183a66','important');
};

document.addEventListener('click', event => {
  const target = event.target.closest('[data-settings-section]');
  if (!target) return;
  const section = document.getElementById(target.dataset.settingsSection);
  if (!section) return;
  event.preventDefault();
  document.querySelectorAll('[data-settings-section]').forEach(button => button.classList.toggle('is-active', button === target));
  if (document.documentElement.dataset.appearance === 'light') document.querySelectorAll('[data-settings-section]').forEach(button => button.style.setProperty('color', button === target ? '#183a66' : '#344156', 'important'));
  section.scrollIntoView({ behavior:'smooth', block:'start' });
}, true);

downloads = function yjDownloads() {
  app.innerHTML = yjShell(`<main class="yj-page"><header class="yj-page-head"><span class="yj-eyebrow">OFFLINE</span><h1>离线内容</h1><p>当前 Windows 版本尚未启用下载引擎。</p></header>${yjEmpty('没有离线任务', '此页面不会生成虚假的下载记录。你可以直接播放已连接来源中的内容。', '<button class="primary" data-go="library">返回资料库</button>')}</main>`, 'library', { title: '离线内容' });
};

showLiveCollection = function yjCollection(kind) {
  if (state.view !== 'collection') yjRememberRoute();
  live.collectionKind = kind;
  state.view = 'collection';
  const items = kind === 'continue' ? (live.continueItems || []) : [];
  const cards = items.map((item, index) => { const progress = Math.min(100,Math.round((item.UserData?.PlaybackPositionTicks || 0)/Math.max(item.RunTimeTicks || 1)*100)); const title = item.SeriesName ? `${item.SeriesName} · ${item.Name}` : item.Name; return `<article class="yj-continue-wall-card"><div class="yj-continue-art" data-live-detail="${esc(item.Id)}" data-kind="${item.Type === 'Movie' ? 'movie' : 'tv'}"><span class="yj-wide-art" style="background-image:url('${item.server.url}/Items/${item.Id}/Images/Primary?maxWidth=960&quality=88&api_key=${encodeURIComponent(item.token)}')">${item.ParentIndexNumber ? `<em class="yj-cont-episode-tag">第 ${item.IndexNumber || '—'} 集</em>` : ''}<em class="yj-cont-progress">${progress}%</em><i class="yj-continue-progress" style="--yj-progress:${progress}%"></i><button class="yj-continue-play" data-continue-play="${index}" aria-label="继续播放 ${esc(title)}">${ico('play')}</button></span></div><button class="yj-continue-copy" data-live-detail="${esc(item.Id)}" data-kind="${item.Type === 'Movie' ? 'movie' : 'tv'}"><b>${esc(title)}</b><small>${esc(item.server.name)}</small></button></article>`; }).join('');
  app.innerHTML = yjShell(`<main class="yj-page yj-list-page"><button class="yj-page-back" data-go="home">${ico('chevron')} 返回首页</button><header class="yj-page-head yj-page-head-row"><div><h1>继续观看</h1><p>来自服务器的真实观看进度。</p></div><b class="yj-count">${items.length}</b></header>${cards ? `<section class="yj-continue-list">${cards}</section>` : yjEmpty('没有继续观看内容','开始播放后，未看完的内容会出现在这里。','<button class="primary" data-go="library">前往资料库</button>')}</main>`, 'home', { title:'继续观看' });
  window.scrollTo(0,0);
};

showLiveRanking = function yjRanking(index) {
  if (state.view !== 'ranking') yjRememberRoute();
  live.rankingIndex = Number(index);
  state.view = 'ranking';
  const group = live.rankings?.[Number(index)];
  if (!group) return;
  const [name, items, meta = {}] = group;
  const lead = items[0] || {};
  const leadArt = yjArt(lead, 'backdrop', 'original') || yjArt(lead, 'poster', 'original');
  const total = Math.max(Number(meta.totalResults || 0), items.length);
  const canLoadMore = meta.source === 'TMDB' && meta.path && Number(meta.page || 1) < Number(meta.totalPages || 1);
  app.innerHTML = yjShell(`<main class="yj-page yj-list-page yj-atv-ranking-page" style="--yj-ranking-art:url('${leadArt}')"><button class="yj-page-back" data-yj-back>${ico('chevron')} 返回</button><section class="yj-atv-ranking-intro"><div><p class="yj-atv-ranking-source">${esc(meta.source || 'TMDB')} · ${esc(meta.family || '实时榜单')}</p><h1>${esc(name)}</h1><p>${esc(meta.summary || '来自 TMDB 的实时影视榜单。')}</p></div><span>已加载 ${items.length} / ${total} 部</span></section><section class="yj-atv-ranking-feature" aria-label="榜首作品"><div class="yj-atv-ranking-feature-art" ${leadArt ? `style="background-image:url('${leadArt}')"` : ''}></div><div><b>本榜第 1 名</b><h2>${esc(yjTitle(lead))}</h2><p>${esc(lead.overview || '打开作品详情，查看资料、剧集与可播放版本。')}</p><button data-live-detail="${esc(lead.id)}" data-kind="${lead.kind || itemKind(lead)}">查看详情 ${ico('chevron')}</button></div></section><section class="yj-atv-ranking-grid" aria-label="${esc(name)}完整榜单">${items.map((item, position) => yjRankingCard(item, position + 1, meta, 'grid')).join('')}</section>${canLoadMore ? `<footer class="yj-atv-ranking-load"><span>该榜单还有 ${Math.max(0, total - items.length)} 部作品</span><button data-load-ranking-more="${Number(index)}" ${meta.loadingMore ? 'disabled aria-busy="true"' : ''}>${meta.loadingMore ? '正在加载…' : '加载更多'} ${ico('chevron')}</button></footer>` : `<footer class="yj-atv-ranking-load is-complete"><span>已显示该榜单的全部 ${items.length} 部作品</span></footer>`}</main>`, 'home', { title:name });
  window.scrollTo(0,0);
};

renderLiveDetail = function yjDetail() {
  const data = live.detail;
  if (!data) return;
  const item = data.item, details = data.detail || item, episodes = data.episodes || [], calendarId = data.tmdbId || item.id;
  if (item.id == null) item.id = calendarId;
  const inWatchlist = live.watchlist.some(entry => String(entry.id) === String(calendarId));
  data.episodeSort ||= 'asc'; data.showAllEpisodes ||= false; data.episodePage ||= 0; data.resourceView ||= 'resource';
  const sortedEpisodes = [...episodes].sort((a,b) => data.episodeSort === 'asc' ? a.number - b.number : b.number - a.number);
  const episodePageSize = 60, episodePages = Math.max(1, Math.ceil(sortedEpisodes.length / episodePageSize));
  data.episodePage = Math.min(data.episodePage, episodePages - 1);
  const visibleEpisodes = data.showAllEpisodes ? sortedEpisodes.slice(data.episodePage * episodePageSize, (data.episodePage + 1) * episodePageSize) : sortedEpisodes.slice(0, 12);
  const selected = episodes.find(episode => Number(episode.number) === Number(data.selectedEpisode));
  const qualities = [...new Set((data.resources || []).map(sourceQuality))].filter(Boolean).sort((a,b) => qualityRank(b) - qualityRank(a));
  if (!qualities.includes(data.selectedResolution)) data.selectedResolution = qualities[0] || '';
  const resources = (data.resources || []).filter(source => sourceQuality(source) === data.selectedResolution).sort((a,b) => Number(b.Bitrate || 0) - Number(a.Bitrate || 0));
  data.selectedResource = Math.min(data.selectedResource || 0, Math.max(0, resources.length - 1));
  const cast = (details.credits?.cast || []).slice(0, 12);
  const trailer = (details.videos?.results || []).find(video => video.site === 'YouTube' && ['Trailer','Teaser'].includes(video.type));
  const posters = (details.images?.posters || []).slice(0, 8);
  const seasons = (details.seasons || []).filter(season => season.season_number > 0 && season.episode_count > 0);
  const episodeCards = visibleEpisodes.map(episode => { const hasStill = !!episode.still_path; const still = hasStill ? image(episode.still_path,'w500') : yjArt(details,'poster','w500'); const played = (data.playedEpisodes || []).includes(Number(episode.number)); const matchingProgress = (live.continueItems || []).find(entry => Number(entry.ParentIndexNumber) === Number(data.seasonNumber) && Number(entry.IndexNumber) === Number(episode.number) && String(entry.SeriesName || '') === String(yjTitle(details))); const progress = matchingProgress ? Math.min(100, Math.round((matchingProgress.UserData?.PlaybackPositionTicks || 0) / Math.max(matchingProgress.RunTimeTicks || 1, 1) * 100)) : played ? 100 : 0; const aired=episode.air_date ? new Intl.DateTimeFormat('zh-CN',{year:'numeric',month:'long',day:'numeric'}).format(new Date(`${episode.air_date}T12:00:00`)) : '播出日期待定'; return `<button class="yj-episode ${Number(episode.number) === Number(data.selectedEpisode) ? 'is-active' : ''} ${played ? 'is-played' : ''}" data-select-episode="${episode.number}"><span class="yj-episode-art ${hasStill ? '' : 'is-poster-fallback'}" ${still ? `style="background-image:url('${still}')"` : ''}><i>第 ${episode.number} 集</i>${progress ? `<em class="yj-episode-progress" style="--yj-episode-progress:${progress}%"><span></span></em>` : ''}${played ? `<em class="yj-played-badge" title="已播放">${ico('check')}<span>已播放</span></em>` : ''}</span><span><b>第 ${episode.number} 集</b><small>${esc(episode.name || '未命名剧集')}</small><time datetime="${esc(episode.air_date || '')}">${esc(aired)}</time></span></button>`; }).join('');
  const resourceCards = resources.map((source,index) => { const filename = source.Name || source.Path?.split(/[\\/]/).at(-1) || '媒体文件'; const direct = source.SupportsDirectPlay !== false; return `<button class="yj-resource ${index === data.selectedResource ? 'is-active' : ''}" data-select-resource="${index}" aria-label="选择 ${esc(source.server?.name || '媒体服务器')} 的 ${esc(sourceVersion(source))} 版本"><span class="yj-resource-server"><i>${esc((source.server?.name || '源')[0])}</i><span><b>${esc(source.server?.name || '媒体服务器')}</b><small>${esc(source.server?.kind || 'Emby')} · ${esc(filename)}</small></span></span><span><b>${esc(sourceVersion(source))}</b><small>${esc(sourceSize(source))} · ${esc(sourceBitrate(source))}</small></span><span><b>${esc(sourceRange(source))}</b><small>${esc(sourceAudioLabel(source))}</small></span><em>${index === data.selectedResource ? '已选择' : direct ? '可直连' : '需转码'}</em></button>`; }).join('');
  app.innerHTML = yjShell(`<main class="yj-detail" style="--detail-art:url('${yjArt(details,'backdrop','original')}')"><button class="yj-back" data-yj-back>${ico('chevron')} 返回</button><section class="yj-detail-hero"><div class="yj-detail-copy"><span class="yj-eyebrow">${itemKind(item) === 'movie' ? 'FILM' : 'SERIES'}</span><h1>${esc(yjTitle(details))}</h1><div class="yj-feature-meta"><b>${esc(yjYear(details) || '年份未知')}</b><span>TMDB ${(details.vote_average || 0).toFixed(1)}</span><span>${episodes.length ? `${episodes.length} 集` : '电影'}</span></div><p>${esc(details.overview || '暂无剧情简介。')}</p><div class="yj-actions">${resources.length ? `<button class="primary" data-detail-play>${ico('play')} 播放所选版本${selected && !selected.movie ? ` · 第 ${selected.number} 集` : ''}</button>` : `<button class="primary" data-go="library">${ico('plus')} 连接播放来源</button>`}${inWatchlist ? `<button class="secondary" data-calendar-remove="${item.id}">${ico('close')} 移出日历</button>` : `<button class="secondary" data-live-watch="${item.id}">${ico('watch')} 加入待看</button>`}</div></div></section><section class="yj-detail-body">${episodes.length ? `<header class="yj-section-head yj-episode-head"><div><button data-episode-sort>${data.episodeSort === 'asc' ? '正序 ↑' : '倒序 ↓'}</button><button data-toggle-all-episodes>${data.showAllEpisodes ? '收起' : `查看全部 ${episodes.length} 集`} ${ico('chevron')}</button></div></header><div class="yj-episode-rail ${data.showAllEpisodes ? 'is-all' : ''}">${episodeCards}</div>${data.showAllEpisodes && episodePages > 1 ? `<nav class="yj-episode-pages"><button data-episode-page="${Math.max(0,data.episodePage-1)}" ${data.episodePage === 0 ? 'disabled' : ''}>上一页</button><span>第 ${data.episodePage + 1} / ${episodePages} 页 · ${data.episodePage * episodePageSize + 1}–${Math.min(episodes.length,(data.episodePage+1)*episodePageSize)} 集</span><button data-episode-page="${Math.min(episodePages-1,data.episodePage+1)}" ${data.episodePage === episodePages-1 ? 'disabled' : ''}>下一页</button></nav>` : ''}` : ''}<section class="yj-resource-zone"><header class="yj-section-head"><div><span>SOURCES</span><h2>播放版本</h2></div><small>${resources.length} 个匹配资源</small></header>${qualities.length ? `<div class="yj-resource-filters">${qualities.map(label => `<button class="${data.selectedResolution === label ? 'is-active' : ''}" data-resolution="${label}">${label}</button>`).join('')}</div>` : ''}${resourceCards ? `<div class="yj-resource-list">${resourceCards}</div>` : yjEmpty('当前分辨率没有资源', qualities.length ? '切换其他分辨率查看可播放线路。' : '扫描资料库后显示真实可用版本。', '<button class="primary" data-go="library">连接服务器</button>')}</section><section class="yj-credits"><header class="yj-section-head"><div><span>CAST & CREW</span><h2>演职人员</h2></div></header>${cast.length ? `<div class="yj-cast-rail">${cast.map(person => `<article><span ${person.profile_path ? `style="background-image:url('${image(person.profile_path,'w342')}')"` : ''}></span><b>${esc(person.name)}</b><small>${esc(person.character || person.known_for_department || '')}</small></article>`).join('')}</div>` : yjEmpty('暂无演职人员资料','TMDB 没有返回相关信息。')}</section><section class="yj-media-extras"><header class="yj-section-head"><div><span>EXTRAS</span><h2>预告片与海报</h2></div></header><div>${trailer ? `<a class="yj-trailer" href="https://www.youtube.com/watch?v=${encodeURIComponent(trailer.key)}" target="_blank" rel="noreferrer"><span style="background-image:url('https://img.youtube.com/vi/${trailer.key}/hqdefault.jpg')">${ico('play')}</span><b>${esc(trailer.name || '官方预告片')}</b></a>` : yjEmpty('暂无预告片','TMDB 没有返回官方预告。')}${posters.length ? `<div class="yj-poster-gallery">${posters.map(poster => `<img src="${image(poster.file_path,'w342')}" alt="${esc(yjTitle(details))} 海报">`).join('')}</div>` : ''}</div></section></section></main>`, 'home', { title: yjTitle(item), hideSearch: true });
  const episodeHead = document.querySelector('.yj-episode-head');
  if (episodeHead) {
    const controls = episodeHead.firstElementChild; controls?.classList.add('yj-episode-controls');
    if (seasons.length > 1) {
      const seasonTabs = document.createElement('nav'); seasonTabs.className = 'yj-season-tabs'; seasonTabs.setAttribute('aria-label','选择季度');
      seasonTabs.innerHTML = seasons.map(season => `<button class="${Number(season.season_number) === Number(data.seasonNumber) ? 'is-active' : ''}" data-select-season="${season.season_number}">第 ${season.season_number} 季</button>`).join('');
      episodeHead.replaceChildren(seasonTabs, controls);
    } else {
      episodeHead.replaceChildren(controls);
    }
  }
  const episodeRail = document.querySelector('.yj-detail .yj-episode-rail');
  if (episodeRail) {
    const viewport = document.createElement('div');
    viewport.className = 'yj-shelf-viewport yj-episode-viewport';
    viewport.innerHTML = `<button class="yj-shelf-arrow is-prev" data-shelf-scroll="-1" aria-label="向左浏览剧集">${ico('chevron')}</button><button class="yj-shelf-arrow is-next" data-shelf-scroll="1" aria-label="向右浏览剧集">${ico('chevron')}</button>`;
    episodeRail.parentElement.insertBefore(viewport, episodeRail);
    episodeRail.dataset.shelfRail = '';
    viewport.insertBefore(episodeRail, viewport.querySelector('.is-next'));
  }
  const resourceZone = document.querySelector('.yj-resource-zone');
  if (resourceZone && resources.length) {
    const grouped = new Map();
    resources.forEach((source, index) => {
      const key = String(source.server?.id || source.server?.url || source.server?.name || index);
      const group = grouped.get(key) || { name:source.server?.name || '媒体服务器', kind:source.server?.kind || 'Emby', choices:[] };
      group.choices.push({ source, index }); grouped.set(key, group);
    });
    const serverGroups = [...grouped.values()];
    const header = resourceZone.querySelector('.yj-section-head');
    header?.querySelector('small')?.replaceWith(Object.assign(document.createElement('div'), { className:'yj-resource-summary', innerHTML:`<b>${esc(data.selectedResolution || '自动')}</b><small>${resources.length} 个匹配资源</small>` }));
    resourceZone.querySelector('.yj-resource-filters')?.insertAdjacentHTML('afterend', `<div class="yj-resource-viewbar"><span>匹配结果</span><div role="group" aria-label="播放版本展示方式"><button class="${data.resourceView === 'resource' ? 'is-active' : ''}" data-resource-view="resource">按资源</button><button class="${data.resourceView === 'server' ? 'is-active' : ''}" data-resource-view="server">按服务器</button></div></div>`);
    const list = resourceZone.querySelector('.yj-resource-list');
    if (list && data.resourceView === 'server') {
      list.classList.add('is-server-view');
      list.innerHTML = serverGroups.map((group, groupIndex) => {
        const chosen = group.choices.find(choice => choice.index === data.selectedResource)?.source || group.choices[0].source;
        return `<button class="yj-resource-server-card ${group.choices.some(choice => choice.index === data.selectedResource) ? 'is-active' : ''}" data-open-server-versions="${groupIndex}" aria-label="查看 ${esc(group.name)} 的 ${group.choices.length} 个版本"><i>${esc(group.name[0])}</i><span><b>${esc(group.name)}</b><small>${esc(group.kind)} · ${group.choices.length} 个 ${esc(data.selectedResolution || '')} 版本</small></span><span><b>${esc(sourceVersion(chosen))}</b><small>${esc(sourceRange(chosen))} · ${esc(sourceAudioLabel(chosen))}</small></span><em>选择版本 ${ico('chevron')}</em></button>`;
      }).join('');
    }
    const pickerIndex = data.resourceServerPicker === null || data.resourceServerPicker === undefined || data.resourceServerPicker === '' ? Number.NaN : Number(data.resourceServerPicker);
    if (Number.isInteger(pickerIndex) && serverGroups[pickerIndex]) {
      const group = serverGroups[pickerIndex];
      const versions = group.choices.map(({source,index}) => `<button class="yj-version-choice ${index === data.selectedResource ? 'is-active' : ''}" data-select-resource="${index}"><span><b>${esc(sourceVersion(source))}</b><small>${esc(sourceSize(source))} · ${esc(sourceBitrate(source))}</small></span><span><b>${esc(sourceRange(source))}</b><small>${esc(sourceAudioLabel(source))}</small></span>${index === data.selectedResource ? `<em>已选择</em>` : ''}</button>`).join('');
      resourceZone.insertAdjacentHTML('beforeend', `<section class="yj-version-sheet" role="dialog" aria-modal="true" aria-label="${esc(group.name)} 的播放版本"><header><div><h3>${esc(group.name)}</h3><p>${group.choices.length} 个 ${esc(data.selectedResolution || '')} 匹配版本</p></div><button data-close-server-versions aria-label="关闭版本选择">${ico('close')}</button></header><div class="yj-version-choices">${versions}</div></section>`);
    }
  }
  yjApplyPosterTheme(details, '.yj-detail');
};

const yjLoadDetailSeason = async seasonNumber => {
  const data = live.detail;
  if (!data || data.kind !== 'tv' || Number(data.seasonNumber) === Number(seasonNumber)) return;
  data.seasonLoading = true; renderLiveDetail();
  try {
    const season = await tmdbRequest(`/tv/${data.tmdbId}/season/${seasonNumber}?language=zh-CN`);
    if (live.detail !== data) return;
    data.seasonNumber = Number(seasonNumber);
    data.episodes = (season.episodes || []).map(episode => ({ ...episode, season:Number(seasonNumber), number:episode.episode_number }));
    data.selectedEpisode = data.episodes[0]?.number || 1;
    data.playedEpisodes = [];
    data.resources = []; data.selectedResolution = ''; data.selectedResource = 0;
    renderLiveDetail(); loadDetailResources(data);
  } catch (error) { data.seasonLoading = false; renderLiveDetail(); notify(`加载第 ${seasonNumber} 季失败：${error.message || '请检查网络'}`); }
};

showPlayerHandoff = function yjPlayerHandoff(title) {
  app.innerHTML = yjShell(`<main class="yj-page yj-handoff"><span class="yj-handoff-icon">${ico('play')}</span><span class="yj-eyebrow">NOW PLAYING IN MPV</span><h1>${esc(title)}</h1><p>mpv 已接管高品质播放。关闭播放器后可以返回资料库继续选择内容。</p><button class="primary" data-go="library">返回资料库</button></main>`, 'library', { title: '正在播放' });
};

syncTraktCalendar = async function yjSyncCalendar() {
  const target = document.querySelector('[data-trakt-calendar]');
  try {
    const [clientId, token, tmdbKey] = await Promise.all([window.yingjiDesktop.getSecret('trakt-client-id'), window.yingjiDesktop.getSecret('trakt-access-token'), window.yingjiDesktop.getSecret('tmdb-key')]);
    if (!token) throw new Error('请先授权 Trakt 账户');
    const start = new Date(); start.setDate(start.getDate() - 2);
    const events = await request(`https://api.trakt.tv/calendars/my/shows/${start.toISOString().slice(0,10)}/10?extended=full`, { headers: { Authorization:`Bearer ${token}`, 'trakt-api-version':'2', 'trakt-api-key':clientId } });
    const posters = {};
    await Promise.all(events.map(async event => { const id = event.show?.ids?.tmdb; if (!id) return; try { posters[id] = (await tmdbRequest(`/tv/${id}`, tmdbKey)).poster_path; } catch {} }));
    live.calendarEvents = events.filter(event => !live.suppressedCalendar.includes(String(event.show?.ids?.tmdb))); live.calendarPosters = posters; calendar();
  } catch (error) { target.innerHTML = yjEmpty('同步失败', esc(error.message || '请检查网络后重试。'), '<button class="primary" data-sync-calendar>重试</button>'); }
};

document.body.classList.add('yj-ui');
document.addEventListener('click', event => {
  const edit = event.target.closest('[data-edit-server],[data-edit-file]');
  if (!edit) return;
  event.preventDefault();
  event.stopImmediatePropagation();
  live.editingServerId = edit.dataset.editServer || null;
  live.editingFileId = edit.dataset.editFile || null;
  live.addingServer = true;
  live.preserveLibraryScroll = window.scrollY;
  library();
}, true);
document.addEventListener('click', event => {
  const continueTarget = event.target.closest('.yj-continue-copy,.yj-continue-art');
  if (continueTarget && !event.target.closest('[data-continue-play]')) {
    event.preventDefault();
    event.stopImmediatePropagation();
    const item = live.continueItems.find(entry => String(entry.Id || entry.id) === String(continueTarget.dataset.liveDetail));
    showLiveDetail(item || continueTarget.dataset.liveDetail, continueTarget.dataset.kind);
    return;
  }
  const rowTitle = event.target.closest('.yj-continue-row b');
  if (!rowTitle) return;
  const item = live.continueItems.find(entry => String(entry.Id) === String(rowTitle.closest('.yj-continue-row')?.dataset.continueId));
  if (!item) return;
  event.preventDefault();
  event.stopImmediatePropagation();
  showLiveDetail(item.Id, item.Type === 'Movie' ? 'movie' : 'tv');
}, true);
document.addEventListener('click', event => {
  if (event.target.closest('[data-live-detail]')) requestAnimationFrame(() => window.scrollTo({ top: 0, behavior: 'instant' }));
  if (event.target.closest('[data-episode-sort]') && live.detail) { live.detail.episodeSort = live.detail.episodeSort === 'asc' ? 'desc' : 'asc'; renderLiveDetail(); }
  const season = event.target.closest('[data-select-season]');
  if (season) { yjLoadDetailSeason(Number(season.dataset.selectSeason)); return; }
  if (event.target.closest('[data-toggle-all-episodes]') && live.detail) { live.detail.showAllEpisodes = !live.detail.showAllEpisodes; live.detail.episodePage = 0; renderLiveDetail(); requestAnimationFrame(() => document.querySelector('.yj-episode-head')?.scrollIntoView({ block:'start' })); }
  const episodePage = event.target.closest('[data-episode-page]');
  if (episodePage && live.detail) { live.detail.episodePage = Number(episodePage.dataset.episodePage); renderLiveDetail(); requestAnimationFrame(() => document.querySelector('.yj-episode-head')?.scrollIntoView({ block:'start' })); }
  const source = event.target.closest('[data-library-source]');
  if (source) { yjRememberRoute(); live.openSourceId = source.dataset.librarySource; live.selectedSourceId = source.dataset.librarySource; state.view = 'library'; library(); yjLoadSourceContent(source.dataset.librarySource); window.scrollTo(0,0); return; }
  const openSource = event.target.closest('[data-open-source]');
  if (openSource) { yjRememberRoute(); live.openSourceId = openSource.dataset.openSource; live.selectedSourceId = openSource.dataset.openSource; state.view = 'library'; library(); yjLoadSourceContent(openSource.dataset.openSource); window.scrollTo(0,0); return; }
  if (event.target.closest('[data-library-home]')) { live.openSourceId = null; state.view = 'library'; library(); }
  if (event.target.closest('[data-reload-source]')) yjLoadSourceContent(live.openSourceId);
  const serverMedia = event.target.closest('[data-server-media]');
  if (serverMedia) { const item = live.serverItems?.[live.openSourceId]?.[Number(serverMedia.dataset.serverMedia)]; if (item) showLiveDetail(item, item.Type === 'Movie' ? 'movie' : 'tv'); }
  const rankingScroll = event.target.closest('[data-scroll-ranking]');
  if (rankingScroll) document.querySelector('.yj-ranking-rail')?.scrollBy({ left: Number(rankingScroll.dataset.scrollRanking) * Math.max(320, window.innerWidth * .72), behavior:'smooth' });
  const shelfScroll = event.target.closest('[data-shelf-scroll]');
  if (shelfScroll) { const viewport=shelfScroll.closest('.yj-shelf-viewport'); const rail=viewport?.querySelector('[data-shelf-rail]'); viewport?.setAttribute('data-edge','none'); rail?.scrollBy({ left:Number(shelfScroll.dataset.shelfScroll) * Math.max(300, rail.clientWidth * .78), behavior:'smooth' }); }
});
document.addEventListener('pointermove', event => {
  const viewport = event.target.closest('.yj-shelf-viewport');
  const hero = event.target.closest('.yj-tv-hero');
  document.querySelectorAll('.yj-shelf-viewport[data-edge]:not(:hover)').forEach(node => node.dataset.edge = 'none');
  document.querySelectorAll('.yj-tv-hero[data-hero-edge]:not(:hover)').forEach(node => delete node.dataset.heroEdge);
  if (hero) {
    const rect = hero.getBoundingClientRect(), edge = Math.min(136, rect.width * .15);
    hero.dataset.heroEdge = event.clientX - rect.left < edge ? 'left' : rect.right - event.clientX < edge ? 'right' : 'none';
  }
  if (!viewport) return;
  const rect = viewport.getBoundingClientRect(), edge = Math.min(112, rect.width * .16);
  viewport.dataset.edge = event.clientX - rect.left < edge ? 'left' : rect.right - event.clientX < edge ? 'right' : 'none';
}, { passive:true });
document.addEventListener('pointerleave', event => {
  const viewport = event.target.closest?.('.yj-shelf-viewport');
  if (viewport) viewport.dataset.edge = 'none';
  const hero = event.target.closest?.('.yj-tv-hero');
  if (hero) delete hero.dataset.heroEdge;
}, true);
document.addEventListener('contextmenu', event => {
  const card = event.target.closest('[data-server-card]');
  if (!card) return;
  event.preventDefault(); document.querySelector('[data-server-menu]')?.remove();
  const source = yjSources().find(item => String(item.id) === String(card.dataset.serverCard));
  if (!source) return;
  const lines = source.kind === 'WebDAV' ? '' : (source.addresses || [source.url]).map((address,index) => `<button data-context-line="${index}"><span>线路 ${index + 1}</span><small>${esc(new URL(address).host)}</small>${index === source.activeAddress ? '<em>当前</em>' : ''}</button>`).join('');
  document.body.insertAdjacentHTML('beforeend', `<menu class="yj-server-menu" data-server-menu data-server-id="${esc(source.id)}" style="--menu-x:${event.clientX}px;--menu-y:${event.clientY}px"><button data-context-edit>${ico('settings')} 编辑此服务器</button><button data-context-refresh>${ico('refresh')} 重新连接并刷新</button><button data-context-icon>${ico('library')} 修改图标</button>${lines}</menu>`);
});
document.addEventListener('click', event => {
  const menu = event.target.closest('[data-server-menu]');
  if (!menu) { document.querySelector('[data-server-menu]')?.remove(); return; }
  const source = yjSources().find(item => String(item.id) === String(menu.dataset.serverId));
  if (event.target.closest('[data-context-edit]') && source) { live.editingServerId = source.kind === 'WebDAV' ? null : source.id; live.editingFileId = source.kind === 'WebDAV' ? source.id : null; live.addingServer=true; live.preserveLibraryScroll=window.scrollY; menu.remove(); library(); return; }
  if (event.target.closest('[data-context-refresh]') && source) { const button=event.target.closest('[data-context-refresh]'); button.disabled=true; button.textContent='正在重新连接…'; refreshSource(source.id).then(() => { menu.remove(); notify(`${source.name} 已重新连接并更新信息`); }).catch(error => { button.disabled=false; notify(`刷新失败：${error.message}`); }); return; }
  const line = event.target.closest('[data-context-line]');
  if (line && source) { source.activeAddress = Number(line.dataset.contextLine); source.url = source.addresses[source.activeAddress]; saveProviders(); menu.remove(); library(); notify(`已切换到线路 ${source.activeAddress + 1}`); return; }
  if (event.target.closest('[data-context-icon]') && source) { const input=document.createElement('input'); input.type='file'; input.accept='image/png,image/jpeg,image/webp'; input.onchange=()=>{const file=input.files?.[0]; if(!file || file.size>2*1024*1024) return notify('请选择小于 2 MB 的图片'); const reader=new FileReader(); reader.onload=()=>{source.customIcon=reader.result;saveProviders();menu.remove();library();notify('服务器图标已更新');};reader.readAsDataURL(file);};input.click(); }
}, true);
const yjNormalizeBackButtons = () => document.querySelectorAll('button[data-go],button[data-library-home]').forEach(button => {
  if (!/^返回/.test(button.textContent.trim())) return;
  button.removeAttribute('data-go');
  button.removeAttribute('data-library-home');
  button.dataset.yjBack = '';
  button.setAttribute('aria-label', '返回');
  button.innerHTML = `${ico('chevron')} 返回`;
});
new MutationObserver(yjNormalizeBackButtons).observe(app, { childList:true, subtree:true });
render();
