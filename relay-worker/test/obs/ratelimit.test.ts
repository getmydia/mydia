import { env, SELF, fetchMock, applyD1Migrations } from "cloudflare:test";
import { describe, it, expect, beforeAll, vi } from "vitest";
import { serviceFromPath } from "../../src/obs/log";
import { isExemptFromProxyLimit } from "../../src/obs/ratelimit";

describe("serviceFromPath", () => {
  it("labels each proxied upstream", () => {
    expect(serviceFromPath("/tmdb/movies/550")).toBe("tmdb");
    expect(serviceFromPath("/tvdb/series/1")).toBe("tvdb");
    expect(serviceFromPath("/music/artist/x")).toBe("music");
    expect(serviceFromPath("/openlibrary/search")).toBe("openlibrary");
    expect(serviceFromPath("/api/v1/subtitles/search")).toBe("subdl");
  });

  it("returns null for routes that are not a proxied upstream", () => {
    expect(serviceFromPath("/health")).toBeNull();
    expect(serviceFromPath("/pairing/claim")).toBeNull();
    expect(serviceFromPath("/crashes/report")).toBeNull();
  });
});

// PROXY_LIMITER is limit: 25, period: 60 UNDER TEST, set by
// vitest.config.ts's miniflare.ratelimits override. Production is 300/60s
// (wrangler.jsonc) and is untouched by that override -- this constant must
// track the TEST value, since it is what the loops below actually spend.
//
// Why the test value is not the production one: nothing in Miniflare can
// spend a rate-limit budget except real requests, so proving a 429 costs
// `limit + 1` round trips through the whole Hono stack, and this file needs
// that four times over. At 300 the file took ~17s locally and blew the 30s
// per-test timeout on CI hardware, failing the deploy job on master
// (2026-09-06). None of these tests assert anything about the SIZE of the
// budget -- they assert that exceeding it produces a 429, with the right
// header, logged in the right order, and not charged to exempt paths. All of
// that holds at 25 exactly as it did at 300, in a fortieth of the requests.
//
// Miniflare's own rate-limit simulator resets its whole counter on wall-clock
// time, not on consumption --
// node_modules/miniflare/dist/src/workers/ratelimit/ratelimit.worker.js:
//   let epoch = Math.floor(Date.now() / (period * 1e3));
//   epoch != this.epoch && (this.epoch = epoch, this.buckets.clear());
// If a real 60s boundary falls in the middle of one of the loops below, the
// in-flight count is wiped to zero and up to another full `limit` requests
// are needed to trip the 429 again -- observed as "expected 500 to be 429"
// (the loop exhausts with the route's own, unthrottled response) at roughly
// once in four to six full-suite runs, in two independent review sessions.
// It's a property of the local simulator, not the Worker: production rate
// limiting is Cloudflare's real service, not this fixed-window-per-process
// approximation.
//
// The smaller budget shrinks that flake too, without being a fix for it: a
// loop that spans ~26 requests occupies a few tens of milliseconds instead of
// seconds, so the odds of a 60s boundary landing inside one drop by roughly
// the same factor the runtime does. The window is narrower, not closed.
//
// So the cap below stays. It survives exactly one reset wherever in the loop
// it lands: up to `limit - 1` requests before the reset, then a full
// `limit + 1` after it. `if (last.status === 429) break` means an ordinary
// run (no reset) still exits after ~26 iterations -- only a run that hits the
// reset pays the extra ones. Do not shrink this toward `limit` because "26
// was fine before"; that reasoning is exactly what shipped the flake, and it
// is no more true at 25 than it was at 300.
const PROXY_LIMIT = 25;
const PROXY_LIMIT_ITERATION_CAP = 2 * PROXY_LIMIT + 10;

describe("rate limiting", () => {
  beforeAll(async () => {
    fetchMock.activate();
    fetchMock.disableNetConnect();

    // "does not charge pairing against the proxy budget" below drives real
    // requests through /pairing/claim/:code, which is now D1-backed (Task
    // 10). Without migrating this file's own isolated storage first, every
    // one of those requests throws "SQLITE_ERROR: no such table:
    // pairing_claims" to stderr -- the assertion still passes (it only
    // checks the sibling /tmdb call), but the noise drowns out real errors.
    await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  });

  it(
    "returns 429 with a Retry-After header once the budget is spent",
    async () => {
      // Explicit timeout below (not Vitest's 5000ms default): the rare
      // mid-loop reset case runs up to PROXY_LIMIT_ITERATION_CAP iterations
      // rather than the usual ~301, and needs the room.
      let last: Response | undefined;
      for (let i = 0; i < PROXY_LIMIT_ITERATION_CAP; i++) {
        last = await SELF.fetch("https://relay.mydia.dev/tmdb/genre/movie", {
          headers: { "cf-connecting-ip": "203.0.113.9" },
        });
        if (last.status === 429) break;
      }

      expect(last!.status).toBe(429);
      expect(last!.headers.get("retry-after")).toBe("60");
      // Exact parity with metadata-relay/lib/metadata_relay/plug/proxy_rate_limit.ex's
      // send_resp(429, Jason.encode!(%{error: "Too many requests", message: "..."})) --
      // NOT router.ex's separate send_rate_limited/2 helper, which uses a
      // differently-cased "rate_limited" error string for pairing/feedback/crash
      // routes. This is the one the proxy limiter itself uses.
      const body = await last!.json<{ error: string; message: string }>();
      expect(body).toMatchObject({
        error: "Too many requests",
        message: "Rate limit exceeded. Please try again later.",
      });
    },
    30000,
  );

  it("logs the final 429 status, not whatever status the route produced before the throttle overwrote it", async () => {
    // Up to PROXY_LIMIT_ITERATION_CAP iterations (see that constant's
    // comment above) against a real fetchMock and a spied console.log run
    // noticeably slower once other heavy loops in this same file have
    // already run in the same worker instance -- comfortably under a second
    // alone, but into double digits back-to-back with its siblings. Not a
    // hang: bumping the timeout is enough (see the isolated per-test timing
    // versus the full-file timing checked while writing this test).
    //
    // Hono composes middleware as an onion: whichever of rateLimitMiddleware
    // and the logging middleware is registered SECOND runs as the INNER
    // layer, closer to the route. If the logging middleware is inner, its
    // `await next()` returns -- and it reads c.res.status -- before control
    // unwinds back out to rateLimitMiddleware, which only then overwrites
    // c.res with the 429. That logs the route's pre-throttle status instead
    // of what the client actually received. Spying on console.log (rather
    // than matching a substring) and parsing the JSON line guards against a
    // regression that happens to still contain "429" somewhere.
    const logSpy = vi.spyOn(console, "log");

    let last: Response | undefined;
    for (let i = 0; i < PROXY_LIMIT_ITERATION_CAP; i++) {
      last = await SELF.fetch("https://relay.mydia.dev/tmdb/genre/movie", {
        headers: { "cf-connecting-ip": "203.0.113.20" },
      });
      if (last.status === 429) break;
    }
    expect(last!.status).toBe(429);

    const lastCall = logSpy.mock.calls.at(-1);
    expect(lastCall).toBeDefined();
    const logged = JSON.parse(lastCall![0] as string) as {
      service: string;
      path: string;
      status: number;
      cache: string;
    };
    expect(logged.status).toBe(429);

    logSpy.mockRestore();
  }, 30000);

  it("does not throttle /health, which monitoring polls", async () => {
    for (let i = 0; i < 50; i++) {
      const res = await SELF.fetch("https://relay.mydia.dev/health", {
        headers: { "cf-connecting-ip": "203.0.113.10" },
      });
      expect(res.status).toBe(200);
    }
  });

  it("does not charge pairing against the proxy budget", async () => {
    // Pairing has its own 10/min and 30/min limiters. Charging both would let
    // an ordinary pairing flow exhaust the metadata budget for the same IP.
    for (let i = 0; i < 40; i++) {
      await SELF.fetch("https://relay.mydia.dev/pairing/claim/NOPE", {
        headers: { "cf-connecting-ip": "203.0.113.11" },
      });
    }

    const res = await SELF.fetch("https://relay.mydia.dev/tmdb/genre/tv", {
      headers: { "cf-connecting-ip": "203.0.113.11" },
    });
    expect(res.status).not.toBe(429);
  });

  // Final-review CRITICAL: the middleware used to call `await next()` --
  // running the real handler and its real upstream fetch() -- BEFORE
  // checking the limiter, only swapping in a 429 afterward. That shape
  // cannot prevent the thing this limiter exists to prevent: probed at 320
  // cache-busted requests from one IP, all 320 (including the 20 that got a
  // 429 back) still produced a real upstream call. Worst for
  // /api/v1/subtitles/search, whose SubDL key carries a shared 2000/day
  // allowance a sustained flood could exhaust in minutes.
  //
  // Registers exactly one interceptor for a path this specific throttled
  // request would hit if (and only if) the handler ran, with a path matcher
  // that flags whether it was ever even evaluated -- a real outbound fetch
  // attempt is the only thing that causes undici's MockAgent to consult a
  // registered interceptor for that origin at all. Deliberately does NOT use
  // fetchMock.assertNoPendingInterceptors() here: that assertion is designed
  // to catch an interceptor nobody used (useful in afterEach elsewhere in
  // this codebase), which is exactly what a CORRECT fix produces in this
  // specific test -- calling it here would assert the wrong direction.
  //
  // Exhausts the budget by calling env.PROXY_LIMITER directly, with the same
  // key the middleware itself derives, rather than looping real HTTP
  // requests through the Worker -- the latter would need up to
  // PROXY_LIMIT_ITERATION_CAP real, unmocked upstream fetch attempts (each
  // one hitting the exact "check runs after next()" hole this test exists to
  // close, pre-fix) just to reach the interesting part of this test, which
  // both defeats the point and reintroduces this file's own documented
  // wall-clock flake risk for no reason -- this test only needs the budget
  // to already read as spent, not to reach that state through the route.
  it("performs NO upstream fetch for a request the limiter throttles, because the check now runs before next()", async () => {
    const ip = "203.0.113.30";

    for (let i = 0; i < PROXY_LIMIT; i++) {
      await env.PROXY_LIMITER.limit({ key: `proxy:${ip}` });
    }

    let upstreamFetchAttempted = false;
    fetchMock
      .get("https://api.themoviedb.org")
      .intercept({
        method: "GET",
        path: (p) => {
          upstreamFetchAttempted = true;
          return p.startsWith("/3/genre/tv");
        },
      })
      .reply(200, { genres: [] });

    const throttled = await SELF.fetch("https://relay.mydia.dev/tmdb/genre/tv", {
      headers: { "cf-connecting-ip": ip },
    });

    expect(throttled.status).toBe(429);
    expect(upstreamFetchAttempted).toBe(false);
  });
});

// Regression coverage for the maintainer dashboards' move from bare /errors
// and /feedback to /admin/errors and /admin/feedback: isExemptFromProxyLimit
// has to be updated in lockstep with any dashboard path change, or dashboard
// reads silently start counting against the shared 300/min proxy budget
// meant to protect upstream provider quota. Deliberately a direct unit test
// of the pure predicate, not an integration test driving ~300+ real
// SELF.fetch() calls to approach PROXY_LIMITER's actual threshold: an
// earlier version of this test did exactly that (320 iterations against
// /admin/errors), and empirically made the wall-clock-dependent flake this
// file's other tests already document (see PROXY_LIMIT_ITERATION_CAP's
// comment above) measurably worse -- 2 of 2 runs with that loop present
// failed on an unrelated heavy-loop test in this same file, versus 0 of 3
// immediately before/after with it removed. Testing the decision function
// directly gets equivalent coverage of the actual regression (a path falling
// out of the exempt list) in microseconds, with no shared mutable rate-limit
// state and no wall-clock dependency at all.
describe("isExemptFromProxyLimit", () => {
  it("exempts both maintainer dashboards under /admin/*", () => {
    expect(isExemptFromProxyLimit("/admin/errors")).toBe(true);
    expect(isExemptFromProxyLimit("/admin/errors/somefingerprint")).toBe(true);
    expect(isExemptFromProxyLimit("/admin/feedback")).toBe(true);
    expect(isExemptFromProxyLimit("/admin/feedback/some-id/state")).toBe(true);
  });

  it("exempts the public feedback ingest path, but not by prefix collision with /admin/feedback", () => {
    expect(isExemptFromProxyLimit("/feedback")).toBe(true);
    // A prefix check on "/feedback" must never accidentally match
    // "/admin/feedback" -- confirmed here by the fact that /admin/feedback
    // is exempt via the SEPARATE "/admin/" prefix in the test above, not
    // this one; this test only asserts the bare ingest path itself.
  });

  it("exempts pairing and crash ingest", () => {
    expect(isExemptFromProxyLimit("/pairing/claim")).toBe(true);
    expect(isExemptFromProxyLimit("/crashes/report")).toBe(true);
  });

  it("exempts /health and /stats exactly, not by prefix", () => {
    expect(isExemptFromProxyLimit("/health")).toBe(true);
    expect(isExemptFromProxyLimit("/stats")).toBe(true);
    // /health and /stats are EXACT matches (a Set), not prefixes -- a path
    // that merely starts with one must still be charged against the budget.
    expect(isExemptFromProxyLimit("/healthcheck")).toBe(false);
  });

  it("does not exempt real proxy/metadata routes", () => {
    expect(isExemptFromProxyLimit("/tmdb/genre/movie")).toBe(false);
    expect(isExemptFromProxyLimit("/tvdb/search")).toBe(false);
    expect(isExemptFromProxyLimit("/music/search")).toBe(false);
    expect(isExemptFromProxyLimit("/api/v1/subtitles/search")).toBe(false);
  });

  // The literal regression this whole test exists to catch: before the
  // dashboards moved, this list read "/errors" (bare), which is what a
  // revert -- accidental or otherwise -- would reintroduce.
  it("does not exempt the old, pre-move dashboard paths", () => {
    expect(isExemptFromProxyLimit("/errors")).toBe(false);
  });
});
