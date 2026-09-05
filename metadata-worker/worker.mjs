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
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
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

export default {
  async fetch(request, env, ctx) {
    const incoming = new URL(request.url);
    const cors = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    };
    if (request.method === 'OPTIONS') return new Response(null, { headers: cors });
    if (request.method !== 'GET') return new Response('Method not allowed', { status: 405, headers: cors });
    if (incoming.pathname === '/health') return Response.json({ ok: true }, { headers: cors });
    const ratingResponse = await handleRatings(request, env, ctx);
    if (ratingResponse) return ratingResponse;
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
