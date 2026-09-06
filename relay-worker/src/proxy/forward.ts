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
    if (key in inject) continue;
    out.append(key, value);
  }
  for (const [key, value] of Object.entries(inject)) {
    out.append(key, value);
  }
  return out;
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

  const res = new Response(body, {
    status: upstream.status,
    headers: {
      "content-type":
        upstream.headers.get("content-type") ?? "application/json",
      // Real edge-cacheable headers. The Elixir relay sent
      // "max-age=0, private, must-revalidate", which is why Cloudflare
      // reported cf-cache-status: DYNAMIC on every route and nothing was
      // ever cached at the edge.
      "cache-control": cacheableHeader(cacheKey),
    },
  });

  // Only successful responses are cached, matching plug/cache.ex.
  if (upstream.status >= 200 && upstream.status < 300) {
    await cachePut(env, cacheKey, res.clone());
  }

  res.headers.set("x-relay-cache", "MISS");
  return res;
}

function cacheableHeader(cacheKey: string): string {
  const ttl = ttlSecondsFor(cacheKey);
  return `public, s-maxage=${ttl}, stale-while-revalidate=86400, stale-if-error=604800`;
}
