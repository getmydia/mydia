import { env, SELF } from "cloudflare:test";
import { describe, it, expect } from "vitest";

describe("GET /health", () => {
  it("returns the shape deployed monitoring reads", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/health");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");

    const body = await res.json<{
      status: string;
      service: string;
      version: string;
      subtitles_configured: boolean;
    }>();
    expect(body).toMatchObject({
      status: "ok",
      service: "metadata-relay",
    });
    expect(typeof body.version).toBe("string");
    expect(typeof body.subtitles_configured).toBe("boolean");
  });

  it("reports subtitles_configured true when a SubDL key is set", async () => {
    // There is a global SUBDL_API_KEY test binding (vitest.config.ts) so
    // the search/download routes can be exercised without 503ing first, which
    // means every SELF.fetch dispatch in this pool now sees a configured key.
    // SELF.fetch has no per-call env override (bindings are fixed for the
    // whole pool at startup; verified empirically that mutating the imported
    // `env` object does not propagate to the dispatched worker), so the
    // "absent key" branch can no longer be reached through this route test.
    // It is covered directly instead, by src/proxy/subdl.ts's exported
    // subdlApiKey helper -- see test/proxy/subdl.test.ts's "subdlApiKey"
    // block for the absent/blank cases this test used to assert.
    const res = await SELF.fetch("https://relay.mydia.dev/health");
    const body = await res.json<{
      status: string;
      service: string;
      version: string;
      subtitles_configured: boolean;
    }>();
    expect(body.subtitles_configured).toBe(true);
  });
});
