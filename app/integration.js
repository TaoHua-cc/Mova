const providerConfig = JSON.parse(localStorage.getItem('yingji.providers') || '{"emby":[]}');
const live = { rankings: null, library: [], active: null };
let discoverySyncing = false;
const saveProviders = () => localStorage.setItem('yingji.providers', JSON.stringify(providerConfig));
const request = (url, options = {}) => window.yingjiDesktop.request({ url, ...options });
const embyHeaders = token => ({ 'X-Emby-Token': token, Accept: 'application/json' });
const connectionBadge = connected => `<span class="connection ${connected ? 'connected' : ''}">${connected ? '已连接' : '未配置'}</span>`;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const metadataEndpoint = (window.YINGJI_CONFIG?.metadataEndpoint || '').replace(/\/$/, '');
const tmdbRequest = async (path, key = '') => key
  ? request(`https://api.themoviedb.org/3${path}${path.includes('?') ? '&' : '?'}api_key=${encodeURIComponent(key)}&language=zh-CN`)
  : request(`${metadataEndpoint}/tmdb${path}`);

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
      ['全球热门电影', '/trending/movie/week'],
      ['全球热门剧集', '/trending/tv/week'],
      ['全球高分剧集', '/tv/top_rated']
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
      if (items.length) live.rankings[3] = ['Trakt 热门剧集', items];
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
  const rows = live.rankings.map(([name, items], index) => `<section class="module"><div class="head"><h2>${esc(name)}</h2><p>TMDB · 实时数据</p><button class="ranking-more" data-live-more="${index}">更多</button></div><div class="rankrow">${cards(items.slice(0, 8))}</div></section>`).join('');
  const feature = live.rankings[1]?.[1]?.[0];
  app.innerHTML = shell(`<section class="hero live-hero" style="--live-backdrop:url('https://image.tmdb.org/t/p/original${feature?.backdrop_path || ''}')"><div class="meta"><b>实时榜单</b>　TMDB / Trakt</div><h1>${esc(feature?.title || feature?.name || '发现新片')}</h1><p>${esc(feature?.overview || '已连接真实影视发现数据。')}</p><div class="actions"><button class="primary" data-live-detail="${feature?.id}" data-kind="${feature?.title ? 'movie' : 'tv'}">查看详情</button><button class="secondary" data-sync-discovery>刷新榜单</button></div></section><main class="content">${rows}</main>`, 'home');
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

async function showLiveDetail(id) {
  const item = live.rankings?.flatMap(group => group[1]).find(entry => String(entry.id) === String(id));
  if (!item) return;
  const title = item.title || item.name;
  const backdrop = item.backdrop_path ? `https://image.tmdb.org/t/p/original${item.backdrop_path}` : '';
  app.innerHTML = shell(`<main class="detail live-detail" style="background-image:linear-gradient(90deg,#080a0df5 0,#080a0de2 48%,#080a0d70 82%),url('${backdrop}')"><button class="back" data-go="home">← 返回首页</button><h1>${esc(title)}</h1><div class="meta">TMDB ${(item.vote_average || 0).toFixed(1)} · ${esc(item.release_date || item.first_air_date || '日期未知')}</div><p class="desc">${esc(item.overview || 'TMDB 暂无中文简介。')}</p><section class="sources"><div class="page-heading compact"><div><h2>我的 Emby 资源</h2><p>正在聚合所有已连接服务器中的同名资源。</p></div></div><div data-live-sources><div class="empty">正在搜索…</div></div></section></main>`, 'home');
  const target = document.querySelector('[data-live-sources]');
  try {
    const groups = await Promise.all((providerConfig.emby || []).map(async server => {
      const token = await window.yingjiDesktop.getSecret(`emby-${server.id}`);
      const data = await request(`${server.url}/Users/${server.userId}/Items?Recursive=true&IncludeItemTypes=Movie,Episode&SearchTerm=${encodeURIComponent(title)}&Fields=Overview,ProviderIds,MediaSources&Limit=20`, { headers: embyHeaders(token) });
      return (data.Items || []).map(found => ({ ...found, server, token }));
    }));
    const matches = groups.flat();
    matches.forEach(match => live.library.push(match));
    target.innerHTML = matches.length ? matches.map(match => `<div class="source"><div><b>${esc(match.Name)}</b><br><small>${esc(match.server.name)}</small></div><span>${esc(match.MediaSources?.[0]?.VideoType || 'Emby')}</span><span>${match.MediaSources?.[0]?.SupportsDirectPlay === false ? '转码' : '直连'}</span><button class="primary" data-emby-play="${live.library.indexOf(match)}">播放</button></div>`).join('') : '<div class="empty">所有服务器中暂未找到该影片。</div>';
  } catch (error) { target.innerHTML = `<div class="error-state"><b>资源搜索失败</b><span>${esc(error.message)}</span></div>`; }
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
  const target = event.target.closest('[data-sync-discovery],[data-load-library],[data-emby-play],[data-live-detail],[data-live-more],[data-trakt-auth],[data-sync-calendar]');
  if (!target) return;
  if (target.hasAttribute('data-sync-discovery')) syncDiscovery();
  if (target.hasAttribute('data-load-library')) loadLibrary();
  if (target.dataset.embyPlay !== undefined) playEmby(live.library[Number(target.dataset.embyPlay)]).catch(error => notify(`播放失败：${error.message}`));
  if (target.dataset.liveDetail !== undefined) showLiveDetail(target.dataset.liveDetail);
  if (target.dataset.liveMore !== undefined) showLiveRanking(target.dataset.liveMore);
  if (target.hasAttribute('data-trakt-auth')) authorizeTrakt();
  if (target.hasAttribute('data-sync-calendar')) syncTraktCalendar();
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
