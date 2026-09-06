import type { Env } from "../env";
import { cacheGet, cachePut } from "../cache/store";
import { ttlSecondsFor } from "../cache/key";

// No allowlist, deliberately. TMDB handlers forward caller params straight
// through, which is the only reason append_to_response works for credits,
// keywords, images, videos, recommendations, release_dates and
// content_ratings. Adding an allowlist here silently breaks enrichment.
export function forwardParams(
  incoming: URLSearchParams,
  inject: Record<string, string>,
): URLSearchParams {
  const out = new URLSearchParams();
  for (const [key, value] of incoming.entries()) {
    if (Object.hasOwn(inject, key)) continue;
    out.append(key, value);
  }
  for (const [key, value] of Object.entries(inject)) {
    out.append(key, value);
  }
  return out;
}

// Every caller-supplied value interpolated into an upstream PATH goes through
// this. Hono hands `c.req.param()` values back already percent-decoded, so a
// request for `/tmdb/movies/%2e%2e%2f%2e%2e%2fauthentication` arrives as the
// literal `../../authentication` in `p.id`; interpolated raw into
// `${TMDB_BASE}/movie/${p.id}`, the URL parser then resolves those segments
// and the relay issues an authenticated request to a path the caller chose,
// with the relay's own API key attached. The host is fixed, so this is not
// SSRF -- it is a confused deputy: the caller cannot reach a new server, but
// it can reach a different endpoint on the one the relay holds credentials
// for. `?`, `#` and `;` in a segment are the same class of problem, splicing
// query or parameters into a path the caller was not supposed to control.
//
// encodeURIComponent, not encodeURI: encodeURI deliberately leaves `/`, `?`
// and `#` intact, which is exactly the set that has to be escaped here.
export function pathSegment(value: string): string {
  return encodeURIComponent(value);
}

export async function proxyJson(
  env: Env,
  upstreamUrl: string,
  cacheKey: string,
  init?: RequestInit,
): Promise<Response> {
  const hit = await cacheGet(env, cacheKey);
  if (hit) {
    // A Response read back from the Cache API has immutable headers, so
    // `hit.headers.set(...)` throws "Can't modify immutable headers." Build a
    // fresh Response around the same body/status/headers to get a mutable
    // Headers instance before stamping the cache-status header.
    const res = new Response(hit.body, hit);
    res.headers.set("x-relay-cache", "HIT");
    return res;
  }

  const upstream = await fetch(upstreamUrl, init);
  const body = await upstream.text();
  const ok = upstream.status >= 200 && upstream.status < 300;

  const res = new Response(body, {
    status: upstream.status,
    headers: {
      "content-type":
        upstream.headers.get("content-type") ?? "application/json",
      // Real edge-cacheable headers. The Elixir relay sent
      // "max-age=0, private, must-revalidate", which is why Cloudflare
      // reported cf-cache-status: DYNAMIC on every route and nothing was
      // ever cached at the edge.
      "cache-control": cacheableHeader(cacheKey, ok),
    },
  });

  // Only successful responses are cached, matching plug/cache.ex.
  if (ok) {
    await cachePut(env, cacheKey, res.clone());
  }

  res.headers.set("x-relay-cache", "MISS");
  return res;
}

// The `ok` split is what stops this header from outliving the relay's own
// caching decision. cachePut above is already limited to 2xx, but the header
// went out on every response regardless -- including an upstream 404, 429,
// 500 or 502 -- and the header is what Cloudflare's edge cache and every
// downstream client obey. Giving an explicit freshness lifetime to a status
// that is otherwise uncacheable is what makes it cacheable: one transient
// TMDB or TVDB failure would then be replayed for the whole TTL, and
// `stale-if-error=604800` would license reusing it for a further week, from a
// cache the relay does not own and cannot purge.
//
// `no-store` rather than `no-cache`: `no-cache` still permits storing the
// response and revalidating, which is a distinction no client here needs and
// leaves the error body sitting in intermediary caches.
function cacheableHeader(cacheKey: string, ok: boolean): string {
  if (!ok) return "no-store";
  const ttl = ttlSecondsFor(cacheKey);
  return `public, s-maxage=${ttl}, stale-while-revalidate=86400, stale-if-error=604800`;
}
