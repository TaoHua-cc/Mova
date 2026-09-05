# MDBList ratings route

This module is not deployed yet. It extends the existing TMDB Worker without replacing its routes.

For Cloudflare's browser editor, use the complete contents of `worker.mjs` (no Markdown fences). This single-file version includes the existing `/health` and `/tmdb/` routes supplied by the maintainer and the ratings handler. Keep a copy of the current deployed version before replacing it. Existing secrets remain `TMDB_TOKEN` and `MDBList`.

The Cloudflare secret is named **MDBList** (case sensitive). Never put its value in source control or a client build.

In the existing module Worker, import `handleRatings` from `./ratings.mjs`, accept the `ctx` argument in `fetch(request, env, ctx)`, and before the existing route dispatch add:

```js
const ratingsResponse = await handleRatings(request, env, ctx);
if (ratingsResponse) return ratingsResponse;
```

Endpoints: `/ratings/movie/{tmdbId}` and `/ratings/tv/{tmdbId}`. All returned rating sources are retained. `value` is the provider's native value; `score` is separate and must not replace it. Null ratings are omitted; actual zero ratings are retained. Missing configuration and upstream failures return safe errors without upstream URLs or credentials.

Successful responses are cached for six hours (empty results for fifteen minutes). Cloudflare Cache API is per data center, not a global quota limiter. Before public rollout, configure an appropriate request budget/rate limit and confirm provider redistribution/caching terms. No public rollout is implied by these local files.

Run `node --test metadata-worker/ratings.test.mjs` from the repository root.
