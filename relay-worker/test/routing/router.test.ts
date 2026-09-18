import { env, createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { describe, it, expect, beforeAll, beforeEach, afterEach, vi } from "vitest";
import { fetchMock } from "../support/fetch-mock";
import { app } from "../../src/index";
import { ROUTING_CONFIG_KEY } from "../../src/routing/config";
import { BACKEND_HEADER, routeRequest, splitBucket, type WorkerHandler } from "../../src/routing/router";
import type { Env } from "../../src/env";

const HOST = "relay.mydia.dev";
const ORIGIN = "https://relay.mydia.dev";

const routedEnv: Env = { ...env, TRAFFIC_HOSTNAME: HOST, TRAFFIC_ORIGIN: ORIGIN };

async function setConfig(config: unknown): Promise<void> {
  await env.CACHE_KV.put(ROUTING_CONFIG_KEY, JSON.stringify(config));
}

function workerReplying(body: unknown, status = 200): ReturnType<typeof vi.fn<WorkerHandler>> {
  return vi.fn<WorkerHandler>(async () => Response.json(body, { status }));
}

async function route(
  request: Request,
  worker: WorkerHandler,
  environment: Env = routedEnv,
): Promise<{ res: Response; body: string; logs: Record<string, unknown>[] }> {
  const log = vi.spyOn(console, "log").mockImplementation(() => {});
  try {
    const ctx = createExecutionContext();
    const res = await routeRequest(request, environment, ctx, worker);
    const body = await res.text();
    await waitOnExecutionContext(ctx);
    const logs = log.mock.calls
      .map(([line]) => {
        try {
          return JSON.parse(String(line)) as Record<string, unknown>;
        } catch {
          return {};
        }
      })
      .filter((entry) => typeof entry.event === "string");
    return { res, body, logs };
  } finally {
    log.mockRestore();
  }
}

beforeAll(() => {
  fetchMock.activate();
  fetchMock.disableNetConnect();
});

beforeEach(async () => {
  await env.CACHE_KV.delete(ROUTING_CONFIG_KEY);
});

afterEach(() => fetchMock.assertNoPendingInterceptors());

describe("hostname gate", () => {
  it("lets the Worker answer everything when TRAFFIC_HOSTNAME is unset", async () => {
    await setConfig({ default: "origin" });
    const worker = workerReplying({ from: "worker" });
    const { res, body } = await route(new Request(`${ORIGIN}/tmdb/movies/1`), worker, env);
    expect(JSON.parse(body)).toEqual({ from: "worker" });
    expect(res.headers.get(BACKEND_HEADER)).toBeNull();
  });

  it("lets the Worker answer other hostnames", async () => {
    const worker = workerReplying({ from: "worker" });
    const { res } = await route(
      new Request("https://mydia-relay.someacct.workers.dev/tmdb/movies/1"),
      worker,
    );
    expect(worker).toHaveBeenCalledOnce();
    expect(res.headers.get(BACKEND_HEADER)).toBeNull();
  });
});

describe("origin mode", () => {
  it("is the default when there is no config", async () => {
    fetchMock.get(ORIGIN).intercept({ method: "GET", path: "/tmdb/movies/1?language=en" }).reply(200, { from: "origin" });
    const worker = workerReplying({ from: "worker" });

    const { res, body, logs } = await route(new Request(`${ORIGIN}/tmdb/movies/1?language=en`), worker);

    expect(JSON.parse(body)).toEqual({ from: "origin" });
    expect(res.headers.get(BACKEND_HEADER)).toBe("origin");
    expect(worker).not.toHaveBeenCalled();
    expect(logs).toContainEqual(
      expect.objectContaining({ event: "route", group: "tmdb", mode: "origin", backend: "origin", status: 200 }),
    );
  });

  it("forwards method, headers and body, and does not follow redirects", async () => {
    await setConfig({ groups: { crashes: "origin", tmdb: "origin" } });
    fetchMock
      .get(ORIGIN)
      .intercept({
        method: "POST",
        path: "/crashes/report",
        headers: (h) => h["content-type"] === "application/json",
        body: (b) => JSON.parse(b).error_type === "RuntimeError",
      })
      .reply(201, { ok: true });
    fetchMock
      .get(ORIGIN)
      .intercept({ method: "GET", path: "/tmdb/old" })
      .reply(301, "", { headers: { location: "https://relay.mydia.dev/tmdb/new" } });

    const post = await route(
      new Request(`${ORIGIN}/crashes/report`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ error_type: "RuntimeError" }),
      }),
      workerReplying({}),
    );
    expect(post.res.status).toBe(201);

    const redirect = await route(new Request(`${ORIGIN}/tmdb/old`), workerReplying({}));
    expect(redirect.res.status).toBe(301);
    expect(redirect.res.headers.get("location")).toBe("https://relay.mydia.dev/tmdb/new");
  });

  it("answers 502 when the origin cannot be reached", async () => {
    // No interceptor registered, so the mocked fetch rejects.
    const { res, logs } = await route(new Request(`${ORIGIN}/tvdb/search?query=x`), workerReplying({}));
    expect(res.status).toBe(502);
    expect(logs).toContainEqual(expect.objectContaining({ event: "origin_error", path: "/tvdb/search" }));
  });

  it("keeps a claim code out of the origin_error log", async () => {
    const { logs } = await route(new Request(`${ORIGIN}/pairing/claim/ABCD`), workerReplying({}));
    expect(logs).toContainEqual(expect.objectContaining({ event: "origin_error", path: "/pairing/claim/*" }));
  });
});

describe("worker mode", () => {
  it("lets the Worker answer the group", async () => {
    await setConfig({ groups: { tvdb: "worker" } });
    const worker = workerReplying({ from: "worker" });
    const { res, body } = await route(new Request(`${ORIGIN}/tvdb/search?query=x`), worker);
    expect(JSON.parse(body)).toEqual({ from: "worker" });
    expect(res.headers.get(BACKEND_HEADER)).toBe("worker");
  });
});

describe("split mode", () => {
  // Two IPs known to fall on opposite sides of 50.
  const low = ["10.0.0.1", "10.0.0.2", "10.0.0.3", "10.0.0.4", "10.0.0.5"].find((ip) => splitBucket(ip) < 50)!;
  const high = ["10.0.0.1", "10.0.0.2", "10.0.0.3", "10.0.0.4", "10.0.0.5"].find((ip) => splitBucket(ip) >= 50)!;

  it("buckets deterministically", () => {
    expect(splitBucket("203.0.113.9")).toBe(splitBucket("203.0.113.9"));
    expect(low).toBeDefined();
    expect(high).toBeDefined();
  });

  it("sends IPs under the percentage to the Worker and the rest to the origin", async () => {
    await setConfig({ groups: { tmdb: "split:50" } });

    const worker = workerReplying({ from: "worker" });
    const toWorker = await route(
      new Request(`${ORIGIN}/tmdb/movies/2`, { headers: { "cf-connecting-ip": low } }),
      worker,
    );
    expect(toWorker.res.headers.get(BACKEND_HEADER)).toBe("worker");

    fetchMock.get(ORIGIN).intercept({ method: "GET", path: "/tmdb/movies/2" }).reply(200, { from: "origin" });
    const toOrigin = await route(
      new Request(`${ORIGIN}/tmdb/movies/2`, { headers: { "cf-connecting-ip": high } }),
      worker,
    );
    expect(toOrigin.res.headers.get(BACKEND_HEADER)).toBe("origin");
    expect(worker).toHaveBeenCalledOnce();
  });
});

describe("shadow mode", () => {
  it("answers from the origin and logs a match when the Worker agrees", async () => {
    await setConfig({ groups: { tmdb: "shadow" } });
    fetchMock.get(ORIGIN).intercept({ method: "GET", path: "/tmdb/movies/3" }).reply(200, { id: 3, title: "A" });
    const worker = workerReplying({ title: "A", id: 3 });

    const { res, body, logs } = await route(new Request(`${ORIGIN}/tmdb/movies/3`), worker);

    expect(JSON.parse(body)).toEqual({ id: 3, title: "A" });
    expect(res.headers.get(BACKEND_HEADER)).toBe("origin");
    expect(worker).toHaveBeenCalledOnce();
    expect(logs).toContainEqual(
      expect.objectContaining({
        event: "shadow",
        group: "tmdb",
        path: "/tmdb/movies/3",
        outcome: "match",
        origin_status: 200,
        worker_status: 200,
      }),
    );
  });

  it("logs where the Worker disagreed without changing the client's response", async () => {
    await setConfig({ groups: { tvdb: "shadow" } });
    fetchMock.get(ORIGIN).intercept({ method: "GET", path: "/tvdb/series/4" }).reply(200, { data: { name: "Glass Meridian" } });
    const worker = workerReplying({ data: { name: "Glass Meridan" } });

    const { body, logs } = await route(new Request(`${ORIGIN}/tvdb/series/4`), worker);

    expect(JSON.parse(body)).toEqual({ data: { name: "Glass Meridian" } });
    expect(logs).toContainEqual(
      expect.objectContaining({ event: "shadow", outcome: "body_mismatch", diff: "$.data.name" }),
    );
  });

  it("logs a Worker exception as worker_error", async () => {
    await setConfig({ groups: { tmdb: "shadow" } });
    fetchMock.get(ORIGIN).intercept({ method: "GET", path: "/tmdb/movies/5" }).reply(200, { id: 5 });
    const worker = vi.fn<WorkerHandler>(async () => {
      throw new Error("boom");
    });

    const { res, logs } = await route(new Request(`${ORIGIN}/tmdb/movies/5`), worker);

    expect(res.status).toBe(200);
    expect(logs).toContainEqual(expect.objectContaining({ event: "shadow", outcome: "worker_error", diff: "boom" }));
  });

  it("never runs a POST twice", async () => {
    await setConfig({ default: "shadow" });
    fetchMock.get(ORIGIN).intercept({ method: "POST", path: "/tmdb/movies/6" }).reply(200, { id: 6 });
    const worker = workerReplying({ id: 6 });

    const { logs } = await route(new Request(`${ORIGIN}/tmdb/movies/6`, { method: "POST", body: "{}" }), worker);

    expect(worker).not.toHaveBeenCalled();
    expect(logs.some((l) => l.event === "shadow")).toBe(false);
  });

  it("skips unsampled requests at 0%", async () => {
    await setConfig({ groups: { tmdb: "shadow:0" } });
    fetchMock.get(ORIGIN).intercept({ method: "GET", path: "/tmdb/movies/8" }).reply(200, { id: 8 });
    const worker = workerReplying({ id: 8 });

    await route(new Request(`${ORIGIN}/tmdb/movies/8`), worker);

    expect(worker).not.toHaveBeenCalled();
  });

  it("drives the real app against a real upstream call", async () => {
    await setConfig({ groups: { tmdb: "shadow" } });
    fetchMock.get(ORIGIN).intercept({ method: "GET", path: "/tmdb/movies/7001" }).reply(200, { id: 7001, title: "Invented Film" });
    fetchMock
      .get("https://api.themoviedb.org")
      .intercept({ method: "GET", path: (p) => p.startsWith("/3/movie/7001") })
      .reply(200, { title: "Invented Film", id: 7001 });

    const ctx = createExecutionContext();
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    try {
      const res = await routeRequest(new Request(`${ORIGIN}/tmdb/movies/7001`), routedEnv, ctx, async (req) =>
        app.fetch(req, routedEnv, ctx),
      );
      expect(await res.json()).toEqual({ id: 7001, title: "Invented Film" });
      await waitOnExecutionContext(ctx);
      const shadowLine = log.mock.calls
        .map(([line]) => String(line))
        .find((line) => line.includes('"event":"shadow"'));
      expect(JSON.parse(shadowLine!)).toMatchObject({ outcome: "match", worker_status: 200 });
    } finally {
      log.mockRestore();
    }
  });
});

describe("fallback mode", () => {
  beforeEach(async () => {
    await setConfig({ groups: { pairing: "fallback" } });
  });

  it("answers from the Worker when it has the claim", async () => {
    const worker = workerReplying({ node_addr: "x" });
    const { res } = await route(new Request(`${ORIGIN}/pairing/claim/ABCD`), worker);
    expect(res.headers.get(BACKEND_HEADER)).toBe("worker");
  });

  it("retries a lookup the Worker cannot find against the origin", async () => {
    fetchMock.get(ORIGIN).intercept({ method: "GET", path: "/pairing/v2/claim/key1" }).reply(200, { sealed: "s" });
    const worker = workerReplying({ error: "not_found" }, 404);

    const { res, body, logs } = await route(new Request(`${ORIGIN}/pairing/v2/claim/key1`), worker);

    expect(res.headers.get(BACKEND_HEADER)).toBe("origin-fallback");
    expect(JSON.parse(body)).toEqual({ sealed: "s" });
    // The lookup key retrieves the claim, so it is never logged.
    expect(logs).toContainEqual(expect.objectContaining({ event: "route", path: "/pairing/v2/claim/*" }));
  });

  it("deletes from both stores", async () => {
    fetchMock.get(ORIGIN).intercept({ method: "DELETE", path: "/pairing/claim/ABCD" }).reply(204);
    const worker = vi.fn<WorkerHandler>(async () => new Response(null, { status: 204 }));

    const { res } = await route(new Request(`${ORIGIN}/pairing/claim/ABCD`, { method: "DELETE" }), worker);

    expect(res.status).toBe(204);
    expect(worker).toHaveBeenCalledOnce();
    // assertNoPendingInterceptors in afterEach proves the origin DELETE ran.
  });

  it("creates claims on the Worker only", async () => {
    const worker = workerReplying({ claim_code: "WXYZ" });
    const { res } = await route(
      new Request(`${ORIGIN}/pairing/claim`, { method: "POST", body: JSON.stringify({ node_addr: "{}" }) }),
      worker,
    );
    expect(res.headers.get(BACKEND_HEADER)).toBe("worker");
  });
});
