import type { MiddlewareHandler } from "hono";
import type { Env } from "../env";

// Paths that are never throttled here. /health and /stats are polled by
// deployed monitoring, and throttling those would turn a busy relay into an
// apparently dead one.
const EXEMPT = new Set(["/health", "/stats"]);

// Prefixes that carry their own, tighter limiter and must not also be charged
// against the 300/min proxy budget. Pairing uses 10/min create and 30/min
// read; feedback uses feedback/ingest.ts's checkFeedbackRateLimit (5/hour by
// IP and by instance id, a D1-backed mirror of router.ex's
// handle_feedback/1); crashes uses crashes/ingest.ts's own per-hour
// write-bounding. Charging any of these against the proxy budget too would
// let a normal flow exhaust that budget for the same IP and break metadata
// for that install.
//
// "/feedback" here is deliberately the bare public POST ingest path only --
// it does NOT match "/admin/feedback" (a prefix check is a literal string
// match; "/admin/feedback" does not start with "/feedback"), so it has no
// bearing on the dashboard below.
//
// "/admin/" covers both maintainer dashboards (dashboards/errors.ts,
// dashboards/feedback.ts, and any future /admin/* route by construction --
// see dashboards/layout.ts). These proxy nothing upstream -- they only read
// or write D1 -- so charging them against a budget that exists to protect
// shared upstream provider quota (TMDB/TVDB/etc.) wouldn't serve this
// limiter's purpose even before considering that they're Access-gated,
// low-volume maintainer traffic. This is a relocation of the exemption that
// used to be spelled out as "/errors" (bare) before both dashboards moved
// under /admin/*, not new behaviour.
const EXEMPT_PREFIXES = ["/pairing/", "/crashes/", "/feedback", "/admin/"];

// Exported so this decision is unit-testable directly, on bare path strings,
// rather than only observable by driving several hundred real requests
// through SELF.fetch() to approach PROXY_LIMITER's actual 300/min threshold
// -- test/obs/ratelimit.test.ts's other tests already need PROXY_LIMIT
// _ITERATION_CAP-sized loops for THAT limiter's own behaviour, and that
// file's own extensive comments document a real, wall-clock-dependent flake
// in miniflare's rate-limit simulator. A prefix-matching predicate needs
// none of that: it is pure, and testing it directly costs microseconds
// instead of a few hundred HTTP+D1 round trips, without weakening coverage
// of the actual regression this guards (an exempt path silently falling out
// of this list, e.g. when a dashboard's route moves).
export function isExemptFromProxyLimit(path: string): boolean {
  if (EXEMPT.has(path)) return true;
  return EXEMPT_PREFIXES.some((prefix) => path.startsWith(prefix));
}

// Final-review fix round: checked BEFORE `next()`, not after. The original
// shape here called `await next()` first -- running the real handler and its
// real upstream `fetch()` to TMDB/TVDB/SubDL/MusicBrainz/OpenLibrary -- and
// only THEN checked the limiter, swapping in a 429 after the fact. That is a
// halting-Plug-pipeline shape (the Elixir this ports is Cache then
// ProxyRateLimit then the handler, so a throttled request never reaches the
// code that calls upstream) that the check-after shape cannot actually
// replicate: probed at 320 cache-busted requests from one IP, all 320 -
// including the 20 that got a 429 back - still produced a real upstream
// call. That defeated the limiter's entire purpose, worst for
// /api/v1/subtitles/search, whose SubDL key carries a shared 2000/day
// allowance a sustained flood could exhaust in minutes.
//
// Checking first means a cache HIT is now also charged against the budget --
// this endpoint used to inspect x-relay-cache after the fact specifically to
// exempt hits, on the theory that a cache hit costs no upstream quota and
// throttling one buys nothing. That's still true in isolation, but knowing a
// request will hit cache requires either running it (defeating the point) or
// probing the cache a second time from inside this middleware (a duplicate
// lookup on every single request, to save nothing on the common path). Given
// that choice, this accepts the stricter, fail-closed direction: a bulk
// "refresh all metadata" pass that would previously have been served
// entirely from cache can now consume rate-limit budget it didn't before
// (recorded in README.md's "what this migration changed"). Protecting
// upstream quota -- this limiter's actual purpose -- only works if the check
// runs before the fetch that spends that quota, not after.
export function rateLimitMiddleware(): MiddlewareHandler<{ Bindings: Env }> {
  return async (c, next) => {
    const path = new URL(c.req.url).pathname;
    if (isExemptFromProxyLimit(path)) return next();

    const ip = c.req.header("cf-connecting-ip") ?? "unknown";
    const { success } = await c.env.PROXY_LIMITER.limit({ key: `proxy:${ip}` });

    if (!success) {
      // Exact parity with metadata_relay/plug/proxy_rate_limit.ex's enforce/1:
      // {"error": "Too many requests", "message": "Rate limit exceeded. Please
      // try again later."}, retry-after 60 (window_ms / 1000). This is
      // deliberately NOT router.ex's separate send_rate_limited/2 helper (used
      // by pairing/feedback/crash-report routes), which answers with a
      // differently-cased "rate_limited" error string -- the two are
      // different limiters in the Elixir codebase with different response
      // bodies, and this one replaces ProxyRateLimit specifically.
      c.res = new Response(
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
      return;
    }

    await next();
  };
}
