import { describe, it, expect } from "vitest";
import rawRoutes from "./routes.json";

// Replays a fixed request list against a deployed Worker and the live Elixir
// relay, diffing status and body. This is the gate that proves the port
// before Task 16 cuts the production hostname over -- see
// .superpowers/sdd/2026-09-05-metadata-relay-on-cloudflare-workers/task-9-report.md
// for what has (and has not) actually been exercised through it.
//
// This file runs as the separate "contract" Vitest project (see
// vitest.workspace.ts), under plain Node rather than workerd: it treats both
// services as opaque HTTP endpoints reached by URL, needs no Workers-specific
// runtime capability, and workerd's self-contained root CA store does not
// necessarily trust every network's TLS-intercepting proxy the way the host
// OS's trust store does (observed directly: identical fetch() calls succeed
// under Node and fail with a cert-trust error under workerd, in a sandbox
// that proxies outbound HTTPS). Plain `process.env` therefore works
// normally here, unlike inside a workerd test.
//
// CONTRACT_WORKER_URL is unset by default, so this whole suite is skipped in
// ordinary `npm run test` / CI runs -- there is no staging Worker to compare
// against until one is deployed (Step 4 of the brief). Point both env vars at
// the live relay to self-compare instead: every route then diffs against
// itself, which proves the harness mechanics, the cache-buster, and the
// volatile-key stripping, and -- most valuable -- that every path in
// routes.json is a real route on the live service.
const WORKER = process.env.CONTRACT_WORKER_URL;
const RELAY = process.env.CONTRACT_RELAY_URL ?? "https://relay.mydia.dev";

interface ContractRoute {
  method: string;
  path: string;
  // Present only for routes that need a JSON request body (SubDL search).
  body?: Record<string, unknown>;
}

const routes = rawRoutes as ContractRoute[];

// Keys whose values legitimately differ between the two services.
const VOLATILE_TOP_LEVEL = new Set(["version"]);

function stripVolatile(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stripVolatile);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .filter(([k]) => !VOLATILE_TOP_LEVEL.has(k))
        .map(([k, v]) => [k, stripVolatile(v)]),
    );
  }
  return value;
}

function requestInit(route: ContractRoute): RequestInit {
  if (route.body === undefined) return { method: route.method };
  return {
    method: route.method,
    body: JSON.stringify(route.body),
    headers: { "content-type": "application/json" },
  };
}

describe.skipIf(!WORKER)("Worker matches the live relay", () => {
  for (const route of routes) {
    it(`${route.method} ${route.path}`, async () => {
      // Cache-buster, because Cloudflare will otherwise serve your own earlier
      // request back to you and the diff will pass against itself.
      const bust = `_cb=${crypto.randomUUID()}`;
      const sep = route.path.includes("?") ? "&" : "?";
      const suffix = `${route.path}${sep}${bust}`;

      const init = requestInit(route);
      const [workerRes, relayRes] = await Promise.all([
        fetch(`${WORKER}${suffix}`, init),
        fetch(`${RELAY}${suffix}`, init),
      ]);

      expect(workerRes.status, "status code").toBe(relayRes.status);

      const workerBody = await workerRes.text();
      const relayBody = await relayRes.text();

      let workerJson: unknown;
      let relayJson: unknown;
      try {
        workerJson = JSON.parse(workerBody) as unknown;
        relayJson = JSON.parse(relayBody) as unknown;
      } catch {
        expect(workerBody).toBe(relayBody);
        return;
      }

      expect(stripVolatile(workerJson)).toEqual(stripVolatile(relayJson));
    });
  }
});
