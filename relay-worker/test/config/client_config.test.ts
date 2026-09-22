import { env, createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { describe, it, expect, beforeEach, vi } from "vitest";
import { app } from "../../src/index";
import { KV_MEMO_MS } from "../../src/config/kv_memo";
import {
  CLIENT_RELAYS_KEY,
  DEFAULT_RELAY_URLS,
  RELAY_LIST_SOURCE_HEADER,
  loadRelayList,
  parseRelayList,
  resetRelayListMemo,
} from "../../src/config/client_config";
import type { Env } from "../../src/env";

const CAE1_1 = "https://cae1-1.relay.mydia.dev";
const CAE1_2 = "https://cae1-2.relay.mydia.dev";

// app.fetch, as in test/routing/router.test.ts, so the memo this file resets
// is certainly the one the handler reads.
async function getClientConfig(): Promise<Response> {
  const ctx = createExecutionContext();
  const res = await app.fetch(new Request("https://relay.mydia.dev/client-config"), env, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}

async function putRelays(value: string): Promise<void> {
  await env.CACHE_KV.put(CLIENT_RELAYS_KEY, value);
  resetRelayListMemo();
}

function loggedEvents(log: { mock: { calls: unknown[][] } }): string[] {
  return log.mock.calls.map(([line]) => String(line));
}

beforeEach(async () => {
  await env.CACHE_KV.delete(CLIENT_RELAYS_KEY);
  resetRelayListMemo();
});

describe("GET /client-config", () => {
  it("serves the built-in list when the key is absent", async () => {
    const res = await getClientConfig();
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");
    expect(res.headers.get(RELAY_LIST_SOURCE_HEADER)).toBe("default");
    expect(await res.json()).toEqual({ p2p: { relays: [...DEFAULT_RELAY_URLS] } });
  });

  it("serves the list written to KV, in the order written", async () => {
    await putRelays(JSON.stringify([CAE1_2, CAE1_1]));

    const res = await getClientConfig();
    expect(res.headers.get(RELAY_LIST_SOURCE_HEADER)).toBe("kv");
    expect(await res.json()).toEqual({ p2p: { relays: [CAE1_2, CAE1_1] } });
  });

  it("falls back to the built-in list when the value is rejected, and logs why", async () => {
    await putRelays(JSON.stringify([CAE1_1, "http://relay.example.test"]));
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    try {
      const res = await getClientConfig();
      expect(res.headers.get(RELAY_LIST_SOURCE_HEADER)).toBe("default");
      expect(await res.json()).toEqual({ p2p: { relays: [...DEFAULT_RELAY_URLS] } });
      expect(loggedEvents(log).some((line) => line.includes('"event":"client_config_warning"'))).toBe(true);
    } finally {
      log.mockRestore();
    }
  });

  it("is cacheable downstream", async () => {
    const cc = (await getClientConfig()).headers.get("cache-control") ?? "";
    expect(cc).toContain("public");
    expect(cc).toContain("s-maxage=3600");
    expect(cc).toContain("stale-while-revalidate=86400");
    expect(cc).toContain("stale-if-error=604800");
  });
});

describe("parseRelayList", () => {
  it("serves the default without a warning when the key is absent", () => {
    expect(parseRelayList(null)).toEqual({ relays: DEFAULT_RELAY_URLS, source: "default", warnings: [] });
  });

  it("accepts distinct https URLs with a host", () => {
    expect(parseRelayList(JSON.stringify([CAE1_1, CAE1_2]))).toEqual({
      relays: [CAE1_1, CAE1_2],
      source: "kv",
      warnings: [],
    });
  });

  it.each([
    ["invalid JSON", "[", "not valid JSON"],
    ["an object", '{"relays":[]}', "not a JSON array"],
    ["an empty array", "[]", "empty"],
    ["a non-string entry", "[42]", "not a string"],
    ["an http URL", '["http://relay.example.test"]', "not an https URL with a host"],
    ["a bare hostname", '["relay.example.test"]', "not an https URL with a host"],
    // `new URL` reads this as host "path"; both clients see an empty host.
    ["an empty host", '["https:///path"]', "not an https URL with a host"],
    ["surrounding whitespace", '[" https://relay.example.test"]', "not an https URL with a host"],
    ["a duplicate", JSON.stringify([CAE1_1, CAE1_1]), "listed twice"],
    ["one bad entry among good ones", JSON.stringify([CAE1_1, "http://relay.example.test"]), "not an https URL"],
  ])("rejects %s whole, with a warning", (_label, raw, fragment) => {
    const result = parseRelayList(raw);
    expect(result.source).toBe("default");
    expect(result.relays).toEqual(DEFAULT_RELAY_URLS);
    expect(result.warnings).toHaveLength(1);
    expect(result.warnings[0]).toContain(fragment);
  });

  it("accepts its own built-in list", () => {
    expect(parseRelayList(JSON.stringify(DEFAULT_RELAY_URLS)).source).toBe("kv");
  });
});

describe("loadRelayList", () => {
  it("serves the built-in list when KV refuses, and logs it", async () => {
    const failing: Env = {
      ...env,
      CACHE_KV: {
        get: async () => {
          throw new Error("KV GET failed: 429 Too Many Requests");
        },
      } as unknown as KVNamespace,
    };
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    try {
      const list = await loadRelayList(failing, 1_000_000);
      expect(list.source).toBe("default");
      expect(list.relays).toEqual(DEFAULT_RELAY_URLS);
      expect(loggedEvents(log).some((line) => line.includes('"event":"client_config_error"'))).toBe(true);
    } finally {
      log.mockRestore();
    }
  });

  it("picks up a KV write once the window has passed", async () => {
    const t0 = 1_000_000;
    await putRelays(JSON.stringify([CAE1_1]));
    expect((await loadRelayList(env, t0)).relays).toEqual([CAE1_1]);

    // Written behind the memo's back, as `wrangler kv key put` would be.
    await env.CACHE_KV.put(CLIENT_RELAYS_KEY, JSON.stringify([CAE1_1, CAE1_2]));

    expect((await loadRelayList(env, t0 + KV_MEMO_MS - 1)).relays).toEqual([CAE1_1]);
    expect((await loadRelayList(env, t0 + KV_MEMO_MS)).relays).toEqual([CAE1_1, CAE1_2]);
  });
});
