import { SELF } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import { RELAY_URLS } from "../../src/config/client_config";

describe("GET /client-config", () => {
  it("returns the p2p relay list", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/client-config");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");

    const body = await res.json<{ p2p: { relays: string[] } }>();
    expect(body.p2p.relays).toEqual([...RELAY_URLS]);
  });

  it("is edge cacheable, unlike the Elixir relay it replaces", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/client-config");
    const cc = res.headers.get("cache-control") ?? "";
    expect(cc).toContain("public");
    expect(cc).toContain("s-maxage=3600");
    expect(cc).toContain("stale-while-revalidate=86400");
    expect(cc).toContain("stale-if-error=604800");
  });

  it("ships the same list the Elixir relay does", () => {
    // Kept in step by hand with metadata-relay/lib/metadata_relay/client_config.ex.
    // test/contract/routes.json diffs the two live services as well.
    expect(RELAY_URLS).toContain("https://cae1-1.relay.mydia.dev");
  });

  it("only lists https URLs with a host", () => {
    for (const url of RELAY_URLS) {
      const parsed = new URL(url);
      expect(parsed.protocol).toBe("https:");
      expect(parsed.hostname).not.toBe("");
    }
  });
});
