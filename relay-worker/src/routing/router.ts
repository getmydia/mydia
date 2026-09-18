import type { Env } from "../env";
import { loggablePath } from "../obs/log";
import { compareResponses, readCapped, type ShadowVerdict } from "./compare";
import { loadRoutingConfig, type RoutingMode } from "./config";
import { routeGroupFor, type RouteGroup } from "./groups";

// The cutover traffic layer. While relay.mydia.dev moves from the Elixir relay
// to this Worker, the Worker sits on the whole hostname and decides, per route
// group, who answers: the Elixir relay (the zone's origin), this Worker, or
// both. See README.md's runbook for how the modes are used in order.
//
// Reaching the origin relies on how Workers route same-zone subrequests: with
// the `global_fetch_strictly_public` compatibility flag OFF (the default, and
// wrangler.jsonc does not set it), a fetch() to a hostname on the Worker's own
// zone goes straight to that hostname's origin server and skips any Worker
// route on it. So fetching TRAFFIC_ORIGIN from inside the relay.mydia.dev route
// reaches the Elixir relay rather than looping back here. Turning that flag on
// would make every "origin" request re-enter this Worker.

export type WorkerHandler = (request: Request) => Promise<Response>;

// Which backend answered, on every response from a routed hostname. Lets a
// curl, a ramp check, or a bug report say which relay produced a response.
export const BACKEND_HEADER = "x-relay-backend";

export type Backend = "origin" | "worker" | "origin-fallback";

// The layer only engages on the one hostname it is configured for, and only
// when an origin is configured to send traffic to. Everywhere else (the
// workers.dev hostnames, preview URLs, local dev, the test suite) this Worker
// answers every request itself, exactly as it did before this layer existed.
export function isRoutedHostname(hostname: string, env: Env): boolean {
  if (!env.TRAFFIC_HOSTNAME || !env.TRAFFIC_ORIGIN) return false;
  return hostname === env.TRAFFIC_HOSTNAME;
}

// 0-99, stable for a given key across requests, isolates and colos (FNV-1a).
// The split key is the client IP, so an install lands on one backend and
// stays there while the percentage holds, and moving the percentage up only
// ever moves installs from the Elixir relay to the Worker.
export function splitBucket(key: string): number {
  let hash = 0x811c9dc5;
  for (let i = 0; i < key.length; i++) {
    hash ^= key.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0) % 100;
}

export async function routeRequest(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
  worker: WorkerHandler,
): Promise<Response> {
  const url = new URL(request.url);
  if (!isRoutedHostname(url.hostname, env)) return worker(request);

  // Checked by isRoutedHostname above.
  const origin = env.TRAFFIC_ORIGIN as string;
  const group = routeGroupFor(url.pathname);
  const { modes } = await loadRoutingConfig(env);
  const mode = modes[group];

  const [response, backend] = await dispatch(request, mode, origin, worker, ctx, group);

  console.log(
    JSON.stringify({
      event: "route",
      group,
      mode: mode.kind,
      backend,
      status: response.status,
      path: loggablePath(url.pathname),
    }),
  );
  return withBackend(response, backend);
}

async function dispatch(
  request: Request,
  mode: RoutingMode,
  origin: string,
  worker: WorkerHandler,
  ctx: ExecutionContext,
  group: RouteGroup,
): Promise<[Response, Backend]> {
  switch (mode.kind) {
    case "origin":
      return [await fromOrigin(request, origin), "origin"];
    case "worker":
      return [await worker(request), "worker"];
    case "split": {
      const ip = request.headers.get("cf-connecting-ip") ?? "";
      return splitBucket(ip) < mode.percent
        ? [await worker(request), "worker"]
        : [await fromOrigin(request, origin), "origin"];
    }
    case "shadow":
      return [await shadow(request, mode.percent, origin, worker, ctx, group), "origin"];
    case "fallback":
      return fallback(request, origin, worker, ctx);
  }
}

async function fromOrigin(request: Request, origin: string): Promise<Response> {
  const url = new URL(request.url);
  const target = new URL(`${url.pathname}${url.search}`, origin);
  try {
    // Redirects are the client's to follow, exactly as when it talked to the
    // Elixir relay directly.
    return await fetch(new Request(target.toString(), request), { redirect: "manual" });
  } catch (err) {
    console.log(
      JSON.stringify({ event: "origin_error", path: loggablePath(url.pathname), error: String(err) }),
    );
    return Response.json({ error: "Bad gateway" }, { status: 502 });
  }
}

function withBackend(response: Response, backend: Backend): Response {
  const out = new Response(response.body, response);
  out.headers.set(BACKEND_HEADER, backend);
  return out;
}

// The client always gets the Elixir relay's response. For a sampled GET/HEAD,
// the Worker also handles a copy of the request after the response is on its
// way, and one `shadow` log line records whether the two agreed.
//
// Everything else passes through to the Elixir relay untouched. The groups
// allowed to shadow at all (see ALLOWED in config.ts) are read-only, but a
// method check here means a POST can never be run twice regardless.
async function shadow(
  request: Request,
  percent: number,
  origin: string,
  worker: WorkerHandler,
  ctx: ExecutionContext,
  group: RouteGroup,
): Promise<Response> {
  const readOnly = request.method === "GET" || request.method === "HEAD";
  // Sampling, not security: nothing depends on this being unpredictable.
  if (!readOnly || Math.random() * 100 >= percent) return fromOrigin(request, origin);

  const shadowRequest = request.clone();
  const originResponse = await fromOrigin(request, origin);
  const path = loggablePath(new URL(request.url).pathname);

  if (originResponse.body === null) {
    ctx.waitUntil(runShadow(shadowRequest, worker, originResponse.status, null, group, path));
    return originResponse;
  }
  const [clientBody, compareBody] = originResponse.body.tee();
  ctx.waitUntil(runShadow(shadowRequest, worker, originResponse.status, compareBody, group, path));
  return new Response(clientBody, originResponse);
}

async function runShadow(
  request: Request,
  worker: WorkerHandler,
  originStatus: number,
  originBody: ReadableStream<Uint8Array> | null,
  group: RouteGroup,
  path: string,
): Promise<void> {
  const started = Date.now();
  let workerStatus: number | undefined;

  // Both run at once, and the origin branch is always drained, even if the
  // Worker throws, so the tee() never buffers a body nobody reads.
  const [originBytes, workerResult] = await Promise.all([
    readCapped(originBody).catch(() => null),
    (async (): Promise<{ status: number; bytes: Uint8Array | null } | Error> => {
      try {
        const res = await worker(request);
        return { status: res.status, bytes: await readCapped(res.body) };
      } catch (err) {
        return err instanceof Error ? err : new Error(String(err));
      }
    })(),
  ]);

  let verdict: ShadowVerdict;
  if (workerResult instanceof Error) {
    verdict = { outcome: "worker_error", diff: workerResult.message };
  } else {
    workerStatus = workerResult.status;
    verdict = compareResponses(
      { status: originStatus, bytes: originBytes },
      { status: workerResult.status, bytes: workerResult.bytes },
    );
  }

  console.log(
    JSON.stringify({
      event: "shadow",
      group,
      path,
      outcome: verdict.outcome,
      diff: verdict.diff,
      origin_status: originStatus,
      worker_status: workerStatus,
      worker_ms: Date.now() - started,
    }),
  );
}

// For moving pairing. This Worker owns the group, but claims created on the
// Elixir relay just before the switch (they live for minutes) still resolve:
// a lookup this Worker cannot find is retried there, and a delete is sent to
// both, so neither store keeps a claim the server already consumed.
async function fallback(
  request: Request,
  origin: string,
  worker: WorkerHandler,
  ctx: ExecutionContext,
): Promise<[Response, Backend]> {
  if (request.method === "GET" || request.method === "HEAD") {
    const retry = request.clone();
    const res = await worker(request);
    if (res.status !== 404) return [res, "worker"];
    await res.body?.cancel();
    return [await fromOrigin(retry, origin), "origin-fallback"];
  }
  if (request.method === "DELETE") {
    const mirror = request.clone();
    const res = await worker(request);
    ctx.waitUntil(fromOrigin(mirror, origin).then((r) => r.body?.cancel()));
    return [res, "worker"];
  }
  return [await worker(request), "worker"];
}
