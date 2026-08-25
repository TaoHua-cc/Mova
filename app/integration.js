const providerConfig = JSON.parse(localStorage.getItem('yingji.providers') || '{"emby":[]}');
const live = { rankings: null, library: [], active: null, heroIndex: 0, detail: null, watchlist: JSON.parse(localStorage.getItem('yingji.live-watchlist') || '[]'), search: null, addingServer: false, returnToLibrary: false,
  ui: JSON.parse(localStorage.getItem('yingji.ui') || '{"calendarFilter":"all","calendarDay":2,"searchFilter":"all","recentSearches":["群星","深海之门","逆时之焰","边境集"],"toggles":{"hardware":true,"hdr":true,"traktOnly":false,"tmdb":true,"emby":true,"trakt":false,"wifi":true}}') };
const prototypeMode = !window.yingjiDesktop;
let discoverySyncing = false;
const saveProviders = () => localStorage.setItem('yingji.providers', JSON.stringify(providerConfig));
const embyHeaders = token => ({ 'X-Emby-Token': token, Accept: 'application/json' });
const connectionBadge = connected => `<span class="connection ${connected ? 'connected' : ''}">${connected ? '已连接' : '未配置'}</span>`;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const metadataEndpoint = (window.YINGJI_CONFIG?.metadataEndpoint || '').replace(/\/$/, '');
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
const saveLiveWatchlist = () => localStorage.setItem('yingji.live-watchlist', JSON.stringify(live.watchlist));
const saveUi = () => localStorage.setItem('yingji.ui', JSON.stringify(live.ui));
const toggleControl = (key, label) => `<button class="switch ${live.ui.toggles[key] ? '' : 'off'}" type="button" role="switch" aria-checked="${!!live.ui.toggles[key]}" aria-label="${label}" data-toggle="${key}"></button>`;
const catalogItem = id => live.rankings?.flatMap(group => group[1]).find(entry => String(entry.id) === String(id));
const liveCard = (item, index = null) => {
  const title = item.title || item.name || item.original_title || item.original_name;
  const poster = image(item.poster_path, 'w500');
  return `<button class="live-card" data-live-detail="${item.id}" data-kind="${itemKind(item)}"><span class="live-poster" style="background-image:url('${poster}')">${index === null ? '' : `<i>${index + 1}</i>`}</span><b>${esc(title)}</b><small>TMDB ${(item.vote_average || 0).toFixed(1)}</small></button>`;
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
    const sources = [
      ['国内热门电视剧', '/discover/tv?with_origin_country=CN&sort_by=popularity.desc'],
      ['国内热门电影', '/discover/movie?with_origin_country=CN&sort_by=popularity.desc'],
      ['全球热门电影', '/trending/movie/week'],
      ['全球热门剧集', '/trending/tv/week'],
      ['全球高分电影', '/movie/top_rated'],
      ['全球高分剧集', '/tv/top_rated'],
      ['即将上线电影', '/movie/upcoming'],
      ['近期热播剧集', '/tv/on_the_air']
    ];
    const settled = await Promise.all(sources.map(async ([name, path]) => {
      try {
        const data = await tmdb(path);
        return Array.isArray(data.results) && data.results.length ? [name, data.results] : null;
      } catch { return null; }
    }));
    live.rankings = settled.filter(Boolean);
    if (!live.rankings.length) throw new Error('TMDB 暂时没有返回榜单，请稍后重试');
    if (traktId) try {
      const trakt = await request('https://api.trakt.tv/shows/trending?limit=8&extended=full', { headers: { 'trakt-api-version': '2', 'trakt-api-key': traktId } });
      const items = (await Promise.all(trakt.map(async entry => {
        const id = entry.show?.ids?.tmdb;
        try { return id ? await tmdb(`/tv/${id}`) : null; } catch { return null; }
      }))).filter(Boolean);
      if (items.length) live.rankings.splice(4, 0, ['Trakt 热门剧集', items]);
    } catch {}
    localStorage.setItem('yingji.discovery-cache', JSON.stringify(live.rankings));
    if (state.view === 'home') home();
    notify(`榜单同步完成${live.rankings.length < sources.length ? '（部分模块稍后重试）' : ''}`);
  } catch (error) { notify(`榜单同步失败：${error.message || '请检查网络后重试'}`); } finally { discoverySyncing = false; }
}

const demoHome = home;
home = function () {
  live.rankings ||= JSON.parse(localStorage.getItem('yingji.discovery-cache') || 'null');
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

async function loadLibrary() {
  const target = document.querySelector('[data-live-library]');
  if (!target) return;
  if (!(providerConfig.emby || []).length) {
    target.innerHTML = '<section class="empty-state compact"><b>先连接一台 Emby 服务器</b><span>连接后即可同步电影和剧集，并在详情页自动聚合可播放版本。</span><button class="primary" data-toggle-library-server>添加服务器</button></section>';
    return;
  }
  target.innerHTML = '<div class="empty">正在读取 Emby 媒体库…</div>';
  try {
    const groups = await Promise.all((providerConfig.emby || []).map(async server => {
      const token = await window.yingjiDesktop.getSecret(`emby-${server.id}`);
      const data = await request(`${server.url}/Users/${server.userId}/Items?Recursive=true&IncludeItemTypes=Movie,Episode&Fields=Overview,ProviderIds,MediaSources&Limit=80`, { headers: embyHeaders(token) });
      return (data.Items || []).map(item => ({ ...item, server, token }));
    }));
    live.library = groups.flat();
    target.innerHTML = live.library.length ? live.library.map((item, index) => `<article class="media-row"><div class="media-thumb" style="background-image:url('${item.server.url}/Items/${item.Id}/Images/Primary?maxWidth=220&quality=85&api_key=${encodeURIComponent(item.token)}')"></div><div><b>${esc(item.SeriesName ? `${item.SeriesName} · ${item.Name}` : item.Name)}</b><small>${esc(item.Type)} · ${esc(item.server.name)}</small></div><button class="primary" data-emby-play="${index}">播放</button></article>`).join('') : '<div class="empty">服务器已连接，但没有找到电影或剧集。</div>';
  } catch (error) { target.innerHTML = `<div class="error-state"><b>媒体库读取失败</b><span>${esc(error.message)}</span><button class="secondary" data-load-library>重试</button></div>`; }
}

library = function () {
  live.returnToLibrary = true;
  const servers = (providerConfig.emby || []).map(server => `<div class="config server-card">${serverMark(server)}<div class="server-copy"><b>${esc(server.name || 'Emby 服务器')}</b><small>${esc(server.url)}</small><span>已连接 · ${esc(server.userName || '家庭账户')}</span></div><div class="server-actions">${connectionBadge(true)}<button class="secondary" data-edit-server="${esc(server.id)}">修改</button></div></div>`).join('') || '<div class="empty">还没有连接服务器。添加后，映迹会在影片详情页自动聚合可播放资源。</div>';
  const editing = live.editingServerId ? (providerConfig.emby || []).find(server => String(server.id) === String(live.editingServerId)) : null;
  const addServer = live.addingServer ? `<section class="panel library-connect"><div class="provider-title"><h2>${editing ? '修改 Emby 服务器' : '添加 Emby 服务器'}</h2><button class="secondary" data-toggle-library-server>收起</button></div><p>服务器名称可留空，映迹会从 Emby 自动获取名称和图标。</p><form data-provider="emby" ${editing ? `data-edit-id="${esc(editing.id)}"` : ''}><input name="name" value="${editing ? esc(editing.name || '') : ''}" placeholder="服务器名称（可选）"><input name="url" type="url" required value="${editing ? esc(editing.url || '') : ''}" placeholder="https://emby.example.com"><input name="username" ${editing ? '' : 'required'} placeholder="用户名${editing ? '（留空则不重新登录）' : ''}"><input name="password" type="password" ${editing ? '' : 'required'} placeholder="密码${editing ? '（留空则不重新登录）' : ''}"><button>${editing ? '保存修改' : '登录并添加'}</button></form></section>` : '';
  app.innerHTML = shell(`<main class="simple-page library-page"><div class="page-heading"><div><h1>媒体库</h1><p>管理已连接的 Emby 服务器，同步后可直接用 mpv 播放。</p></div><div class="page-actions"><button class="secondary" data-toggle-library-server>＋ 添加服务器</button><button class="primary" data-load-library>同步媒体库</button></div></div><section class="panel server-summary">${servers}</section>${addServer}<section class="live-library" data-live-library><div class="empty">点击“同步媒体库”读取真实内容。</div></section></main>`, 'library');
};

const image = (path, size = 'w500') => path ? `https://image.tmdb.org/t/p/${size}${path}` : '';
const itemKind = item => item?.title ? 'movie' : 'tv';
const serverMark = server => `<span class="server-mark" aria-hidden="true">${esc((server.name || 'E').trim().slice(0, 1).toUpperCase())}</span>`;
const sourceQuality = source => {
  const video = source?.MediaStreams?.find(stream => stream.Type === 'Video') || source?.VideoStream || {};
  const height = video.Height || source?.Height || 0;
  if (height >= 2000) return '2160p';
  if (height >= 1000) return '1080p';
  if (height >= 700) return '720p';
  return height ? `${height}p` : '原始规格';
};
const sourceCodec = source => {
  const video = source?.MediaStreams?.find(stream => stream.Type === 'Video') || source?.VideoStream || {};
  const audio = source?.MediaStreams?.find(stream => stream.Type === 'Audio') || {};
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
  const episodeCards = episodes.map(episode => `<button class="live-episode ${episode.number === selectedEpisode ? 'on' : ''}" data-select-episode="${episode.number}"><span class="episode-thumb" style="background-image:url('${image(episode.still_path, 'w500') || 'yingji-hero-original.png'}')"><i>${episodeLabel(episode)}</i></span><span class="episode-body"><b>${esc(episode.name || episodeLabel(episode))}</b><small>${esc(episode.air_date || '播出日期待定')} · ${episode.runtime ? `${episode.runtime} 分钟` : '时长待定'}</small><em>${esc(episode.overview || 'TMDB 暂无本集简介。')}</em></span></button>`).join('');
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
        <section class="detail-episodes" id="episode-section"><span class="season-picker">第 ${context.seasonNumber} 季</span><div class="episode-rail">${episodeCards || '<div class="empty">剧集资料加载中…</div>'}</div></section>
      </section>
      <aside class="detail-side">
        <section class="detail-panel resource-panel"><h2>播放资源</h2><div class="resolution-filter">${resolutions.map(resolution => `<button class="${resolution === selectedResolution ? 'on' : ''}" data-resolution="${esc(resolution)}">${esc(resolution)}</button>`).join('')}</div><div class="resource-list">${resourceState}</div>${selectedMatch ? `<button class="primary side-play" data-emby-play="${live.library.indexOf(selectedMatch)}">${ico('play')} 使用 mpv 播放</button>` : '<button class="primary side-play" data-go="library">连接 Emby 服务器</button>'}</section>
        <section class="detail-panel media-panel"><h2>媒体信息</h2>${providerRows}</section>
      </aside>
    </div>
    <div class="detail-flow"><section class="detail-section people-section"><div class="section-title"><div><h2>演员与主创</h2></div><p>${cast.length ? `${cast.length} 位主要演职员` : 'TMDB 暂无演职员资料'}</p></div><div class="cast-strip">${cast.map(person => `<article class="cast-person"><img src="${image(person.profile_path, 'w185')}" alt=""><b>${esc(person.name)}</b><small>${esc(person.character || person.job || '')}</small></article>`).join('') || '<div class="empty">暂无资料</div>'}</div></section><section class="detail-section extras-section"><div class="section-title"><div><h2>预告片与海报</h2></div><p>来自 TMDB 的官方媒体资料</p></div><div class="extras-grid">${trailer ? `<a class="trailer-card" href="https://www.youtube.com/watch?v=${encodeURIComponent(trailer.key)}" target="_blank" rel="noreferrer"><span style="background-image:url('https://img.youtube.com/vi/${trailer.key}/hqdefault.jpg')"></span><b>▶ ${esc(trailer.name || '官方预告片')}</b><small>YouTube · ${esc(trailer.type || 'Trailer')}</small></a>` : '<div class="empty">暂无官方预告片</div>'}<div class="poster-gallery">${posters.map(entry => `<img src="${image(entry.file_path, 'w342')}" alt="${esc(title)} 海报">`).join('') || `<img src="${poster}" alt="${esc(title)} 海报">`}</div></div></section></div>
  </main>`, 'home');
}

async function loadDetailResources(context) {
  const selected = context.episodes.find(episode => episode.number === context.selectedEpisode) || context.episodes[0];
  const title = context.detail.name || context.detail.title || context.item.name || context.item.title;
  try {
    const groups = await Promise.all((providerConfig.emby || []).map(async server => {
      const token = await window.yingjiDesktop.getSecret(`emby-${server.id}`);
      const type = context.kind === 'movie' ? 'Movie' : 'Episode';
      const data = await request(`${server.url}/Users/${server.userId}/Items?Recursive=true&IncludeItemTypes=${type}&SearchTerm=${encodeURIComponent(title)}&Fields=Overview,ProviderIds,MediaSources,ParentIndexNumber,IndexNumber,RunTimeTicks&Limit=100`, { headers: embyHeaders(token) });
      return (data.Items || []).filter(found => context.kind === 'movie' || (Number(found.ParentIndexNumber) === Number(context.seasonNumber) && Number(found.IndexNumber) === Number(selected.number))).map(found => ({ ...found, server, token }));
    }));
    if (live.detail !== context) return;
    context.resources = groups.flat();
    context.resources.forEach(found => { if (!live.library.some(item => item.Id === found.Id && item.server?.id === found.server.id)) live.library.push(found); });
  } catch (error) {
    if (live.detail !== context) return;
    context.resourceError = error.message || '资源读取失败';
  }
  renderLiveDetail();
}

async function showLiveDetail(id, preferredKind) {
  const item = catalogItem(id) || live.search?.results.find(entry => String(entry.id) === String(id)) || live.watchlist.find(entry => String(entry.id) === String(id));
  if (!item) return;
  state.view = 'detail';
  const kind = preferredKind || itemKind(item);
  if (prototypeMode) {
    const names = ['启程','寂静信号','迷失的坐标','最早未播放','黑箱协议','观察者'];
    live.detail = {
      item,
      detail: { ...item, name: item.name || item.title, original_name: 'Beyond the Stars', first_air_date: '2026-01-01', number_of_seasons: 3, overview: '当人类走出地球，宇宙的真相远比想象更广阔。一群探险者踏上寻找新世界的旅程，却发现文明的边界早已被改写。', genres: [{name:'科幻'},{name:'冒险'},{name:'剧情'}], credits: { cast: [] }, videos: { results: [] }, images: { posters: [] } },
      kind: 'tv', seasonNumber: 1, selectedEpisode: 4, selectedResolution: '全部', selectedResource: 0, resources: [], resourceError: '',
      episodes: names.map((name, index) => ({ number: index + 1, season: 1, name, air_date: `2026/05/${String(10 + index * 7).padStart(2,'0')}`, runtime: 49 + index % 3, overview: '他们在深空中接收到来自未知星系的微弱信号。' }))
    };
    renderLiveDetail();
    return;
  }
  app.innerHTML = shell(`<main class="simple-page"><div class="empty">正在加载《${esc(item.title || item.name)}》的详细资料…</div></main>`, 'home');
  try {
    let tmdbKey = '';
    try { tmdbKey = await window.yingjiDesktop.getSecret('tmdb-key'); } catch {}
    const detail = await tmdbRequest(`/${kind}/${item.id}?append_to_response=credits,videos,images`, tmdbKey);
    let seasonNumber = 1;
    let episodes = [];
    if (kind === 'tv') {
      const regular = (detail.seasons || []).filter(season => season.season_number > 0 && season.episode_count > 0);
      seasonNumber = regular[0]?.season_number || 1;
      const season = await tmdbRequest(`/tv/${item.id}/season/${seasonNumber}`, tmdbKey);
      episodes = (season.episodes || []).map(episode => ({ ...episode, season: seasonNumber, number: episode.episode_number }));
    } else {
      episodes = [{ movie: true, number: 1, season: 0, name: '正片', overview: detail.overview, air_date: detail.release_date, runtime: detail.runtime, still_path: detail.backdrop_path }];
    }
    const context = { item, detail, kind, seasonNumber, episodes, selectedEpisode: episodes[0]?.number || 1, resources: [], selectedResolution: '全部', selectedResource: 0 };
    live.detail = context;
    renderLiveDetail();
    loadDetailResources(context);
  } catch (error) {
    app.innerHTML = shell(`<main class="simple-page"><button class="back" data-go="home">← 返回首页</button><div class="error-state"><b>详情加载失败</b><span>${esc(error.message || '请检查网络后重试')}</span><button class="secondary" data-live-detail="${item.id}" data-kind="${kind}">重试</button></div></main>`, 'home');
  }
}

settingsV2 = function () {
  live.returnToLibrary = false;
  const servers = (providerConfig.emby || []).map(server => `<div class="config server-card">${serverMark(server)}<div class="server-copy"><b>${esc(server.name || 'Emby 服务器')}</b><small>${esc(server.url)} · ${esc(server.userName || '家庭账户')}</small></div><div class="server-actions">${connectionBadge(true)}<button class="secondary" data-edit-server="${esc(server.id)}">修改</button></div></div>`).join('') || '<div class="empty">尚未连接服务器。</div>';
  app.innerHTML = shell(`<main class="settings ios-settings"><div class="page-heading"><div><h1>设置</h1><p>连接服务、播放偏好与本机安全设置。</p></div></div><div class="provider-grid"><section class="panel provider"><div class="provider-title"><h2>TMDB</h2>${connectionBadge(!!metadataEndpoint || !!providerConfig.tmdb)}</div><p>${metadataEndpoint ? '默认由映迹元数据服务提供中文资料、海报和榜单。' : '中文资料、海报、演职员与热门榜单。'}</p>${metadataEndpoint ? '<div class="managed-source">托管模式已启用 · 可选填入自己的 Key 覆盖使用</div>' : ''}<form data-provider="tmdb"><input name="key" type="password" required placeholder="TMDB API Key（可选覆盖托管模式）"><button>保存并测试</button></form></section><section class="panel provider"><div class="provider-title"><h2>Trakt</h2>${connectionBadge(!!providerConfig.traktAuthorized)}</div><p>热门趋势、观看记录与追剧日历。</p><form data-provider="trakt"><input name="key" type="password" required placeholder="Trakt Client ID"><input name="secret" type="password" required placeholder="Trakt Client Secret"><button>保存应用凭据</button></form>${providerConfig.trakt ? `<button class="secondary authorize" data-trakt-auth>${providerConfig.traktAuthorized ? '重新授权 Trakt' : '授权 Trakt 账户'}</button>` : ''}<div data-trakt-device></div></section><section class="panel provider emby-provider"><div class="provider-title"><h2>Emby 服务器</h2>${connectionBadge((providerConfig.emby || []).length > 0)}</div>${servers}<form data-provider="emby"><input name="name" placeholder="服务器名称（可选，留空自动获取）"><input name="url" type="url" required placeholder="https://emby.example.com"><input name="username" required placeholder="用户名"><input name="password" type="password" required placeholder="密码"><button>登录并添加</button></form></section><section class="panel provider player-provider"><div class="provider-title"><h2>播放器</h2><span class="status connected">mpv</span></div><div class="setting-row"><span><b>硬件解码</b><small>自动选择 D3D11 / gpu-next</small></span>${toggleControl('hardware','硬件解码')}</div><div class="setting-row"><span><b>HDR 与 Dolby Vision</b><small>跟随显示器能力自动切换</small></span>${toggleControl('hdr','HDR 与 Dolby Vision')}</div><button class="setting-row setting-action" data-preference="subtitle"><span><b>字幕优先语言</b><small>简体中文 · ASS 样式保留</small></span><span class="chevron">›</span></button></section></div></main>`, 'settings');
};

async function authorizeTrakt() {
  const box = document.querySelector('[data-trakt-device]');
  try {
    const [clientId, clientSecret] = await Promise.all([window.yingjiDesktop.getSecret('trakt-client-id'), window.yingjiDesktop.getSecret('trakt-client-secret')]);
    const device = await request('https://api.trakt.tv/oauth/device/code', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: { client_id: clientId } });
    box.innerHTML = `<div class="device-code"><span>浏览器打开 <b>${esc(device.verification_url)}</b></span><strong>${esc(device.user_code)}</strong><small>完成授权后此页会自动连接。</small></div>`;
    const expires = Date.now() + device.expires_in * 1000;
    while (Date.now() < expires) {
      await sleep(device.interval * 1000);
      const result = await request('https://api.trakt.tv/oauth/device/token', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: { code: device.device_code, client_id: clientId, client_secret: clientSecret }, acceptErrors: true });
      if (result.status === 200) {
        await Promise.all([window.yingjiDesktop.setSecret('trakt-access-token', result.data.access_token), window.yingjiDesktop.setSecret('trakt-refresh-token', result.data.refresh_token)]);
        providerConfig.traktAuthorized = true; saveProviders(); settingsV2(); notify('Trakt 账户授权成功'); return;
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
    const byDate = Object.groupBy(events, event => event.first_aired.slice(0, 10));
    target.innerHTML = Array.from({ length: 10 }, (_, index) => {
      const day = new Date(start); day.setDate(day.getDate() + index); const key = day.toISOString().slice(0, 10); const items = byDate[key] || [];
      return `<article class="day ${index === 2 ? 'today' : ''}"><div class="day-label"><h3>${new Intl.DateTimeFormat('zh-CN',{month:'long',day:'numeric',weekday:'short'}).format(day)}</h3><small>${index === 2 ? '今天' : index < 2 ? '已过去' : '未来更新'}</small></div>${items.length ? items.map(event => `<div class="airing"><div class="calendar-poster" style="background-image:url('${posters[event.show.ids.tmdb] ? `https://image.tmdb.org/t/p/w300${posters[event.show.ids.tmdb]}` : ''}')"></div><div class="airing-copy"><b>${esc(event.show.title)}</b><span>第 ${event.episode.season} 季 · 第 ${event.episode.number} 集</span><small>${new Date(event.first_aired).toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit'})} · Trakt</small></div></div>`).join('') : '<div class="calendar-empty">暂无追剧更新</div>'}</article>`;
    }).join('');
  } catch (error) { target.innerHTML = `<div class="error-state"><b>Trakt 日历同步失败</b><span>${esc(error.message)}</span></div>`; }
}

calendar = function () {
  const start = new Date(); start.setDate(start.getDate() - 2);
  const dates = Array.from({length:9},(_,index)=>{const day=new Date(start);day.setDate(day.getDate()+index);return `<button class="date-chip ${index===live.ui.calendarDay?'on':''}" data-calendar-day="${index}"><b>${index===2?'今天':new Intl.DateTimeFormat('zh-CN',{month:'numeric',day:'numeric'}).format(day)}</b><small>${new Intl.DateTimeFormat('zh-CN',{weekday:'short'}).format(day)}</small><i>${index%3+1}</i></button>`}).join('');
  const platforms = ['HBO', 'Youku', 'Netflix', 'Disney+'];
  const demos = ['群星之外','深海之门','逆时之焰','暗潮之下'].map((title,index)=>`<article class="calendar-event"><span class="calendar-poster p${index}"></span><span class="calendar-event-main"><b>${title}</b><small>2026 · 剧情 / 悬疑</small><strong>第 ${index + 1} 季 · 第 ${index + 2} 集</strong></span><em class="calendar-platform">${platforms[index]}</em><time>${ico('bell')} ${String(9 + index).padStart(2, '0')}:00</time><span class="chevron">›</span></article>`).join('');
  const filters=[['all','全部追剧'],['watch','待看'],['watched','已观看']].map(([id,label])=>`<button class="${live.ui.calendarFilter===id?'on':''}" data-calendar-filter="${id}">${label}</button>`).join('');
  app.innerHTML = shell(`<main class="calendar-page ios-calendar"><header class="page-heading"><div><h1>日历</h1><p>前两天至未来一周的追剧安排</p></div><div class="segmented">${filters}</div></header><div class="date-strip">${dates}</div><div class="calendar-layout"><section class="calendar-events" data-trakt-calendar><div class="calendar-day-title">${live.ui.calendarDay===2?'今天':'所选日期'} · ${new Intl.DateTimeFormat('zh-CN',{month:'long',day:'numeric',weekday:'long'}).format(new Date(start.getTime()+live.ui.calendarDay*86400000))}</div>${live.ui.calendarFilter==='watched'?'<section class="empty-state compact"><b>这一天没有已观看内容</b><span>播放完成后会自动出现在这里。</span></section>':demos}</section><aside class="calendar-side"><section class="ios-card side-card"><h2>本周概览</h2><div class="summary-row"><span>今天</span><b>3</b></div><div class="summary-row"><span>本周</span><b>12</b></div><div class="summary-row"><span>完结</span><b>2</b></div></section><section class="ios-card side-card"><div class="side-heading"><h2>Trakt 同步</h2><em>${providerConfig.traktAuthorized?'已连接':'未连接'}</em></div><p>同步观看记录和我的追剧日历。</p><div class="setting-row"><span>仅显示我的追剧</span>${toggleControl('traktOnly','仅显示我的追剧')}</div><button class="calendar-sync" data-sync-calendar>立即同步</button></section></aside></div></main>`, 'calendar');
};

watchlist = function () {
  const cards = live.watchlist.map(item => { const poster = image(item.poster_path, 'w500'); return `<article class="watch-card live-watch-card"><button class="watch-poster ${item.posterClass || ''}" data-live-detail="${item.id}" data-kind="${item.kind}" ${poster ? `style="background-image:url('${poster}')"` : ''}></button><div class="watch-copy"><div><small>${item.kind === 'movie' ? '电影' : '剧集'} · TMDB ${(item.vote_average || 0).toFixed(1)}</small><h2>${esc(item.title || item.name)}</h2></div><button class="secondary" data-live-unwatch="${item.id}">移出待看</button></div></article>`; }).join('');
  app.innerHTML = shell(`<main class="simple-page watchlist-page"><div class="page-heading"><div><h1>待看</h1><p>加入待看的电影和剧集会保存在本机，并可与 Trakt 追剧记录一起查看。</p></div><span class="page-stat">${live.watchlist.length} 部待看</span></div>${cards ? `<section class="watch-grid">${cards}</section>` : `<section class="empty-state"><b>待看列表还是空的</b><span>在首页或详情页点击“加入待看”，想看的内容就会放在这里。</span><button class="primary" data-go="home">去发现内容</button></section>`}</main>`, 'watchlist');
};

downloads = function () {
  app.innerHTML = shell(`<main class="simple-page downloads-page ios-downloads"><div class="page-heading"><div><h1>下载</h1><p>离线任务与本机空间管理</p></div><span class="page-stat">暂未开放</span></div><div class="downloads-layout"><section class="panel download-queue"><div class="provider-title"><h2>下载队列</h2><div class="segmented"><button class="on" disabled>全部</button><button disabled>进行中</button><button disabled>已完成</button></div></div><div class="download-placeholder"><span>↓</span><b>离线下载尚未开放</b><small>当前版本不会创建虚假的下载任务。你仍可从媒体库直接播放已连接服务器中的内容。</small><button class="primary" data-go="library">前往媒体库</button></div></section><aside class="downloads-side"><section class="ios-card side-card"><h2>本机空间</h2><div class="storage-ring unavailable"><b>—</b><small>等待启用</small></div><p>启用下载引擎后，这里会显示真实空间与缓存占用。</p></section><section class="ios-card side-card"><h2>下载偏好</h2><div class="setting-row"><span><b>仅 Wi-Fi</b><small>偏好已保存，功能开放后生效</small></span>${toggleControl('wifi','下载仅使用 Wi-Fi')}</div><button class="setting-row setting-action" data-preference="quality"><span><b>自动选择清晰度</b><small>${live.ui.downloadQuality || '优先 1080p'}</small></span><span class="chevron">›</span></button></section></aside></div></main>`, 'downloads');
};

searchPage = function () {
  const results = live.search?.results || [];
  const fallback = live.rankings?.flatMap(group=>group[1]).slice(0,6) || [];
  const base = results.length ? results : fallback;
  const shown = live.ui.searchFilter === 'movie' ? base.filter(item=>itemKind(item)==='movie') : live.ui.searchFilter === 'tv' ? base.filter(item=>itemKind(item)==='tv') : base;
  const cards = shown.map(item => liveCard(item)).join('');
  const best = shown[0]; const bestTitle=best?.title||best?.name; const bestBackdrop=image(best?.backdrop_path||best?.poster_path,'w780');
  const tabs=[['all','全部'],['movie','电影'],['tv','剧集']].map(([id,label])=>`<button class="${live.ui.searchFilter===id?'on':''}" data-search-filter="${id}">${label}</button>`).join('');
  const recent=live.ui.recentSearches.map(text=>`<div class="recent-row"><span>◷</span><button data-recent-search="${esc(text)}">${esc(text)}</button><button data-remove-recent="${esc(text)}" aria-label="移除${esc(text)}">×</button></div>`).join('')||'<div class="empty compact">暂无搜索记录</div>';
  app.innerHTML = shell(`<main class="search-page live-search-page ios-search"><h1>搜索</h1><form class="search-form" data-live-search><span>${ico('search')}</span><input name="query" required autofocus value="${esc(live.search?.query || '')}" placeholder="搜索电影、剧集、演员或服务器资源"><button class="primary">搜索</button></form><div class="segmented search-tabs">${tabs}</div><div class="search-layout"><section class="search-main">${best?`<h2>最佳匹配</h2><article class="best-match ios-card"><span class="best-image" style="background-image:url('${bestBackdrop}')"></span><div><h2>${esc(bestTitle)}</h2><p>${best.release_date?.slice(0,4)||best.first_air_date?.slice(0,4)||'最新'} · ${(best.vote_average||0).toFixed(1)}</p><small>${esc(best.overview||'进入详情后会自动匹配你的 Emby 资源。')}</small><div class="actions"><button class="secondary" data-live-detail="${best.id}" data-kind="${itemKind(best)}">查看详情</button></div></div></article>`:''}<h2>电影与剧集</h2>${live.search?.loading?'<div class="empty">正在搜索 TMDB…</div>':shown.length?`<div class="search-results">${cards}</div>`:`<section class="empty-state"><b>没有符合筛选条件的结果</b><span>换一个分类或搜索词试试。</span></section>`}</section><aside class="search-side"><section class="ios-card side-card"><h2>搜索范围</h2>${[['tmdb','TMDB','电影与剧集信息'],['emby','Emby','本地媒体库匹配'],['trakt','Trakt','观看记录与收藏']].map(([id,name,desc])=>`<div class="setting-row"><span><b>${name}</b><small>${desc}</small></span>${toggleControl(id,`${name} 搜索范围`)}</div>`).join('')}</section><section class="ios-card side-card"><div class="side-heading"><h2>最近搜索</h2><button data-clear-recent>清除</button></div>${recent}</section></aside></div></main>`, 'search');
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
  live.active = item;
  const info = await request(`${item.server.url}/Items/${item.Id}/PlaybackInfo?UserId=${item.server.userId}`, { method: 'POST', headers: { ...embyHeaders(item.token), 'Content-Type': 'application/json' }, body: { UserId: item.server.userId, AutoOpenLiveStream: true } });
  const source = info.MediaSources?.[0];
  if (!source) throw new Error('Emby 没有返回可播放媒体源');
  const title = item.SeriesName ? `${item.SeriesName} · ${item.Name}` : item.Name;
  const url = `${item.server.url}/Videos/${item.Id}/stream?Static=true&MediaSourceId=${encodeURIComponent(source.Id)}&api_key=${encodeURIComponent(item.token)}`;
  await window.yingjiDesktop.playMpv({
    url, title, token: item.token, serverUrl: item.server.url, userId: item.server.userId,
    itemId: item.Id, mediaSourceId: source.Id, playSessionId: info.PlaySessionId,
    position: (item.UserData?.PlaybackPositionTicks || 0) / 10000000
  });
  app.innerHTML = shell(`<main class="simple-page player-handoff"><h1>已在 mpv 中播放</h1><p>${esc(title)}</p><div class="panel"><h2>高品质播放已启用</h2><p>gpu-next · D3D11 · 自动硬件解码 · HDR / Dolby Vision · 原生 ASS 字幕</p><button class="primary" data-go="library">返回媒体库</button></div></main>`, 'library');
}

const runBusy = async (button, task) => {
  if (button.disabled) return;
  button.disabled = true;
  button.setAttribute('aria-busy', 'true');
  try { await task(); } finally {
    if (button.isConnected) { button.disabled = false; button.removeAttribute('aria-busy'); }
  }
};

document.addEventListener('click', async event => {
  const target = event.target.closest('[data-sync-discovery],[data-load-library],[data-emby-play],[data-live-detail],[data-live-more],[data-open-shelf],[data-edit-server],[data-trakt-auth],[data-sync-calendar],[data-retry-search],[data-hero-prev],[data-hero-next],[data-select-episode],[data-resolution],[data-select-resource],[data-scroll-top],[data-scroll-episodes],[data-scroll-people],[data-scroll-extras],[data-live-watch],[data-live-unwatch],[data-toggle-library-server],[data-toggle],[data-calendar-filter],[data-calendar-day],[data-search-filter],[data-recent-search],[data-remove-recent],[data-clear-recent],[data-preference]');
  if (!target) return;
  if (target.hasAttribute('data-sync-discovery')) return runBusy(target, syncDiscovery);
  if (target.hasAttribute('data-load-library')) return runBusy(target, loadLibrary);
  if (target.hasAttribute('data-retry-search')) return runBusy(target, () => searchDiscovery(live.search?.query || ''));
  if (target.dataset.embyPlay !== undefined) return runBusy(target, () => playEmby(live.library[Number(target.dataset.embyPlay)]).catch(error => notify(`播放失败：${error.message}`)));
  if (target.dataset.liveDetail !== undefined) showLiveDetail(target.dataset.liveDetail, target.dataset.kind);
  if (target.dataset.liveMore !== undefined) showLiveRanking(target.dataset.liveMore);
  if (target.dataset.openShelf) showLiveCollection(target.dataset.openShelf);
  if (target.dataset.editServer !== undefined) { live.editingServerId = target.dataset.editServer; live.addingServer = true; library(); }
  if (target.hasAttribute('data-trakt-auth')) return runBusy(target, authorizeTrakt);
  if (target.hasAttribute('data-sync-calendar')) return runBusy(target, syncTraktCalendar);
  if (target.dataset.toggle) {
    const key = target.dataset.toggle;
    live.ui.toggles[key] = !live.ui.toggles[key]; saveUi();
    target.classList.toggle('off', !live.ui.toggles[key]); target.setAttribute('aria-checked', String(live.ui.toggles[key]));
    notify(`${target.getAttribute('aria-label')}已${live.ui.toggles[key] ? '开启' : '关闭'}`); return;
  }
  if (target.dataset.calendarFilter) { live.ui.calendarFilter = target.dataset.calendarFilter; saveUi(); calendar(); return; }
  if (target.dataset.calendarDay !== undefined) { live.ui.calendarDay = Number(target.dataset.calendarDay); saveUi(); calendar(); return; }
  if (target.dataset.searchFilter) { live.ui.searchFilter = target.dataset.searchFilter; saveUi(); searchPage(); return; }
  if (target.dataset.recentSearch) return searchDiscovery(target.dataset.recentSearch);
  if (target.dataset.removeRecent) { live.ui.recentSearches = live.ui.recentSearches.filter(text => text !== target.dataset.removeRecent); saveUi(); searchPage(); return; }
  if (target.hasAttribute('data-clear-recent')) { live.ui.recentSearches = []; saveUi(); searchPage(); notify('最近搜索已清除'); return; }
  if (target.dataset.preference === 'quality') { live.ui.downloadQuality = live.ui.downloadQuality === '优先 1080p' ? '保持原画' : '优先 1080p'; saveUi(); downloads(); notify(`下载清晰度：${live.ui.downloadQuality}`); return; }
  if (target.dataset.preference === 'subtitle') { notify('字幕优先语言将在播放器语言设置中开放'); return; }
  if (target.hasAttribute('data-hero-prev')) { live.heroIndex--; home(); }
  if (target.hasAttribute('data-hero-next')) { live.heroIndex++; home(); }
  if (target.hasAttribute('data-scroll-top')) window.scrollTo({ top: 0, behavior: 'smooth' });
  if (target.hasAttribute('data-scroll-episodes')) document.querySelector('#episode-section')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  if (target.hasAttribute('data-scroll-people')) document.querySelector('.people-section')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  if (target.hasAttribute('data-scroll-extras')) document.querySelector('.extras-section')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  if (target.dataset.liveWatch !== undefined) {
    const item = catalogItem(target.dataset.liveWatch) || live.detail?.item;
    if (item && !live.watchlist.some(entry => String(entry.id) === String(item.id))) {
      live.watchlist.push({ id: item.id, kind: itemKind(item), title: item.title || item.name, name: item.name, poster_path: item.poster_path, vote_average: item.vote_average });
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
  if (target.hasAttribute('data-toggle-library-server')) { live.addingServer = !live.addingServer; if (!live.addingServer) live.editingServerId = null; library(); }
  if (target.dataset.selectEpisode !== undefined && live.detail) {
    live.detail.selectedEpisode = Number(target.dataset.selectEpisode);
    live.detail.resources = [];
    live.detail.selectedResolution = '全部';
    live.detail.selectedResource = 0;
    renderLiveDetail();
    loadDetailResources(live.detail);
  }
  if (target.dataset.resolution !== undefined && live.detail) {
    live.detail.selectedResolution = target.dataset.resolution;
    live.detail.selectedResource = 0;
    renderLiveDetail();
  }
  if (target.dataset.selectResource !== undefined && live.detail) {
    live.detail.selectedResource = Number(target.dataset.selectResource);
    renderLiveDetail();
  }
});

let heroTouchX = null;
document.addEventListener('touchstart', event => {
  if (event.target.closest('.home-hero')) heroTouchX = event.changedTouches[0].clientX;
}, { passive: true });
document.addEventListener('touchend', event => {
  if (heroTouchX === null || !event.target.closest('.home-hero')) return;
  const delta = event.changedTouches[0].clientX - heroTouchX;
  heroTouchX = null;
  if (Math.abs(delta) > 45) { live.heroIndex += delta < 0 ? 1 : -1; home(); }
}, { passive: true });

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
      if (server) Object.assign(server, { name: String(form.get('name') || '').trim() || server.name || '家庭 NAS', url: String(form.get('url') || '').trim() || server.url });
      else providerConfig.emby = [{ id: 'prototype', name: String(form.get('name') || '').trim() || '家庭 NAS', url: form.get('url') || 'http://192.168.1.10', userName: form.get('username') || '林先生' }];
    }
    saveProviders(); settingsV2(); notify('原型模式：连接状态已更新'); return;
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
    } else {
      const url = form.get('url').trim().replace(/\/$/, '');
      const editId = event.target.dataset.editId;
      const existing = editId && (providerConfig.emby || []).find(item => String(item.id) === String(editId));
      const username = String(form.get('username') || '').trim();
      const password = String(form.get('password') || '');
      const customName = String(form.get('name') || '').trim();
      if (existing && !username && !password) {
        existing.url = url;
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
        try { const publicInfo = await request(`${url}/System/Info/Public`); autoName = publicInfo.ServerName || publicInfo.ProductName || autoName; } catch {}
        const next = { id, name: customName || autoName || new URL(url).hostname, url, userId: auth.User.Id, userName: auth.User.Name };
        if (existing) Object.assign(existing, next); else { providerConfig.emby ||= []; providerConfig.emby.push(next); }
      }
    }
    saveProviders();
    if (type === 'emby' && live.returnToLibrary) { live.addingServer = false; live.editingServerId = null; library(); }
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
if (metadataEndpoint) syncDiscovery();
if (prototypeMode) {
  const demoItems = titles.map((title, index) => ({ id: index + 1, title, name: title, vote_average: 8.9 - index * .17, posterClass: `p${index}`, kind: index % 3 ? 'movie' : 'tv', overview: '进入详情后可查看剧集、播放版本和媒体信息。' }));
  if (!providerConfig.emby?.length) providerConfig.emby = [
    { id:'demo-1', name:'家庭 NAS', url:'https://home.example', userName:'林先生' },
    { id:'demo-2', name:'影音服务器', url:'https://media.example', userName:'家庭账户' },
    { id:'demo-3', name:'客厅 Emby', url:'https://living.example', userName:'共享用户' },
    { id:'demo-4', name:'云端媒体库', url:'https://cloud.example', userName:'林先生' }
  ];
  live.rankings = [['为你推荐', demoItems], ['全球热门剧集', [...demoItems].reverse()]];
  if (!live.watchlist.length) live.watchlist = demoItems.slice(0, 4);
  const prototypePage = location.hash.slice(1) || new URLSearchParams(location.search).get('page');
  ({ home, search: searchPage, detail: () => showLiveDetail(1, 'tv'), calendar, watchlist, library, downloads, settings: settingsV2 }[prototypePage] || home)();
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

// Keep the first viewport alive without interrupting detail work or keyboard navigation.
setInterval(() => {
  if (state.view !== 'home' || !live.rankings?.length || document.hidden) return;
  live.heroIndex += 1;
  home();
}, 8000);
