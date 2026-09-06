import { env } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import { cacheGet, cachePut, filterHeaders } from "../../src/cache/store";

describe("filterHeaders", () => {
  it("keeps only the four allowed headers", () => {
    const input = new Headers({
      "content-type": "application/json",
      "content-disposition": "attachment",
      "cache-control": "public, max-age=60",
      etag: '"abc"',
      "set-cookie": "session=leak",
      "x-request-id": "noise",
      authorization: "Bearer secret",
    });

    const out = filterHeaders(input);

    expect(out.get("content-type")).toBe("application/json");
    expect(out.get("content-disposition")).toBe("attachment");
    expect(out.get("cache-control")).toBe("public, max-age=60");
    expect(out.get("etag")).toBe('"abc"');
    expect(out.get("set-cookie")).toBeNull();
    expect(out.get("x-request-id")).toBeNull();
    expect(out.get("authorization")).toBeNull();
  });
});

describe("cache round trip", () => {
  it("returns null for a key never written", async () => {
    expect(await cacheGet(env, "GET:/tmdb/movies/1:")).toBeNull();
  });

  it("returns a stored response body and status", async () => {
    const key = "GET:/tmdb/movies/550:";
    await cachePut(
      env,
      key,
      new Response(JSON.stringify({ id: 550 }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    );

    const hit = await cacheGet(env, key);
    expect(hit).not.toBeNull();
    expect(hit!.status).toBe(200);
    expect(await hit!.json<{ id: number }>()).toEqual({ id: 550 });
  });

  it("does not leak headers outside the allowlist through the cache", async () => {
    const key = "GET:/tmdb/movies/551:";
    await cachePut(
      env,
      key,
      new Response("{}", {
        status: 200,
        headers: { "content-type": "application/json", "set-cookie": "x=1" },
      }),
    );

    const hit = await cacheGet(env, key);
    expect(hit!.headers.get("set-cookie")).toBeNull();
  });

  it("keeps entries for distinct keys separate", async () => {
    await cachePut(env, "GET:/a:", new Response("A"));
    await cachePut(env, "GET:/b:", new Response("B"));

    expect(await (await cacheGet(env, "GET:/a:"))!.text()).toBe("A");
    expect(await (await cacheGet(env, "GET:/b:"))!.text()).toBe("B");
  });

  it("does not write to KV unless asked", async () => {
    await cachePut(env, "GET:/kvless:", new Response("no kv"));
    expect(await env.CACHE_KV.get("GET:/kvless:")).toBeNull();
  });

  it("writes to KV when the caller opts in", async () => {
    await cachePut(env, "POST:/subs:v1:abc", new Response("subs"), { kv: true });
    expect(await env.CACHE_KV.get("POST:/subs:v1:abc")).not.toBeNull();
  });
});
