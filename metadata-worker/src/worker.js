export default {
  async fetch(request, env) {
    const incoming = new URL(request.url);
    const headers = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'GET,OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type' };
    if (request.method === 'OPTIONS') return new Response(null, { headers });
    if (request.method !== 'GET') return new Response('Method not allowed', { status: 405, headers });
    if (incoming.pathname === '/health') return Response.json({ ok: true }, { headers });
    if (!incoming.pathname.startsWith('/tmdb/')) return new Response('Not found', { status: 404, headers });
    const upstream = new URL(`https://api.themoviedb.org/3/${incoming.pathname.slice(6)}`);
    incoming.searchParams.forEach((value, key) => upstream.searchParams.set(key, value));
    if (!upstream.searchParams.has('language')) upstream.searchParams.set('language', 'zh-CN');
    const cached = await caches.default.match(upstream.href);
    if (cached) return new Response(cached.body, { status: cached.status, headers: { ...Object.fromEntries(cached.headers), ...headers } });
    const response = await fetch(upstream, { headers: { Authorization: `Bearer ${env.TMDB_TOKEN}`, Accept: 'application/json' } });
    const outgoing = new Response(response.body, { status: response.status, headers: { 'Content-Type': 'application/json', 'Cache-Control': response.ok ? 'public, max-age=1800' : 'no-store', ...headers } });
    if (response.ok) await caches.default.put(upstream.href, outgoing.clone());
    return outgoing;
  }
};
