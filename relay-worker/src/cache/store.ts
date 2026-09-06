import type { Env } from "../env";
import { ttlSecondsFor } from "./key";

// Mirrors filter_headers/1 in plug/cache.ex. content-disposition is here
// because a cached response that drops it changes how the client handles the
// body, and keeping it means a future file-serving route stays correct.
export const CACHED_HEADER_ALLOWLIST = [
  "content-type",
  "content-disposition",
  "cache-control",
  "etag",
] as const;

export function filterHeaders(headers: Headers): Headers {
  const out = new Headers();
  for (const name of CACHED_HEADER_ALLOWLIST) {
    const value = headers.get(name);
    if (value !== null) out.set(name, value);
  }
  return out;
}

// The Cache API is URL-keyed, so a logical key becomes a synthetic URL on a
// reserved host that never resolves. Encoding keeps a key containing "/" or
// "?" from splitting into path and query.
//
// Exported so passthrough.ts can address the same edge-cache entries with its
// own binary-safe get/put: cachePut below always round-trips the body through
// `.text()`, which corrupts a JPEG (or anything else that isn't valid UTF-8)
// on the way back out, so the music cover art route cannot reuse cacheGet/
// cachePut and instead talks to `caches.default` directly, keyed the same way.
export function cacheUrl(key: string): string {
  return `https://cache.invalid/${encodeURIComponent(key)}`;
}

interface StoredEntry {
  status: number;
  headers: [string, string][];
  body: string;
}

export async function cacheGet(
  env: Env,
  key: string,
  opts: { kv?: boolean } = {},
): Promise<Response | null> {
  const edge = await caches.default.match(cacheUrl(key));
  // A Response read back from the Cache API has immutable headers. Every
  // caller of cacheGet eventually wants to stamp something onto the
  // response it gets back (x-relay-cache today, more later), so return a
  // fresh Response here rather than letting each call site discover the
  // "Can't modify immutable headers" TypeError on its own.
  if (edge) return new Response(edge.body, edge);

  if (!opts.kv) return null;

  const stored = await env.CACHE_KV.get<StoredEntry>(key, "json");
  if (!stored) return null;

  return new Response(stored.body, {
    status: stored.status,
    headers: new Headers(stored.headers),
  });
}

export async function cachePut(
  env: Env,
  key: string,
  res: Response,
  opts: { ttlSeconds?: number; kv?: boolean } = {},
): Promise<void> {
  const ttlSeconds = opts.ttlSeconds ?? ttlSecondsFor(key);
  const body = await res.clone().text();
  const headers = filterHeaders(res.headers);

  // Edge copy: fast, per-PoP, evictable. This is the whole cache for every
  // route except SubDL search.
  const edgeHeaders = new Headers(headers);
  edgeHeaders.set("cache-control", `public, max-age=${ttlSeconds}`);
  await caches.default.put(
    cacheUrl(key),
    new Response(body, { status: res.status, headers: edgeHeaders }),
  );

  if (!opts.kv) return;

  // KV copy, opt-in. Only SubDL search asks for this: it spends a shared key
  // with a 2000/day allowance, and a per-PoP cache would let each PoP spend it
  // separately. Nothing else has a reason to pay for a second tier.
  const entry: StoredEntry = {
    status: res.status,
    headers: [...headers.entries()],
    body,
  };
  await env.CACHE_KV.put(key, JSON.stringify(entry), {
    expirationTtl: Math.max(ttlSeconds, 60),
  });
}
