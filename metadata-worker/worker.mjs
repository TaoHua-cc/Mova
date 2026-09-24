// Integrate with the existing Worker before its /tmdb/ route.
// Only the server reads env.MDBList; neither responses nor cache keys contain it.
export function parseRatings(data) {
  const ratings = new Map();
  for (const row of Array.isArray(data?.ratings) ? data.ratings : []) {
    if (typeof row?.source !== 'string' || !row.source.trim()) continue;
    const raw = row.value;
    if (raw == null || raw === '' || typeof raw === 'boolean') continue;
    const value = typeof raw === 'number' ? raw : Number(raw);
    if (!Number.isFinite(value) || value < 0) continue;
    // A real zero is valid (e.g. 0% approval); null is missing, not zero.
    const source = row.source.trim().toLowerCase();
    const score = typeof row.score === 'number' && Number.isFinite(row.score)
      ? row.score : null;
    const votes = typeof row.votes === 'number' && row.votes >= 0
      ? row.votes : null;
    ratings.set(source, { source, value, score, votes });
  }
  return [...ratings.values()];
}

export async function fetchSameOrigin(input, options, fetcher = fetch) {
  let url = new URL(input);
  const origin = url.origin;
  for (let redirects = 0; redirects <= 3; redirects++) {
    const response = await fetcher(url, { ...options, redirect: 'manual' });
    if (![301, 302, 303, 307, 308].includes(response.status)) return response;
    const location = response.headers.get('Location');
    await response.body?.cancel();
    if (!location || redirects === 3) throw new Error('redirect_limit');
    const next = new URL(location, url);
    if (next.protocol !== 'https:' || next.origin !== origin || next.username || next.password) {
      throw new Error('redirect_rejected');
    }
    url = next;
  }
}

function safeFailure(error) {
  const message = String(error?.message ?? '');
  if (/redirect/i.test(message)) return 'redirect_rejected';
  if (/illegal invocation|receiver|this binding/i.test(message)) return 'runtime_binding';
  if (/timeout|abort/i.test(message) || error?.name === 'TimeoutError') return 'timeout';
  if (/not a function|not defined/i.test(message)) return 'runtime_api';
  return 'network_or_runtime';
}

const pending = new Map();
const headers = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
  'Content-Type': 'application/json; charset=utf-8',
};
const json = (body, status = 200, ttl = 0) => new Response(JSON.stringify(body), {
  status,
  headers: { ...headers, 'Cache-Control': ttl ? `public, max-age=${ttl}` : 'no-store' },
});

export async function handleRatings(request, env, ctx, {
  fetcher = fetch,
  cache = globalThis.caches?.default,
} = {}) {
  const url = new URL(request.url);
  if (!url.pathname.startsWith('/ratings/')) return null;
  if (request.method === 'OPTIONS') return new Response(null, { headers });
  if (request.method !== 'GET') return json({ error: 'method_not_allowed' }, 405);
  const match = /^\/ratings\/(movie|tv)\/([1-9]\d{0,9})\/?$/.exec(url.pathname);
  if (!match || url.search) return json({ error: 'invalid_rating_request' }, 400);
  if (typeof env.MDBList !== 'string' || !env.MDBList.trim()) {
    return json({ error: 'ratings_not_configured' }, 503);
  }
  const [, type, id] = match;
  const cacheKey = new Request(`${url.origin}/ratings/${type}/${id}`);
  const cached = cache ? await cache.match(cacheKey) : null;
  if (cached) return cached;
  const key = cacheKey.url;
  if (!pending.has(key)) {
    pending.set(key, (async () => {
      try {
        const upstream = new URL(`https://api.mdblist.com/tmdb/${type === 'tv' ? 'show' : 'movie'}/${id}/`);
        upstream.searchParams.set('apikey', env.MDBList.trim());
        const response = await fetchSameOrigin(upstream, {
          headers: { Accept: 'application/json' },
          signal: AbortSignal.timeout(8000),
        }, fetcher);
        if (!response.ok) {
          return json({ error: response.status === 429 ? 'ratings_rate_limited' : 'ratings_unavailable', upstreamStatus: response.status }, 503);
        }
        const data = await response.json();
        if (!Array.isArray(data?.ratings)) return json({ error: 'ratings_invalid_response' }, 502);
        const ratings = parseRatings(data);
        const result = json({
          provider: 'MDBList', type, tmdbId: Number(id),
          fetchedAt: new Date().toISOString(), ratings,
        }, 200, ratings.length ? 21600 : 900);
        if (cache) {
          const write = cache.put(cacheKey, result.clone()).catch(() => {});
          if (ctx?.waitUntil) ctx.waitUntil(write);
          else await write;
        }
        return result;
      } catch (error) {
        // Never return an upstream error/URL: it can contain the API key.
        return json({ error: 'ratings_unavailable', reason: safeFailure(error) }, 503);
      }
    })());
  }
  try { return (await pending.get(key)).clone(); }
  finally { pending.delete(key); }
}

const officialLists = new Set([
  'anticipated', 'justwatch-streaming-charts', 'most-watched',
  'most-watched-week', 'moviemeter', 'popular', 'streaming-charts', 'trending',
]);

export async function handleDiscovery(request, env, ctx, {
  fetcher = fetch,
  cache = globalThis.caches?.default,
} = {}) {
  const url = new URL(request.url);
  if (!url.pathname.startsWith('/discover/mdblist/')) return null;
  if (request.method === 'OPTIONS') return new Response(null, { headers });
  if (request.method !== 'GET') return json({ error: 'method_not_allowed' }, 405);
  const match = /^\/discover\/mdblist\/(movie|tv)\/([a-z-]+)\/?$/.exec(url.pathname);
  const page = Number(url.searchParams.get('page') ?? '1');
  const country = (url.searchParams.get('country') ?? 'all').toUpperCase();
  if (!match || !officialLists.has(match[2]) || !Number.isInteger(page) || page < 1 || page > 50 ||
      !/^(ALL|[A-Z]{2})$/.test(country)) {
    return json({ error: 'invalid_discovery_request' }, 400);
  }
  if (typeof env.MDBList !== 'string' || !env.MDBList.trim()) {
    return json({ error: 'discovery_not_configured' }, 503);
  }
  const [, type, list] = match;
  const cacheKey = new Request(`${url.origin}${url.pathname}?page=${page}&country=${country}`);
  const cached = cache ? await cache.match(cacheKey) : null;
  if (cached) return cached;
  try {
    const upstream = new URL(`https://api.mdblist.com/lists/official/${type === 'tv' ? 'shows' : 'movies'}/${list}/items`);
    upstream.searchParams.set('apikey', env.MDBList.trim());
    upstream.searchParams.set('mediatype', type === 'tv' ? 'show' : 'movie');
    if (country === 'ALL') upstream.searchParams.set('extended', 'ids_only');
    // Fetch enough rows to apply the country filter without exposing MDBList data.
    upstream.searchParams.set('limit', country === 'ALL' ? '20' : '250');
    upstream.searchParams.set('offset', `${(page - 1) * (country === 'ALL' ? 20 : 250)}`);
    const response = await fetchSameOrigin(upstream, {
      headers: { Accept: 'application/json' },
      signal: AbortSignal.timeout(10000),
    }, fetcher);
    if (!response.ok) {
      return json({ error: response.status === 429 ? 'discovery_rate_limited' : 'discovery_unavailable', upstreamStatus: response.status }, 503);
    }
    const data = await response.json();
    const bucket = type === 'tv' ? data?.shows : data?.movies;
    if (!Array.isArray(bucket)) return json({ error: 'discovery_invalid_response' }, 502);
    const results = [];
    for (const row of bucket) {
      if (country !== 'ALL' && String(row?.country ?? '').toUpperCase() !== country) continue;
      const tmdbId = Number(row?.ids?.tmdb ?? row?.tmdb_id);
      if (Number.isInteger(tmdbId) && tmdbId > 0 && !results.some(item => item.tmdbId === tmdbId)) {
        results.push({ tmdbId, mediaType: type });
      }
      if (results.length === 20) break;
    }
    const result = json({ provider: 'MDBList', type, list, page, results }, 200, 1800);
    if (cache) {
      const write = cache.put(cacheKey, result.clone()).catch(() => {});
      if (ctx?.waitUntil) ctx.waitUntil(write);
      else await write;
    }
    return result;
  } catch (error) {
    return json({ error: 'discovery_unavailable', reason: safeFailure(error) }, 503);
  }
}

const traktLists = new Set([
  'anticipated', 'boxoffice', 'collected', 'played', 'popular', 'trending', 'watched',
]);

const traktRedirectUri = 'http://127.0.0.1:43829/trakt/callback';

/** Keep Trakt's private OAuth secret on the Worker, never in the desktop app. */
export async function handleTraktOAuth(request, env, {
  fetcher = fetch,
} = {}) {
  const url = new URL(request.url);
  if (!url.pathname.startsWith('/trakt/oauth/')) return null;
  if (request.method === 'OPTIONS') return new Response(null, { headers });
  if (typeof env.TRAKT_CLIENT_ID !== 'string' || !env.TRAKT_CLIENT_ID.trim() ||
      typeof env.TRAKT_CLIENT_SECRET !== 'string' || !env.TRAKT_CLIENT_SECRET.trim()) {
    return json({ error: 'trakt_oauth_not_configured' }, 503);
  }
  if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const isDeviceCode = url.pathname === '/trakt/oauth/device/code';
  const isDeviceToken = url.pathname === '/trakt/oauth/device/token';
  if (!isDeviceCode && !isDeviceToken && url.pathname !== '/trakt/oauth/token') {
    return json({ error: 'not_found' }, 404);
  }
  let body;
  try {
    const raw = await request.text();
    if (raw.length > 8192) return json({ error: 'invalid_trakt_oauth_request' }, 413);
    body = JSON.parse(raw);
  } catch {
    return json({ error: 'invalid_trakt_oauth_request' }, 400);
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return json({ error: 'invalid_trakt_oauth_request' }, 400);
  }

  let endpoint;
  let payload;
  if (isDeviceCode) {
    endpoint = 'https://api.trakt.tv/oauth/device/code';
    payload = { client_id: env.TRAKT_CLIENT_ID.trim() };
  } else if (isDeviceToken) {
    if (typeof body.code !== 'string' || !/^[\w-]{4,256}$/.test(body.code)) {
      return json({ error: 'invalid_trakt_oauth_request' }, 400);
    }
    endpoint = 'https://api.trakt.tv/oauth/device/token';
    payload = {
      code: body.code,
      client_id: env.TRAKT_CLIENT_ID.trim(),
      client_secret: env.TRAKT_CLIENT_SECRET.trim(),
    };
  } else {
    if (body.grant_type === 'authorization_code') {
      if (typeof body.code !== 'string' || !/^[\w-]{8,1024}$/.test(body.code) ||
          body.redirect_uri !== traktRedirectUri) {
        return json({ error: 'invalid_trakt_oauth_request' }, 400);
      }
      payload = {
        code: body.code,
        grant_type: 'authorization_code',
        redirect_uri: traktRedirectUri,
      };
    } else if (body.grant_type === 'refresh_token' &&
        typeof body.refresh_token === 'string' && body.refresh_token.length >= 8 &&
        body.refresh_token.length <= 4096) {
      payload = { grant_type: 'refresh_token', refresh_token: body.refresh_token };
    } else {
      return json({ error: 'invalid_trakt_oauth_request' }, 400);
    }
    endpoint = 'https://auth.trakt.tv/oauth/token';
    payload.client_id = env.TRAKT_CLIENT_ID.trim();
    payload.client_secret = env.TRAKT_CLIENT_SECRET.trim();
    payload.redirect_uri ??= traktRedirectUri;
  }

  try {
    const response = await fetcher(endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'trakt-api-version': '2',
        'trakt-api-key': env.TRAKT_CLIENT_ID.trim(),
        Accept: 'application/json',
      },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(10000),
    });
    const responseBody = await response.text();
    // Trakt OAuth errors may include request details; return only a safe status.
    if (!response.ok) {
      return json({ error: 'trakt_oauth_failed', upstreamStatus: response.status }, response.status === 400 ? 400 : 503);
    }
    let data;
    try { data = JSON.parse(responseBody); } catch { return json({ error: 'trakt_oauth_invalid_response' }, 502); }
    return json(data);
  } catch (error) {
    return json({ error: 'trakt_oauth_unavailable', reason: safeFailure(error) }, 503);
  }
}

export async function handleTraktDiscovery(request, _env, ctx, {
  fetcher = fetch,
  cache = globalThis.caches?.default,
} = {}) {
  const url = new URL(request.url);
  if (!url.pathname.startsWith('/discover/trakt/')) return null;
  if (request.method === 'OPTIONS') return new Response(null, { headers });
  if (request.method !== 'GET') return json({ error: 'method_not_allowed' }, 405);
  const match = /^\/discover\/trakt\/(movies|shows)\/([a-z]+)\/?$/.exec(url.pathname);
  const page = Number(url.searchParams.get('page') ?? '1');
  if (!match || !traktLists.has(match[2]) || !Number.isInteger(page) || page < 1 || page > 100) {
    return json({ error: 'invalid_trakt_request' }, 400);
  }
  if (match[1] === 'shows' && match[2] === 'boxoffice') {
    return json({ error: 'invalid_trakt_request' }, 400);
  }
  const clientId = request.headers.get('trakt-api-key')?.trim();
  if (!clientId) return json({ error: 'trakt_not_configured' }, 503);
  const [, type, list] = match;
  const cacheKey = new Request(`${url.origin}${url.pathname}?page=${page}`);
  const cached = cache ? await cache.match(cacheKey) : null;
  if (cached) return cached;
  try {
    const upstream = new URL(`https://api.trakt.tv/${type}/${list}`);
    upstream.searchParams.set('page', `${page}`);
    upstream.searchParams.set('limit', '20');
    upstream.searchParams.set('extended', 'full');
    if (['watched', 'played', 'collected'].includes(list)) {
      upstream.searchParams.set('period', 'weekly');
    }
    const response = await fetchSameOrigin(upstream, {
      headers: {
        'trakt-api-version': '2',
        'trakt-api-key': clientId,
        Accept: 'application/json',
      },
      signal: AbortSignal.timeout(10000),
    }, fetcher);
    if (!response.ok) {
      return json({ error: 'trakt_unavailable', upstreamStatus: response.status }, 503);
    }
    const data = await response.json();
    if (!Array.isArray(data)) return json({ error: 'trakt_invalid_response' }, 502);
    const result = json(data, 200, 900);
    if (cache) {
      const write = cache.put(cacheKey, result.clone()).catch(() => {});
      if (ctx?.waitUntil) ctx.waitUntil(write);
      else await write;
    }
    return result;
  } catch (error) {
    return json({ error: 'trakt_unavailable', reason: safeFailure(error) }, 503);
  }
}

function decodeHtml(value) {
  return value
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replace(/&#(\d+);/g, (_, code) => String.fromCodePoint(Number(code)));
}

export async function handleDoubanDiscovery(request, _env, ctx, {
  fetcher = fetch,
  cache = globalThis.caches?.default,
} = {}) {
  const url = new URL(request.url);
  if (!url.pathname.startsWith('/discover/douban/')) return null;
  if (request.method === 'OPTIONS') return new Response(null, { headers });
  if (request.method !== 'GET') return json({ error: 'method_not_allowed' }, 405);
  const match = /^\/discover\/douban\/movie\/(chart|top250)\/?$/.exec(url.pathname);
  const page = Number(url.searchParams.get('page') ?? '1');
  if (!match || !Number.isInteger(page) || page < 1 || page > 10 || (match[1] === 'chart' && page !== 1)) {
    return json({ error: 'invalid_douban_request' }, 400);
  }
  const list = match[1];
  const cacheKey = new Request(`${url.origin}${url.pathname}?page=${page}`);
  const cached = cache ? await cache.match(cacheKey) : null;
  if (cached) return cached;
  try {
    const upstream = new URL(list === 'top250'
      ? `https://movie.douban.com/top250?start=${(page - 1) * 25}&filter=`
      : 'https://movie.douban.com/chart');
    const response = await fetchSameOrigin(upstream, {
      headers: { Accept: 'text/html', 'User-Agent': 'Mozilla/5.0 (compatible; Mova/3)' },
      signal: AbortSignal.timeout(10000),
    }, fetcher);
    if (!response.ok) return json({ error: 'douban_unavailable', upstreamStatus: response.status }, 503);
    const html = await response.text();
    const results = [];
    const seen = new Set();
    for (const match of html.matchAll(/class=["']nbg["'][^>]*title=["']([^"']+)["']/gi)) {
      const title = decodeHtml(match[1]).trim();
      if (title && !seen.has(title)) {
        seen.add(title);
        results.push({ title, mediaType: 'movie' });
      }
    }
    if (!results.length) return json({ error: 'douban_invalid_response' }, 502);
    const result = json({ provider: '豆瓣公开榜单', type: 'movie', list, page, results }, 200, 3600);
    if (cache) {
      const write = cache.put(cacheKey, result.clone()).catch(() => {});
      if (ctx?.waitUntil) ctx.waitUntil(write);
      else await write;
    }
    return result;
  } catch (error) {
    return json({ error: 'douban_unavailable', reason: safeFailure(error) }, 503);
  }
}

export default {
  async fetch(request, env, ctx) {
    const incoming = new URL(request.url);
    const cors = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    };
    if (request.method === 'OPTIONS') return new Response(null, { headers: cors });
    if (incoming.pathname.startsWith('/trakt/oauth/')) {
      const traktOAuthResponse = await handleTraktOAuth(request, env);
      if (traktOAuthResponse) return traktOAuthResponse;
    }
    if (request.method !== 'GET') return new Response('Method not allowed', { status: 405, headers: cors });
    if (incoming.pathname === '/health') return Response.json({ ok: true }, { headers: cors });
    const ratingResponse = await handleRatings(request, env, ctx);
    if (ratingResponse) return ratingResponse;
    const discoveryResponse = await handleDiscovery(request, env, ctx);
    if (discoveryResponse) return discoveryResponse;
    const traktResponse = await handleTraktDiscovery(request, env, ctx);
    if (traktResponse) return traktResponse;
    const doubanResponse = await handleDoubanDiscovery(request, env, ctx);
    if (doubanResponse) return doubanResponse;
    if (!incoming.pathname.startsWith('/tmdb/')) return new Response('Not found', { status: 404, headers: cors });

    const upstream = new URL(`https://api.themoviedb.org/3/${incoming.pathname.slice(6)}`);
    incoming.searchParams.forEach((value, key) => upstream.searchParams.set(key, value));
    if (!upstream.searchParams.has('language')) upstream.searchParams.set('language', 'zh-CN');
    const cached = await caches.default.match(upstream.href);
    if (cached) return new Response(cached.body, {
      status: cached.status,
      headers: { ...Object.fromEntries(cached.headers), ...cors },
    });
    try {
      const response = await fetchSameOrigin(upstream, {
        headers: { Authorization: `Bearer ${env.TMDB_TOKEN}`, Accept: 'application/json' },
        signal: AbortSignal.timeout(12000),
      });
      const outgoing = new Response(response.body, {
        status: response.status,
        headers: {
          'Content-Type': 'application/json',
          'Cache-Control': response.ok ? 'public, max-age=1800' : 'no-store',
          ...cors,
        },
      });
      if (response.ok) {
        const write = caches.default.put(upstream.href, outgoing.clone()).catch(() => {});
        if (ctx?.waitUntil) ctx.waitUntil(write);
        else await write;
      }
      return outgoing;
    } catch (error) {
      return Response.json({ error: 'tmdb_unavailable', reason: safeFailure(error) }, { status: 502, headers: cors });
    }
  },
};
