import test from 'node:test';
import assert from 'node:assert/strict';
import { handleRatings, parseRatings, fetchSameOrigin } from './ratings.mjs';
import worker, { parseRatings as bundledParseRatings } from './worker.mjs';

test('same-origin redirect succeeds with manual mode and preserves headers', async () => {
  let calls = 0;
  const response = await fetchSameOrigin('https://api.example.com/item/', {
    headers: { Authorization: 'Bearer test-secret' },
  }, async (url, options) => {
    assert.equal(options.redirect, 'manual');
    assert.equal(options.headers.Authorization, 'Bearer test-secret');
    calls++;
    if (calls === 1) return new Response(null, { status: 301, headers: { Location: '/item' } });
    assert.equal(url.pathname, '/item');
    return Response.json({ ok: true });
  });
  assert.equal(response.status, 200);
  assert.equal(calls, 2);
});

test('redirect never sends credentials to another origin or insecure HTTP', async () => {
  for (const location of ['https://other.example.com/', 'http://api.example.com/']) {
    let calls = 0;
    await assert.rejects(fetchSameOrigin('https://api.example.com/', {}, async () => {
      calls++;
      return new Response(null, { status: 302, headers: { Location: location } });
    }), /redirect_rejected/);
    assert.equal(calls, 1);
  }
});

test('redirect loops stop after three hops', async () => {
  let calls = 0;
  await assert.rejects(fetchSameOrigin('https://api.example.com/', {}, async () => {
    calls++;
    return new Response(null, { status: 307, headers: { Location: '/' } });
  }), /redirect_limit/);
  assert.equal(calls, 4);
});

test('single-file worker preserves health, preflight and route guards', async () => {
  for (const [path, method, status] of [
    ['/health', 'GET', 200], ['/tmdb/tv/1396', 'OPTIONS', 200],
    ['/tmdb/tv/1396', 'POST', 405], ['/unknown', 'GET', 404],
    ['/ratings/tv/1396', 'GET', 503],
  ]) {
    const response = await worker.fetch(new Request(`https://example.com${path}`, { method }), {});
    assert.equal(response.status, status);
    assert.equal(response.headers.get('Access-Control-Allow-Origin'), '*');
  }
  const data = { ratings: [{ source: 'popcorn', value: 81 }] };
  assert.deepEqual(bundledParseRatings(data), parseRatings(data));
});

test('single-file worker retains TMDB forwarding and cached replies', async () => {
  const originalFetch = globalThis.fetch;
  const originalCaches = globalThis.caches;
  let saved;
  let calls = 0;
  globalThis.caches = { default: {
    match: async () => saved?.clone(),
    put: async (_key, response) => { saved = response; },
  } };
  globalThis.fetch = async (url, options) => {
    calls++;
    assert.equal(url.pathname, '/3/tv/1396');
    assert.equal(url.searchParams.get('language'), 'zh-CN');
    assert.equal(options.headers.Authorization, 'Bearer test-token');
    return Response.json({ id: 1396 });
  };
  try {
    const request = new Request('https://example.com/tmdb/tv/1396');
    assert.deepEqual(await (await worker.fetch(request, { TMDB_TOKEN: 'test-token' })).json(), { id: 1396 });
    assert.deepEqual(await (await worker.fetch(request, { TMDB_TOKEN: 'test-token' })).json(), { id: 1396 });
    assert.equal(calls, 1);
  } finally {
    globalThis.fetch = originalFetch;
    globalThis.caches = originalCaches;
  }
});

test('all returned sources, zero and native values survive; missing values do not', () => {
  const rows = parseRatings({ ratings: [
    { source: 'imdb', value: 8.2, score: 82 },
    { source: 'tomatoes', value: 0 },
    { source: 'popcorn', value: 96 },
    { source: 'future_source', value: '4.1' },
    { source: 'missing', value: null },
    { source: 'invalid', value: 'N/A' },
  ] });
  assert.deepEqual(rows.map(r => [r.source, r.value]), [
    ['imdb', 8.2], ['tomatoes', 0], ['popcorn', 96], ['future_source', 4.1],
  ]);
});

test('TMDB TV identity maps to show; credentials stay out of response and cache key', async () => {
  let stored;
  const response = await handleRatings(new Request('https://example.com/ratings/tv/1396'),
    { MDBList: 'test-secret' }, null, {
      fetcher: async url => {
        assert.equal(url.pathname, '/tmdb/show/1396/');
        assert.equal(url.searchParams.get('apikey'), 'test-secret');
        return Response.json({ ratings: [{ source: 'imdb', value: 9.5 }] });
      },
      cache: { match: async () => null, put: async (key, value) => { stored = key.url; await value.text(); } },
    });
  assert.equal(response.status, 200);
  assert.equal(stored, 'https://example.com/ratings/tv/1396');
  assert.ok(!(await response.text()).includes('test-secret'));
});

test('missing secret, bad path and upstream failures are safe and not cached', async () => {
  const request = new Request('https://example.com/ratings/movie/550');
  assert.equal((await handleRatings(request, {}, null)).status, 503);
  assert.equal((await handleRatings(new Request('https://example.com/ratings/any/550'), {}, null)).status, 400);
  const response = await handleRatings(request, { MDBList: 'test-secret' }, null, {
    fetcher: async () => { throw new Error('test-secret'); },
  });
  assert.equal(response.status, 503);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.ok(!(await response.text()).includes('test-secret'));
});

test('cache hit does not consume another upstream request', async () => {
  const response = await handleRatings(new Request('https://example.com/ratings/movie/550'),
    { MDBList: 'test-secret' }, null, {
      fetcher: async () => { assert.fail('must use cache'); },
      cache: { match: async () => Response.json({ ratings: [] }) },
    });
  assert.equal(response.status, 200);
});
