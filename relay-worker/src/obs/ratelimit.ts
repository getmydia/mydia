import type { Context } from "hono";
import type { Env } from "../env";

// Per-client-IP budgets on upstream calls, charged at the one point a request
// is about to spend upstream quota: after its cache lookup missed, before its
// fetch(). That is the Elixir relay's order too (Cache, then ProxyRateLimit,
// then the handler), so a cache hit never counts and a throttled request never
// reaches TMDB, TVDB, SubDL, MusicBrainz or OpenLibrary.
//
// This used to be a middleware that charged every request before the handler
// ran, cache hits included, because a middleware cannot know whether the
// handler's cache lookup will hit. Shadowing production traffic from
// 2026-09-18 to 2026-09-21 showed the cost: at 300/min it would have answered
// 32% of TVDB requests with a 429 that the Elixir relay served. One install's
// library scan peaked at 2,487 requests/min and three others reached
// 890-1,230/min. A hit comes back from the edge in milliseconds, so charging
// hits throttled re-scans of already cached libraries hardest, and those cost
// upstream nothing.
//
// Routes that never call upstream (health, stats, client-config, pairing,
// crash and feedback ingest, the dashboards) never get here, so there is no
// exemption list to keep in sync. Pairing, crashes and feedback carry their
// own limiters.
//
// Two budgets, so a metadata scan and a subtitle flood cannot spend each
// other's:
// - PROXY_LIMITER: TMDB, TVDB, MusicBrainz, Cover Art Archive, OpenLibrary.
//   Sized at about twice the highest scan rate measured above.
// - SUBTITLE_LIMITER: SubDL search and download. Kept at the old 300/min,
//   because SubDL's key has one 2000/day allowance for every install.
export type UpstreamLimiter = "PROXY_LIMITER" | "SUBTITLE_LIMITER";

// Returns the 429 to send, or null when the request may go upstream.
export async function throttleUpstream(
  c: Context<{ Bindings: Env }>,
  limiter: UpstreamLimiter,
): Promise<Response | null> {
  const ip = c.req.header("cf-connecting-ip") ?? "unknown";
  const { success } = await c.env[limiter].limit({ key: `proxy:${ip}` });
  if (success) return null;

  // Exact parity with metadata_relay/plug/proxy_rate_limit.ex's enforce/1,
  // retry-after included (window_ms / 1000). Deliberately NOT router.ex's
  // send_rate_limited/2, whose "rate_limited" body belongs to the pairing,
  // feedback and crash-report limiters.
  return new Response(
    JSON.stringify({
      error: "Too many requests",
      message: "Rate limit exceeded. Please try again later.",
    }),
    {
      status: 429,
      headers: {
        "content-type": "application/json",
        "retry-after": "60",
      },
    },
  );
}
