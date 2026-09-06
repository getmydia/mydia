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
});
