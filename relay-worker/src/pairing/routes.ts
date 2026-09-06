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
export const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const CODE_LENGTH = 6;

type PairingContext = Context<{ Bindings: Env }>;
type ErrorBody = { error: string; message: string };

// Rejection sampling, not `byte % 31`. 256 is not a multiple of the
// alphabet's 31 characters: taking the modulo of a uniform byte maps nine
// byte values onto each of the first eight characters and eight onto each of
// the remaining twenty-three, so those eight are 12.5% likelier per position
// than the rest. Over a 6-character code that is a measurable skew in the
// search space an attacker guessing a live claim has to cover, which is the
// only property this code has -- it is the whole secret protecting a pairing
// claim for its 300-second TTL. CodeQL flags the modulo form directly (alert
// 249, "Creating biased random numbers from a cryptographically secure
// source").
//
// 248 is the largest multiple of 31 that fits in a byte, so discarding
// 248-255 leaves exactly 8 uniform values per character. Rejection is drawn
// from a fresh block rather than a single fixed-size draw: ~3.1% of bytes are
// rejected, so a 6-character code almost always completes on the first block,
// and the loop is what makes "almost always" irrelevant to correctness.
// Exported so test/pairing/routes.test.ts can sample it directly. Going
// through POST /pairing/claim instead would mean paying PAIRING_CREATE_LIMITER
// and a D1 write per sample, and a uniformity check needs thousands.
export const REJECTION_THRESHOLD = 248; // floor(256 / 31) * 31

export function generateCode(): string {
  const chars: string[] = [];
  while (chars.length < CODE_LENGTH) {
    const bytes = crypto.getRandomValues(new Uint8Array(CODE_LENGTH));
    for (const b of bytes) {
      if (b >= REJECTION_THRESHOLD) continue;
      chars.push(CODE_ALPHABET[b % CODE_ALPHABET.length]);
      if (chars.length === CODE_LENGTH) break;
    }
  }
  return chars.join("");
}

// Mirrors Pairing.normalize_code/1, applied by the Elixir context to every
// GET/DELETE lookup (never to create): uppercases and strips the dashes or
// spaces a person introduces reading a 6-character code aloud or typing it
// from memory. The stored key itself is always the code exactly as
// generated, so lookups must normalize to match it.
function normalizeCode(code: string): string {
  return code.toUpperCase().replace(/[-\s]/g, "");
}

// router.ex's allow_web_player/1, verbatim: origin only, no allow-headers.
// This is correct ONLY for a non-preflight request (a plain GET/DELETE/404,
// or an OPTIONS that isn't a genuine CORS preflight) -- see
// isGenuinePreflight/corsicaPreflightResponse below for the case this does
// NOT cover. A first pass at this file concluded router.ex's missing
// allow-headers was a production gap; it is not, because router.ex is not
// the whole picture in production (see below).
function corsOrigin(extra: Record<string, string> = {}): Record<string, string> {
  return { ...extra, "access-control-allow-origin": "*" };
}

// metadata_relay_web/endpoint.ex plugs Corsica GLOBALLY, in front of the
// router: `plug Corsica, origins: "*", allow_headers: ["content-type",
// "authorization", "x-request-id"], allow_methods: ["GET", "POST", "PUT",
// "DELETE", "OPTIONS"]`. Corsica's own preflight_req?/1 (verified against
// its v2.1.3 source) treats a request as a genuine preflight only when it is
// OPTIONS AND carries both an Origin header and an
// Access-Control-Request-Method header; when both are present it halts the
// plug pipeline and answers directly with send_preflight_resp/4 -- the
// router's own `options "/pairing/claim/:code"` handler (the one
// corsOrigin() above serves) is never reached at all. A bare OPTIONS missing
// either header is not a CORS request to Corsica and falls through to that
// router handler unmodified, which is what corsOrigin() continues to model.
//
// This is why send_rate_limited-style parity wasn't enough: for a genuine
// preflight, production never even reaches router.ex, so router.ex's own
// CORS gaps (no allow-headers, "GET, DELETE" methods scoped to one route)
// are irrelevant -- Corsica answers first, with its own STATIC, app-wide
// configuration, regardless of which path or which methods that specific
// route actually supports.
function isGenuinePreflight(c: PairingContext): boolean {
  return (
    c.req.header("origin") !== undefined &&
    c.req.header("access-control-request-method") !== undefined
  );
}

// Mirrors Corsica.send_preflight_resp/4 exactly for this app's static
// config, confirmed against the v2.1.3 source:
// - status 200 (Corsica's default), not the router's own 204.
// - access-control-allow-origin: "*" (origins: "*", allow_credentials not
//   set so send_wildcard_origin?/1 is true -- literal "*", no Vary header).
// - access-control-allow-methods / -headers: Enum.join(list, ",") -- a bare
//   comma, NOT ", " -- over the endpoint's full configured list, not just
//   the methods this one route supports.
// - body "" (empty), no max-age (option not configured, so Corsica never
//   sends the header at all -- there is no default value to fall back to).
function corsicaPreflightResponse(): Response {
  return new Response("", {
    status: 200,
    headers: {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET,POST,PUT,DELETE,OPTIONS",
      "access-control-allow-headers": "content-type,authorization,x-request-id",
    },
  });
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

  // Preflight for the claim lookup. A GENUINE preflight (Origin +
  // Access-Control-Request-Method) never reaches router.ex in production --
  // Corsica answers it first, globally -- so that case is served by
  // corsicaPreflightResponse() instead of this route's own 204. Anything
  // else (a bare OPTIONS probe, or one missing either header) falls through
  // to router.ex's own handler, which this models faithfully.
  app.options("/pairing/claim/:code", (c) =>
    isGenuinePreflight(c)
      ? corsicaPreflightResponse()
      : c.body(null, 204, corsOrigin({ "access-control-allow-methods": "GET, DELETE" })),
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

  // Same Corsica-vs-router split as the v1 OPTIONS handler above.
  app.options("/pairing/v2/claim/:lookup_key", (c) =>
    isGenuinePreflight(c)
      ? corsicaPreflightResponse()
      : c.body(null, 204, corsOrigin({ "access-control-allow-methods": "GET, DELETE" })),
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
