import { describe, it, expect } from "vitest";
import rawRoutes from "./routes.json";

// Replays a fixed request list against a deployed Worker and the live Elixir
// relay, diffing status and body. This is the gate that proves the port
// before the production cutover moves the hostname over. Note what it has
// NOT exercised: no run has ever compared a real deployed Worker against the
// relay, only the relay against itself (see below), so the harness mechanics
// are proven and the actual port parity is not.
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
// against until one is deployed. Point both env vars at
// the live relay to self-compare instead: every route then diffs against
// itself, which proves the harness mechanics, the cache-buster, and the
// volatile-key stripping, and -- most valuable -- that every path in
// routes.json is a real route on the live service.
//
// IMPORTANT for whoever wires this into the cutover gate: Vitest
// exits 0 for a run that is entirely `describe.skipIf`-skipped, same as a
// run where every test genuinely passed. A gate that only checks the exit
// code would rubber-stamp a cutover having compared nothing, which is the
// single worst failure mode this harness could have. Assert the skip count
// is zero (or, simpler, that CONTRACT_WORKER_URL is actually set) before
// trusting a green `test:contract` run as a real gate pass.
const WORKER = process.env.CONTRACT_WORKER_URL;
const RELAY = process.env.CONTRACT_RELAY_URL ?? "https://relay.mydia.dev";

interface ContractRoute {
  method: string;
  path: string;
  // Present only for routes that need a JSON request body (SubDL search).
  body?: Record<string, unknown>;
  // Human-readable-only. Documents why a specific route is in this list
  // despite not being a clean positive check (e.g. a route both services
  // are expected to fail on identically), or a caveat about what the diff
  // against it does and doesn't prove. Never read by the test logic below.
  note?: string;
}

const routes = rawRoutes as ContractRoute[];

// The SubDL search route (POST /api/v1/subtitles/search) keys its cache on
// a SHA-256 of the JSON request body (subtitleSearchCacheKey/bodyFingerprint
// in src/cache/key.ts), not on the URL or query string at all -- so the
// `_cb` cache-buster appended below is a genuine no-op for that one route.
// Harmless for this self-comparison (relay.mydia.dev's own cache-control is
// `private, must-revalidate`, so it is never edge-cached regardless), but it
// matters once CONTRACT_WORKER_URL points at a real deployed staging Worker:
// that Worker's KV-backed cache (cachePut/cacheGet with {kv: true}) WILL
// serve a stale transform for an identical body across separate contract
// runs. Deploy staging with a fresh KV namespace (or purge
// CACHE_KV) before trusting this route's result, or a stale cached response
// could be compared instead of a fresh one.
function bytesEqual(a: ArrayBuffer, b: ArrayBuffer): boolean {
  if (a.byteLength !== b.byteLength) return false;
  const av = new Uint8Array(a);
  const bv = new Uint8Array(b);
  for (let i = 0; i < av.length; i++) {
    if (av[i] !== bv[i]) return false;
  }
  return true;
}

// Keys whose values legitimately differ between the two services.
const VOLATILE_TOP_LEVEL = new Set(["version"]);

// `created` needs shape-aware handling, not a blanket name match: found live
// on GET /music/search, whose upstream (MusicBrainz) stamps a bare ISO-8601
// string set to "now" on every single search -- confirmed empirically, this
// self-comparison failed on it even though both sides hit the identical
// live relay milliseconds apart. But the same key name also appears, in a
// completely different shape, on the OpenLibrary works/authors routes:
// `created: { type: "/type/datetime", value: "..." }`, a stable catalog
// record timestamp that is exactly the kind of real content this diff
// should keep comparing. Stripping by name alone would blind those two
// routes to a genuine mismatch for no reason -- so only a bare *string*
// `created` is treated as volatile; the OpenLibrary object shape is left to
// recurse into (and its `value` string survives too, since the key there is
// "value", not "created").
function isVolatile(key: string, value: unknown): boolean {
  if (VOLATILE_TOP_LEVEL.has(key)) return true;
  if (key === "created" && typeof value === "string") return true;
  return false;
}

function stripVolatile(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stripVolatile);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .filter(([k, v]) => !isVolatile(k, v))
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

      // Read as raw bytes, not text: /music/cover/:id returns a JPEG, and
      // decoding arbitrary binary as UTF-8 replaces invalid byte sequences
      // with U+FFFD, so two genuinely different images can decode to the
      // same lossy string -- a text-based comparison would silently pass a
      // real corruption. JSON bodies are still compared semantically below;
      // only the "not JSON" fallback needs to be byte-exact rather than
      // text-exact.
      const workerBytes = await workerRes.arrayBuffer();
      const relayBytes = await relayRes.arrayBuffer();

      let workerJson: unknown;
      let relayJson: unknown;
      try {
        workerJson = JSON.parse(new TextDecoder().decode(workerBytes)) as unknown;
        relayJson = JSON.parse(new TextDecoder().decode(relayBytes)) as unknown;
      } catch {
        expect(bytesEqual(workerBytes, relayBytes), "byte-for-byte body").toBe(
          true,
        );
        return;
      }

      expect(stripVolatile(workerJson)).toEqual(stripVolatile(relayJson));
    });
  }
});
