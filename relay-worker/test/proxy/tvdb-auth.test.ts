import { env, fetchMock } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { parseJwtExpiry, getTvdbToken } from "../../src/proxy/tvdb-auth";

beforeAll(() => {
  fetchMock.activate();
  fetchMock.disableNetConnect();
});

function makeJwt(expUnixSeconds: number): string {
  const payload = btoa(JSON.stringify({ exp: expUnixSeconds }))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  return `header.${payload}.signature`;
}

describe("parseJwtExpiry", () => {
  it("reads exp from the payload", () => {
    const exp = Math.floor(Date.now() / 1000) + 12345;
    expect(parseJwtExpiry(makeJwt(exp))).toBe(exp);
  });

  it("falls back to 30 days when the token is not a JWT", () => {
    const now = Math.floor(Date.now() / 1000);
    const got = parseJwtExpiry("not-a-jwt");
    expect(got).toBeGreaterThan(now + 29 * 86400);
    expect(got).toBeLessThanOrEqual(now + 30 * 86400 + 5);
  });

  it("falls back to 30 days when the payload has no exp", () => {
    const now = Math.floor(Date.now() / 1000);
    const noExp = `header.${btoa(JSON.stringify({ sub: "x" })).replace(/=+$/, "")}.sig`;
    expect(parseJwtExpiry(noExp)).toBeGreaterThan(now + 29 * 86400);
  });
});

describe("getTvdbToken", () => {
  it("logs in when KV holds no token, and stores what it got", async () => {
    const exp = Math.floor(Date.now() / 1000) + 30 * 86400;
    const token = makeJwt(exp);

    fetchMock
      .get("https://api4.thetvdb.com")
      .intercept({ method: "POST", path: "/v4/login" })
      .reply(200, { data: { token } });

    const got = await getTvdbToken({ ...env, TVDB_API_KEY: "key" } as never);

    expect(got).toBe(token);
    const stored = await env.CACHE_KV.get("tvdb:jwt", "json");
    expect(stored).toMatchObject({ token });
  });

  it("reuses a stored token that is not near expiry, with no login call", async () => {
    const exp = Math.floor(Date.now() / 1000) + 20 * 86400;
    await env.CACHE_KV.put(
      "tvdb:jwt",
      JSON.stringify({ token: "stored-token", exp }),
    );

    // No interceptor registered: a login attempt would throw.
    const got = await getTvdbToken({ ...env, TVDB_API_KEY: "key" } as never);
    expect(got).toBe("stored-token");
  });

  it("refreshes a token inside the one hour window before expiry", async () => {
    const nearlyExpired = Math.floor(Date.now() / 1000) + 600;
    await env.CACHE_KV.put(
      "tvdb:jwt",
      JSON.stringify({ token: "old-token", exp: nearlyExpired }),
    );

    const fresh = makeJwt(Math.floor(Date.now() / 1000) + 30 * 86400);
    fetchMock
      .get("https://api4.thetvdb.com")
      .intercept({ method: "POST", path: "/v4/login" })
      .reply(200, { data: { token: fresh } });

    const got = await getTvdbToken({ ...env, TVDB_API_KEY: "key" } as never);
    expect(got).toBe(fresh);
  });

  it("throws when TVDB_API_KEY is absent rather than sending an empty key", async () => {
    // vitest.config.ts binds a test-wide TVDB_API_KEY so route tests reach
    // upstream instead of 503ing, so this must clear it explicitly rather
    // than relying on the ambient env lacking the key.
    await expect(
      getTvdbToken({ ...env, TVDB_API_KEY: undefined } as never),
    ).rejects.toThrow(/TVDB_API_KEY/);
  });
});
