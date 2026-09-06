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

  it("reports subtitles_configured false when no SubDL key is set", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/health");
    const body = await res.json<{
      status: string;
      service: string;
      version: string;
      subtitles_configured: boolean;
    }>();
    expect(body.subtitles_configured).toBe(false);
  });
});
