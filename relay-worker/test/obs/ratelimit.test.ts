import { env, SELF, fetchMock, applyD1Migrations } from "cloudflare:test";
import { describe, it, expect, beforeAll, vi } from "vitest";
import { serviceFromPath } from "../../src/obs/log";

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

// PROXY_LIMITER is limit: 300, period: 60 (wrangler.jsonc). Miniflare's own
// rate-limit simulator resets its whole counter on wall-clock time, not on
// consumption -- node_modules/miniflare/dist/src/workers/ratelimit/ratelimit.worker.js:
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
// The cap below (2 * limit + margin) survives exactly one such reset,
// wherever in the loop it lands: up to `limit - 1` requests before the
// reset, then a full `limit + 1` after it. `if (last.status === 429) break`
// means an ordinary run (no reset) still exits after ~301 iterations, same
// as before -- only a run that hits the reset pays the extra iterations.
// This does not eliminate the flake (two resets in one loop would still
// lose), it makes the common single-reset case survivable by construction.
// Do not shrink this back toward `limit` because "305 was fine before" --
// that reasoning is exactly what shipped the flake.
const PROXY_LIMIT = 300;
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
});
