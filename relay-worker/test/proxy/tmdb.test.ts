import { SELF, fetchMock } from "cloudflare:test";
import { describe, it, expect, beforeAll, afterEach } from "vitest";

beforeAll(() => {
  fetchMock.activate();
  fetchMock.disableNetConnect();
});

afterEach(() => fetchMock.assertNoPendingInterceptors());

describe("TMDB routes", () => {
  it("proxies movie details and injects the key", async () => {
    fetchMock
      .get("https://api.themoviedb.org")
      .intercept({
        method: "GET",
        path: (p) => p.startsWith("/3/movie/550") && p.includes("api_key="),
      })
      .reply(200, { id: 550, title: "Fictional Film" });

    const res = await SELF.fetch("https://relay.mydia.dev/tmdb/movies/550");

    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ id: 550 });
  });

  it("passes append_to_response through untouched", async () => {
    let seenPath = "";
    fetchMock
      .get("https://api.themoviedb.org")
      .intercept({
        method: "GET",
        path: (p) => {
          seenPath = p;
          return p.startsWith("/3/movie/551");
        },
      })
      .reply(200, { id: 551 });

    await SELF.fetch(
      "https://relay.mydia.dev/tmdb/movies/551?append_to_response=credits,release_dates",
    );

    expect(seenPath).toContain("append_to_response=credits%2Crelease_dates");
  });

  it("emits an edge-cacheable cache-control header, not private no-store", async () => {
    fetchMock
      .get("https://api.themoviedb.org")
      .intercept({ method: "GET", path: (p) => p.startsWith("/3/configuration") })
      .reply(200, { images: {} });

    const res = await SELF.fetch("https://relay.mydia.dev/configuration");
    const cc = res.headers.get("cache-control") ?? "";

    expect(cc).toContain("public");
    expect(cc).toContain("s-maxage=");
    expect(cc).toContain("stale-if-error=");
    expect(cc).not.toContain("private");
  });

  it("serves the second identical request from cache without a second upstream call", async () => {
    fetchMock
      .get("https://api.themoviedb.org")
      .intercept({ method: "GET", path: (p) => p.startsWith("/3/movie/552") })
      .reply(200, { id: 552 });

    const first = await SELF.fetch("https://relay.mydia.dev/tmdb/movies/552");
    expect(first.headers.get("x-relay-cache")).toBe("MISS");

    // Only one interceptor was registered, so a second upstream call would
    // throw rather than silently succeeding.
    const second = await SELF.fetch("https://relay.mydia.dev/tmdb/movies/552");
    expect(second.headers.get("x-relay-cache")).toBe("HIT");
    expect(await second.json()).toMatchObject({ id: 552 });
  });

  // cachePut was already limited to 2xx, but the cache-control header went out
  // on every status. An explicit freshness lifetime is what MAKES an otherwise
  // uncacheable status cacheable, so a transient upstream 500 would be
  // replayed by Cloudflare's edge and every downstream client for the whole
  // TTL, and stale-if-error would license reusing it for a further week.
  it("sends no-store rather than a cacheable header on an upstream error", async () => {
    fetchMock
      .get("https://api.themoviedb.org")
      .intercept({ method: "GET", path: (p) => p.startsWith("/3/movie/553") })
      .reply(500, { status_message: "upstream is having a day" });

    const res = await SELF.fetch("https://relay.mydia.dev/tmdb/movies/553");

    expect(res.status).toBe(500);
    expect(res.headers.get("cache-control")).toBe("no-store");
  });

  it("sends no-store on an upstream 404 too, so a miss is not cached for the TTL", async () => {
    fetchMock
      .get("https://api.themoviedb.org")
      .intercept({ method: "GET", path: (p) => p.startsWith("/3/movie/554") })
      .reply(404, { status_message: "The resource you requested could not be found." });

    const res = await SELF.fetch("https://relay.mydia.dev/tmdb/movies/554");

    expect(res.status).toBe(404);
    expect(res.headers.get("cache-control")).toBe("no-store");
  });

  // Hono percent-decodes path params, so `%2e%2e%2f` arrives as `../`. Without
  // encoding, interpolating that into `${TMDB_BASE}/movie/${p.id}` lets the
  // caller pick which TMDB endpoint the relay's own API key is spent on --
  // a confused deputy, not SSRF: the host stays fixed, the path does not.
  it("encodes a traversal attempt in :id instead of resolving it upstream", async () => {
    let seenPath = "";
    fetchMock
      .get("https://api.themoviedb.org")
      .intercept({
        method: "GET",
        path: (p) => {
          seenPath = p;
          return true;
        },
      })
      .reply(200, {});

    await SELF.fetch(
      "https://relay.mydia.dev/tmdb/movies/%2e%2e%2f%2e%2e%2fauthentication",
    );

    expect(seenPath.startsWith("/3/movie/")).toBe(true);
    expect(seenPath).not.toContain("/3/authentication");
    expect(seenPath).not.toContain("../");
  });

  it("encodes a query-splicing attempt in :id", async () => {
    let seenPath = "";
    fetchMock
      .get("https://api.themoviedb.org")
      .intercept({
        method: "GET",
        path: (p) => {
          seenPath = p;
          return true;
        },
      })
      .reply(200, {});

    await SELF.fetch("https://relay.mydia.dev/tmdb/movies/550%3Fapi_key%3Dstolen");

    expect(seenPath.startsWith("/3/movie/550%3F")).toBe(true);
  });
});
