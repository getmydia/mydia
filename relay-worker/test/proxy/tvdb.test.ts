import { env, SELF, fetchMock } from "cloudflare:test";
import { describe, it, expect, beforeAll, afterEach } from "vitest";

beforeAll(async () => {
  fetchMock.activate();
  fetchMock.disableNetConnect();
  // Pre-seed a valid token so route tests do not each need a login interceptor.
  await env.CACHE_KV.put(
    "tvdb:jwt",
    JSON.stringify({
      token: "test-token",
      exp: Math.floor(Date.now() / 1000) + 20 * 86400,
    }),
  );
});

afterEach(() => fetchMock.assertNoPendingInterceptors());

describe("TVDB routes", () => {
  it("sends the stored JWT as a bearer token", async () => {
    let sawAuth: string | undefined;
    fetchMock
      .get("https://api4.thetvdb.com")
      .intercept({
        method: "GET",
        path: (p) => p.startsWith("/v4/series/331753"),
        headers: (h) => {
          sawAuth = h["authorization"];
          return true;
        },
      })
      .reply(200, { data: { id: 331753 } });

    const res = await SELF.fetch("https://relay.mydia.dev/tvdb/series/331753");

    expect(res.status).toBe(200);
    expect(await res.json<{ data: { id: number } }>()).toMatchObject({
      data: { id: 331753 },
    });
    expect(sawAuth).toBe("Bearer test-token");
  });

  it("routes the extended variant to the extended upstream path", async () => {
    let seenPath = "";
    fetchMock
      .get("https://api4.thetvdb.com")
      .intercept({
        method: "GET",
        path: (p) => {
          seenPath = p;
          return p.includes("/v4/series/1/extended");
        },
      })
      .reply(200, { data: {} });

    await SELF.fetch("https://relay.mydia.dev/tvdb/series/1/extended");
    expect(seenPath).toContain("/v4/series/1/extended");
  });

  // metadata_relay/tvdb/handler.ex's get_series_episodes/2 reads `page`
  // (default 0) out of the params map and bakes it into the path as
  // .../episodes/default/page/N — it is not simply /series/{id}/episodes,
  // and the naive `/series/{id}/episodes/default` mapping this route is easy
  // to write silently drops the page segment TVDB requires.
  it("maps the episodes route to the paginated default-season upstream path", async () => {
    let seenPath = "";
    fetchMock
      .get("https://api4.thetvdb.com")
      .intercept({
        method: "GET",
        path: (p) => {
          seenPath = p;
          return p.startsWith("/v4/series/81189/episodes/default/page/");
        },
      })
      .reply(200, { data: { episodes: [] } });

    await SELF.fetch(
      "https://relay.mydia.dev/tvdb/series/81189/episodes?page=2",
    );

    expect(seenPath).toBe("/v4/series/81189/episodes/default/page/2");
  });

  it("defaults the episodes page to 0 when the caller sends none", async () => {
    let seenPath = "";
    fetchMock
      .get("https://api4.thetvdb.com")
      .intercept({
        method: "GET",
        path: (p) => {
          seenPath = p;
          return p.startsWith("/v4/series/81189/episodes/default/page/");
        },
      })
      .reply(200, { data: { episodes: [] } });

    await SELF.fetch("https://relay.mydia.dev/tvdb/series/81189/episodes");

    expect(seenPath).toBe("/v4/series/81189/episodes/default/page/0");
  });

  // handler.ex's plain lookups (get_series/2, get_season/2, get_episode/2,
  // get_artwork/2) declare `_params \\ []` and call Client.get(path) with no
  // :params option at all, so nothing forwards upstream. Only the *_extended
  // handlers and search pass `params: params` through. A caller-supplied
  // query string on a plain route must not leak into the upstream request.
  it("does not forward query params on the plain series route", async () => {
    let seenPath = "";
    fetchMock
      .get("https://api4.thetvdb.com")
      .intercept({
        method: "GET",
        path: (p) => {
          seenPath = p;
          return p.startsWith("/v4/series/2");
        },
      })
      .reply(200, { data: {} });

    await SELF.fetch("https://relay.mydia.dev/tvdb/series/2?foo=bar");

    expect(seenPath).toBe("/v4/series/2");
  });

  it("forwards query params on the extended route", async () => {
    let seenPath = "";
    fetchMock
      .get("https://api4.thetvdb.com")
      .intercept({
        method: "GET",
        path: (p) => {
          seenPath = p;
          return p.startsWith("/v4/series/3/extended");
        },
      })
      .reply(200, { data: {} });

    await SELF.fetch(
      "https://relay.mydia.dev/tvdb/series/3/extended?meta=translations",
    );

    expect(seenPath).toContain("meta=translations");
  });

  it("maps a login failure to 502 rather than passing it off as a metadata error", async () => {
    await env.CACHE_KV.delete("tvdb:jwt");
    fetchMock
      .get("https://api4.thetvdb.com")
      .intercept({ method: "POST", path: "/v4/login" })
      .reply(401, { message: "unauthorized" });

    const res = await SELF.fetch("https://relay.mydia.dev/tvdb/series/999");

    expect(res.status).toBe(502);
    expect(await res.json<{ error: string }>()).toMatchObject({
      error: "TVDB authentication failed",
    });
  });
});
