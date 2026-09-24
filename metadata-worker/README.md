# MDBList ratings route

This module is not deployed yet. It extends the existing TMDB Worker without replacing its routes.

For Cloudflare's browser editor, use the complete contents of `worker.mjs` (no Markdown fences). This single-file version includes the existing `/health` and `/tmdb/` routes supplied by the maintainer and the ratings handler. Keep a copy of the current deployed version before replacing it. Existing secrets remain `TMDB_TOKEN` and `MDBList`.

The Cloudflare secret is named **MDBList** (case sensitive). Never put its value in source control or a client build.

## Trakt browser authorization

The Worker also owns Trakt OAuth code/token exchange at `/trakt/oauth/token` and Android device-code exchange at `/trakt/oauth/device/*`. Configure these Worker environment values before deploying:

- `TRAKT_CLIENT_ID`: Mova's public Trakt application ID (Text variable).
- `TRAKT_CLIENT_SECRET`: Mova's Trakt application secret (Secret; never add to source control or the client build).

Register `http://127.0.0.1:43829/trakt/callback` as the exact Redirect URI in the Mova Trakt API app. In Cloudflare, open **Workers & Pages → yingji-metadata → Settings → Variables and Secrets**, add the values above, then deploy the Worker. End users only authorize in the browser; Mova stores their individual access/refresh tokens locally. Token responses are not cached.

The Worker source in `worker.mjs` is the self-contained editor version and preserves the health, TMDB, ratings, discovery, and Trakt discovery routes. Add a Cloudflare rate-limiting rule for `/trakt/oauth/*` before public rollout to limit abuse of the shared OAuth proxy.

In the existing module Worker, import `handleRatings` from `./ratings.mjs`, accept the `ctx` argument in `fetch(request, env, ctx)`, and before the existing route dispatch add:

```js
const ratingsResponse = await handleRatings(request, env, ctx);
if (ratingsResponse) return ratingsResponse;
```

Endpoints: `/ratings/movie/{tmdbId}` and `/ratings/tv/{tmdbId}`. All returned rating sources are retained. `value` is the provider's native value; `score` is separate and must not replace it. Null ratings are omitted; actual zero ratings are retained. Missing configuration and upstream failures return safe errors without upstream URLs or credentials.

Successful responses are cached for six hours (empty results for fifteen minutes). Cloudflare Cache API is per data center, not a global quota limiter. Before public rollout, configure an appropriate request budget/rate limit and confirm provider redistribution/caching terms. No public rollout is implied by these local files.

Run `node --test metadata-worker/ratings.test.mjs` from the repository root.
