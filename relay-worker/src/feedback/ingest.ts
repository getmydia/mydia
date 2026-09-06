import type { Hono } from "hono";
import type { Env } from "../env";

// router.ex's validate_feedback_type/2: only these three are accepted.
const TYPES = ["bug", "idea", "question"] as const;

// router.ex's `process_feedback/2` never reads a `state` from the request at
// all (get_feedback_param only reads type/message/contact/instance_id/
// mydia_version) -- every submission is created via Submission's schema
// default. A client-supplied `state` is silently ignored, not merely
// rejected, matching the producer exactly: it must not be a way to bypass
// triage by posting straight to "archived".
const DEFAULT_STATE = "unread";

export const MESSAGE_MAX_BYTES = 4096;

export interface Submission {
  id: string;
  type: string;
  message: string;
  contact: string | null;
  instance_id: string | null;
  mydia_version: string | null;
  source_ip: string | null;
  state: string;
  github_ref: string | null;
}

export interface FeedbackRow extends Submission {
  inserted_at: number;
  updated_at: number;
}

// Mirrors router.ex's require_feedback_field/3: is_binary(value) &&
// String.trim(value) != "" -- a value only counts as present when it is a
// string that isn't empty once whitespace is trimmed.
function isRequiredFieldPresent(value: unknown): value is string {
  return typeof value === "string" && value.trim() !== "";
}

// Mirrors router.ex's validate_feedback_type/2's own binary/non-empty guard,
// which runs independently of require_feedback_field/3 above (not gated on
// it) -- a whitespace-only type can produce BOTH "Missing required field:
// type" and "Invalid type: <raw value>" at once, same as router.ex.
function isNonEmptyBinary(value: unknown): value is string {
  return typeof value === "string" && value !== "";
}

// Mirrors router.ex's validate_optional_feedback_field/3: nil/absent is
// fine, any string (including "") is fine, anything else (a number, array,
// object, boolean) is rejected outright rather than silently coerced.
function isValidOptionalField(value: unknown): boolean {
  return value === undefined || value === null || typeof value === "string";
}

// Mirrors router.ex's normalize_optional_feedback_field/1: trims, then
// turns an empty result into nil. Unlike type/message, the stored value IS
// the trimmed string, not the raw one.
function normalizeOptional(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed === "" ? null : trimmed;
}

export function validateSubmission(
  body: Record<string, unknown>,
): { ok: true; value: Submission } | { ok: false; errors: string[] } {
  const errors: string[] = [];

  const type = body.type;
  const message = body.message;

  if (!isRequiredFieldPresent(type)) errors.push("Missing required field: type");
  if (!isRequiredFieldPresent(message)) errors.push("Missing required field: message");

  if (isNonEmptyBinary(type) && !TYPES.includes(type as (typeof TYPES)[number])) {
    errors.push(`Invalid type: ${type}`);
  }

  if (!isValidOptionalField(body.contact)) errors.push("Invalid field: contact");
  if (!isValidOptionalField(body.instance_id)) errors.push("Invalid field: instance_id");
  if (!isValidOptionalField(body.mydia_version)) errors.push("Invalid field: mydia_version");

  if (errors.length > 0) return { ok: false, errors };

  return {
    ok: true,
    value: {
      id: crypto.randomUUID(),
      // isRequiredFieldPresent narrowed these to `string` above; errors would
      // have been non-empty otherwise and we would have returned already.
      type: type as string,
      message: message as string,
      contact: normalizeOptional(body.contact),
      instance_id: normalizeOptional(body.instance_id),
      mydia_version: normalizeOptional(body.mydia_version),
      source_ip: null,
      state: DEFAULT_STATE,
      github_ref: null,
    },
  };
}

// Mirrors the guard in feedback/notifier.ex's @contact_address: strips CR
// and LF so a crafted contact or message excerpt cannot inject additional
// mail headers into the subject or reply-to fields sent to Resend's API.
export function sanitizeHeaderValue(value: string): string {
  return value.replace(/[\r\n]/g, " ").trim();
}

// Mirrors notifier.ex's @contact_address: `\A[^\s@,;:<>"]+@[^\s@,;:<>"]+\.[^\s@,;:<>"]+\z`.
// Deliberately whole-string anchored (JS's `^`/`$` without the `m` flag
// already behave like Elixir's `\A`/`\z`, unlike Elixir's own `^`/`$`, which
// are per-line anchors -- this is the exact case that comment warns about),
// so an embedded CR/LF can never sneak an extra "line" past the check.
const CONTACT_ADDRESS = /^[^\s@,;:<>"]+@[^\s@,;:<>"]+\.[^\s@,;:<>"]+$/;

function contactAsReplyTo(contact: string | null): string | null {
  if (contact === null) return null;
  return CONTACT_ADDRESS.test(contact) ? contact : null;
}

// notifier.ex's subject_preview/1: collapse all whitespace runs (not just
// CR/LF) to a single space, trim, then cap at 80 characters.
function subjectPreview(message: string): string {
  return message.replace(/\s+/g, " ").trim().slice(0, 80);
}

function optionalValue(value: string | null): string {
  return value ?? "-";
}

// Mirrors notifier.ex's deliver_new_submission/1 via Resend's HTTP API --
// Workers cannot open the SMTP connections Swoosh used. Called only after
// the row has already committed to D1 (see registerFeedbackRoutes below), so
// a Resend outage can never turn a stored submission into a client-visible
// error.
export async function notify(env: Env, submission: Submission): Promise<void> {
  if (!env.RESEND_API_KEY) return;

  const replyTo = contactAsReplyTo(submission.contact);

  const payload: Record<string, unknown> = {
    from: env.FEEDBACK_FROM,
    to: [env.FEEDBACK_TO],
    subject: sanitizeHeaderValue(
      `[Mydia feedback] ${submission.type}: ${subjectPreview(submission.message)}`,
    ),
    text: [
      "New Mydia feedback received.",
      "",
      `Type: ${submission.type}`,
      `Contact: ${optionalValue(submission.contact)}`,
      `Instance: ${optionalValue(submission.instance_id)}`,
      `Mydia version: ${optionalValue(submission.mydia_version)}`,
      `Source IP: ${optionalValue(submission.source_ip)}`,
      "",
      "Message:",
      submission.message,
    ].join("\n"),
  };

  if (replyTo) payload.reply_to = sanitizeHeaderValue(replyTo);

  await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.RESEND_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
}

// -- Rate limiting -------------------------------------------------------
//
// router.ex's handle_feedback/1: two independent checks -- 5 requests/hour
// by client IP, and 5 requests/hour by an anti-collision-namespaced
// instance id -- both gating BEFORE process_feedback/2 (validation and the
// D1 insert) ever runs. This endpoint is public and unauthenticated with no
// per-identity cap otherwise, sharing D1's 100k-row-writes/day free-tier
// budget with crash ingest, so leaving it unthrottled risks the same class
// of exhaustion Task 11 spent two rounds bounding for /crashes/report --
// except here every accepted row also fires an unthrottled outbound Resend
// call.
//
// Cloudflare's `ratelimit` binding (PROXY_LIMITER etc.) cannot express this:
// its `simple.period` only supports 10 or 60 seconds (confirmed against
// node_modules/wrangler/config-schema.json), so "5 per hour" needs a D1
// bucket instead, structured like crashes/ingest.ts's ingest_buckets.

export const FEEDBACK_RATE_LIMIT = 5;

interface RateLimitBucketRow {
  hour_bucket: number;
  count: number;
}

// SHA-256 hex digest, same primitive crashes/ingest.ts's fingerprintOf uses.
// Bounds every bucket_key to a fixed size regardless of what a client sends
// -- see feedbackInstanceRateLimitKey below for why that matters.
async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Mirrors router.ex's feedback_rate_limit_instance_id/2's T-236
// anti-collision namespacing: the supplied and fallback cases are tagged
// with fixed, disjoint literal prefixes applied BEFORE the
// caller-controlled or IP-derived value, not interpolated together into one
// string a caller could reproduce. A caller sending
// instance_id: "fallback:<victim ip>" therefore produces
// "instance:supplied:<hash of that literal string>", which can never equal
// another caller's real fallback key "instance:fallback:<hash of their
// ip>" -- only the fallback path can ever produce a key with that prefix,
// and hashing doesn't change that: the prefix, not the hash, is what
// prevents the collision.
//
// The value is hashed (not used raw) because, unlike an IP address --
// bounded in size and cardinality by Cloudflare's own edge, which sets
// cf-connecting-ip and isn't something an attacker can cheaply manufacture
// more of -- `instance_id` is an arbitrary client-supplied JSON string with
// no length cap anywhere (validateSubmission only bounds `message`), and
// this check runs BEFORE validation. Without hashing, one row lands in
// feedback_rate_limits per distinct instance_id ever sent, sized by
// whatever the attacker chose to send, at zero attacker cost and no upper
// bound -- unlike crashes/ingest.ts's ingest_buckets, whose cardinality is
// bounded by real crash/install diversity, not attacker-paced. Hashing
// makes every row a fixed ~90 bytes regardless of input; sweepStale
// FeedbackRateLimits (src/obs/sweep.ts) bounds the row *count* the same way
// Elixir's ETS-backed RateLimiter self-evicts via its own periodic cleaner.
export async function feedbackInstanceRateLimitKey(
  rawInstanceId: unknown,
  ip: string,
): Promise<string> {
  if (typeof rawInstanceId === "string" && rawInstanceId !== "") {
    return `instance:supplied:${await sha256Hex(rawInstanceId)}`;
  }
  return `instance:fallback:${await sha256Hex(ip)}`;
}

export interface FeedbackRateLimitResult {
  allowed: boolean;
  writes: number;
}

// Final-review fix round: the two-statement read-then-write shape this
// function used to have (a SELECT, decide in JS, then a SEPARATE INSERT) is
// exactly what let 20 concurrent identical-IP submissions all get admitted
// against this table's 5/hour cap in a real reproduction -- D1 only
// guarantees ordering within a single statement (or a .batch()), not across
// two independent .prepare()/.run() calls, so concurrent requests could all
// read the same pre-increment state and all decide to admit.
//
// The fix keeps the cheap read as a non-authoritative pre-check (once a
// bucket is solidly saturated for the hour, this still costs exactly one
// read and zero writes, same as before), but the actual admission decision
// now comes from ONE atomic `INSERT ... ON CONFLICT DO UPDATE ... RETURNING`
// statement: `count` is an uncapped, monotonic-within-the-hour counter, and
// SQLite serialises writers to the same row even without an explicit
// transaction wrapper, so the Nth request to actually commit is guaranteed a
// unique `count = N` -- "admitted" is simply `count <= FEEDBACK_RATE_LIMIT`,
// decided from the RETURNED value, with no stale read in the decision path.
async function checkAndIncrementBucket(
  db: D1Database,
  bucketKey: string,
  hourBucket: number,
): Promise<FeedbackRateLimitResult> {
  const existing = await db
    .prepare("SELECT hour_bucket, count FROM feedback_rate_limits WHERE bucket_key = ?")
    .bind(bucketKey)
    .first<RateLimitBucketRow>();

  if (existing && existing.hour_bucket === hourBucket && existing.count >= FEEDBACK_RATE_LIMIT) {
    return { allowed: false, writes: 0 };
  }

  const result = await db
    .prepare(
      `INSERT INTO feedback_rate_limits (bucket_key, hour_bucket, count)
       VALUES (?, ?, 1)
       ON CONFLICT(bucket_key) DO UPDATE SET
         count = CASE
           WHEN feedback_rate_limits.hour_bucket != excluded.hour_bucket THEN 1
           ELSE feedback_rate_limits.count + 1
         END,
         hour_bucket = excluded.hour_bucket
       RETURNING count`,
    )
    .bind(bucketKey, hourBucket)
    .run<{ count: number }>();

  const count = result.results[0]?.count ?? 0;
  return { allowed: count <= FEEDBACK_RATE_LIMIT, writes: result.meta.rows_written };
}

// Mirrors router.ex's `with {:ok, _} <- check(ip), {:ok, _} <- check(instance)
// do process_feedback(...) end`. The IP check runs first; same as the
// Elixir's ETS-backed RateLimiter (which inserts the request into a bucket
// the moment that bucket's own check passes), its write happens whenever it
// INDIVIDUALLY passes -- independent of whether the instance check that
// follows then rejects the request. The instance check is never reached at
// all once the IP check itself rejects (a `with` short-circuits), so a
// fully-saturated-on-IP request costs one read and zero writes total.
export async function checkFeedbackRateLimit(
  db: D1Database,
  ip: string,
  rawInstanceId: unknown,
  hourBucket: number,
): Promise<FeedbackRateLimitResult> {
  const ipResult = await checkAndIncrementBucket(db, `ip:${ip}`, hourBucket);
  if (!ipResult.allowed) return ipResult;

  const instanceKey = await feedbackInstanceRateLimitKey(rawInstanceId, ip);
  const instanceResult = await checkAndIncrementBucket(db, instanceKey, hourBucket);

  return {
    allowed: instanceResult.allowed,
    writes: ipResult.writes + instanceResult.writes,
  };
}

const RATE_LIMITED_BODY = {
  error: "Too many requests",
  message: "Rate limit exceeded. Please try again later.",
} as const;

export function registerFeedbackRoutes(app: Hono<{ Bindings: Env }>): void {
  // This is the public ingest endpoint every mydia install calls -- a wire
  // contract that must never move. It stays at bare /feedback; the
  // maintainer dashboard (src/dashboards/feedback.ts) lives at the separate
  // /admin/feedback path specifically so the two can be governed
  // independently by Cloudflare Access, which -- like Hono's router --
  // matches on path only and cannot gate one HTTP method on a shared path
  // while leaving another method on that same path alone. Keeping this an
  // app.post (not app.all) is still correct in its own right: nothing else
  // should ever answer other methods at this exact path.
  app.post("/feedback", async (c) => {
    // undefined here means the body wasn't parseable JSON *at all* -- this
    // is the one case that never reaches Elixir's controller action, since
    // Plug.Parsers rejects genuinely malformed syntax before routing, so it
    // is also the one case that bypasses rate limiting entirely.
    const parsed: unknown = await c.req.json().catch(() => undefined);
    if (parsed === undefined) {
      return c.json({ error: "Invalid JSON", message: "Request body must be valid JSON" }, 400);
    }

    const isObject = parsed !== null && typeof parsed === "object" && !Array.isArray(parsed);
    const body = isObject ? (parsed as Record<string, unknown>) : {};

    const ip = c.req.header("cf-connecting-ip") ?? "unknown";
    const hourBucket = Math.floor(Date.now() / 3_600_000);

    // Final-review fix round: the atomic, D1-free burst guard in front of
    // checkFeedbackRateLimit below. See wrangler.jsonc's
    // FEEDBACK_INGEST_LIMITER comment for the numbers and rationale. Keyed
    // on IP -- the identity the demonstrated race actually exploited (20
    // concurrent identical-IP submissions, all 20 admitted against the
    // 5/hour cap) -- and checked before D1 is touched at all, same ordering
    // as the D1-backed check it guards (both run before validation, matching
    // router.ex's handle_feedback/1).
    const { success: burstOk } = await c.env.FEEDBACK_INGEST_LIMITER.limit({
      key: `feedback:${ip}`,
    });
    if (!burstOk) {
      return c.json(RATE_LIMITED_BODY, 429, {
        "retry-after": "10",
        "x-relay-d1-writes": "0",
      });
    }

    // router.ex checks both rate limits BEFORE process_feedback/2 runs at
    // all -- before it even checks whether the body decoded to a proper
    // JSON object -- so a parseable-but-non-object body, or one that will
    // go on to fail field validation, still spends a rate-limit slot.
    const rateLimit = await checkFeedbackRateLimit(c.env.DB, ip, body.instance_id, hourBucket);
    if (!rateLimit.allowed) {
      return c.json(RATE_LIMITED_BODY, 429, {
        "retry-after": "3600",
        "x-relay-d1-writes": String(rateLimit.writes),
      });
    }

    // router.ex's validate_feedback(_) catch-all: params must be a JSON
    // object (a map on the Elixir side), not an array, string, number, or
    // null.
    if (!isObject) {
      return c.json(
        { error: "Invalid JSON", message: "Request body must be valid JSON" },
        400,
        { "x-relay-d1-writes": String(rateLimit.writes) },
      );
    }

    const result = validateSubmission(body);
    if (!result.ok) {
      return c.json({ error: "Validation failed", errors: result.errors }, 400, {
        "x-relay-d1-writes": String(rateLimit.writes),
      });
    }

    // Only checked once the other validations pass, matching router.ex's
    // `cond` ordering: errors != [] short-circuits before the byte-length
    // check ever runs. Uses the RAW (untrimmed) message, same as
    // byte_size(message) does on the Elixir side.
    const messageBytes = new TextEncoder().encode(result.value.message).length;
    if (messageBytes > MESSAGE_MAX_BYTES) {
      return c.json(
        { error: "Message too long", limit_bytes: MESSAGE_MAX_BYTES },
        400,
        { "x-relay-d1-writes": String(rateLimit.writes) },
      );
    }

    const now = Math.floor(Date.now() / 1000);
    const submission: Submission = {
      ...result.value,
      source_ip: c.req.header("cf-connecting-ip") ?? null,
    };

    const insertResult = await c.env.DB.prepare(
      `INSERT INTO feedback_submissions
         (id, type, message, contact, instance_id, mydia_version, source_ip,
          state, github_ref, inserted_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
      .bind(
        submission.id,
        submission.type,
        submission.message,
        submission.contact,
        submission.instance_id,
        submission.mydia_version,
        submission.source_ip,
        submission.state,
        submission.github_ref,
        now,
        now,
      )
      .run();

    // The row is already committed above. A Resend outage must never turn a
    // stored submission into a 500 that makes Mydia.Feedback.Sender retry
    // and duplicate it -- Sender only recognises 201 as success.
    c.executionCtx.waitUntil(notify(c.env, submission).catch(() => undefined));

    return c.json({ status: "created", id: submission.id }, 201, {
      "x-relay-d1-writes": String(rateLimit.writes + insertResult.meta.rows_written),
    });
  });
}
