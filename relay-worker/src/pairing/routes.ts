import type { Context, Hono } from "hono";
import type { Env } from "../env";
import { storeClaim, readClaim, deleteClaim } from "./store";

// @default_ttl_seconds in metadata_relay/pairing.ex
const TTL_SECONDS = 300;
const V1_PREFIX = "pairing:";
const V2_PREFIX = "pairing:v2:";

const LOOKUP_KEY_PATTERN = /^[0-9a-f]{64}$/;
// Matches Pairing.Handler's @max_sealed_bytes: a real payload is a few
// hundred bytes, the cap stops the store being used as free blob hosting.
const MAX_SEALED_BYTES = 8192;

// Matches Pairing.generate_code/1's alphabet exactly: excludes 0, O, I, 1 AND
// L (easy to misread as 1) so a code read aloud or typed by hand is
// unambiguous. Length 6, also matching the Elixir default.
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const CODE_LENGTH = 6;

type PairingContext = Context<{ Bindings: Env }>;
type ErrorBody = { error: string; message: string };

function generateCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(CODE_LENGTH));
  return [...bytes].map((b) => CODE_ALPHABET[b % CODE_ALPHABET.length]).join("");
}

// Mirrors Pairing.normalize_code/1, applied by the Elixir context to every
// GET/DELETE lookup (never to create): uppercases and strips the dashes or
// spaces a person introduces reading a 6-character code aloud or typing it
// from memory. The stored key itself is always the code exactly as
// generated, so lookups must normalize to match it.
function normalizeCode(code: string): string {
  return code.toUpperCase().replace(/[-\s]/g, "");
}

// router.ex's allow_web_player/1, verbatim: origin only. The Elixir router
// never sends access-control-allow-headers, even on the OPTIONS preflight
// below -- don't add one here even though a browser client with custom
// headers would want it; that's a latent gap in the Elixir this task is not
// scoped to fix.
function corsOrigin(extra: Record<string, string> = {}): Record<string, string> {
  return { ...extra, "access-control-allow-origin": "*" };
}

function validationError(message: string): ErrorBody {
  return { error: "Validation error", message };
}

function notFoundError(): ErrorBody {
  return { error: "Not found", message: "Claim code not found or expired" };
}

// Exact parity with router.ex's send_rate_limited/2: {"error": "rate_limited",
// "message": "Too many requests. Please try again later.", "retry_after": N}.
// This is deliberately NOT ratelimit.ts's rateLimitMiddleware body (which
// mirrors the separate ProxyRateLimit plug's differently-cased "Too many
// requests" error string and has no retry_after field) -- pairing uses the
// router's own helper in the Elixir, not the proxy plug.
//
// `withCors` is true only for the GET/DELETE routes, where the Elixir conn
// already carries the access-control-allow-origin header (set by
// allow_web_player/1 before the rate-limit check runs) by the time
// send_rate_limited/2 sends the 429. The POST create routes never call
// allow_web_player, so their 429 carries no CORS header either.
function rateLimitedResponse(withCors: boolean): Response {
  return new Response(
    JSON.stringify({
      error: "rate_limited",
      message: "Too many requests. Please try again later.",
      retry_after: 60,
    }),
    {
      status: 429,
      headers: {
        "content-type": "application/json",
        "retry-after": "60",
        ...(withCors ? corsOrigin() : {}),
      },
    },
  );
}

async function limited(limiter: RateLimit, ip: string): Promise<boolean> {
  // check_pairing_rate_limit/2 keys every pairing route on "pairing:<ip>";
  // create vs. read/delete is separated by which Cloudflare Rate Limiting
  // binding is passed in (PAIRING_CREATE_LIMITER 10/min, PAIRING_READ_LIMITER
  // 30/min -- wrangler.jsonc), not by a key prefix, since each binding is
  // already its own independent counter namespace.
  const { success } = await limiter.limit({ key: `pairing:${ip}` });
  return !success;
}

function ipOf(c: PairingContext): string {
  return c.req.header("cf-connecting-ip") ?? "unknown";
}

// Handler.validate_node_addr/1: required, must be a string, and must itself
// be valid JSON (it's an opaque iroh EndpointAddr the relay never inspects
// beyond that).
function validateNodeAddr(nodeAddr: unknown): ErrorBody | null {
  if (nodeAddr === undefined || nodeAddr === null || nodeAddr === "") {
    return validationError("node_addr is required");
  }
  if (typeof nodeAddr !== "string") {
    return validationError("node_addr must be a string");
  }
  try {
    JSON.parse(nodeAddr);
  } catch {
    return validationError("node_addr must be valid JSON");
  }
  return null;
}

// Handler.validate_lookup_key/1.
function validateLookupKey(lookupKey: unknown): ErrorBody | null {
  if (typeof lookupKey !== "string") {
    return validationError("lookup_key is required");
  }
  if (!LOOKUP_KEY_PATTERN.test(lookupKey)) {
    return validationError("lookup_key must be 64 lowercase hex characters");
  }
  return null;
}

// Handler.validate_sealed/1. Uses UTF-8 byte length (like Elixir's
// byte_size/1 on a binary), not JS string length, since sealed is base64url
// text that could in principle contain multi-byte characters.
function validateSealed(sealed: unknown): ErrorBody | null {
  if (typeof sealed !== "string" || sealed.length === 0) {
    return validationError("sealed is required");
  }
  if (new TextEncoder().encode(sealed).length > MAX_SEALED_BYTES) {
    return validationError(`sealed exceeds ${MAX_SEALED_BYTES} bytes`);
  }
  return null;
}

export function registerPairingRoutes(app: Hono<{ Bindings: Env }>): void {
  // Create claim code for node_addr (v1). Handler.create_claim/1 + router.ex
  // POST /pairing/claim. Response is {"claim_code": "..."} -- NOT {"code",
  // "expires_in"}; the Elixir never returns an expires_in field at all.
  app.post("/pairing/claim", async (c) => {
    if (await limited(c.env.PAIRING_CREATE_LIMITER, ipOf(c))) {
      return rateLimitedResponse(false);
    }

    const body = (await c.req.json().catch(() => null)) as { node_addr?: unknown } | null;
    const invalid = validateNodeAddr(body?.node_addr);
    if (invalid) return c.json(invalid, 400);

    const code = generateCode();
    await storeClaim(c.env, V1_PREFIX + code, body!.node_addr as string, TTL_SECONDS);

    return c.json({ claim_code: code }, 200);
  });

  // Get node_addr for claim code (v1). router.ex applies allow_web_player/1
  // before the rate-limit check, so every response below -- 200, 404, and a
  // 429 from the limiter -- carries the CORS origin header.
  app.get("/pairing/claim/:code", async (c) => {
    if (await limited(c.env.PAIRING_READ_LIMITER, ipOf(c))) {
      return rateLimitedResponse(true);
    }

    const key = V1_PREFIX + normalizeCode(c.req.param("code"));
    const value = await readClaim(c.env, key);
    if (!value) return c.json(notFoundError(), 404, corsOrigin());
    return c.json({ node_addr: value }, 200, corsOrigin());
  });

  // Preflight for the claim lookup. Elixir sets allow-methods but never
  // allow-headers, even here.
  app.options("/pairing/claim/:code", (c) =>
    c.body(null, 204, corsOrigin({ "access-control-allow-methods": "GET, DELETE" })),
  );

  // Delete claim code after successful pairing. Idempotent in the Elixir
  // (delete_claim/1 never distinguishes "existed" from "didn't"), so this
  // always answers 204, never 404.
  app.delete("/pairing/claim/:code", async (c) => {
    if (await limited(c.env.PAIRING_READ_LIMITER, ipOf(c))) {
      return rateLimitedResponse(true);
    }
    const key = V1_PREFIX + normalizeCode(c.req.param("code"));
    await deleteClaim(c.env, key);
    return c.body(null, 204, corsOrigin());
  });

  // v2: the relay stores a blinded lookup key against a sealed blob and can
  // read neither the claim code nor the server's node address. This is the
  // only pairing surface the Elixir backend itself calls
  // (lib/mydia/remote_access.ex) -- the v1 routes above exist for the
  // Flutter player's fallback path only.
  app.post("/pairing/v2/claim", async (c) => {
    if (await limited(c.env.PAIRING_CREATE_LIMITER, ipOf(c))) {
      return rateLimitedResponse(false);
    }

    const body = (await c.req.json().catch(() => null)) as
      | { lookup_key?: unknown; sealed?: unknown }
      | null;

    const keyError = validateLookupKey(body?.lookup_key);
    if (keyError) return c.json(keyError, 400);
    const sealedError = validateSealed(body?.sealed);
    if (sealedError) return c.json(sealedError, 400);

    await storeClaim(
      c.env,
      V2_PREFIX + (body!.lookup_key as string),
      body!.sealed as string,
      TTL_SECONDS,
    );
    return c.body(null, 204);
  });

  app.get("/pairing/v2/claim/:lookup_key", async (c) => {
    if (await limited(c.env.PAIRING_READ_LIMITER, ipOf(c))) {
      return rateLimitedResponse(true);
    }

    const lookupKey = c.req.param("lookup_key");
    const keyError = validateLookupKey(lookupKey);
    if (keyError) return c.json(keyError, 400, corsOrigin());

    const value = await readClaim(c.env, V2_PREFIX + lookupKey);
    if (!value) return c.json(notFoundError(), 404, corsOrigin());
    return c.json({ sealed: value }, 200, corsOrigin());
  });

  app.options("/pairing/v2/claim/:lookup_key", (c) =>
    c.body(null, 204, corsOrigin({ "access-control-allow-methods": "GET, DELETE" })),
  );

  app.delete("/pairing/v2/claim/:lookup_key", async (c) => {
    if (await limited(c.env.PAIRING_READ_LIMITER, ipOf(c))) {
      return rateLimitedResponse(true);
    }

    const lookupKey = c.req.param("lookup_key");
    const keyError = validateLookupKey(lookupKey);
    if (keyError) return c.json(keyError, 400, corsOrigin());

    await deleteClaim(c.env, V2_PREFIX + lookupKey);
    return c.body(null, 204, corsOrigin());
  });
}
