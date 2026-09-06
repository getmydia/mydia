import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";

const json = { "content-type": "application/json" };

// PAIRING_CREATE_LIMITER is a shared 10/min budget per IP (wrangler.jsonc),
// and every POST call below defaults to the same "unknown" bucket without an
// explicit cf-connecting-ip header. With a dozen create calls in this file
// that aren't themselves testing the limiter, sharing one bucket would trip
// it partway through the suite for reasons that have nothing to do with the
// test being run. Giving each its own IP keeps that budget irrelevant except
// in the two tests that deliberately exhaust it.
let nextTestIp = 10;
function freshIp(): string {
  return `203.0.113.${nextTestIp++}`;
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

describe("pairing v1", () => {
  it("stores a claim and reads it back by claim_code", async () => {
    // Handler.create_claim/1 responds {"claim_code": "..."} -- not {"code",
    // "expires_in"}; confirmed against metadata_relay/pairing/handler.ex and
    // its handler_test.exs, which asserts the same key.
    const created = await SELF.fetch("https://relay.mydia.dev/pairing/claim", {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify({ node_addr: '{"id":"09ecb63dd2"}' }),
    });

    expect(created.status).toBe(200);
    const { claim_code } = await created.json<{ claim_code: string }>();
    expect(typeof claim_code).toBe("string");
    expect(claim_code).toHaveLength(6);

    const fetched = await SELF.fetch(`https://relay.mydia.dev/pairing/claim/${claim_code}`);
    expect(fetched.status).toBe(200);
    expect(await fetched.json<{ node_addr: string }>()).toMatchObject({
      node_addr: '{"id":"09ecb63dd2"}',
    });
  });

  it("returns 404 for an unknown code", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/pairing/claim/NOSUCHCODE");
    expect(res.status).toBe(404);
  });

  it("normalizes a hand-typed code (case, dashes, spaces), like Pairing.normalize_code/1", async () => {
    const created = await SELF.fetch("https://relay.mydia.dev/pairing/claim", {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify({ node_addr: '{"id":"norm-test"}' }),
    });
    const { claim_code } = await created.json<{ claim_code: string }>();

    const typedByHand = claim_code.toLowerCase().split("").join("-");
    const fetched = await SELF.fetch(`https://relay.mydia.dev/pairing/claim/${typedByHand}`);
    expect(fetched.status).toBe(200);
  });

  it("returns the Elixir validation error shape when node_addr is missing", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/pairing/claim", {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify({}),
    });
    expect(res.status).toBe(400);
    expect(await res.json<{ error: string; message: string }>()).toMatchObject({
      error: "Validation error",
      message: "node_addr is required",
    });
  });

  it("returns the Elixir validation error shape when node_addr is not valid JSON", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/pairing/claim", {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      // Deliberately a JSON body whose node_addr *value* is not itself valid
      // JSON text -- Handler.validate_node_addr/1 Jason.decodes the string
      // and rejects "addr" (no surrounding quotes) as malformed.
      body: JSON.stringify({ node_addr: "addr" }),
    });
    expect(res.status).toBe(400);
    expect(await res.json<{ error: string; message: string }>()).toMatchObject({
      error: "Validation error",
      message: "node_addr must be valid JSON",
    });
  });

  it("deletes a claim and then returns 404", async () => {
    const created = await SELF.fetch("https://relay.mydia.dev/pairing/claim", {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify({ node_addr: '{"id":"delete-test"}' }),
    });
    const { claim_code } = await created.json<{ claim_code: string }>();

    const deleted = await SELF.fetch(`https://relay.mydia.dev/pairing/claim/${claim_code}`, {
      method: "DELETE",
    });
    expect(deleted.status).toBe(204);

    const after = await SELF.fetch(`https://relay.mydia.dev/pairing/claim/${claim_code}`);
    expect(after.status).toBe(404);
  });

  it("deletes an unknown code with 204 anyway, matching Pairing.delete_claim/1's idempotence", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/pairing/claim/NOSUCHCODE", {
      method: "DELETE",
    });
    expect(res.status).toBe(204);
  });

  it("treats an expired claim as absent", async () => {
    await env.DB.prepare(
      "INSERT INTO pairing_claims (key, value, expires_at) VALUES (?, ?, ?)",
    )
      .bind("pairing:EXPIRED1", "stale", Math.floor(Date.now() / 1000) - 10)
      .run();

    const res = await SELF.fetch("https://relay.mydia.dev/pairing/claim/EXPIRED1");
    expect(res.status).toBe(404);
  });

  it("answers the CORS preflight with 204, the allowed methods, and no allow-headers", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/pairing/claim/ABC", {
      method: "OPTIONS",
    });
    expect(res.status).toBe(204);
    expect(res.headers.get("access-control-allow-methods")).toBe("GET, DELETE");
    expect(res.headers.get("access-control-allow-origin")).toBe("*");
    // router.ex's allow_web_player/1 never sets this header, even on the
    // preflight -- a real (if pre-existing) gap in the Elixir, not something
    // to silently "fix" while porting.
    expect(res.headers.get("access-control-allow-headers")).toBeNull();
  });

  it("carries the CORS origin header on a 404, not just a 200", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/pairing/claim/NOSUCHCODE");
    expect(res.status).toBe(404);
    expect(res.headers.get("access-control-allow-origin")).toBe("*");
  });

  it("does not send a CORS header on the create route, matching router.ex", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/pairing/claim", {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify({ node_addr: '{"id":"no-cors-on-create"}' }),
    });
    expect(res.headers.get("access-control-allow-origin")).toBeNull();
  });

  it("uses send_rate_limited/2's body shape, not the proxy plug's, once the create limiter trips", async () => {
    // PAIRING_CREATE_LIMITER is 10/min (wrangler.jsonc); an 11th request from
    // the same IP inside the window must trip it. Distinct IP from every
    // other test in this file/suite to avoid cross-test contamination of the
    // shared limiter state.
    let last: Response | undefined;
    for (let i = 0; i < 11; i++) {
      last = await SELF.fetch("https://relay.mydia.dev/pairing/claim", {
        method: "POST",
        headers: { ...json, "cf-connecting-ip": "203.0.113.77" },
        body: JSON.stringify({ node_addr: '{"id":"rl-create"}' }),
      });
      if (last.status === 429) break;
    }

    expect(last!.status).toBe(429);
    expect(last!.headers.get("retry-after")).toBe("60");
    // No CORS header either: the create route never calls allow_web_player.
    expect(last!.headers.get("access-control-allow-origin")).toBeNull();

    const body = await last!.json<{ error: string; message: string; retry_after: number }>();
    expect(body).toMatchObject({
      error: "rate_limited",
      message: "Too many requests. Please try again later.",
      retry_after: 60,
    });
  });

  it("uses send_rate_limited/2's body shape once the read limiter trips, with CORS present", async () => {
    // PAIRING_READ_LIMITER is 30/min.
    let last: Response | undefined;
    for (let i = 0; i < 31; i++) {
      last = await SELF.fetch("https://relay.mydia.dev/pairing/claim/NOSUCHCODE", {
        headers: { "cf-connecting-ip": "203.0.113.78" },
      });
      if (last.status === 429) break;
    }

    expect(last!.status).toBe(429);
    expect(last!.headers.get("retry-after")).toBe("60");
    expect(last!.headers.get("access-control-allow-origin")).toBe("*");

    const body = await last!.json<{ error: string; message: string; retry_after: number }>();
    expect(body).toMatchObject({
      error: "rate_limited",
      message: "Too many requests. Please try again later.",
      retry_after: 60,
    });
  });
});

describe("pairing v2 sealed claims", () => {
  it("stores a sealed blob against a lookup key and returns 204 with no CORS header", async () => {
    const lookupKey = "a".repeat(64);
    const res = await SELF.fetch("https://relay.mydia.dev/pairing/v2/claim", {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify({ lookup_key: lookupKey, sealed: "c2VhbGVk" }),
    });
    expect(res.status).toBe(204);
    expect(res.headers.get("access-control-allow-origin")).toBeNull();

    const fetched = await SELF.fetch(
      `https://relay.mydia.dev/pairing/v2/claim/${lookupKey}`,
    );
    expect(fetched.status).toBe(200);
    expect(await fetched.json<{ sealed: string }>()).toMatchObject({ sealed: "c2VhbGVk" });
    expect(fetched.headers.get("access-control-allow-origin")).toBe("*");
  });

  it("keeps v1 and v2 keyspaces separate", async () => {
    // The key prefixes "pairing:" and "pairing:v2:" are what stop the same
    // string colliding across versions, exactly as the Redis keys did.
    const shared = "b".repeat(64);
    await SELF.fetch("https://relay.mydia.dev/pairing/v2/claim", {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify({ lookup_key: shared, sealed: "v2value" }),
    });

    const v1 = await SELF.fetch(`https://relay.mydia.dev/pairing/claim/${shared}`);
    expect(v1.status).toBe(404);
  });

  it("rejects a lookup key that is not 64 lowercase hex characters, with the Elixir's exact message", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/pairing/v2/claim", {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify({ lookup_key: "tooshort", sealed: "x" }),
    });
    expect(res.status).toBe(400);
    expect(await res.json<{ error: string; message: string }>()).toMatchObject({
      error: "Validation error",
      message: "lookup_key must be 64 lowercase hex characters",
    });
  });

  it("rejects a missing sealed blob, with the Elixir's exact message", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/pairing/v2/claim", {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify({ lookup_key: "d".repeat(64) }),
    });
    expect(res.status).toBe(400);
    expect(await res.json<{ error: string; message: string }>()).toMatchObject({
      error: "Validation error",
      message: "sealed is required",
    });
  });

  it("rejects an oversized sealed blob", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/pairing/v2/claim", {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify({ lookup_key: "f".repeat(64), sealed: "x".repeat(8193) }),
    });
    expect(res.status).toBe(400);
    expect(await res.json<{ error: string; message: string }>()).toMatchObject({
      error: "Validation error",
      message: "sealed exceeds 8192 bytes",
    });
  });

  it("returns 404 for an unknown lookup key", async () => {
    const res = await SELF.fetch(
      `https://relay.mydia.dev/pairing/v2/claim/${"c".repeat(64)}`,
    );
    expect(res.status).toBe(404);
  });

  it("validates the lookup_key format on GET too, before doing a lookup", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/pairing/v2/claim/tooshort");
    expect(res.status).toBe(400);
    expect(await res.json<{ error: string; message: string }>()).toMatchObject({
      error: "Validation error",
      message: "lookup_key must be 64 lowercase hex characters",
    });
  });

  it("deletes a sealed claim and then returns 404", async () => {
    const lookupKey = "e".repeat(64);
    await SELF.fetch("https://relay.mydia.dev/pairing/v2/claim", {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify({ lookup_key: lookupKey, sealed: "c2VhbGVk" }),
    });

    const deleted = await SELF.fetch(`https://relay.mydia.dev/pairing/v2/claim/${lookupKey}`, {
      method: "DELETE",
    });
    expect(deleted.status).toBe(204);
    expect(deleted.headers.get("access-control-allow-origin")).toBe("*");

    const after = await SELF.fetch(`https://relay.mydia.dev/pairing/v2/claim/${lookupKey}`);
    expect(after.status).toBe(404);
  });

  it("answers the v2 CORS preflight with 204 and the allowed methods", async () => {
    const res = await SELF.fetch(
      `https://relay.mydia.dev/pairing/v2/claim/${"1".repeat(64)}`,
      { method: "OPTIONS" },
    );
    expect(res.status).toBe(204);
    expect(res.headers.get("access-control-allow-methods")).toBe("GET, DELETE");
    expect(res.headers.get("access-control-allow-origin")).toBe("*");
  });
});
