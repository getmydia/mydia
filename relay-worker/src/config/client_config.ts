import type { Hono } from "hono";
import type { Env } from "../env";
import { kvMemo } from "./kv_memo";

// The iroh relays mydia operates, served at GET /client-config. Installs read
// it at boot to learn which relays to use, so a relay is added, moved or
// retired by writing this key, with no deploy and no client release:
//
//   npx wrangler kv key put --env production --binding CACHE_KV --remote \
//     client-config:relays '["https://cae1-1.relay.mydia.dev"]'
//
// README.md, "Changing the relay list", has the whole procedure. The Elixir
// relay serves the same document from its CLIENT_CONFIG_RELAYS env var, and
// test/contract/routes.json includes /client-config, so the cutover gate
// reports the two services being configured differently.
//
// Clients append iroh's own public relays underneath these, so the list
// carries only mydia's own.
export const CLIENT_RELAYS_KEY = "client-config:relays";

// Served when the key is absent or its value is rejected. It is the relay
// production served before the list moved to KV, so an empty namespace (local
// dev, a fresh staging) still hands out a relay that works.
export const DEFAULT_RELAY_URLS: readonly string[] = ["https://cae1-1.relay.mydia.dev"];

// "kv" or "default", so a `kv key put` can be checked with one curl.
export const RELAY_LIST_SOURCE_HEADER = "x-relay-list-source";

export interface RelayList {
  relays: readonly string[];
  source: "kv" | "default";
  warnings: string[];
}

// The Worker answers every request (nothing caches /client-config at
// Cloudflare's edge), so these directives only reach downstream shared caches.
// A relay move is a planned change, so an hour of staleness there costs
// nothing.
const CACHE_CONTROL =
  "public, s-maxage=3600, stale-while-revalidate=86400, stale-if-error=604800";

// Installs keep only https URLs with a non-empty host (valid_urls/1 in
// lib/mydia/p2p/relay_list.ex, _validUrls in player/lib/core/p2p/relay_list.dart).
// The prefix check is stricter than `new URL`, which reads "https:///x" as
// host "x" where both clients see an empty host.
const HTTPS_WITH_HOST = /^https:\/\/[^/?#\s]/;

// Never throws. One bad entry rejects the whole value: a list with a relay
// silently dropped is harder to notice than one that falls back to the default
// and logs why.
export function parseRelayList(raw: string | null): RelayList {
  if (raw === null) return fallback([]);

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return fallback(["relay list is not valid JSON"]);
  }
  if (!Array.isArray(parsed)) return fallback(["relay list is not a JSON array"]);
  if (parsed.length === 0) return fallback(["relay list is empty"]);

  const relays: string[] = [];
  for (const entry of parsed as unknown[]) {
    if (typeof entry !== "string") {
      return fallback([`relay ${JSON.stringify(entry)} is not a string`]);
    }
    if (!HTTPS_WITH_HOST.test(entry) || /\s/.test(entry) || !parsesAsUrl(entry)) {
      return fallback([`relay ${JSON.stringify(entry)} is not an https URL with a host`]);
    }
    if (relays.includes(entry)) {
      return fallback([`relay ${JSON.stringify(entry)} is listed twice`]);
    }
    relays.push(entry);
  }
  return { relays, source: "kv", warnings: [] };
}

function parsesAsUrl(value: string): boolean {
  try {
    new URL(value);
    return true;
  } catch {
    return false;
  }
}

function fallback(warnings: string[]): RelayList {
  return { relays: DEFAULT_RELAY_URLS, source: "default", warnings };
}

const relayListMemo = kvMemo<RelayList>({
  key: CLIENT_RELAYS_KEY,
  parse: (raw) => {
    const list = parseRelayList(raw);
    if (list.warnings.length > 0) {
      console.log(JSON.stringify({ event: "client_config_warning", warnings: list.warnings }));
    }
    return list;
  },
  onReadError: (err) => {
    console.log(JSON.stringify({ event: "client_config_error", error: String(err) }));
    return fallback(["relay list could not be read"]);
  },
});

export function loadRelayList(env: Env, now: number = Date.now()): Promise<RelayList> {
  return relayListMemo.load(env, now);
}

// Test-only: forget what this isolate has read, so a test's KV write is seen
// by the next request.
export function resetRelayListMemo(): void {
  relayListMemo.reset();
}

export function registerClientConfigRoutes(app: Hono<{ Bindings: Env }>): void {
  app.get("/client-config", async (c) => {
    const { relays, source } = await loadRelayList(c.env);
    return c.json({ p2p: { relays } }, 200, {
      "cache-control": CACHE_CONTROL,
      [RELAY_LIST_SOURCE_HEADER]: source,
    });
  });
}
