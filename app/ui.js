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
  const base = item?.server?.url?.replace(/\/+$/, ''), token = item?.token;
  if (!base || !token) return [];
  const imageUrl = (id, kind) => `${base}/Items/${encodeURIComponent(id)}/Images/${kind}?maxWidth=${width}&quality=88&api_key=${encodeURIComponent(token)}`;
  const candidates = [];
  const add = (id, kind) => { if (id && !candidates.includes(`${id}:${kind}`)) candidates.push(`${id}:${kind}`); };
  // Episodes commonly have no Primary image of their own. Try the episode's
  // still/thumb first, then inherit artwork from its series/parent item.
  add(item.Id, 'Primary'); add(item.Id, 'Thumb'); add(item.Id, 'Backdrop');
  add(item.SeriesId, 'Backdrop'); add(item.SeriesId, 'Primary');
  add(item.ParentId, 'Backdrop'); add(item.ParentId, 'Primary');
  return candidates.slice(0, 7).map(value => { const [id, kind] = value.split(':'); return imageUrl(id, kind); });
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
let yjRankingLoadObserver;
const yjObserveRankingLoad = () => {
  yjRankingLoadObserver?.disconnect();
  const sentinel = document.querySelector('[data-ranking-load-sentinel]');
  if (!sentinel || !('IntersectionObserver' in window)) return;
  yjRankingLoadObserver = new IntersectionObserver(entries => {
    if (!entries.some(entry => entry.isIntersecting)) return;
    yjRankingLoadObserver?.disconnect();
    loadMoreRanking(Number(sentinel.dataset.rankingIndex));
  }, { rootMargin:'420px 0px' });
  yjRankingLoadObserver.observe(sentinel);
};
const yjApplyPosterTheme = (item, selector = '.yj-home') => {
  const url = yjArt(item, 'poster', 'w185');
  if (!url) return;
  document.querySelector('#app')?.style.setProperty('--yj-page-art', `url('${url}')`);
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
  const nav = yjNav.map(([route, icon, label]) => `<button class="yj-nav-item ${active === route ? 'is-active' : ''}" data-go="${route}" aria-current="${active === route ? 'page' : 'false'}" aria-label="${label}" data-tooltip="${label}">${ico(icon)}<span>${label}</span></button>`).join('');
  const sourceDock = sources.length ? `<section class="yj-source-dock" aria-label="已添加媒体来源">${sources.slice(0, 3).map(source => { const status=live.sourceStats[source.id]?.state || 'pending'; const name=esc(source.name || '媒体来源'); return `<button data-open-source="${esc(source.id)}" aria-label="${name}" data-tooltip="${name}"><i class="yj-dock-logo" ${source.customIcon || live.sourceIcons[source.id] ? `style="background-image:url('${esc(source.customIcon || live.sourceIcons[source.id])}')"` : ''}>${source.customIcon || live.sourceIcons[source.id] ? '' : esc((source.name || '源')[0])}</i><span><b>${name}</b><small>${esc(source.kind || 'Emby')} · ${status === 'connected' ? '已连接' : status === 'error' ? '连接异常' : '等待连接'}</small></span><em class="is-${status}" aria-label="${status === 'connected' ? '已连接' : status === 'error' ? '连接异常' : '等待连接'}"></em></button>`; }).join('')}</section>` : '';
  return `<header class="yj-titlebar" aria-label="窗口控制"><div class="win"><span>—</span><span>□</span><span>×</span></div></header>
    <aside class="yj-sidebar"><nav class="yj-nav" aria-label="主导航">${nav}</nav>${sourceDock}</aside>
    <div class="network-status">当前离线，保留本机内容与配置。</div>${content}`;
};
const yjEmpty = (title, text, action = '') => `<section class="yj-empty"><span>${ico('library')}</span><h2>${title}</h2><p>${text}</p>${action}</section>`;
const yjPoster = (item, index = 0) => {
  const epBadge = (item.season != null && item.number != null) ? `S${item.season}E${String(item.number).padStart(2,'0')}` : (item.kind === 'tv' && item.episode_count ? `全${item.episode_count}集` : '');
  return `<button class="yj-poster-card" data-live-detail="${item.id}" data-kind="${item.kind || itemKind(item)}"><span class="yj-poster" ${yjArt(item, 'poster', 'w500') ? `style="background-image:url('${yjArt(item, 'poster', 'w500')}')"` : ''}>${epBadge ? `<em class="yj-poster-badge">${epBadge}</em>` : ''}</span><span><b>${esc(yjTitle(item))}</b><small>${esc(yjYear(item) || '年份未知')} · TMDB ${(item.vote_average || 0).toFixed(1)}</small></span></button>`;
};
// Rank has its own hierarchy: the order is content, while each card remains
// one accessible route into the same real detail data used elsewhere.
const yjRankingCard = (item, position, meta = {}, variant = 'rail', showRank = true) => {
  const kind = item.kind || itemKind(item), art = yjArt(item, 'poster', 'w500');
  const source = meta.source === 'Trakt' ? 'Trakt 热度' : `TMDB ${(item.vote_average || 0).toFixed(1)}`;
  const type = kind === 'movie' ? '电影' : '剧集';
  return `<button class="yj-atv-rank-card yj-atv-rank-card--${variant}" data-live-detail="${esc(item.id)}" data-kind="${kind}" aria-label="${showRank ? `第 ${position} 名，` : ''}${esc(yjTitle(item))}"><span class="yj-atv-rank-art" ${art ? `style="background-image:url('${art}')"` : ''}>${showRank ? `<i class="yj-atv-rank-no">${String(position).padStart(2, '0')}</i>` : ''}<span class="yj-atv-rank-sheen" aria-hidden="true"></span></span><span class="yj-atv-rank-copy"><b>${esc(yjTitle(item))}</b><small>${esc(yjYear(item) || type)} · ${esc(source)}</small></span></button>`;
};
const yjOrderRankings = groups => {
  const saved = readLocalJson('yingji.shelf-order', []);
  const position = new Map(saved.map((name, index) => [name, index]));
  return [...groups].sort((left, right) => {
    const leftPosition = position.has(left[0]) ? position.get(left[0]) : Number.MAX_SAFE_INTEGER;
    const rightPosition = position.has(right[0]) ? position.get(right[0]) : Number.MAX_SAFE_INTEGER;
    return leftPosition - rightPosition || groups.indexOf(left) - groups.indexOf(right);
  });
};
const yjAllRankings = () => yjOrderRankings((live.rankings || []).reduce((rows, group, index) => {
  if (group?.[1]?.length && !['IMDb', '豆瓣'].includes(group[2]?.source)) rows.push([...group, index]);
  return rows;
}, []));
const yjApplyShelfOrder = order => {
  const home = document.querySelector('.yj-tv-home-content');
  if (home) order.forEach(name => {
    const row = [...home.querySelectorAll('.yj-atv-rank-row')].find(node => node.dataset.shelfName === name);
    if (row) home.appendChild(row);
  });
  const options = document.querySelector('.yj-atv-rank-options');
  if (options) order.forEach(name => {
    const option = [...options.querySelectorAll('[data-shelf-option]')].find(node => node.dataset.shelfOption === name);
    if (option) options.appendChild(option);
  });
};
const yjCommitShelfOrder = visibleOrder => {
  const current = yjAllRankings().map(group => group[0]);
  const visible = new Set(visibleOrder);
  let position = 0;
  const order = current.map(name => visible.has(name) ? visibleOrder[position++] : name);
  localStorage.setItem('yingji.shelf-order', JSON.stringify(order));
  if (!live.shelfPanelOpen) yjApplyShelfOrder(order);
  return order;
};
const yjWideCard = (item, label = '') => `<button class="yj-wide-card" data-live-detail="${item.id}" data-kind="${item.kind || itemKind(item)}"><span class="yj-wide-art" ${yjArt(item) ? `style="background-image:url('${yjArt(item)}')"` : ''}>${label ? `<em>${esc(label)}</em>` : ''}</span><span><b>${esc(yjTitle(item))}</b><small>${esc(yjYear(item) || (itemKind(item) === 'movie' ? '电影' : '剧集'))}</small></span></button>`;
const heroMarkup = (feature, featureKind, heroes, heroIndex) => `<section class="yj-feature yj-tv-hero" style="--yj-hero-art:url('${yjArt(feature, 'backdrop', 'original')}')"><button class="yj-hero-arrow is-prev" data-hero-prev aria-label="上一部作品">${ico('chevron')}</button><div class="yj-feature-copy"><h1>${esc(yjTitle(feature))}</h1><div class="yj-feature-meta"><b>${esc(yjYear(feature) || '最新')}</b><span>${featureKind === 'movie' ? '电影' : '剧集'}</span><span>TMDB ${(feature.vote_average || 0).toFixed(1)}</span></div><p>${esc(feature.overview || '查看作品资料并匹配你的私人媒体来源。')}</p></div><button class="yj-hero-arrow is-next" data-hero-next aria-label="下一部作品">${ico('chevron')}</button><div class="yj-feature-switch">${heroes.map((_, index) => `<button class="${index === heroIndex ? 'is-active' : ''}" data-hero-dot="${index}" aria-label="第 ${index + 1} 项"></button>`).join('')}</div></section>`;

let yjHeroRotationTimer;
const yjStartHeroRotation = heroCount => {
  clearInterval(yjHeroRotationTimer);
  yjHeroRotationTimer = null;
  if (heroCount < 2 || window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) return;
  yjHeroRotationTimer = setInterval(() => {
    if (state.view !== 'home' || !document.querySelector('.yj-home .yj-hero-wrap')) {
      clearInterval(yjHeroRotationTimer);
      yjHeroRotationTimer = null;
      return;
    }
    live.heroIndex += 1;
    if (typeof updateHero === 'function') updateHero();
  }, 7000);
};

const yjRankingsForHome = groups => {
  const toggles = readLocalJson('yingji.shelf-toggles', {});
  return yjOrderRankings(groups).map((group, index) => {
    const [name, items, meta = {}, sourceIndex = index] = group;
    const enabled = Object.hasOwn(toggles, name) ? toggles[name] : meta.featured !== false;
    const preview = (items || []).slice(0, 10);
    return preview.length ? { index: sourceIndex, name, items: preview, meta, enabled } : null;
  }).filter(Boolean);
};

// The settings sheet controls homepage placement only. It never claims a
// scraped provider, and each grouping remains traceable to its real source.
renderShelfPanel = function yjRankingShelfPanel() {
  let root = document.getElementById('yj-shelf-panel-root');
  if (!live.shelfPanelOpen) { root?.remove(); return; }
  const groups = yjAllRankings();
  const toggles = readLocalJson('yingji.shelf-toggles', {});
  const filters = ['all', '热度', '地区', '类型', '平台', '档期', '口碑', 'Trakt'];
  const activeFilter = filters.includes(live.shelfFilter) ? live.shelfFilter : 'all';
  const enabled = ([name, , meta = {}]) => Object.hasOwn(toggles, name) ? toggles[name] : meta.featured !== false;
  const shown = groups.filter(([, , meta = {}]) => activeFilter === 'all' || meta.family === activeFilter || meta.source === activeFilter).sort((left, right) => Number(enabled(right)) - Number(enabled(left)));
  if (!root) { root = document.createElement('div'); root.id = 'yj-shelf-panel-root'; document.body.appendChild(root); }
  root.innerHTML = `<section class="yj-atv-rank-sheet-backdrop" data-shelf-panel-close><section class="yj-atv-rank-sheet" role="dialog" aria-modal="true" aria-label="定制首页榜单"><header><div><h2>定制首页榜单</h2><p>选择要出现在首页的真实数据轨道；长按任一榜单后拖动即可排序。</p></div><button class="yj-panel-close" data-shelf-panel-close aria-label="关闭">${ico('close')}</button></header><nav class="yj-atv-rank-filter" aria-label="榜单分类">${filters.map(filter => `<button class="${activeFilter === filter ? 'on' : ''}" data-shelf-filter="${filter}">${filter === 'all' ? `全部 ${groups.length}` : `${filter} ${groups.filter(([, , meta = {}]) => meta.family === filter || meta.source === filter).length}`}</button>`).join('')}</nav><div class="yj-atv-rank-options">${shown.map(([name, , meta = {}]) => { const checked = Object.hasOwn(toggles, name) ? toggles[name] : meta.featured !== false; return `<article data-shelf-option="${esc(name)}" class="${checked ? 'is-enabled' : ''}" tabindex="0" aria-label="${esc(name)}，长按后拖动排序"><span class="yj-atv-rank-drag-mark" aria-hidden="true"><svg viewBox="0 0 12 18"><circle cx="3" cy="3" r="1.25"/><circle cx="9" cy="3" r="1.25"/><circle cx="3" cy="9" r="1.25"/><circle cx="9" cy="9" r="1.25"/><circle cx="3" cy="15" r="1.25"/><circle cx="9" cy="15" r="1.25"/></svg></span><span><b>${esc(name)}</b><small>${esc(meta.source || 'TMDB')} · ${esc(meta.summary || '实时影视榜单')}</small></span><div class="yj-atv-rank-option-actions"><button type="button" class="yj-atv-rank-toggle" role="switch" aria-checked="${checked}" data-shelf-toggle="${esc(name)}"><i></i><em>${checked ? '显示' : '隐藏'}</em></button></div></article>`; }).join('')}</div></section></section>`;
};

home = function yjHome() {
  const sameView = !!document.querySelector('.yj-home');
  if (!live.rankings?.length) live.rankings = readLocalJson('yingji.discovery-cache', null) || [];
  const groups = yjAllRankings();
  const visibleShelves = yjRankingsForHome(groups);
  const enabledShelves = visibleShelves.filter(shelf => shelf.enabled);
  const items = groups.flatMap(group => group[1]);
  if (!items.length) {
    yjStartHeroRotation(0);
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
  const homeArt = yjArt(feature, 'backdrop', 'original') || yjArt(feature, 'poster', 'original');
  app.innerHTML = yjShell(`<main class="yj-home ${sameView ? 'yj-no-anim' : ''}" ${homeArt ? `style="--home-art:url('${homeArt}')"` : ''}><div class="yj-hero-wrap">${heroMarkup(feature, featureKind, heroes, live.heroIndex)}</div>
    <section class="yj-home-content yj-tv-home-content">${continueItems.length ? `<section class="yj-home-shelf yj-home-continue"><header class="yj-section-head"><h2>继续观看</h2><button data-open-shelf="continue">查看全部 ${ico('chevron')}</button></header><div class="yj-shelf-viewport yj-continue-viewport"><button class="yj-shelf-arrow is-prev" data-shelf-scroll="-1" aria-label="向左浏览继续观看">${ico('chevron')}</button><div class="yj-wide-rail" data-shelf-rail>${continueCards}</div><button class="yj-shelf-arrow is-next" data-shelf-scroll="1" aria-label="向右浏览继续观看">${ico('chevron')}</button></div></section>` : ''}
    <section class="yj-atv-rank-hub"><div><h2>影视榜单</h2><p>以真实热度、播出档期与口碑整理，随时回到正在发生的影视世界。</p></div><div class="yj-atv-rank-hub-actions"><span data-shelf-count>${enabledShelves.length} 个轨道</span><button class="yj-atv-rank-manage" data-shelf-panel>${ico('settings')} 定制</button></div></section>
    ${visibleShelves.map(({index, name, items: group, meta, enabled}, groupIndex) => `<section class="yj-atv-rank-row" data-shelf-name="${esc(name)}" ${enabled ? '' : 'hidden'} style="--yj-shelf-delay:${Math.min(220, groupIndex * 45)}ms"><header><div><h2>${esc(name)}</h2><p>${esc(meta?.summary || 'TMDB · 实时影视榜单')}</p></div><button class="yj-atv-rank-more" data-live-more="${index}">查看全部 ${ico('chevron')}</button></header><div class="yj-atv-rank-viewport"><button class="yj-rank-edge is-prev" data-rank-scroll="-1" aria-label="向左浏览 ${esc(name)}">${ico('chevron')}</button><div class="yj-atv-rank-scroll"><div class="yj-atv-rank-rail">${group.map((item, position) => yjRankingCard(item, position + 1, meta, 'rail', false)).join('')}</div></div><button class="yj-rank-edge is-next" data-rank-scroll="1" aria-label="向右浏览 ${esc(name)}">${ico('chevron')}</button></div></section>`).join('')}
    </section></main>`, 'home', { hideSearch:true });
  try { yjApplyPosterTheme(feature); yjWarmContinueArt(); renderShelfPanel(); } catch {}
  yjStartHeroRotation(heroes.length);
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

const yjMpvStyle = () => {
  if (document.getElementById('yj-mpv-style')) return;
  const style = document.createElement('style');
  style.id = 'yj-mpv-style';
  style.textContent = `
    .yj-setting-select { align-items:flex-start !important; }
    .yj-setting-select > span:last-of-type { flex:1 1 auto; }
    .yj-setting-select select { margin-left:auto; min-width:8.5rem; max-width:14rem; padding:.45rem .6rem; border-radius:.6rem; background:rgba(255,255,255,.07); color:inherit; border:1px solid rgba(255,255,255,.14); font:inherit; font-size:.82rem; }
    .yj-setting-select select:focus-visible { outline:2px solid #6ea8ff; outline-offset:1px; }
    body.light .yj-setting-select select { background:rgba(8,12,20,.06); border-color:rgba(8,12,20,.18); }
    .yj-setting-sub { font-size:.72rem; opacity:.55; margin:.1rem 0 .2rem; }
    .yj-media-info { display:flex; flex-wrap:wrap; gap:.5rem; justify-content:center; margin:1.1rem 0 1.5rem; }
    .yj-media-chip { display:inline-flex; flex-direction:column; align-items:flex-start; gap:.1rem; padding:.4rem .7rem; border-radius:.7rem; background:rgba(255,255,255,.06); border:1px solid rgba(255,255,255,.1); min-width:4.2rem; }
    .yj-media-chip b { font-size:.62rem; opacity:.58; font-weight:600; letter-spacing:.05em; text-transform:uppercase; }
    .yj-media-chip i { font-style:normal; font-size:.92rem; font-weight:650; }
    .yj-media-chip.yj-media-empty, .yj-media-chip.yj-media-ended { opacity:.6; font-size:.82rem; }
    body.light .yj-media-chip { background:rgba(8,12,20,.05); border-color:rgba(8,12,20,.12); }
  `;
  document.head.appendChild(style);
};
const selectControl = (key, label, hint, options) => `<article class="yj-setting-select"><span>${ico('chip')}</span><span><b>${esc(label)}</b><small>${esc(hint)}</small></span><select data-setting="${key}">${options.map(([value, text]) => `<option value="${esc(value)}" ${String(live.ui[key] ?? '') === String(value) ? 'selected' : ''}>${esc(text)}</option>`).join('')}</select></article>`;
const yjPixelDepth = format => {
  const f = String(format || '');
  if (/p12/.test(f)) return '12-bit';
  if (/p10/.test(f)) return '10-bit';
  if (/p16/.test(f)) return '16-bit';
  if (/p8|420p|422p|444p/.test(f)) return '8-bit';
  return '';
};
const yjHdrLabel = v => {
  if (!v) return '';
  if (v.dovi || v.hdr === 'dovi') return 'Dolby Vision';
  const gamma = v.gamma || '';
  if (v.hdr === 'smpte2084' || gamma === 'smpte2084') return 'HDR10';
  if (v.hdr === 'arib-std-b67' || gamma === 'arib-std-b67') return 'HLG';
  if (v.hdr && v.hdr !== 'no') return String(v.hdr).toUpperCase();
  if (v.primaries === 'bt.2020' && gamma === 'smpte2084') return 'HDR10';
  return '';
};
const yjRenderMediaInfo = info => {
  const host = document.querySelector('[data-mpv-info]');
  if (!host) return;
  // The console opens before any media info arrives, so info is null on the
  // first paint. Without this the `.video` read below throws and everything
  // after the call (mpv state snapshot, GPU adapters) silently never runs.
  if (!info) info = {};
  if (info?.ended) { host.innerHTML = '<span class="yj-media-chip yj-media-ended">播放已结束</span>'; return; }
  const v = info.video || {}, a = info.audio || {};
  const chips = [];
  const res = v.dw && v.dh ? `${v.dw}×${v.dh}` : (v.w && v.h ? `${v.w}×${v.h}` : null);
  if (res) chips.push(['分辨率', res]);
  if (v.codec) chips.push(['编码', String(v.codec).toUpperCase()]);
  const depth = yjPixelDepth(v.format);
  if (depth) chips.push(['位深', depth]);
  const fps = info.fps || v.fps;
  if (fps) chips.push(['帧率', `${Number(fps).toFixed(3).replace(/\.?0+$/, '')} fps`]);
  const hdr = yjHdrLabel(v);
  if (hdr) chips.push(['动态范围', hdr]);
  if (info.bitrate) chips.push(['码率', `${(info.bitrate / 1000).toFixed(0)} kbps`]);
  if (a.codec) chips.push(['音频编码', String(a.codec).toUpperCase()]);
  if (a.channels) chips.push(['声道', a.channels]);
  if (a.samplerate) chips.push(['采样率', `${(a.samplerate / 1000).toFixed(1)} kHz`]);
  host.innerHTML = chips.length
    ? chips.map(([k, val]) => `<span class="yj-media-chip"><b>${esc(k)}</b><i>${esc(val)}</i></span>`).join('')
    : '<span class="yj-media-chip yj-media-empty">正在读取媒体信息…</span>';
};

settingsV2 = function yjSettings() {
  const servers = providerConfig.emby || [];
  app.innerHTML = yjShell(`<main class="yj-page"><header class="yj-page-head"><span class="yj-eyebrow">PREFERENCES</span><h1>设置</h1><p>连接服务、播放器和本机隐私选项。</p></header><div class="yj-settings-layout"><nav class="yj-settings-nav"><button class="is-active">账户与服务</button><button>播放</button><button>字幕</button><button>网络与缓存</button><button>关于映迹</button></nav><section class="yj-settings-content"><section class="yj-setting-group"><header><h2>元数据与追剧</h2></header><article><span class="yj-service-badge">T</span><span><b>TMDB</b><small>中文资料、海报与搜索</small></span>${connectionBadge(!!metadataEndpoint || !!providerConfig.tmdb)}</article><form data-provider="tmdb"><input name="key" type="password" required placeholder="TMDB API Key（托管模式可选）"><button>保存并测试</button></form><article><span class="yj-service-badge">Tr</span><span><b>Trakt</b><small>观看记录与追剧日历</small></span>${connectionBadge(!!providerConfig.traktAuthorized)}</article><form data-provider="trakt"><input name="key" type="password" required placeholder="Trakt Client ID"><input name="secret" type="password" required placeholder="Trakt Client Secret"><button>保存凭据</button></form>${providerConfig.trakt ? `<button class="secondary" data-trakt-auth>${providerConfig.traktAuthorized ? '重新授权 Trakt' : '授权 Trakt 账户'}</button><div data-trakt-device></div>` : ''}</section><section class="yj-setting-group"><header><h2>播放器</h2><span>mpv</span></header><article><span>${ico('smart')}</span><span><b>硬件解码</b><small>D3D11 与 gpu-next</small></span>${toggleControl('hardware','硬件解码')}</article>${selectControl('hwdec', '硬解模式', '自动安全优先兼容，D3D11VA Copy 用于多显卡', [['auto-safe','自动安全'],['d3d11va','D3D11VA'],['d3d11va-copy','D3D11VA Copy'],['no','软解 (CPU)']])}${selectControl('renderer', '渲染器', 'gpu-next 支持 HDR 与色调映射', [['gpu-next','gpu-next'],['gpu','gpu']])}${selectControl('gpu', 'GPU 选择', '指定 D3D11 适配器，留空自动', [['','自动（系统默认）']])}<article><span>${ico('play')}</span><span><b>HDR 与 Dolby Vision</b><small>跟随显示器能力</small></span>${toggleControl('hdr','HDR 与 Dolby Vision')}</article><article><span>${ico('audio')}</span><span><b>立体声下混</b><small>多声道压缩为立体声</small></span>${toggleControl('downmix','立体声下混')}</article><article><span>${ico('audio')}</span><span><b>人声增强</b><small>提升对白清晰度</small></span>${toggleControl('vocal','人声增强')}</article><article><span>${ico('audio')}</span><span><b>夜间模式</b><small>压缩动态范围，避免忽大忽小</small></span>${toggleControl('night','夜间模式')}</article><article><span>${ico('library')}</span><span><b>已连接服务器</b><small>${servers.length} 个 Emby / Jellyfin 来源</small></span><button class="yj-inline" data-go="library">管理 ${ico('chevron')}</button></article></section></section></div></main>`, 'settings', { title: '设置' });
  yjMpvStyle();
  if (!prototypeMode && window.yingjiDesktop?.listAdapters) {
    window.yingjiDesktop.listAdapters().then(adapters => {
      const sel = document.querySelector('select[data-setting="gpu"]');
      if (!sel) return;
      const current = live.ui.gpu || '';
      sel.innerHTML = ['<option value="">自动（系统默认）</option>'].concat((adapters || []).map(name => `<option value="${esc(name)}" ${current === name ? 'selected' : ''}>${esc(name)}</option>`)).join('');
    }).catch(() => {});
  }
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

const yjSettingsWithMediaPreferences = settingsV2;
const yjDanmakuApiForm = (entry = {}, index = 0) => {
  const id = String(entry.id || `danmaku-${Date.now()}-${index}`);
  const name = String(entry.name || `弹幕 API ${index + 1}`);
  const tokenPlaceholder = entry.token ? '已保存，留空则不修改' : 'Bearer Token';
  return `<form class="yj-danmaku-api-form" data-danmaku-api data-danmaku-id="${esc(id)}"><label><b>名称（可选）</b><input name="name" value="${esc(name)}" placeholder="例如：主弹幕源"></label><label><b>API 地址</b><small>支持 {tmdbId}、{season}、{episode}、{title}、{name}、{url}。填写 danmu_api 部署根地址时会自动调用 /api/v2/fongmi/danmaku。</small><input name="urlTemplate" value="${esc(entry.urlTemplate || '')}" placeholder="http://127.0.0.1:9321/87654321"></label><label><b>API Token（可选）</b><input name="token" type="password" placeholder="${tokenPlaceholder}"></label><div class="yj-danmaku-api-actions"><button class="secondary" type="submit">保存弹幕 API</button>${entry.id ? '<button class="secondary" type="button" data-remove-danmaku>删除</button>' : ''}</div></form>`;
};
const yjChapterApiForm=(entry={},index=0)=>`<form class="yj-danmaku-api-form" data-chapter-api data-chapter-id="${esc(entry.id || `chapter-${Date.now()}-${index}`)}"><div class="yj-chapter-api-head"><b>${esc(entry.name || `片头片尾源 ${index+1}`)}</b><button class="switch ${entry.enabled === false ? 'off' : ''}" type="button" role="switch" aria-checked="${entry.enabled !== false}" aria-label="启用 ${esc(entry.name || `片头片尾源 ${index+1}`)}" data-chapter-enabled></button></div><label><b>来源名称</b><input name="name" value="${esc(entry.name || `片头片尾源 ${index+1}`)}"></label><label><b>HTTP 数据源</b><small>支持 {tmdbId}、{imdbId}、{tvdbId}、{seriesId}、{season}、{episode}、{title}；TheIntroDB/IntroDB 返回毫秒时间。</small><input name="urlTemplate" value="${esc(entry.urlTemplate || '')}" placeholder="https://api.theintrodb.org/v3/media?tmdb_id={tmdbid}&season={season}&episode={episode}"></label><label><b>Token（可选）</b><input name="token" type="password" placeholder="${entry.token?'已保存，留空不修改':'Bearer Token'}"></label><div class="yj-danmaku-api-actions"><button class="secondary" type="button" data-chapter-move="up">上移</button><button class="secondary" type="button" data-chapter-move="down">下移</button><button class="secondary" type="submit">保存来源</button><button class="secondary" type="button" data-remove-chapter-api>删除</button></div></form>`;
settingsV2 = function yjSettingsMediaPreferences() {
  yjSettingsWithMediaPreferences();
  const content = document.querySelector('.yj-settings-content');
  const nav = document.querySelector('.yj-settings-nav');
  if (!content || !nav) return;
  const servers = providerConfig.emby || [];
  content.insertAdjacentHTML('beforeend', `<section id="settings-subtitles" class="yj-setting-group"><header><h2>字幕</h2><span>播放器偏好</span></header><article><span>${ico('audio')}</span><span><b>显示字幕</b><small>播放时允许 mpv 自动载入和切换字幕</small></span>${toggleControl('subtitleEnabled','显示字幕')}</article>${selectControl('subtitleLanguage','优先语言','媒体含有多个字幕时优先选择', [['auto','自动'],['chi','简体中文'],['zho','中文'],['eng','English'],['jpn','日本語']])}${selectControl('subtitleScale','字幕大小','仅调整播放器字幕缩放', [['85','小'],['100','标准'],['115','大'],['130','特大']])}</section><section id="settings-danmaku" class="yj-setting-group"><header><h2>弹幕</h2><span>可配置多个来源</span></header><article><span>${ico('more')}</span><span><b>启用弹幕</b><small>播放时并行请求已保存的弹幕 API</small></span>${toggleControl('danmakuEnabled','启用弹幕')}</article>${selectControl('danmakuMode','显示模式','智能避让会将弹幕分布在画面上方；也可固定在顶部或底部', [['smart','智能避让'],['top','顶部优先'],['bottom','底部优先']])}${selectControl('danmakuDensity','显示密度','控制同一时刻最多显示的弹幕数量', [['low','稀疏'],['normal','标准'],['high','密集']])}${selectControl('danmakuFontScale','弹幕字号','只影响弹幕，不改变普通字幕大小', [['80','小'],['100','标准'],['120','大'],['140','特大']])}${selectControl('danmakuOpacity','弹幕不透明度','降低不透明度可减少对画面的干扰', [['60','轻'],['75','中'],['86','标准'],['100','清晰']])}${selectControl('danmakuDuration','弹幕停留时长','控制一条弹幕从右侧进入到离开画面的时间', [['3','快 · 3 秒'],['5','标准 · 5 秒'],['7','慢 · 7 秒'],['9','慢速 · 9 秒']])}</section><section id="settings-servers" class="yj-setting-group"><header><h2>服务器</h2><span>${servers.length} 个已添加来源</span></header>${servers.length ? servers.map(server => `<article><span>${ico('library')}</span><span><b>${esc(server.name || '媒体服务器')}</b><small>${esc(server.kind || 'Emby')} · ${server.aggregate === false ? '不参与详情页聚合' : '参与详情页聚合'}</small></span><button class="switch ${server.aggregate === false ? 'off' : ''}" type="button" role="switch" aria-checked="${server.aggregate !== false}" aria-label="${esc(server.name || '媒体服务器')} 聚合搜索" data-server-aggregate="${esc(server.id)}"></button></article>`).join('') : yjEmpty('尚未添加服务器','在资料库中连接 Emby、Jellyfin 或 WebDAV。','<button class="primary" data-go="library">前往资料库</button>')}<button class="secondary yj-settings-library" data-go="library">管理媒体服务器 ${ico('chevron')}</button></section>`);
  const danmakuGroup = content.querySelector('#settings-danmaku');
  danmakuGroup?.insertAdjacentHTML('beforeend', `${selectControl('danmakuMaxCount','弹幕上限','限制单集最多载入的弹幕条数，减少内存占用', [['500','500 条'],['1000','1000 条'],['1500','标准 · 1500 条'],['3000','3000 条']])}${selectControl('danmakuOutline','弹幕描边','在复杂画面上提高文字可读性', [['none','无描边'],['soft','柔和'],['strong','清晰']])}`);
  const danmakuApis = yjDanmakuApis();
  const danmakuForms = danmakuApis.length ? danmakuApis.map(yjDanmakuApiForm).join('') : yjDanmakuApiForm();
  content.querySelector('#settings-danmaku')?.insertAdjacentHTML('beforeend', `<div class="yj-danmaku-api-list" data-danmaku-api-list>${danmakuForms}</div><button class="secondary yj-danmaku-add" type="button" data-add-danmaku-api>添加弹幕 API</button>`);
  const chapterApis=yjChapterApis(),chapterRules=yjChapterRules();
  content.insertAdjacentHTML('beforeend',`<section id="settings-chapters" class="yj-setting-group"><header><h2>片头片尾</h2><span>${chapterRules.length} 条手动规则</span></header><article><span>${ico('play')}</span><span><b>自动跳过</b><small>按手动规则、媒体章节或社区来源自动应用</small></span>${toggleControl('chapterAutoSkip','自动跳过片头片尾')}</article><div class="yj-danmaku-api-list" data-chapter-api-list>${chapterApis.map(yjChapterApiForm).join('')}</div><button class="secondary yj-danmaku-add" type="button" data-add-chapter-api>添加 HTTP 来源</button>${chapterRules.length?`<div class="yj-chapter-rule-summary">已保存 ${chapterRules.length} 集手动规则，可在播放器“片头片尾”面板中修改或删除。</div>`:''}</section>`);
  nav.innerHTML = `<button class="is-active" data-settings-section="settings-services">账户与服务</button><button data-settings-section="settings-playback">播放</button><button data-settings-section="settings-subtitles">字幕</button><button data-settings-section="settings-danmaku">弹幕</button><button data-settings-section="settings-chapters">片头片尾</button><button data-settings-section="settings-servers">服务器</button><button data-settings-section="settings-appearance">外观</button>`;
};

document.addEventListener('submit', event => {
  const form = event.target.closest('[data-danmaku-api]');
  if (!form) return;
  event.preventDefault();
  const existingApis = yjDanmakuApis();
  const forms = [...document.querySelectorAll('[data-danmaku-api]')];
  const entries = forms.map((current, index) => {
    const data = new FormData(current);
    const id = String(current.dataset.danmakuId || `danmaku-${Date.now()}-${index}`);
    const existing = existingApis.find(api => api.id === id);
    return { id, name: String(data.get('name') || '').trim() || `弹幕 API ${index + 1}`, urlTemplate: String(data.get('urlTemplate') || '').trim(), token: String(data.get('token') || '').trim() || existing?.token || '' };
  });
  if (entries.some(entry => entry.urlTemplate && !/^https?:\/\//i.test(entry.urlTemplate))) { notify('弹幕 API 必须使用 HTTP 或 HTTPS 地址'); return; }
  providerConfig.danmaku = { apis: entries.filter(entry => entry.urlTemplate) };
  saveProviders();
  settingsV2();
  notify(providerConfig.danmaku.apis.length ? `已保存 ${providerConfig.danmaku.apis.length} 个弹幕 API` : '已清除弹幕 API');
}, true);

document.addEventListener('submit',event=>{
  if (!event.target.closest('[data-chapter-api]')) return;
  event.preventDefault(); event.stopImmediatePropagation();
  const existing=yjChapterApis();
  const entries=[...document.querySelectorAll('[data-chapter-api]')].map((form,index)=>{ const data=new FormData(form),id=String(form.dataset.chapterId),old=existing.find(item=>item.id===id); return {id,name:String(data.get('name')||'').trim()||`片头片尾源 ${index+1}`,urlTemplate:String(data.get('urlTemplate')||'').trim(),token:String(data.get('token')||'').trim()||old?.token||'',enabled:form.querySelector('[data-chapter-enabled]')?.getAttribute('aria-checked')!=='false',priority:index+1}; });
  if (entries.some(item=>item.urlTemplate&&!/^https?:\/\//i.test(item.urlTemplate))) return notify('片头片尾来源必须使用 HTTP 或 HTTPS 地址');
  providerConfig.chapterApis=entries.filter(item=>item.urlTemplate); saveProviders(); settingsV2(); notify(`已保存 ${providerConfig.chapterApis.length} 个片头片尾来源`);
},true);

document.addEventListener('click', event => {
  const addDanmaku = event.target.closest('[data-add-danmaku-api]');
  if (addDanmaku) {
    event.preventDefault();
    const list = document.querySelector('[data-danmaku-api-list]');
    if (list) list.insertAdjacentHTML('beforeend', yjDanmakuApiForm({ id: `danmaku-${Date.now()}`, name: `弹幕 API ${list.querySelectorAll('[data-danmaku-api]').length + 1}` }, list.querySelectorAll('[data-danmaku-api]').length));
    return;
  }
  const addChapter=event.target.closest('[data-add-chapter-api]');
  if (addChapter) { event.preventDefault(); const list=document.querySelector('[data-chapter-api-list]'); if (list) list.insertAdjacentHTML('beforeend',yjChapterApiForm({},list.children.length)); return; }
  const removeChapter=event.target.closest('[data-remove-chapter-api]');
  if (removeChapter) { event.preventDefault(); removeChapter.closest('[data-chapter-api]')?.remove(); return; }
  const moveChapter=event.target.closest('[data-chapter-move]');
  if (moveChapter) { event.preventDefault(); const form=moveChapter.closest('[data-chapter-api]'),sibling=moveChapter.dataset.chapterMove==='up'?form?.previousElementSibling:form?.nextElementSibling; if (form&&sibling) sibling.insertAdjacentElement(moveChapter.dataset.chapterMove==='up'?'beforebegin':'afterend',form); return; }
  const chapterEnabled=event.target.closest('[data-chapter-enabled]');
  if (chapterEnabled) { event.preventDefault(); const enabled=chapterEnabled.getAttribute('aria-checked')!=='true'; chapterEnabled.setAttribute('aria-checked',String(enabled)); chapterEnabled.classList.toggle('off',!enabled); return; }
  const removeDanmaku = event.target.closest('[data-remove-danmaku]');
  if (removeDanmaku) {
    event.preventDefault();
    removeDanmaku.closest('[data-danmaku-api]')?.remove();
    const list = document.querySelector('[data-danmaku-api-list]');
    if (list && !list.querySelector('[data-danmaku-api]')) list.insertAdjacentHTML('beforeend', yjDanmakuApiForm());
    return;
  }
  const aggregate = event.target.closest('[data-server-aggregate]');
  if (aggregate) {
    const source = (providerConfig.emby || []).find(server => String(server.id) === String(aggregate.dataset.serverAggregate));
    if (!source) return;
    event.preventDefault(); event.stopImmediatePropagation();
    source.aggregate = !(source.aggregate !== false); saveProviders();
    aggregate.classList.toggle('off', source.aggregate === false); aggregate.setAttribute('aria-checked', String(source.aggregate !== false));
    const copy = aggregate.closest('article')?.querySelector('small'); if (copy) copy.textContent = `${source.kind || 'Emby'} · ${source.aggregate === false ? '不参与详情页聚合' : '参与详情页聚合'}`;
    notify(`${source.name || '媒体服务器'}已${source.aggregate === false ? '退出' : '加入'}详情页聚合`);
    return;
  }
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

showLiveRanking = function yjRanking(index, options = {}) {
  if (state.view !== 'ranking') yjRememberRoute();
  const scrollTop = options.preserveScroll ? window.scrollY : 0;
  live.rankingIndex = Number(index);
  state.view = 'ranking';
  const group = live.rankings?.[Number(index)];
  if (!group) return;
  const [name, items, meta = {}] = group;
  const lead = items[0] || {};
  const leadPoster = yjArt(lead, 'poster', 'w780') || yjArt(lead, 'backdrop', 'original');
  const leadBackdrop = yjArt(lead, 'backdrop', 'original') || leadPoster;
  const total = Math.max(Number(meta.totalResults || 0), items.length);
  const canLoadMore = meta.source === 'TMDB' && meta.path && Number(meta.page || 1) < Number(meta.totalPages || 1);
  app.innerHTML = yjShell(`<main class="yj-page yj-list-page yj-atv-ranking-page" style="--yj-ranking-art:url('${leadBackdrop}')"><button class="yj-page-back" data-yj-back>${ico('chevron')} 返回</button><section class="yj-atv-ranking-intro"><div><p class="yj-atv-ranking-source">${esc(meta.source || 'TMDB')} · ${esc(meta.family || '实时榜单')}</p><h1>${esc(name)}</h1><p>${esc(meta.summary || '来自 TMDB 的实时影视榜单。')}</p></div><span>已加载 ${items.length} / ${total} 部</span></section><section class="yj-atv-ranking-feature" aria-label="榜首作品"><div class="yj-atv-ranking-feature-art" ${leadPoster ? `style="background-image:url('${leadPoster}')"` : ''}>${leadPoster ? '' : `<span>${esc(yjTitle(lead))}</span>`}</div><div><b>本榜第 1 名</b><h2>${esc(yjTitle(lead))}</h2><p>${esc(lead.overview || '打开作品详情，查看资料、剧集与可播放版本。')}</p><button data-live-detail="${esc(lead.id)}" data-kind="${lead.kind || itemKind(lead)}">查看详情 ${ico('chevron')}</button></div></section><section class="yj-atv-ranking-grid" aria-label="${esc(name)}完整榜单">${items.map((item, position) => yjRankingCard(item, position + 1, meta, 'grid', false)).join('')}</section>${canLoadMore ? `<footer class="yj-atv-ranking-load" data-ranking-load-sentinel data-ranking-index="${Number(index)}" aria-live="polite"><span>${meta.loadingMore ? '正在加载下一批作品…' : `继续向下浏览，自动加载另外 ${Math.max(0, total - items.length)} 部`}</span><i aria-hidden="true"></i></footer>` : `<footer class="yj-atv-ranking-load is-complete"><span>已显示该榜单的全部 ${items.length} 部作品</span></footer>`}</main>`, 'home', { title:name });
  yjObserveRankingLoad();
  if (options.preserveScroll) yjRestoreScroll(scrollTop); else window.scrollTo(0,0);
};

window.renderLiveDetail = function yjDetail() {
  const data = live.detail;
  if (!data) return;
  const item = data.item, details = data.detail || item, episodes = data.episodes || [], calendarId = data.tmdbId || item.id;
  if (item.id == null) item.id = calendarId;
  const inWatchlist = live.watchlist.some(entry => String(entry.id) === String(calendarId));
  data.episodeSort ||= 'asc'; data.showAllEpisodes ||= false; data.episodePage ||= 0; data.resourceView ||= localStorage.getItem('yingji.resource-view') || 'server'; data.resourceSort ||= 'bitrate'; data.resourceSortDirection ||= 'desc';
  const sortedEpisodes = [...episodes].sort((a,b) => data.episodeSort === 'asc' ? a.number - b.number : b.number - a.number);
  const episodePageSize = 60, episodePages = Math.max(1, Math.ceil(sortedEpisodes.length / episodePageSize));
  data.episodePage = Math.min(data.episodePage, episodePages - 1);
  const selectedIndex = sortedEpisodes.findIndex(episode => Number(episode.number) === Number(data.selectedEpisode));
  const episodeWindowStart = selectedIndex >= 12 ? Math.min(Math.max(0, selectedIndex - 4), Math.max(0, sortedEpisodes.length - 12)) : 0;
  const visibleEpisodes = data.showAllEpisodes ? sortedEpisodes.slice(data.episodePage * episodePageSize, (data.episodePage + 1) * episodePageSize) : sortedEpisodes.slice(episodeWindowStart, episodeWindowStart + 12);
  const selected = episodes.find(episode => Number(episode.number) === Number(data.selectedEpisode));
  const qualities = [...new Set((data.resources || []).map(sourceQuality))].filter(Boolean).sort((a,b) => qualityRank(b) - qualityRank(a));
  if (!qualities.includes(data.selectedResolution)) data.selectedResolution = qualities[0] || '';
  const resources = window.yjSortResourceList((data.resources || []).filter(source => sourceQuality(source) === data.selectedResolution), data);
  data.selectedResource = Math.min(data.selectedResource || 0, Math.max(0, resources.length - 1));
  const cast = (details.credits?.cast || []).slice(0, 12);
  const trailer = (details.videos?.results || []).find(video => video.site === 'YouTube' && ['Trailer','Teaser'].includes(video.type));
  const posters = (details.images?.posters || []).slice(0, 8);
  const seasons = (details.seasons || []).filter(season => season.season_number > 0 && season.episode_count > 0);
  const episodeCards = visibleEpisodes.map(episode => { const hasStill = !!episode.still_path; const still = hasStill ? image(episode.still_path,'w500') : yjArt(details,'poster','w500'); const played = (data.playedEpisodes || []).includes(Number(episode.number)); const matchingProgress = (live.continueItems || []).find(entry => Number(entry.ParentIndexNumber) === Number(data.seasonNumber) && Number(entry.IndexNumber) === Number(episode.number) && String(entry.SeriesName || '') === String(yjTitle(details))); const progress = matchingProgress ? Math.min(100, Math.round((matchingProgress.UserData?.PlaybackPositionTicks || 0) / Math.max(matchingProgress.RunTimeTicks || 1, 1) * 100)) : played ? 100 : 0; const aired=episode.air_date ? new Intl.DateTimeFormat('zh-CN',{year:'numeric',month:'long',day:'numeric'}).format(new Date(`${episode.air_date}T12:00:00`)) : '播出日期待定'; return `<button class="yj-episode ${Number(episode.number) === Number(data.selectedEpisode) ? 'is-active' : ''} ${played ? 'is-played' : ''}" data-select-episode="${episode.number}"><span class="yj-episode-art ${hasStill ? '' : 'is-poster-fallback'}" ${still ? `style="background-image:url('${still}')"` : ''}><i>第 ${episode.number} 集</i>${progress ? `<em class="yj-episode-progress" style="--yj-episode-progress:${progress}%"><span></span></em>` : ''}${played ? `<em class="yj-played-badge" title="已播放">${ico('check')}<span>已播放</span></em>` : ''}</span><span><b>第 ${episode.number} 集</b><small>${esc(episode.name || '未命名剧集')}</small><time datetime="${esc(episode.air_date || '')}">${esc(aired)}</time></span></button>`; }).join('');
  const resourceCards = resources.map((source,index) => { const filename = source.Name || source.Path?.split(/[\\/]/).at(-1) || '媒体文件'; const direct = source.SupportsDirectPlay !== false; return `<button class="yj-resource ${index === data.selectedResource ? 'is-active' : ''}" data-select-resource="${index}" aria-label="选择 ${esc(source.server?.name || '媒体服务器')} 的 ${esc(sourceVersion(source))} 版本"><span class="yj-resource-server"><i>${esc((source.server?.name || '源')[0])}</i><span><b>${esc(source.server?.name || '媒体服务器')}</b><small>${esc(source.server?.kind || 'Emby')} · ${esc(filename)}</small></span></span><span><b>${esc(sourceVersion(source))}</b><small>${esc(sourceSize(source))} · ${esc(sourceBitrate(source))}</small></span><span><b>${esc(sourceRange(source))}</b><small>${esc(sourceAudioLabel(source))}</small></span><em>${index === data.selectedResource ? '已选择' : direct ? '可直连' : '需转码'}</em></button>`; }).join('');
  const resourceState = data.resourceLoading
    ? yjEmpty('正在搜索匹配资源', '正在从已连接服务器查询可播放版本。')
    : resourceCards
      ? `<div class="yj-resource-list">${resourceCards}</div>`
      : yjEmpty('当前分辨率没有资源', qualities.length ? '切换其他分辨率查看可播放线路。' : '扫描资料库后显示真实可用版本。', '<button class="primary" data-go="library">连接服务器</button>');
  app.innerHTML = yjShell(`<main class="yj-detail" style="--detail-art:url('${yjArt(details,'backdrop','original')}')"><button class="yj-page-back yj-detail-return" data-detail-return data-yj-back aria-label="返回">${ico('chevron')} 返回</button><section class="yj-detail-hero"><div class="yj-detail-copy"><span class="yj-eyebrow">${itemKind(item) === 'movie' ? 'FILM' : 'SERIES'}</span><h1>${esc(yjTitle(details))}</h1><div class="yj-feature-meta"><b>${esc(yjYear(details) || '年份未知')}</b><span>TMDB ${(details.vote_average || 0).toFixed(1)}</span><span>${episodes.length ? `${episodes.length} 集` : '电影'}</span></div><p>${esc(details.overview || '暂无剧情简介。')}</p><div class="yj-actions">${resources.length ? `<button class="primary" data-detail-play>${ico('play')} 播放所选版本${selected && !selected.movie ? ` · 第 ${selected.number} 集` : ''}</button>` : `<button class="primary" data-go="library">${ico('plus')} 连接播放来源</button>`}${inWatchlist ? `<button class="secondary" data-calendar-remove="${item.id}">${ico('close')} 移出日历</button>` : `<button class="secondary" data-live-watch="${item.id}">${ico('watch')} 加入待看</button>`}</div></div></section><section class="yj-detail-body">${episodes.length ? `<header class="yj-section-head yj-episode-head"><div><button data-episode-sort>${data.episodeSort === 'asc' ? '正序 ↑' : '倒序 ↓'}</button><button data-toggle-all-episodes>${data.showAllEpisodes ? '收起' : `查看全部 ${episodes.length} 集`} ${ico('chevron')}</button></div></header><div class="yj-episode-rail ${data.showAllEpisodes ? 'is-all' : ''}">${episodeCards}</div>${data.showAllEpisodes && episodePages > 1 ? `<nav class="yj-episode-pages"><button data-episode-page="${Math.max(0,data.episodePage-1)}" ${data.episodePage === 0 ? 'disabled' : ''}>上一页</button><span>第 ${data.episodePage + 1} / ${episodePages} 页 · ${data.episodePage * episodePageSize + 1}–${Math.min(episodes.length,(data.episodePage+1)*episodePageSize)} 集</span><button data-episode-page="${Math.min(episodePages-1,data.episodePage+1)}" ${data.episodePage === episodePages-1 ? 'disabled' : ''}>下一页</button></nav>` : ''}` : ''}<section class="yj-resource-zone ${data.resourceLoading ? 'is-searching' : ''}" aria-busy="${data.resourceLoading ? 'true' : 'false'}"><header class="yj-section-head"><div><span>SOURCES</span><h2>播放版本</h2></div><small>${data.resourceLoading ? '正在搜索…' : `${resources.length} 个匹配资源`}</small></header>${qualities.length ? `<div class="yj-resource-filters">${qualities.map(label => `<button class="${data.selectedResolution === label ? 'is-active' : ''}" data-resolution="${label}">${label}</button>`).join('')}</div>` : ''}${resourceState}</section><section class="yj-credits"><header class="yj-section-head"><div><span>CAST & CREW</span><h2>演职人员</h2></div></header>${cast.length ? `<div class="yj-cast-rail">${cast.map(person => `<article><span ${person.profile_path ? `style="background-image:url('${image(person.profile_path,'w342')}')"` : ''}></span><b>${esc(person.name)}</b><small>${esc(person.character || person.known_for_department || '')}</small></article>`).join('')}</div>` : yjEmpty('暂无演职人员资料','TMDB 没有返回相关信息。')}</section><section class="yj-media-extras"><header class="yj-section-head"><div><span>EXTRAS</span><h2>预告片与海报</h2></div></header><div>${trailer ? `<a class="yj-trailer" href="https://www.youtube.com/watch?v=${encodeURIComponent(trailer.key)}" target="_blank" rel="noreferrer"><span style="background-image:url('https://img.youtube.com/vi/${trailer.key}/hqdefault.jpg')">${ico('play')}</span><b>${esc(trailer.name || '官方预告片')}</b></a>` : yjEmpty('暂无预告片','TMDB 没有返回官方预告。')}${posters.length ? `<div class="yj-poster-gallery">${posters.map(poster => `<img src="${image(poster.file_path,'w342')}" alt="${esc(yjTitle(details))} 海报">`).join('')}</div>` : ''}</div></section></section></main>`, 'home', { title: yjTitle(item), hideSearch: true });
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
    const sortLabels = [['bitrate','视频码率'],['resolution','分辨率'],['range','色彩范围'],['size','文件大小']];
    const sortDirectionLabel = data.resourceSortDirection === 'asc' ? '升序' : '降序';
    const resourceFilterAnchor = resourceZone.querySelector('.yj-resource-filters') || resourceZone.querySelector('.yj-section-head');
    resourceFilterAnchor?.insertAdjacentHTML('afterend', `<div class="yj-resource-viewbar"><div class="yj-resource-tools"><span>匹配结果</span><div class="yj-resource-sort" role="group" aria-label="匹配结果排序">${sortLabels.map(([key,label]) => `<button class="${data.resourceSort === key ? 'is-active' : ''}" data-resource-sort="${key}" aria-label="按${label}${data.resourceSort === key ? `，${sortDirectionLabel}` : ''}">${label}${data.resourceSort === key ? `<small>${data.resourceSortDirection === 'asc' ? '↑' : '↓'}</small>` : ''}</button>`).join('')}</div></div><div class="yj-resource-view-toggle" role="group" aria-label="播放版本展示方式"><button class="${data.resourceView === 'resource' ? 'is-active' : ''}" data-resource-view="resource">按资源</button><button class="${data.resourceView === 'server' ? 'is-active' : ''}" data-resource-view="server">按服务器</button></div></div>`);
    const list = resourceZone.querySelector('.yj-resource-list');
    const pickerIndex = data.resourceServerPicker === null || data.resourceServerPicker === undefined || data.resourceServerPicker === '' ? Number.NaN : Number(data.resourceServerPicker);
    if (list && data.resourceView === 'server') {
      list.classList.add('is-server-view');
      list.innerHTML = serverGroups.map((group, groupIndex) => {
        const chosen = group.choices.find(choice => choice.index === data.selectedResource)?.source || group.choices[0].source;
        const versions = group.choices.map(({source,index}) => `<button class="yj-version-choice ${index === data.selectedResource ? 'is-active' : ''}" data-select-resource="${index}"><span><b>${esc(sourceVersion(source))}</b><small>${esc(sourceSize(source))} · ${esc(sourceBitrate(source))}</small></span><span><b>${esc(sourceRange(source))}</b><small>${esc(sourceAudioLabel(source))}</small></span>${index === data.selectedResource ? `<em>已选择</em>` : ''}</button>`).join('');
        return `<div class="yj-server-version-group"><button class="yj-resource yj-resource-server-card ${group.choices.some(choice => choice.index === data.selectedResource) ? 'is-active' : ''}" data-open-server-versions="${groupIndex}" aria-label="查看 ${esc(group.name)} 的 ${group.choices.length} 个版本"><span class="yj-resource-server"><i>${esc(group.name[0])}</i><span><b>${esc(group.name)}</b><small>${esc(group.kind)} · ${group.choices.length} 个 ${esc(data.selectedResolution || '')} 版本</small></span></span><span><b>${esc(sourceVersion(chosen))}</b><small>${esc(sourceSize(chosen))} · ${esc(sourceBitrate(chosen))}</small></span><span><b>${esc(sourceRange(chosen))}</b><small>${esc(sourceAudioLabel(chosen))}</small></span><em>选择版本 ${ico('chevron')}</em></button>${pickerIndex === groupIndex ? `<div class="yj-version-backdrop" data-close-server-versions><section class="yj-version-sheet" role="dialog" aria-modal="true" aria-label="${esc(group.name)} 的播放版本" data-version-dialog><header><div><h3>${esc(group.name)}</h3><p>${group.choices.length} 个 ${esc(data.selectedResolution || '')} 匹配版本</p></div><button data-close-server-versions aria-label="关闭版本选择">${ico('close')}</button></header><div class="yj-version-choices">${versions}</div></section></div>` : ''}</div>`;
      }).join('');
    }
  }
  yjApplyPosterTheme(details, '.yj-detail');
};

// Make the app router use this renderer too; otherwise a later route render can
// fall back to the legacy detail function after the initial UI override.
detailV2 = window.renderLiveDetail;
detail = window.renderLiveDetail;

const yjLoadDetailSeason = async seasonNumber => {
  const data = live.detail;
  if (!data || data.kind !== 'tv' || Number(data.seasonNumber) === Number(seasonNumber)) return;
  data.seasonLoading = true; data.resourceLoading = true; data.resourceError = null; renderLiveDetail();
  try {
    const season = await tmdbRequest(`/tv/${data.tmdbId}/season/${seasonNumber}?language=zh-CN`);
    if (live.detail !== data) return;
    data.seasonNumber = Number(seasonNumber);
    data.episodes = (season.episodes || []).map(episode => ({ ...episode, season:Number(seasonNumber), number:episode.episode_number }));
    data.selectedEpisode = data.episodes[0]?.number || 1;
    data.playedEpisodes = [];
    data.resources = []; data.selectedResolution = ''; data.selectedResource = 0; data.resourceLoading = true; data.resourceError = null;
    renderLiveDetail(); loadDetailResources(data);
  } catch (error) { data.seasonLoading = false; renderLiveDetail(); notify(`加载第 ${seasonNumber} 季失败：${error.message || '请检查网络'}`); }
};

/* ══════════════════════════════════════════════════════════════════════════
   Player console
   mpv owns the video window; this page is the app-side surface for it. It
   mirrors live mpv state and writes back through the whitelisted command
   channel in main.cjs. Controls that only exist as launch flags are labelled
   as taking effect on the next playback instead of pretending to be live.
   ══════════════════════════════════════════════════════════════════════════ */
const yjClock = seconds => {
  const total = Math.max(0, Math.round(Number(seconds) || 0));
  const h = Math.floor(total / 3600), m = Math.floor(total % 3600 / 60), s = total % 60;
  return h ? `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}` : `${m}:${String(s).padStart(2, '0')}`;
};

// Same 24×24 stroke language as ico() in index.html, for transport glyphs the
// shared icon set has no entry for (skip track, seek nudge, fullscreen).
const yjSvg = d => `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="${d}"/></svg>`;
const yjMpvCommand = async (payload, label) => {
  if (!window.yingjiDesktop?.mpvCommand) return false;
  try {
    const result = await window.yingjiDesktop.mpvCommand(payload);
    if (result?.ok) return true;
    if (label) notify(result?.reason === 'no-player' ? '播放器已关闭' : `${label}未生效`);
    return false;
  } catch { if (label) notify(`${label}未生效`); return false; }
};
// Settings that are baked into mpv's command line. Changing them here only
// affects the next launch — say so rather than leaving a dead control.
const yjRelaunchNote = () => `<div class="p-note">${ico('history')}<span>硬解模式、渲染器与 GPU 属于启动参数，改动会在<strong>下次播放</strong>生效。</span></div>`;
const yjConsoleSwitch = (key, label, on = null) => {
  const active = on === null ? !!live.ui.toggles[key] : !!on;
  return `<button class="switch ${active ? '' : 'off'}" role="switch" aria-checked="${active}" data-console-toggle="${esc(key)}" aria-label="${esc(label)}"></button>`;
};
const yjConsoleSeg = (key, options, current) => `<div class="p-seg" data-console-seg="${esc(key)}">${options.map(([value, text]) => `<button class="${String(current) === String(value) ? 'is-active' : ''}" data-value="${esc(value)}">${esc(text)}</button>`).join('')}</div>`;
const yjConsoleSelect = (key, options, current, ariaLabel) => `<select class="p-select" data-console-select="${esc(key)}" aria-label="${esc(ariaLabel)}">${options.map(([value, text]) => `<option value="${esc(value)}" ${String(current ?? '') === String(value) ? 'selected' : ''}>${esc(text)}</option>`).join('')}</select>`;

const yjConsoleTracks = (tracks, type, activeId) => {
  const rows = (tracks || []).filter(track => track?.type === type);
  if (!rows.length) return `<div class="p-track-list"><button class="p-track-row" disabled><i class="p-track-index">—</i><span class="p-track-copy"><b>暂无可切换${type === 'audio' ? '音轨' : '字幕'}</b><small>等待 mpv 报告轨道列表</small></span></button></div>`;
  const off = `<button class="p-track-row ${activeId === false || activeId === 'no' ? 'is-active' : ''}" data-console-track="${type}" data-track-id="no"><i class="p-track-index">—</i><span class="p-track-copy"><b>关闭</b></span><em></em></button>`;
  return `<div class="p-track-list">${rows.map(track => { const id = track.id; const lang = track.lang ? `${track.lang} · ` : ''; const title = track.title || track['demux-title'] || track.externalFilename || ''; const codec = track.codec ? String(track.codec).toUpperCase() : ''; const channels = track['demux-channels'] ? `${track['demux-channels']}` : ''; return `<button class="p-track-row ${String(activeId) === String(id) ? 'is-active' : ''}" data-console-track="${type}" data-track-id="${esc(id)}"><i class="p-track-index">${esc(id)}</i><span class="p-track-copy"><b>${esc(lang + (title || (type === 'audio' ? '音轨' : '字幕')))}</b><small>${esc([codec, channels ? `${channels} 声道` : ''].filter(Boolean).join(' · '))}</small></span><em></em></button>`; }).join('')}${type === 'sub' ? off : ''}</div>`;
};

const yjConsolePane = (tab, player, state) => {
  const t = live.ui.toggles || {};
  if (tab === 'audio') return `
    <section class="yj-setting-group p-group"><header><h2>音轨</h2><span>${(state.tracks || []).filter(track => track?.type === 'audio').length || '—'} 条</span></header>${yjConsoleTracks(state.tracks, 'audio', state.aid)}</section>
    <section class="yj-setting-group p-group"><header><h2>音频处理</h2></header>
      <article><span class="yj-ico">${ico('smart')}</span><span><b>立体声下混</b><small>多声道转为 2.0，适配耳机与音箱</small></span>${yjConsoleSwitch('downmix')}</article>
      <article><span class="yj-ico">${ico('audio')}</span><span><b>人声增强</b><small>highpass 80Hz + 1k/2.8k 提升</small></span>${yjConsoleSwitch('vocal')}</article>
      <article><span class="yj-ico">${ico('moon')}</span><span><b>夜间模式</b><small>压缩动态范围，压低爆炸声</small></span>${yjConsoleSwitch('night')}</article>
    </section>
    <section class="yj-setting-group p-group"><header><h2>同步</h2></header>
      <article><span class="yj-ico">${ico('history')}</span><span><b>音频延迟</b><small>正值表示声音延后</small></span>${yjConsoleSelect('audioDelay', [['0', '0 ms'], ['0.05', '+50 ms'], ['-0.12', '-120 ms'], ['-0.25', '-250 ms'], ['-0.5', '-500 ms']], String(Number(state.audioDelay || 0).toFixed(2)), '音频延迟')}</article>
      <article><span class="yj-ico">${yjSvg('M4 7h9M17 7h3M4 12h3M11 12h9M4 17h6M14 17h6')}</span><span><b>声道布局</b><small>由 mpv 依设备能力选择</small></span>${yjConsoleSelect('audioChannels', [['auto', '自动'], ['stereo', '立体声'], ['5.1', '5.1'], ['7.1', '7.1']], state.audioChannels || 'auto', '声道布局')}</article>
    </section>`;
  if (tab === 'subtitle') return `
    <section class="yj-setting-group p-group"><header><h2>字幕轨</h2><span>${(state.tracks || []).filter(track => track?.type === 'sub').length || '—'} 条</span></header>${yjConsoleTracks(state.tracks, 'sub', state.sid)}</section>
    <section class="yj-setting-group p-group"><header><h2>外观</h2></header>
      <article><span class="yj-ico">${ico('chip')}</span><span><b>字幕字号</b><small>相对画面高度</small></span>${yjConsoleSelect('subScale', [['0.8', '小'], ['1', '标准'], ['1.2', '大'], ['1.5', '特大']], String(Number(state.subScale || 1).toFixed(1)), '字幕字号')}</article>
      <article><span class="yj-ico">${ico('display')}</span><span><b>字幕位置</b><small>距底部百分比</small></span>${yjConsoleSelect('subPos', [['95', '顶部'], ['92', '底部 5%'], ['85', '底部 12%'], ['78', '底部 20%']], String(Math.round(Number(state.subPos || 92))), '字幕位置')}</article>
      <article><span class="yj-ico">${ico('history')}</span><span><b>字幕延迟</b><small>与画面对齐</small></span>${yjConsoleSelect('subDelay', [['0', '0 ms'], ['0.25', '+250 ms'], ['-0.25', '-250 ms'], ['-0.5', '-500 ms'], ['-1', '-1 秒']], String(Number(state.subDelay || 0).toFixed(2)), '字幕延迟')}</article>
      <article><span class="yj-ico">${ico('chip')}</span><span><b>首选语言</b><small>自动匹配简体中文优先</small></span>${yjConsoleSelect('subtitleLanguage', [['auto', '自动'], ['chi', '简体中文'], ['zho', '繁體中文'], ['eng', 'English']], live.ui.subtitleLanguage || 'auto', '字幕首选语言')}</article>
    </section>`;
  if (tab === 'danmaku') return `
    <section class="yj-setting-group p-group"><header><h2>弹幕</h2><span>${player.danmakuCount != null ? `${player.danmakuCount} 条` : '—'}</span></header>
      <article><span class="yj-ico">${ico('chip')}</span><span><b>显示弹幕</b><small>弹幕渲染在独立浮层</small></span>${yjConsoleSwitch('danmakuEnabled')}</article>
      <article><span class="yj-ico">${ico('smart')}</span><span><b>防挡模式</b><small>智能避让人物与字幕区</small></span>${yjConsoleSeg('danmakuMode', [['smart', '智能'], ['top', '顶部'], ['bottom', '底部'], ['off', '关闭']], live.ui.danmakuMode)}</article>
      <article><span class="yj-ico">${ico('chip')}</span><span><b>同屏密度</b><small>越高越密集</small></span>${yjConsoleSeg('danmakuDensity', [['low', '稀疏'], ['normal', '标准'], ['high', '密集']], live.ui.danmakuDensity)}</article>
    </section>
    <section class="yj-setting-group p-group"><header><h2>外观细节</h2></header>
      <article><span class="yj-ico">${ico('chip')}</span><span><b>字号</b><small>${live.ui.danmakuFontScale || 100}%</small></span><input class="p-slider" style="width:96px" type="range" min="60" max="180" step="10" value="${esc(live.ui.danmakuFontScale || 100)}" data-console-range="danmakuFontScale" aria-label="弹幕字号"></article>
      <article><span class="yj-ico">${ico('chip')}</span><span><b>不透明度</b><small>${live.ui.danmakuOpacity || 86}%</small></span><input class="p-slider" style="width:96px" type="range" min="20" max="100" step="2" value="${esc(live.ui.danmakuOpacity || 86)}" data-console-range="danmakuOpacity" aria-label="弹幕不透明度"></article>
      <article><span class="yj-ico">${ico('history')}</span><span><b>停留时长</b><small>滚动一条耗时</small></span>${yjConsoleSelect('danmakuDuration', [['4', '4 秒'], ['5', '5 秒'], ['7', '7 秒'], ['9', '9 秒']], live.ui.danmakuDuration, '弹幕停留时长')}</article>
      <article><span class="yj-ico">${ico('chip')}</span><span><b>同屏上限</b><small>超出后丢弃新弹幕</small></span>${yjConsoleSelect('danmakuMaxCount', [['800', '800 条'], ['1500', '1500 条'], ['3000', '3000 条'], ['0', '不限']], live.ui.danmakuMaxCount, '弹幕同屏上限')}</article>
      <article><span class="yj-ico">${ico('display')}</span><span><b>描边</b><small>硬描边在亮画面更清晰</small></span>${yjConsoleSeg('danmakuOutline', [['soft', '柔和'], ['hard', '硬边'], ['none', '关闭']], live.ui.danmakuOutline)}</article>
    </section>
    <div class="p-note">${ico('history')}<span>弹幕参数随下一次播放或切集生效；密度与模式改动会重新拉取弹幕。</span></div>`;
  if (tab === 'picture') return `
    <section class="yj-setting-group p-group"><header><h2>取景</h2></header>
      <article><span class="yj-ico">${ico('display')}</span><span><b>画面比例</b><small>原始比例来自片源</small></span>${yjConsoleSelect('videoAspect', [['auto', '原始'], ['16:9', '16:9'], ['4:3', '4:3'], ['2.35:1', '2.35:1']], state.videoAspect === 'auto' || !state.videoAspect ? 'auto' : state.videoAspect, '画面比例')}</article>
      <article><span class="yj-ico">${ico('search')}</span><span><b>缩放</b><small>${Number(state.videoZoom || 0).toFixed(2)}</small></span><input class="p-slider" style="width:96px" type="range" min="-1" max="1" step="0.05" value="${esc(Number(state.videoZoom || 0))}" data-console-range="videoZoom" aria-label="画面缩放"></article>
      <article><span class="yj-ico">${ico('refresh')}</span><span><b>旋转</b><small>修正竖拍素材</small></span>${yjConsoleSelect('videoRotate', [['0', '0°'], ['90', '90°'], ['180', '180°'], ['270', '270°']], String(Math.round(Number(state.videoRotate || 0))), '画面旋转')}</article>
    </section>
    <section class="yj-setting-group p-group"><header><h2>解码与渲染</h2><span>mpv</span></header>
      <article><span class="yj-ico">${ico('smart')}</span><span><b>硬件解码</b><small>D3D11 与 gpu-next</small></span>${yjConsoleSwitch('hardware')}</article>
      <article><span class="yj-ico">${ico('chip')}</span><span><b>硬解模式</b><small>自动安全优先兼容性</small></span>${yjConsoleSelect('hwdec', [['auto-safe', '自动安全'], ['d3d11va', 'D3D11VA'], ['d3d11va-copy', 'D3D11VA Copy'], ['no', '软解 (CPU)']], live.ui.hwdec, '硬解模式')}</article>
      <article><span class="yj-ico">${ico('display')}</span><span><b>渲染器</b><small>gpu-next 支持 HDR 与色调映射</small></span>${yjConsoleSelect('renderer', [['gpu-next', 'gpu-next'], ['gpu', 'gpu']], live.ui.renderer, '渲染器')}</article>
      <article><span class="yj-ico">${ico('chip')}</span><span><b>GPU 选择</b><small>指定 D3D11 适配器</small></span><select class="p-select" data-console-select="gpu" aria-label="GPU 选择"><option value="">自动（系统默认）</option>${(live.gpuAdapters || []).map(name => `<option value="${esc(name)}" ${live.ui.gpu === name ? 'selected' : ''}>${esc(name)}</option>`).join('')}</select></article>
      <article><span class="yj-ico">${ico('sun')}</span><span><b>HDR 与 Dolby Vision</b><small>跟随显示器能力输出</small></span>${yjConsoleSwitch('hdr')}</article>
    </section>
    ${yjRelaunchNote()}`;
  if (tab === 'playback') return `
    <section class="yj-setting-group p-group"><header><h2>速度</h2></header>
      <article><span class="yj-ico">${ico('chip')}</span><span><b>播放速度</b><small>保持音调不变</small></span>${yjConsoleSelect('speed', [['0.5', '0.5×'], ['0.75', '0.75×'], ['1', '1.0×'], ['1.25', '1.25×'], ['1.5', '1.5×'], ['2', '2.0×']], String(Number(state.speed || 1)), '播放速度')}</article>
      <article><span class="yj-ico">${ico('refresh')}</span><span><b>单文件循环</b><small>AB 循环请在 mpv 窗口内操作</small></span>${yjConsoleSwitch('loopFile', state.loopFile)}</article>
    </section>
    <section class="yj-setting-group p-group"><header><h2>窗口</h2></header>
      <article><span class="yj-ico">${ico('display')}</span><span><b>窗口置顶</b><small>播放器始终在最前</small></span>${yjConsoleSwitch('windowOntop')}</article>
      <article><span class="yj-ico">${ico('display')}</span><span><b>画中画</b><small>缩为小窗继续观看</small></span>${yjConsoleSwitch('windowPip', live.consolePip)}</article>
      <article><span class="yj-ico">${ico('display')}</span><span><b>全屏</b><small>独占显示器输出</small></span><div class="p-seg" data-console-fullscreen><button>${live.consoleFullscreen ? '退出全屏' : '进入全屏'}</button></div></article>
    </section>
    <section class="yj-setting-group p-group"><header><h2>工具</h2></header>
      <div class="p-group-actions"><button data-console-tool="screenshot">${ico('display')}截图</button><button data-console-tool="clip">${ico('plus')}截取片段</button></div>
    </section>`;
  if (tab === 'chapter') {
    const rule = player.chapterRule || null;
    const intro = rule?.introEnd != null ? yjClock(rule.introEnd) : null;
    const outro = rule?.outroStart != null ? yjClock(rule.outroStart) : null;
    const chapters = Array.isArray(state.chapters) && state.chapters.length
      ? state.chapters.map((chapter, index) => ({ time:Number(chapter.time || 0), title:chapter.title || `章节 ${index + 1}`, kind:/片头|intro|opening/i.test(chapter.title || '') ? '片头' : /片尾|outro|ending|credits/i.test(chapter.title || '') ? '片尾' : '正片' }))
      : [{time:0,title:'开场',kind:'正片'}, ...(rule?.introEnd != null ? [{time:Number(rule.introEnd),title:'片头结束',kind:'片头'}] : []), ...(rule?.outroStart != null ? [{time:Number(rule.outroStart),title:'片尾开始',kind:'片尾'}] : [])];
    const currentIndex = chapters.reduce((found, chapter, index) => chapter.time <= Number(state.timePos || 0) ? index : found, 0);
    return `
    <section class="yj-setting-group p-group"><header><h2>自动跳过</h2><span>${rule?.source ? esc(rule.source) : '未识别'}</span></header>
      <article><span class="yj-ico">${ico('play')}</span><span><b>跳过片头</b><small>${intro ? `已识别片头，结束于 ${intro}` : '本集未识别到片头标记'}</small></span>${yjConsoleSwitch('chapterAutoSkip')}</article>
      <article><span class="yj-ico">${ico('play')}</span><span><b>跳过片尾</b><small>${outro ? `已识别片尾，开始于 ${outro}` : '本集未识别到片尾标记'}</small></span>${yjConsoleSwitch('chapterAutoSkip')}</article>
      <article><span class="yj-ico">${ico('history')}</span><span><b>章节来源</b><small>优先使用 Emby 内嵌章节</small></span>${yjConsoleSelect('chapterSource', [['server', '服务器章节'], ['local', '本地解析'], ['off', '关闭']], live.ui.chapterSource || 'server', '章节来源')}</article>
    </section>
    <section class="yj-setting-group p-group"><header><h2>章节</h2><span>${chapters.length} 个</span></header>
      <div class="p-chapter-list">${chapters.map((chapter,index) => `<button class="p-chapter-row ${index === currentIndex ? 'is-current' : ''}" data-console-chapter="${esc(chapter.time)}"><time>${yjClock(chapter.time)}</time><span>${esc(chapter.title)}</span><em class="p-chapter-kind">${esc(chapter.kind)}</em></button>`).join('')}</div>
    </section>`;
  }
  const v = player.info?.video || {}, a = player.info?.audio || {};
  return `
    <section class="yj-setting-group p-group"><header><h2>媒体信息</h2><span>实时</span></header>
      <dl class="p-diag">
        <dt>视频编码</dt><dd>${esc(String(v.codec || '—').toUpperCase())}</dd>
        <dt>分辨率</dt><dd>${esc(v.dw && v.dh ? `${v.dw}×${v.dh}` : '—')}</dd>
        <dt>位深 / 色度</dt><dd>${esc([yjPixelDepth(v.format), v.format].filter(Boolean).join(' · '))}</dd>
        <dt>帧率</dt><dd>${esc(player.info?.fps ? `${Number(player.info.fps).toFixed(3).replace(/\.?0+$/, '')} fps` : '—')}</dd>
        <dt>动态范围</dt><dd>${esc(yjHdrLabel(v) || 'SDR')}</dd>
        <dt>码率</dt><dd>${esc(player.info?.bitrate ? `${(player.info.bitrate / 1000).toFixed(0)} kbps` : '—')}</dd>
        <dt>音频编码</dt><dd>${esc(String(a.codec || '—').toUpperCase())}</dd>
        <dt>声道 / 采样</dt><dd>${esc([a.channels, a.samplerate ? `${(a.samplerate / 1000).toFixed(1)} kHz` : ''].filter(Boolean).join(' · ') || '—')}</dd>
      </dl>
    </section>
    <section class="yj-setting-group p-group"><header><h2>解码状态</h2></header>
      <dl class="p-diag">
        <dt>实际硬解</dt><dd class="${state.hwdec && state.hwdec !== 'no' ? 'is-ok' : ''}">${esc(state.hwdec || '—')}</dd>
        <dt>渲染器</dt><dd>${esc(state.vo || '—')}</dd>
        <dt>GPU 适配器</dt><dd>${esc(live.ui.gpu || '自动（系统默认）')}</dd>
        <dt>丢帧</dt><dd class="${state.dropCount ? 'is-warn' : 'is-ok'}">${esc(state.dropCount || 0)}</dd>
        <dt>播放速度</dt><dd>${esc(Number(state.speed || 1))}×</dd>
        <dt>音量</dt><dd>${esc(Math.round(Number(state.volume ?? 100)))}%</dd>
      </dl>
    </section>
    <section class="yj-setting-group p-group"><header><h2>日志</h2></header>
      <div class="p-group-actions p-group-actions-single"><button data-console-tool="copy-diagnostics">复制诊断信息</button></div>
    </section>`;
};

const yjConsoleMarkup = (tab, player, state) => {
  const meta = (player.meta || []).filter(Boolean);
  const total = Number(state.duration || 0);
  const played = Number(state.timePos || 0);
  const percent = total > 0 ? Math.min(100, Math.max(0, played / total * 100)) : 0;
  const rule = player.chapterRule || null;
  const introMark = rule?.introEnd != null && total > 0 ? `<span class="p-progress-mark" style="left:${Math.min(100, rule.introEnd / total * 100).toFixed(2)}%" title="片头结束 ${yjClock(rule.introEnd)}"></span>` : '';
  const outroMark = rule?.outroStart != null && total > 0 ? `<span class="p-progress-mark" style="left:${Math.min(100, rule.outroStart / total * 100).toFixed(2)}%" title="片尾开始 ${yjClock(rule.outroStart)}"></span>` : '';
  // Embedded layout: mpv renders into the Electron window via --wid.
  // .p-video is transparent — mpv draws to the window behind it.
  return `<main class="p-console p-page">
    <div class="p-video" data-mpv-video aria-hidden="true"></div>
    <section class="p-stage" ${player.tint ? `style="--poster-rgb:${esc(player.tint)}"` : ''}>
      <div class="p-head">
        <span class="p-poster" ${player.poster ? `style="background-image:url('${esc(player.poster)}')"` : ''}></span>
        <div class="p-head-copy">
          <span class="yj-eyebrow">NOW PLAYING · MPV</span>
          <h1>${esc(player.title || '正在播放')}</h1>
          <ul class="p-stage-meta">${meta.map(entry => `<li>${esc(entry)}</li>`).join('')}</ul>
        </div>
      </div>
      <div class="yj-media-info p-media-info" data-mpv-info aria-live="polite"><span class="yj-media-chip yj-media-empty">正在读取媒体信息…</span></div>
      <div class="p-progress">
        <div class="p-progress-track" data-console-seek role="slider" aria-label="播放进度" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${percent.toFixed(0)}" tabindex="0">
          <div class="p-progress-buffer"></div>
          <div class="p-progress-played" style="width:${percent.toFixed(2)}%"><i class="p-progress-handle"></i></div>
          ${introMark}${outroMark}
        </div>
        <div class="p-times">
          <b data-console-time>${yjClock(played)}</b>
          <span data-console-duration>/ ${total ? yjClock(total) : '--:--'}</span>
          <span data-console-remain>${total ? `剩余 ${yjClock(total - played)}` : ''}</span>
          ${rule?.introEnd != null ? `<button class="p-skip-intro" data-console-skip="${esc(rule.introEnd)}">跳过片头 ${yjClock(rule.introEnd)}</button>` : ''}
        </div>
      </div>
      <div class="p-transport">
        <button class="p-transport-btn" data-console-cmd="playlist-prev" title="上一集" aria-label="上一集">${yjSvg('M18 6v12L9 12zM6 6v12')}</button>
        <button class="p-transport-btn" data-console-cmd="seek-back" title="后退 10 秒" aria-label="后退 10 秒">${yjSvg('M20 6v5h-5M19 11a8 8 0 1 0 1 5')}</button>
        <button class="p-transport-btn solid ${state.pause ? 'is-paused' : ''}" data-console-cmd="pause" title="${state.pause ? '播放' : '暂停'}" aria-label="${state.pause ? '播放' : '暂停'}"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="${state.pause ? 'M9 7l8 5-8 5z' : 'M9 7v10m6-10v10'}"/></svg></button>
        <button class="p-transport-btn" data-console-cmd="seek-forward" title="前进 10 秒" aria-label="前进 10 秒">${yjSvg('M4 6v5h5M5 11a8 8 0 1 1 1 5')}</button>
        <button class="p-transport-btn" data-console-cmd="playlist-next" title="下一集" aria-label="下一集">${yjSvg('M6 6v12l9-6zM18 6v12')}</button>
        <div class="p-transport-div"></div>
        <div class="p-vol">
          <button class="p-volume-button" data-console-cmd="mute" title="静音" aria-label="静音">${ico('audio')}</button>
          <input class="p-vol-slider" type="range" min="0" max="100" value="${Math.round(Number(state.volume ?? 100))}" data-console-range="volume" aria-label="音量">
        </div>
        <div class="p-transport-spacer"></div>
        <span class="p-status-chip is-live">${ico('check')}直连</span>
        <span class="p-status-chip">${esc(state.hwdec || live.ui.hwdec || '—')}</span>
        <span class="p-status-chip">${esc(state.vo || live.ui.renderer || '—')}</span>
        <div class="p-transport-div"></div>
        <button class="p-transport-btn" data-console-tab="subtitle" title="字幕" aria-label="字幕">${yjSvg('M3 5h18v14H3zM7 14h4M13 14h4')}</button>
        <button class="p-transport-btn" data-console-tab="danmaku" title="弹幕" aria-label="弹幕">${yjSvg('M4 7h9M17 7h3M4 12h3M11 12h9M4 17h6M14 17h6')}</button>
        <button class="p-transport-btn" data-console-tab="playback" title="播放设置" aria-label="播放设置">${ico('more')}</button>
        <button class="p-transport-btn" data-console-cmd="fullscreen" title="全屏" aria-label="全屏">${yjSvg('M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5')}</button>
      </div>
    </section>
    <aside class="p-rail">
      <div class="p-rail-head"><h2>播放设置</h2><p>${player.connected ? '改动即时下发给 mpv，并记入播放偏好。' : '播放器已关闭，重新播放后可继续调整。'}</p></div>
      <nav class="p-rail-tabs" aria-label="播放设置分类">
        ${[['audio', '声音'], ['subtitle', '字幕'], ['danmaku', '弹幕'], ['picture', '画面'], ['playback', '播放'], ['chapter', '章节'], ['diag', '诊断']].map(([key, label]) => `<button class="p-rail-tab ${tab === key ? 'is-active' : ''}" data-console-tab="${key}" aria-pressed="${tab === key}">${label}</button>`).join('')}
      </nav>
      <div class="p-rail-body" data-console-pane>${yjConsolePane(tab, player, state)}</div>
    </aside>
  </main>`;
};

const yjPlayerShell = (content, player) => {
  const nav = yjNav.map(([route, icon, label]) => `<button class="p-shell-nav ${route === 'library' ? 'is-active' : ''}" data-go="${route}" aria-label="${label}" title="${label}">${ico(icon)}</button>`).join('');
  return `<header class="p-shell-titlebar" aria-label="窗口控制"><b>映迹</b><span>正在播放</span><div class="win"><span>—</span><span>□</span><span>×</span></div></header>
    <aside class="p-shell-sidebar"><div class="p-shell-brand">映</div><nav aria-label="主导航">${nav}</nav></aside>
    <div class="p-shell-commandbar">
      <button class="p-back" data-yj-back>${ico('chevron')} 返回</button>
      <div class="p-crumb"><b>${esc(player.crumbTitle || player.title || '正在播放')}</b><small>${esc(player.crumbSource || 'mpv · 当前播放')}</small></div>
      <div class="p-command-spacer"></div>
      <button class="p-icon-btn" data-live-watch="${esc(player.itemId || '')}" title="加入待看" aria-label="加入待看">${ico('watch')}</button>
      <button class="p-icon-btn" data-console-tab="playback" title="更多" aria-label="更多">${ico('more')}</button>
    </div>${content}`;
};

// Patch only the nodes that change every tick. Re-rendering the rail here
// would fight the user's cursor and drop the open select menus.
const yjConsoleLive = state => {
  const track = document.querySelector('[data-console-seek]');
  if (!track) return;
  const total = Number(state.duration || 0), played = Number(state.timePos || 0);
  const percent = total > 0 ? Math.min(100, Math.max(0, played / total * 100)) : 0;
  const bar = track.querySelector('.p-progress-played');
  if (bar) bar.style.width = `${percent.toFixed(2)}%`;
  track.setAttribute('aria-valuenow', percent.toFixed(0));
  const time = document.querySelector('[data-console-time]');
  if (time) time.textContent = yjClock(played);
  const duration = document.querySelector('[data-console-duration]');
  if (duration) duration.textContent = `/ ${total ? yjClock(total) : '--:--'}`;
  const remain = document.querySelector('[data-console-remain]');
  if (remain) remain.textContent = total ? `剩余 ${yjClock(total - played)}` : '';
  const play = document.querySelector('[data-console-cmd="pause"]');
  if (play) {
    play.classList.toggle('is-paused', !!state.pause);
    play.title = play.ariaLabel = state.pause ? '播放' : '暂停';
    const path = play.querySelector('path');
    if (path) path.setAttribute('d', state.pause ? 'M9 7l8 5-8 5z' : 'M9 7v10m6-10v10');
  }
};

const yjConsolePlayer = () => ({ ...(live.player || { title: '正在播放', meta: [] }) });

// Build the console view model from the Emby item that just started playing.
const yjPlayerContext = ({ item, source, title, chapterKey, chapterRule, danmakuContext, danmakuCount, resourceLabel } = {}) => {
  const server = item?.server || {};
  const itemId = item?.SeriesId || item?.Id || '';
  const poster = item?.poster_path
    ? `https://image.tmdb.org/t/p/w500${item.poster_path}`
    : (server.url && item?.token && itemId
      ? `${String(server.url).replace(/\/$/, '')}/Items/${encodeURIComponent(itemId)}/Images/Primary?maxWidth=420&quality=90&api_key=${encodeURIComponent(item.token)}`
      : '');
  const season = item?.ParentIndexNumber ?? item?.season;
  const episode = item?.IndexNumber ?? item?.episode;
  const meta = [
    item?.ProductionYear || '',
    item?.Type === 'Movie' ? '电影' : '剧集',
    season != null && episode != null ? `第 ${season} 季 · 第 ${episode} 集` : '',
    server.name || '',
    resourceLabel ? `版本 · ${resourceLabel}` : ''
  ];
  let tint = '';
  try { if (item?.id) tint = localStorage.getItem(`yingji.poster-color-${item.id}`) || ''; } catch {}
  return {
    title: (typeof seriesTitleFor === 'function' ? seriesTitleFor(item) : '') || title || '正在播放',
    crumbTitle: (typeof seriesTitleFor === 'function' ? seriesTitleFor(item) : '') || title || '正在播放',
    crumbSource: [server.name || 'Emby', resourceLabel || '当前版本'].filter(Boolean).join(' · '),
    itemId: item?.Id || '',
    poster, tint, meta,
    chapterKey: chapterKey || '', chapterRule: chapterRule || null,
    danmakuContext: danmakuContext || null, danmakuCount: danmakuCount ?? null,
    connected: true, info: null
  };
};

const yjPlayerConsole = () => {
  const tab = ['audio', 'subtitle', 'danmaku', 'picture', 'playback', 'chapter', 'diag'].includes(live.consoleTab) ? live.consoleTab : 'audio';
  const player = yjConsolePlayer();
  const state = live.playerState || {};
  app.innerHTML = yjPlayerShell(yjConsoleMarkup(tab, player, state), player);
  yjMpvStyle();
  yjRenderMediaInfo(player.info || null);
  if (!prototypeMode) {
    // Pull the authoritative snapshot so a console opened mid-playback is not
    // blank until the next property change arrives.
    window.yingjiDesktop?.mpvState?.().then(snapshot => {
      if (!snapshot) return;
      if (snapshot.state) { live.playerState = snapshot.state; yjConsoleLive(snapshot.state); }
      if (snapshot.info) { const merged = { ...(live.player || {}), info: snapshot.info }; live.player = merged; yjRenderMediaInfo(snapshot.info); }
      const rail = document.querySelector('.p-rail-head p');
      if (rail && snapshot.ok === false) rail.textContent = '播放器已关闭，重新播放后可继续调整。';
    }).catch(() => {});
    if (!live.gpuAdapters && window.yingjiDesktop?.listAdapters) {
      window.yingjiDesktop.listAdapters().then(list => { live.gpuAdapters = list || []; }).catch(() => { live.gpuAdapters = []; });
    }
  }
};
// `player` is declared in the index.html bootstrap (let home,detail,player,…)
// and is the route render() dispatches to for state.view === 'player'.
player = yjPlayerConsole;

/* ── Console interaction ─────────────────────────────────────────────────── */
// Mirrors mpvSettingArgs() in main.cjs so a runtime edit produces the same
// filter chain a fresh launch would.
const yjConsoleAudioFilters = () => {
  const filters = [];
  if (live.ui.toggles?.vocal) filters.push('lavfi=[highpass=f=80,equalizer=f=1000:t=q:w=1.5:g=6,equalizer=f=2800:t=q:w=1.5:g=4]');
  if (live.ui.toggles?.night) filters.push('lavfi=[dynaudnorm=f=200:g=15:p=0.85]');
  return filters.join(',');
};
const YJ_CONSOLE_COMMANDS = {
  pause: { command: ['cycle', 'pause'] },
  'seek-back': { command: ['seek', -10, 'relative'] },
  'seek-forward': { command: ['seek', 10, 'relative'] },
  'playlist-prev': { command: ['playlist-prev'] },
  'playlist-next': { command: ['playlist-next'] },
  mute: { command: ['cycle', 'mute'] }
  // `fullscreen` is deliberately absent: it is window state, not playback
  // state. mpv is embedded with --wid and owns no window, so `cycle
  // fullscreen` sent to mpv does nothing. Handled in yjConsoleCommand below.
};
const yjSyncFullscreenLabel = () => {
  const button = document.querySelector('[data-console-fullscreen] button');
  if (button) button.textContent = live.consoleFullscreen ? '退出全屏' : '进入全屏';
};
const yjConsoleCommand = async key => {
  if (key === 'fullscreen') {
    const api = window.yingjiDesktop;
    if (!api?.setWindowFullScreen) return;
    live.consoleFullscreen = !!(await api.setWindowFullScreen());
    yjSyncFullscreenLabel();
    return;
  }
  const payload = YJ_CONSOLE_COMMANDS[key];
  if (!payload) return;
  yjMpvCommand(payload, '该操作');
};
// Registered once at module scope so Esc / F11 (which leave fullscreen without
// going through the button) still update the label.
window.yingjiDesktop?.onWindowFullScreen?.(on => {
  live.consoleFullscreen = !!on;
  yjSyncFullscreenLabel();
});
const yjConsoleToggle = async button => {
  const key = button.dataset.consoleToggle;
  if (!key) return;
  live.ui.toggles = live.ui.toggles || {};
  if (key === 'downmix' || key === 'vocal' || key === 'night') {
    live.ui.toggles[key] = !live.ui.toggles[key];
    const ok = key === 'downmix'
      ? await yjMpvCommand({ set: { name: 'audio-channels', value: live.ui.toggles.downmix ? 'stereo' : 'auto' } }, '立体声下混')
      : await yjMpvCommand({ set: { name: 'af', value: yjConsoleAudioFilters() } }, key === 'vocal' ? '人声增强' : '夜间模式');
    if (!ok) live.ui.toggles[key] = !live.ui.toggles[key];
  } else if (key === 'loopFile') {
    const next = !live.playerState?.loopFile;
    if (!await yjMpvCommand({ set: { name: 'loop-file', value: next } }, '单文件循环')) return;
    live.playerState = { ...(live.playerState || {}), loopFile: next };
  } else if (key === 'windowOntop') {
    // Window state, same as fullscreen — mpv has no window to keep on top.
    const next = !live.consoleOntop;
    const api = window.yingjiDesktop;
    if (!api?.setWindowOnTop) return;
    await api.setWindowOnTop(next);
    live.consoleOntop = next;
  } else if (key === 'windowPip') {
    const next = !live.consolePip;
    const api = window.yingjiDesktop;
    if (!api?.setWindowPictureInPicture) return;
    live.consolePip = !!(await api.setWindowPictureInPicture(next));
    document.body.classList.toggle('yj-player-pip', live.consolePip);
  } else {
    live.ui.toggles[key] = !live.ui.toggles[key];
  }
  saveUi();
  const checked = key === 'loopFile' ? live.playerState?.loopFile : key === 'windowOntop' ? live.consoleOntop : key === 'windowPip' ? live.consolePip : live.ui.toggles[key];
  button.classList.toggle('off', !checked);
  button.setAttribute('aria-checked', String(!!checked));
};
const yjConsoleSetting = async (key, value) => {
  if (['hwdec', 'renderer', 'gpu'].includes(key)) { live.ui[key] = value; saveUi(); notify('已保存，下次播放生效'); return; }
  if (key === 'subtitleLanguage') { live.ui.subtitleLanguage = value; saveUi(); notify('字幕首选语言已保存，下次播放生效'); return; }
  if (key === 'chapterSource') { live.ui.chapterSource = value; saveUi(); notify('章节来源已保存'); return; }
  if (key.startsWith('danmaku')) { live.ui[key] = value; saveUi(); notify('弹幕设置已保存，下次播放或切集生效'); return; }
  if (key === 'chapterAutoSkip') { live.ui.toggles.chapterAutoSkip = value === true || value === 'true'; saveUi(); notify(`自动跳过片头片尾已${live.ui.toggles.chapterAutoSkip ? '开启' : '关闭'}`); return; }
  const write = {
    audioDelay: () => yjMpvCommand({ set: { name: 'audio-delay', value: Number(value) || 0 } }, '音频延迟'),
    audioChannels: () => yjMpvCommand({ set: { name: 'audio-channels', value: String(value || 'auto') } }, '声道布局'),
    subDelay: () => yjMpvCommand({ set: { name: 'sub-delay', value: Number(value) || 0 } }, '字幕延迟'),
    subPos: () => yjMpvCommand({ set: { name: 'sub-pos', value: Number(value) || 92 } }, '字幕位置'),
    subScale: () => yjMpvCommand({ set: { name: 'sub-scale', value: Number(value) || 1 } }, '字幕字号'),
    videoAspect: () => yjMpvCommand({ set: { name: 'video-aspect', value: value === 'auto' ? '-1' : String(value) } }, '画面比例'),
    videoZoom: () => yjMpvCommand({ set: { name: 'video-zoom', value: Number(value) || 0 } }, '画面缩放'),
    videoRotate: () => yjMpvCommand({ set: { name: 'video-rotate', value: Number(value) || 0 } }, '画面旋转'),
    speed: () => yjMpvCommand({ set: { name: 'speed', value: Number(value) || 1 } }, '播放速度'),
    volume: () => yjMpvCommand({ set: { name: 'volume', value: Number(value) || 0 } }, '音量'),
    aid: () => yjMpvCommand({ set: { name: 'aid', value: value === 'no' ? 'no' : Number(value) } }, '音轨切换'),
    sid: () => yjMpvCommand({ set: { name: 'sid', value: value === 'no' ? 'no' : Number(value) } }, '字幕切换')
  }[key];
  if (!write) return;
  const ok = await write();
  if (ok) live.playerState = { ...(live.playerState || {}), [key === 'aid' ? 'aid' : key === 'sid' ? 'sid' : key]: value };
};
const yjConsoleTool = async kind => {
  if (kind === 'copy-diagnostics') {
    const player = live.player || {}, state = live.playerState || {}, info = player.info || {};
    const text = JSON.stringify({ title:player.title || '', video:info.video || null, audio:info.audio || null, fps:info.fps || null, bitrate:info.bitrate || null, playback:state }, null, 2);
    try { await navigator.clipboard.writeText(text); notify('诊断信息已复制'); } catch { notify('复制失败，请检查剪贴板权限'); }
    return;
  }
  const result = await window.yingjiDesktop?.captureMpv?.(kind);
  if (!result?.ok) return notify('播放器尚未准备好');
  if (kind === 'clip' && result.phase === 'start') return notify(`片段起点已设为 ${yjClock(result.position)}，再次点击保存`);
  notify(kind === 'screenshot' ? '截图已保存到“图片/映迹”' : '片段已保存到“视频/映迹”');
};
const yjConsoleSeek = event => {
  const track = event.currentTarget;
  const total = Number(live.playerState?.duration || 0);
  if (!total) return notify('还没有可用的总时长');
  const rect = track.getBoundingClientRect();
  const ratio = Math.min(1, Math.max(0, (event.clientX - rect.left) / Math.max(rect.width, 1)));
  yjMpvCommand({ set: { name: 'time-pos', value: Number((ratio * total).toFixed(2)) } }, '跳转');
};
const yjConsoleSeekTo = seconds => yjMpvCommand({ set: { name: 'time-pos', value: Math.max(0, Number(seconds) || 0) } }, '跳转');
const yjConsoleMark = field => {
  const context = live.player?.danmakuContext || live.player?.context;
  if (!context) return notify('当前内容缺少章节标识，无法保存标记');
  const seconds = Number(live.playerState?.timePos || 0);
  const rules = yjChapterRules();
  const key = String(live.player?.chapterKey || yjMediaKey(context));
  const index = rules.findIndex(rule => rule.key === key);
  const current = index >= 0 ? rules[index] : { key, source: '手动' };
  const next = { ...current, source: '手动', updatedAt: new Date().toISOString() };
  if (field === 'introEnd') next.introEnd = Math.max(0, Math.round(seconds));
  else if (field === 'outroStart') next.outroStart = Math.max(0, Math.round(seconds));
  else return;
  if (index >= 0) rules[index] = next; else rules.push(next);
  providerConfig.chapterRules = rules;
  saveProviders();
  if (live.player) live.player.chapterRule = next;
  notify(`${field === 'introEnd' ? '片头结束' : '片尾开始'}已标记为 ${yjClock(seconds)}`);
  if (typeof render === 'function' && state.view === 'player') render();
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
// Final spatial layer: keep the navigation as floating controls, never as a rail.
// This is injected after the legacy styles so every page shares the same full-bleed canvas.
if (!document.getElementById('yj-final-spatial-layer')) {
  const style = document.createElement('style');
  style.id = 'yj-final-spatial-layer';
  style.textContent = `
    body.yj-ui #app.app { --yj-content-start:clamp(7rem,6vw,10rem); --yj-content-end:clamp(1.25rem,3vw,3.5rem); }
    body.yj-ui #app.app > .yj-detail { position:relative !important; isolation:isolate !important; box-sizing:border-box !important; width:100% !important; margin-left:0 !important; padding:0 !important; min-height:100vh !important; overflow:hidden !important; background:linear-gradient(180deg,rgba(8,10,15,.04) 0,rgba(8,10,15,.2) 31rem,rgba(8,10,15,.75) 49rem,#08090d 76rem) !important; }
    body.yj-ui #app.app > .yj-detail::before { content:"" !important; position:fixed !important; z-index:0 !important; inset:-2.5rem !important; display:block !important; background:var(--detail-art) center top/cover no-repeat !important; filter:blur(30px) saturate(1.16) !important; opacity:.62 !important; transform:scale(1.055) !important; transform-origin:top center !important; pointer-events:none !important; }
    body.yj-ui #app.app > .yj-detail::after { content:"" !important; position:fixed !important; z-index:0 !important; inset:0 !important; display:block !important; background:linear-gradient(180deg,rgba(7,9,14,.04) 0,rgba(7,9,14,.12) 34vh,rgba(7,9,14,.58) 67vh,rgba(7,9,14,.93) 100vh,#08090d 150vh) !important; pointer-events:none !important; }
    body.yj-ui #app.app > .yj-detail > .yj-detail-hero, body.yj-ui #app.app > .yj-detail > .yj-detail-body { position:relative !important; z-index:1 !important; width:100% !important; margin-left:0 !important; }
    body.yj-ui #app.app > .yj-detail > .yj-detail-hero { min-height:clamp(31rem,48vw,46rem) !important; background:transparent !important; }
    body.yj-ui #app.app > .yj-detail > .yj-detail-hero::after { content:"" !important; position:absolute !important; z-index:0 !important; inset:0 !important; display:block !important; background:linear-gradient(180deg,rgba(8,10,15,.02) 0,rgba(8,10,15,.07) 40%,rgba(8,10,15,.56) 74%,rgba(8,10,15,.94) 100%),linear-gradient(90deg,rgba(8,10,15,.76) 0,rgba(8,10,15,.22) 62%,transparent 100%),var(--detail-art) center top/cover no-repeat !important; -webkit-mask-image:linear-gradient(to bottom,#000 0,#000 58%,rgba(0,0,0,.78) 76%,transparent 100%) !important; mask-image:linear-gradient(to bottom,#000 0,#000 58%,rgba(0,0,0,.78) 76%,transparent 100%) !important; pointer-events:none !important; }
    body.yj-ui #app.app > .yj-detail > .yj-detail-hero > * { position:relative !important; z-index:2 !important; }
    body.yj-ui #app.app > .yj-detail > .yj-detail-hero .yj-detail-copy { padding-left:var(--yj-content-start) !important; padding-right:var(--yj-content-end) !important; }
    body.yj-ui #app.app > .yj-detail > .yj-detail-body { max-width:none !important; padding-inline:var(--yj-content-start) var(--yj-content-end) !important; background:transparent !important; box-shadow:none !important; }
    body.yj-ui #app.app > .yj-detail > .yj-back { position:fixed !important; z-index:2000 !important; top:calc(var(--yj-top) + .85rem) !important; left:var(--yj-content-start) !important; display:grid !important; width:3.15rem !important; height:3.15rem !important; min-width:3.15rem !important; min-height:3.15rem !important; padding:0 !important; place-items:center !important; border:1px solid var(--yj-material-border,rgba(255,255,255,.28)) !important; border-radius:999px !important; background:var(--yj-material-idle,rgba(11,14,20,.56)) !important; box-shadow:var(--yj-material-shadow,0 .75rem 2rem rgba(0,0,0,.33)) !important; color:#fff !important; cursor:pointer !important; touch-action:manipulation !important; backdrop-filter:var(--yj-material-blur,blur(18px) saturate(1.2)) !important; pointer-events:auto !important; transform:none !important; -webkit-app-region:no-drag !important; }
    body.yj-ui #app.app > .yj-detail > .yj-detail-return { position:fixed !important; z-index:2001 !important; top:calc(var(--yj-top) + .85rem) !important; left:var(--yj-content-start) !important; display:flex !important; align-items:center !important; gap:.42rem !important; min-width:auto !important; min-height:2.65rem !important; padding:.15rem .9rem !important; margin:0 !important; border:1px solid var(--yj-material-border,rgba(255,255,255,.24)) !important; border-radius:999px !important; background:var(--yj-material-idle,rgba(11,14,20,.58)) !important; box-shadow:var(--yj-material-shadow,0 .7rem 1.8rem rgba(0,0,0,.28)) !important; color:#fff !important; font:inherit !important; font-weight:700 !important; cursor:pointer !important; pointer-events:auto !important; touch-action:manipulation !important; transform:none !important; transition:background .16s ease,color .16s ease,box-shadow .16s ease !important; -webkit-app-region:no-drag !important; }
    body.yj-ui #app.app > .yj-detail > .yj-detail-return svg { width:1rem !important; height:1rem !important; transform:rotate(180deg) !important; stroke-width:2 !important; stroke-linecap:round !important; stroke-linejoin:round !important; }
    body.yj-ui #app.app > .yj-detail > .yj-detail-return:hover, body.yj-ui #app.app > .yj-detail > .yj-detail-return:focus-visible { background:var(--yj-material-active,rgba(255,255,255,.96)) !important; color:#11151d !important; box-shadow:var(--yj-material-active-shadow,0 .85rem 2rem rgba(0,0,0,.34)) !important; transform:none !important; }
    body.yj-ui #app.app > .yj-detail > .yj-back span { display:none !important; }
    body.yj-ui #app.app > .yj-detail > .yj-back svg { width:1.22rem !important; height:1.22rem !important; transform:rotate(180deg) !important; stroke-width:2.15 !important; stroke-linecap:round !important; stroke-linejoin:round !important; }
    body.yj-ui #app.app > .yj-detail > .yj-back:hover, body.yj-ui #app.app > .yj-detail > .yj-back:focus-visible { background:rgba(255,255,255,.96) !important; color:#131820 !important; transform:scale(1.07) !important; }
    @media (min-width:841px) {
      body.yj-ui #app.app .yj-sidebar, body.yj-ui #app.app .yj-sidebar:hover, body.yj-ui #app.app .yj-sidebar:focus-within { display:contents !important; width:auto !important; min-width:0 !important; padding:0 !important; margin:0 !important; border:0 !important; background:transparent !important; box-shadow:none !important; backdrop-filter:none !important; transition:none !important; }
      body.yj-ui #app.app .yj-sidebar .yj-nav, body.yj-ui #app.app .yj-sidebar:hover .yj-nav, body.yj-ui #app.app .yj-sidebar:focus-within .yj-nav { position:fixed !important; z-index:510 !important; top:50vh !important; right:auto !important; bottom:auto !important; left:1rem !important; display:flex !important; width:2.8rem !important; height:auto !important; padding:0 !important; margin:0 !important; flex-direction:column !important; align-items:center !important; gap:.4rem !important; overflow:visible !important; border:0 !important; background:transparent !important; box-shadow:none !important; pointer-events:none !important; transform:translate3d(0,-50%,0) !important; -webkit-app-region:no-drag !important; }
      body.yj-ui #app.app .yj-sidebar .yj-nav-item, body.yj-ui #app.app .yj-sidebar .yj-nav-item[data-go="settings"] { position:relative !important; z-index:511 !important; top:auto !important; right:auto !important; bottom:auto !important; left:auto !important; display:grid !important; box-sizing:border-box !important; width:2.8rem !important; height:2.8rem !important; min-width:2.8rem !important; min-height:2.8rem !important; flex:0 0 2.8rem !important; padding:0 !important; margin:0 !important; place-items:center !important; overflow:visible !important; contain:layout style !important; border:1px solid var(--yj-material-border,rgba(255,255,255,.18)) !important; border-radius:999px !important; background:var(--yj-material-idle,rgba(9,12,18,.58)) !important; box-shadow:var(--yj-material-shadow,0 .5rem 1.45rem rgba(0,0,0,.26)) !important; color:rgba(255,255,255,.94) !important; opacity:1 !important; pointer-events:auto !important; translate:none !important; transform:none !important; will-change:auto !important; transition:background .16s ease,color .16s ease,box-shadow .16s ease !important; backdrop-filter:var(--yj-material-blur,blur(18px) saturate(140%)) !important; -webkit-app-region:no-drag !important; }
      body.yj-ui #app.app .yj-sidebar .yj-nav-item:hover, body.yj-ui #app.app .yj-sidebar .yj-nav-item:focus-visible { top:auto !important; right:auto !important; bottom:auto !important; left:auto !important; translate:none !important; transform:none !important; background:rgba(255,255,255,.94) !important; color:#11151d !important; box-shadow:0 .75rem 1.8rem rgba(0,0,0,.32) !important; }
      body.yj-ui #app.app .yj-sidebar .yj-nav-item.is-active { border-color:rgba(255,255,255,.92) !important; background:rgba(255,255,255,.98) !important; color:#11151d !important; box-shadow:0 .6rem 1.75rem rgba(0,0,0,.3) !important; }
      body.yj-ui #app.app .yj-sidebar .yj-nav-item span { display:none !important; }
      body.yj-ui #app.app .yj-sidebar .yj-nav-item svg { position:relative !important; display:block !important; width:1.16rem !important; height:1.16rem !important; flex:none !important; translate:none !important; transform:none !important; transition:none !important; stroke-width:1.8 !important; stroke-linecap:round !important; stroke-linejoin:round !important; }
      body.yj-ui #app.app .yj-sidebar .yj-source-dock, body.yj-ui #app.app .yj-sidebar:hover .yj-source-dock, body.yj-ui #app.app .yj-sidebar:focus-within .yj-source-dock { position:fixed !important; z-index:509 !important; top:calc(50vh + 9.5rem) !important; right:auto !important; bottom:auto !important; left:1rem !important; display:flex !important; flex-direction:column !important; gap:.65rem !important; width:2.8rem !important; padding-top:1rem !important; margin:0 !important; border-top:1px solid rgba(255,255,255,.3) !important; background:transparent !important; box-shadow:none !important; pointer-events:auto !important; transform:none !important; -webkit-app-region:no-drag !important; }
      body.yj-ui #app.app .yj-sidebar .yj-source-dock button, body.yj-ui #app.app .yj-sidebar .yj-source-dock button:hover, body.yj-ui #app.app .yj-sidebar .yj-source-dock button:focus-visible { box-sizing:border-box !important; width:2.8rem !important; height:2.8rem !important; min-width:2.8rem !important; min-height:2.8rem !important; flex:0 0 2.8rem !important; padding:0 !important; overflow:visible !important; contain:layout style !important; border:1px solid var(--yj-material-border,rgba(255,255,255,.18)) !important; border-radius:999px !important; background:var(--yj-material-idle,rgba(9,12,18,.58)) !important; box-shadow:var(--yj-material-shadow,0 .5rem 1.45rem rgba(0,0,0,.26)) !important; translate:none !important; transform:none !important; will-change:auto !important; transition:background .16s ease,color .16s ease,box-shadow .16s ease !important; backdrop-filter:var(--yj-material-blur,blur(18px) saturate(140%)) !important; }
      body.yj-ui #app.app .yj-sidebar button[data-tooltip]::after { top:50% !important; left:calc(100% + .72rem) !important; margin:0 !important; opacity:0 !important; pointer-events:none !important; translate:none !important; transform:translate3d(0,-50%,0) !important; transition:opacity .14s ease !important; will-change:opacity !important; }
      body.yj-ui #app.app .yj-sidebar button[data-tooltip]:hover::after { opacity:1 !important; translate:none !important; transform:translate3d(0,-50%,0) !important; }
      body.yj-ui #app.app > .yj-home .yj-tv-hero .yj-feature-copy { padding-left:var(--yj-content-start) !important; padding-right:var(--yj-content-end) !important; }
      body.yj-ui #app.app > .yj-home .yj-tv-hero .yj-feature-switch { position:absolute !important; right:clamp(1.25rem,3vw,3.2rem) !important; left:auto !important; bottom:clamp(1.5rem,3vw,2.4rem) !important; justify-content:flex-end !important; }
      body.yj-ui #app.app > .yj-home .yj-home-content, body.yj-ui #app.app > .yj-home .yj-tv-home-content { box-sizing:border-box !important; width:auto !important; max-width:none !important; margin-right:var(--yj-content-end) !important; margin-left:var(--yj-content-start) !important; padding-top:clamp(2rem,3vw,3rem) !important; padding-right:0 !important; padding-left:0 !important; }
      body.yj-ui #app.app > .yj-atv-ranking-page { box-sizing:border-box !important; width:100% !important; max-width:none !important; margin-left:0 !important; padding-inline:var(--yj-content-start) var(--yj-content-end) !important; }
      body.yj-ui #app.app > .yj-atv-ranking-page .yj-atv-ranking-intro, body.yj-ui #app.app > .yj-atv-ranking-page .yj-atv-ranking-feature, body.yj-ui #app.app > .yj-atv-ranking-page .yj-atv-ranking-grid { width:100% !important; max-width:none !important; margin-left:0 !important; margin-right:0 !important; }
      body.yj-ui #app.app > .yj-atv-ranking-page .yj-atv-ranking-intro { padding-inline:0 !important; }
      body.yj-ui #app.app > .yj-atv-ranking-page .yj-atv-ranking-grid { grid-template-columns:repeat(auto-fill,minmax(clamp(8.8rem,9vw,11.5rem),1fr)) !important; gap:clamp(1.25rem,1.7vw,2rem) clamp(.9rem,1.2vw,1.4rem) !important; padding-inline:0 !important; }
      html[data-appearance="light"] body.yj-ui #app.app .yj-sidebar .yj-nav-item { border-color:rgba(24,33,49,.18) !important; background:rgba(255,255,255,.66) !important; color:#19212e !important; box-shadow:0 .55rem 1.5rem rgba(34,48,72,.18) !important; }
      html[data-appearance="light"] body.yj-ui #app.app .yj-sidebar .yj-nav-item.is-active, html[data-appearance="light"] body.yj-ui #app.app .yj-sidebar .yj-nav-item:hover { background:rgba(255,255,255,.98) !important; color:#101720 !important; }
      html[data-appearance="light"] body.yj-ui #app.app > .yj-detail > .yj-back, html[data-appearance="light"] body.yj-ui #app.app > .yj-detail > .yj-detail-return { border-color:rgba(24,33,49,.16) !important; background:rgba(255,255,255,.8) !important; color:#151c27 !important; box-shadow:0 .7rem 1.8rem rgba(35,50,70,.18) !important; }
    }
    @media (min-width:1600px) {
      body.yj-ui #app.app > .yj-home .yj-home-content, body.yj-ui #app.app > .yj-home .yj-tv-home-content { margin-right:var(--yj-content-end) !important; margin-left:var(--yj-content-start) !important; }
      body.yj-ui #app.app > .yj-detail > .yj-detail-body { padding-inline:var(--yj-content-start) var(--yj-content-end) !important; }
    }
    @media (max-width:840px) {
      body.yj-ui #app.app > .yj-detail > .yj-detail-body { padding-inline:1rem !important; }
      body.yj-ui #app.app > .yj-detail > .yj-back, body.yj-ui #app.app > .yj-detail > .yj-detail-return { top:.85rem !important; left:.85rem !important; }
    }
  `;
  document.head.append(style);
}
// Every compact icon control exposes the same plain-language hover label as the
// sidebar. Text buttons already describe their action in place.
const yjSyncButtonTitles = root => (root || document).querySelectorAll?.('button[aria-label]').forEach(button => {
  if (!button.title) button.title = button.getAttribute('aria-label');
});
yjSyncButtonTitles(document);
new MutationObserver(records => records.forEach(record => record.addedNodes.forEach(node => {
  if (node.nodeType !== Node.ELEMENT_NODE) return;
  if (node.matches?.('button[aria-label]') && !node.title) node.title = node.getAttribute('aria-label');
  yjSyncButtonTitles(node);
}))).observe(app, { childList:true, subtree:true });
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
  const rankScroll = event.target.closest('[data-rank-scroll]');
  if (rankScroll) {
    const rail = rankScroll.closest('.yj-atv-rank-viewport')?.querySelector('.yj-atv-rank-scroll');
    rail?.scrollBy({ left:Number(rankScroll.dataset.rankScroll) * Math.max(300, rail.clientWidth * .78), behavior:'smooth' });
    return;
  }
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
  if (viewport && !viewport.classList.contains('yj-atv-rank-viewport')) viewport.dataset.edge = 'none';
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
  document.body.insertAdjacentHTML('beforeend', `<menu class="yj-server-menu" data-server-menu data-server-id="${esc(source.id)}"><button data-context-edit>${ico('settings')} 编辑此服务器</button><button data-context-refresh>${ico('refresh')} 重新连接并刷新</button><button data-context-icon>${ico('library')} 修改图标</button><button data-context-aggregate>${ico('library')} ${source.aggregate === false ? '加入详情页聚合' : '退出详情页聚合'}</button>${lines}</menu>`);
  const menu = document.body.querySelector('[data-server-menu]');
  if (menu) {
    const margin = 12, rect = menu.getBoundingClientRect();
    menu.style.setProperty('--menu-x', `${Math.round(Math.max(margin, Math.min(event.clientX, window.innerWidth - rect.width - margin)))}px`);
    menu.style.setProperty('--menu-y', `${Math.round(Math.max(margin, Math.min(event.clientY, window.innerHeight - rect.height - margin)))}px`);
  }
});
document.addEventListener('click', event => {
  const menu = event.target.closest('[data-server-menu]');
  if (!menu) { document.querySelector('[data-server-menu]')?.remove(); return; }
  const source = yjSources().find(item => String(item.id) === String(menu.dataset.serverId));
  if (event.target.closest('[data-context-edit]') && source) { live.editingServerId = source.kind === 'WebDAV' ? null : source.id; live.editingFileId = source.kind === 'WebDAV' ? source.id : null; live.addingServer=true; live.preserveLibraryScroll=window.scrollY; menu.remove(); library(); return; }
  if (event.target.closest('[data-context-refresh]') && source) { const button=event.target.closest('[data-context-refresh]'); button.disabled=true; button.textContent='正在重新连接…'; refreshSource(source.id).then(() => { menu.remove(); notify(`${source.name} 已重新连接并更新信息`); }).catch(error => { button.disabled=false; notify(`刷新失败：${error.message}`); }); return; }
  if (event.target.closest('[data-context-aggregate]') && source) { source.aggregate = !(source.aggregate !== false); saveProviders(); menu.remove(); library(); notify(`${source.name}已${source.aggregate === false ? '退出' : '加入'}详情页聚合`); return; }
  const line = event.target.closest('[data-context-line]');
  if (line && source) { source.activeAddress = Number(line.dataset.contextLine); source.url = source.addresses[source.activeAddress]; saveProviders(); menu.remove(); library(); notify(`已切换到线路 ${source.activeAddress + 1}`); return; }
  if (event.target.closest('[data-context-icon]') && source) { const input=document.createElement('input'); input.type='file'; input.accept='image/png,image/jpeg,image/webp'; input.onchange=()=>{const file=input.files?.[0]; if(!file || file.size>2*1024*1024) return notify('请选择小于 2 MB 的图片'); const reader=new FileReader(); reader.onload=()=>{source.customIcon=reader.result;saveProviders();menu.remove();library();notify('服务器图标已更新');};reader.readAsDataURL(file);};input.click(); }
}, true);
const yjNormalizeBackButtons = () => document.querySelectorAll('button[data-go],button[data-library-home]').forEach(button => {
  if (button.hasAttribute('data-detail-return')) return;
  if (!/^返回/.test(button.textContent.trim())) return;
  button.removeAttribute('data-go');
  button.removeAttribute('data-library-home');
  button.dataset.yjBack = '';
  button.setAttribute('aria-label', '返回');
  button.innerHTML = `${ico('chevron')} 返回`;
});

new MutationObserver(yjNormalizeBackButtons).observe(app, { childList:true, subtree:true });
const yjEnsureResourceCardStructure = () => {
  const list = document.querySelector('.yj-resource-list.is-server-view');
  if (!list || !live?.detail) return;
  const legacyCard = [...list.querySelectorAll('.yj-resource-server-card')].find(card => !card.querySelector('.yj-resource-server'));
  if (legacyCard) window.renderLiveDetail?.();
};
new MutationObserver(yjEnsureResourceCardStructure).observe(app, { childList:true, subtree:true });
render();
