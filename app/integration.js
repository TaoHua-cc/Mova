const providerConfig = JSON.parse(localStorage.getItem('yingji.providers') || '{"emby":[]}');
const live = { rankings: null, library: [], active: null, heroIndex: 0, detail: null };
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
    home(); notify(`榜单同步完成${live.rankings.length < sources.length ? '（部分模块稍后重试）' : ''}`);
  } catch (error) { notify(`榜单同步失败：${error.message || '请检查网络后重试'}`); } finally { discoverySyncing = false; }
}

const demoHome = home;
home = function () {
  live.rankings ||= JSON.parse(localStorage.getItem('yingji.discovery-cache') || 'null');
  if (!live.rankings) {
    demoHome();
    document.querySelector('.content')?.insertAdjacentHTML('afterbegin', `<div class="sync-banner"><div><b>连接真实榜单</b><span>已托管 TMDB 数据；配置 Trakt 后可额外显示其热门趋势。</span></div><button class="primary" data-sync-discovery>立即同步</button></div>`);
    return;
  }
  const cards = items => items.map((item, index) => {
    const title = item.title || item.name || item.original_title || item.original_name;
    const poster = item.poster_path ? `https://image.tmdb.org/t/p/w500${item.poster_path}` : '';
    return `<button class="live-card" data-live-detail="${item.id}" data-kind="${item.title ? 'movie' : 'tv'}"><span class="live-poster" style="background-image:url('${poster}')"><i>${index + 1}</i></span><b>${esc(title)}</b><small>TMDB ${(item.vote_average || 0).toFixed(1)}</small></button>`;
  }).join('');
  const rows = live.rankings.map(([name, items], index) => `<section class="module"><div class="head"><div><h2>${esc(name)}</h2><p>${name.startsWith('Trakt') ? 'Trakt · 实时趋势' : 'TMDB · 实时数据'} · ${items.length} 部</p></div><button class="ranking-more" data-live-more="${index}">更多 <span>→</span></button></div><div class="rankrow">${cards(items.slice(0, 12))}</div></section>`).join('');
  const heroItems = live.rankings.flatMap(group => group[1]).filter(item => item.backdrop_path || item.poster_path).slice(0, 12);
  live.heroIndex = ((live.heroIndex % heroItems.length) + heroItems.length) % heroItems.length;
  const feature = heroItems[live.heroIndex] || live.rankings[0]?.[1]?.[0];
  const title = feature?.title || feature?.name || '发现新片';
  const date = feature?.release_date || feature?.first_air_date || '';
  const heroBackdrop = feature?.backdrop_path || feature?.poster_path || '';
  app.innerHTML = shell(`<section class="hero live-hero" style="--live-backdrop:url('https://image.tmdb.org/t/p/original${heroBackdrop}')"><div class="hero-copy"><div class="meta"><b>正在热映</b><span>TMDB / Trakt 实时榜单</span></div><h1>${esc(title)}</h1><div class="hero-facts"><span>${date ? esc(date.slice(0, 4)) : '最新'}</span><span>TMDB ${(feature?.vote_average || 0).toFixed(1)}</span><span>${feature?.title ? '电影' : '剧集'}</span></div><p>${esc(feature?.overview || '已连接真实影视发现数据，中文标题与简介将自动保存到本机缓存。')}</p><div class="actions"><button class="primary" data-live-detail="${feature?.id}" data-kind="${feature?.title ? 'movie' : 'tv'}">查看详情</button><button class="secondary" data-live-watch="${feature?.id}">＋ 加入待看</button><button class="hero-sync" data-sync-discovery title="刷新榜单">↻</button></div></div><div class="hero-controls"><button data-hero-prev aria-label="上一张海报">←</button><span>${String(live.heroIndex + 1).padStart(2, '0')} / ${String(heroItems.length).padStart(2, '0')}</span><button data-hero-next aria-label="下一张海报">→</button></div></section><main class="content"><div class="discovery-note">榜单由 TMDB 提供；连接 Trakt 后会加入其趋势数据。榜单完整列表可进入“更多”。</div>${rows}</main>`, 'home');
};

function showLiveRanking(index) {
  const ranking = live.rankings?.[Number(index)];
  if (!ranking) return;
  const [name, items] = ranking;
  const cards = items.map((item, itemIndex) => {
    const title = item.title || item.name || item.original_title || item.original_name;
    const poster = item.poster_path ? `https://image.tmdb.org/t/p/w500${item.poster_path}` : '';
    return `<button class="live-card" data-live-detail="${item.id}" data-kind="${item.title ? 'movie' : 'tv'}"><span class="live-poster" style="background-image:url('${poster}')"><i>${itemIndex + 1}</i></span><b>${esc(title)}</b><small>TMDB ${(item.vote_average || 0).toFixed(1)}</small></button>`;
  }).join('');
  app.innerHTML = shell(`<main class="ranking-page"><div class="page-heading"><div><button class="back" data-go="home">← 返回首页</button><h1>${esc(name)}</h1><p>来自 TMDB 的完整实时榜单</p></div><span class="page-stat">${items.length} 部作品</span></div><div class="ranking-grid">${cards}</div></main>`, 'home');
}

async function loadLibrary() {
  const target = document.querySelector('[data-live-library]');
  if (!target) return;
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
  const servers = (providerConfig.emby || []).map(server => `<div class="config"><div><b>${esc(server.name)}</b><br><small>${esc(server.url)}</small></div>${connectionBadge(true)}</div>`).join('') || '<div class="empty">尚未连接 Emby 服务器，请前往设置登录。</div>';
  app.innerHTML = shell(`<main class="simple-page"><div class="page-heading"><div><h1>媒体库</h1><p>来自你已登录的 Emby 服务器，视频将直接从服务器播放。</p></div><button class="primary" data-load-library>同步媒体库</button></div><section class="panel">${servers}</section><section class="live-library" data-live-library><div class="empty">点击“同步媒体库”读取真实内容。</div></section></main>`, 'library');
};

const image = (path, size = 'w500') => path ? `https://image.tmdb.org/t/p/${size}${path}` : '';
const itemKind = item => item?.title ? 'movie' : 'tv';
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
const episodeLabel = episode => episode.movie ? '正片' : `S${String(episode.season).padStart(2, '0')} · E${String(episode.number).padStart(2, '0')}`;

function renderLiveDetail() {
  const context = live.detail;
  if (!context) return;
  const { item, detail, kind, episodes, resources, selectedEpisode, selectedResolution, selectedResource } = context;
  const title = detail.name || detail.title || item.name || item.title;
  const backdrop = image(detail.backdrop_path || item.backdrop_path, 'original');
  const poster = image(detail.poster_path || item.poster_path);
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
  const episodeCards = episodes.map(episode => `<button class="live-episode ${episode.number === selectedEpisode ? 'on' : ''}" data-select-episode="${episode.number}"><span class="episode-thumb" style="background-image:url('${image(episode.still_path, 'w500')}')"><i>${episodeLabel(episode)}</i></span><span class="episode-body"><b>${esc(episode.name || episodeLabel(episode))}</b><small>${esc(episode.air_date || '播出日期待定')} · ${episode.runtime ? `${episode.runtime} 分钟` : '时长待定'}</small><em>${esc(episode.overview || 'TMDB 暂无本集简介。')}</em></span></button>`).join('');
  const resourceCards = shownResources.map((resource, index) => {
    const source = resource.MediaSources?.[0] || {};
    const libraryIndex = live.library.indexOf(resource);
    return `<button class="resource-option ${resource === selectedMatch ? 'on' : ''}" data-select-resource="${index}"><span><b>${esc(resource.server.name)}</b><small>${esc(resource.Name || selected?.name || title)} · ${sourceQuality(source)} · ${source.SupportsDirectPlay === false ? '需要转码' : '可直连'}</small></span><strong>${sourceQuality(source)}</strong></button>${resource === selectedMatch ? `<div class="resource-inspector"><div><small>视频 / 音频</small><b>${esc(sourceCodec(source))}</b></div><div><small>资源规格</small><b>${esc(source.Container || source.VideoType || 'Emby')}</b></div><button class="primary" data-emby-play="${libraryIndex}">播放此资源</button></div>` : ''}`;
  }).join('');
  app.innerHTML = shell(`<main class="live-detail"><section class="detail-intro" style="--detail-backdrop:url('${backdrop}')"><button class="back" data-go="home">← 返回首页</button><div class="detail-heading"><img class="detail-poster" src="${poster}" alt=""><div><div class="meta"><b>TMDB ${(detail.vote_average || item.vote_average || 0).toFixed(1)}</b><span>${esc(year)}</span><span>${esc(genres || (kind === 'movie' ? '电影' : '剧集'))}</span></div><h1>${esc(title)}</h1><p>${esc(detail.overview || item.overview || 'TMDB 暂无中文简介。')}</p><div class="detail-actions"><button class="primary" data-scroll-episodes>查看${kind === 'movie' ? '正片' : '剧集'}</button><button class="secondary" data-live-watch="${item.id}">＋ 加入待看</button></div></div></div></section><div class="detail-flow"><section class="detail-section episode-section" id="episode-section"><div class="section-title"><div><span>剧集与预览</span><h2>${kind === 'movie' ? '正片信息' : `第 ${context.seasonNumber} 季`}</h2></div><p>${kind === 'movie' ? '电影正片的可用资源会在下方聚合显示。' : '默认选中最早未播放的一集；选择后将重新聚合该集资源。'}</p></div><div class="episode-rail">${episodeCards || '<div class="empty">剧集资料加载中…</div>'}</div>${selected ? `<div class="selected-episode"><span>${episodeLabel(selected)}</span><div><b>${esc(selected.name || '正片')}</b><small>${esc(selected.air_date || '日期待定')} · ${selected.runtime || runtime || '—'} 分钟</small></div><p>${esc(selected.overview || 'TMDB 暂无本集简介。')}</p></div>` : ''}</section><section class="detail-section resource-section"><div class="section-title"><div><span>聚合资源</span><h2>我的 Emby 服务器</h2></div><p>${providerConfig.emby?.length ? `已搜索 ${providerConfig.emby.length} 个已连接服务器` : '请先在媒体库中添加 Emby 服务器'}</p></div><div class="resolution-filter">${resolutions.map(resolution => `<button class="${resolution === selectedResolution ? 'on' : ''}" data-resolution="${esc(resolution)}">${esc(resolution)}</button>`).join('')}</div><div class="resource-list">${resources.length ? (shownResources.length ? resourceCards : '<div class="empty">这个清晰度暂无资源，请切换筛选。</div>') : '<div class="empty">正在聚合服务器资源；如果没有结果，可能是服务器未收录该集或标题未匹配。</div>'}</div></section><section class="detail-section people-section"><div class="section-title"><div><span>创作人员</span><h2>演员与主创</h2></div><p>${cast.length ? `${cast.length} 位主要演职员` : 'TMDB 暂无演职员资料'}</p></div><div class="cast-strip">${cast.map(person => `<article class="cast-person"><img src="${image(person.profile_path, 'w185')}" alt=""><b>${esc(person.name)}</b><small>${esc(person.character || person.job || '')}</small></article>`).join('') || '<div class="empty">暂无资料</div>'}</div></section><section class="detail-section extras-section"><div class="section-title"><div><span>更多内容</span><h2>预告片与海报</h2></div><p>来自 TMDB 的官方媒体资料</p></div><div class="extras-grid">${trailer ? `<a class="trailer-card" href="https://www.youtube.com/watch?v=${encodeURIComponent(trailer.key)}" data-open-external="https://www.youtube.com/watch?v=${encodeURIComponent(trailer.key)}"><span style="background-image:url('https://img.youtube.com/vi/${trailer.key}/hqdefault.jpg')"></span><b>▶ ${esc(trailer.name || '官方预告片')}</b><small>YouTube · ${esc(trailer.type || 'Trailer')}</small></a>` : '<div class="empty">暂无官方预告片</div>'}<div class="poster-gallery">${posters.map(entry => `<img src="${image(entry.file_path, 'w342')}" alt="${esc(title)} 海报">`).join('') || `<img src="${poster}" alt="${esc(title)} 海报">`}</div></div></section></div></main>`, 'home');
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
  const item = live.rankings?.flatMap(group => group[1]).find(entry => String(entry.id) === String(id));
  if (!item) return;
  const kind = preferredKind || itemKind(item);
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
  const servers = (providerConfig.emby || []).map(server => `<div class="config"><div><b>${esc(server.name)}</b><br><small>${esc(server.url)} · ${esc(server.userName)}</small></div>${connectionBadge(true)}</div>`).join('') || '<div class="empty">尚未连接服务器。</div>';
  app.innerHTML = shell(`<main class="settings"><div class="page-heading"><div><h1>连接设置</h1><p>密钥和 Emby 令牌使用 Windows 数据保护加密保存。</p></div></div><div class="provider-grid"><section class="panel provider"><div class="provider-title"><h2>TMDB</h2>${connectionBadge(!!metadataEndpoint || !!providerConfig.tmdb)}</div><p>${metadataEndpoint ? '默认由映迹元数据服务提供中文资料、海报和榜单。' : '中文资料、海报、演职员与热门榜单。'}</p>${metadataEndpoint ? '<div class="managed-source">托管模式已启用 · 可选填入自己的 Key 覆盖使用</div>' : ''}<form data-provider="tmdb"><input name="key" type="password" required placeholder="TMDB API Key（可选覆盖托管模式）"><button>保存并测试</button></form></section><section class="panel provider"><div class="provider-title"><h2>Trakt</h2>${connectionBadge(!!providerConfig.traktAuthorized)}</div><p>热门趋势、观看记录与追剧日历。</p><form data-provider="trakt"><input name="key" type="password" required placeholder="Trakt Client ID"><input name="secret" type="password" required placeholder="Trakt Client Secret"><button>保存应用凭据</button></form>${providerConfig.trakt ? `<button class="secondary authorize" data-trakt-auth>${providerConfig.traktAuthorized ? '重新授权 Trakt' : '授权 Trakt 账户'}</button>` : ''}<div data-trakt-device></div></section><section class="panel provider emby-provider"><div class="provider-title"><h2>Emby 服务器</h2>${connectionBadge((providerConfig.emby || []).length > 0)}</div>${servers}<form data-provider="emby"><input name="name" required placeholder="服务器名称"><input name="url" type="url" required placeholder="https://emby.example.com"><input name="username" required placeholder="用户名"><input name="password" type="password" required placeholder="密码"><button>登录并添加</button></form></section></div></main>`, 'settings');
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
  app.innerHTML = shell(`<main class="calendar-page"><div class="page-heading"><div><h1>追剧日历</h1><p>来自已授权 Trakt 账户，从前天显示到未来一周。</p></div><button class="primary" data-sync-calendar>同步日历</button></div><div class="calendar-range" data-trakt-calendar><div class="empty">点击“同步日历”读取真实追剧更新。</div></div></main>`, 'calendar');
};

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

document.addEventListener('click', event => {
  const target = event.target.closest('[data-sync-discovery],[data-load-library],[data-emby-play],[data-live-detail],[data-live-more],[data-trakt-auth],[data-sync-calendar],[data-hero-prev],[data-hero-next],[data-select-episode],[data-resolution],[data-select-resource],[data-scroll-episodes],[data-live-watch]');
  if (!target) return;
  if (target.hasAttribute('data-sync-discovery')) syncDiscovery();
  if (target.hasAttribute('data-load-library')) loadLibrary();
  if (target.dataset.embyPlay !== undefined) playEmby(live.library[Number(target.dataset.embyPlay)]).catch(error => notify(`播放失败：${error.message}`));
  if (target.dataset.liveDetail !== undefined) showLiveDetail(target.dataset.liveDetail, target.dataset.kind);
  if (target.dataset.liveMore !== undefined) showLiveRanking(target.dataset.liveMore);
  if (target.hasAttribute('data-trakt-auth')) authorizeTrakt();
  if (target.hasAttribute('data-sync-calendar')) syncTraktCalendar();
  if (target.hasAttribute('data-hero-prev')) { live.heroIndex--; home(); }
  if (target.hasAttribute('data-hero-next')) { live.heroIndex++; home(); }
  if (target.hasAttribute('data-scroll-episodes')) document.querySelector('#episode-section')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  if (target.dataset.liveWatch !== undefined) notify('已加入待看，后续会同步到追剧日历');
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

document.addEventListener('submit', async event => {
  const type = event.target.dataset.provider;
  if (!type) return;
  event.preventDefault(); event.stopImmediatePropagation();
  const form = new FormData(event.target);
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
      const id = crypto.randomUUID();
      const auth = await request(`${url}/Users/AuthenticateByName`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Emby-Authorization': 'MediaBrowser Client="Yingji", Device="Windows", DeviceId="yingji-desktop", Version="0.2.0"' },
        body: { Username: form.get('username').trim(), Pw: form.get('password') }
      });
      await window.yingjiDesktop.setSecret(`emby-${id}`, auth.AccessToken);
      providerConfig.emby ||= [];
      providerConfig.emby.push({ id, name: form.get('name').trim(), url, userId: auth.User.Id, userName: auth.User.Name });
    }
    saveProviders(); settingsV2(); notify('连接成功，配置已安全保存');
  } catch (error) { notify(`连接失败：${error.message}`); }
}, true);

render();
if (metadataEndpoint) syncDiscovery();
