import { env, SELF, fetchMock, applyD1Migrations } from "cloudflare:test";
import { describe, it, expect, beforeAll, afterEach } from "vitest";
import {
  validateSubmission,
  sanitizeHeaderValue,
  feedbackInstanceRateLimitKey,
  checkFeedbackRateLimit,
  FEEDBACK_RATE_LIMIT,
} from "../../src/feedback/ingest";

const json = { "content-type": "application/json" };
const FEEDBACK_URL = "https://relay.mydia.dev/feedback";

interface CreatedResponse {
  status: string;
  id: string;
}

interface ValidationErrorResponse {
  error: string;
  errors: string[];
}

interface RateLimitedResponse {
  error: string;
  message: string;
}

interface FeedbackRowShape {
  id: string;
  type: string;
  message: string;
  contact: string | null;
  instance_id: string | null;
  mydia_version: string | null;
  state: string;
}

// Every request now spends a rate-limit slot (including rejected ones -- see
// the "rate limiting" describe block below), so tests that aren't
// deliberately exercising the limiter must not share an IP: otherwise they'd
// all pile into the "unknown" bucket and start tripping 429s on each other.
// Mirrors test/pairing/routes.test.ts's freshIp() for the same reason.
let nextTestIp = 10;
function freshIp(): string {
  return `198.51.100.${nextTestIp++}`;
}

async function getRowByVersion(version: string): Promise<FeedbackRowShape | null> {
  return env.DB.prepare(
    "SELECT id, type, message, contact, instance_id, mydia_version, state FROM feedback_submissions WHERE mydia_version = ?",
  )
    .bind(version)
    .first<FeedbackRowShape>();
}

async function tableCounts(): Promise<{ submissions: number; rateLimits: number }> {
  const [submissions, rateLimits] = await Promise.all([
    env.DB.prepare("SELECT COUNT(*) AS n FROM feedback_submissions").first<{ n: number }>(),
    env.DB.prepare("SELECT COUNT(*) AS n FROM feedback_rate_limits").first<{ n: number }>(),
  ]);
  return { submissions: submissions!.n, rateLimits: rateLimits!.n };
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  fetchMock.activate();
  fetchMock.disableNetConnect();
});

// RESEND_API_KEY is set for every test (vitest.config.ts), so every POST
// /feedback that gets past validation attempts a real notification call and
// each such test must account for (mock) exactly one -- an unconsumed
// interceptor is a real bug here, not noise, since it means the code
// silently stopped calling out to Resend.
afterEach(() => fetchMock.assertNoPendingInterceptors());

function mockResendSuccess(): void {
  fetchMock
    .get("https://api.resend.com")
    .intercept({ method: "POST", path: "/emails" })
    .reply(200, { id: "email-1" });
}

describe("validateSubmission", () => {
  it("accepts the three allowed types", () => {
    for (const type of ["bug", "idea", "question"]) {
      expect(validateSubmission({ type, message: "hi" }).ok).toBe(true);
    }
  });

  it("rejects a type outside the allowed set with router.ex's exact message", () => {
    const result = validateSubmission({ type: "rant", message: "hi" });
    expect(result.ok).toBe(false);
    expect(!result.ok && result.errors).toEqual(["Invalid type: rant"]);
  });

  it("requires both type and message, matching router.ex's exact messages", () => {
    const missingMessage = validateSubmission({ type: "bug" });
    expect(!missingMessage.ok && missingMessage.errors).toEqual([
      "Missing required field: message",
    ]);

    const missingType = validateSubmission({ message: "hi" });
    expect(!missingType.ok && missingType.errors).toEqual(["Missing required field: type"]);
  });

  // router.ex's require_feedback_field/3 treats a whitespace-only value as
  // absent (String.trim(value) != ""), same as a missing field entirely.
  it("treats a whitespace-only message as missing", () => {
    const result = validateSubmission({ type: "bug", message: "   " });
    expect(!result.ok && result.errors).toContain("Missing required field: message");
  });

  // The relay never reads a client-supplied `state` at all (router.ex's
  // get_feedback_param only reads type/message/contact/instance_id/
  // mydia_version) -- state is always server-assigned. A client sending
  // state: "archived" must not be able to bypass triage.
  it("defaults state to unread and ignores a client-supplied state", () => {
    const result = validateSubmission({ type: "bug", message: "hi", state: "archived" });
    expect(result.ok && result.value.state).toBe("unread");
  });

  // router.ex's validate_optional_feedback_field/3: nil is fine, any string
  // is fine, anything else (a map, here) is rejected outright rather than
  // silently coerced to null.
  it("rejects a non-string optional field instead of silently dropping it", () => {
    const result = validateSubmission({ type: "bug", message: "hi", contact: { x: 1 } });
    expect(!result.ok && result.errors).toEqual(["Invalid field: contact"]);
  });

  it("trims contact/instance_id/mydia_version and nulls out whitespace-only values", () => {
    const result = validateSubmission({
      type: "bug",
      message: "hi",
      contact: "  a@b.com  ",
      instance_id: "   ",
    });
    expect(result.ok && result.value.contact).toBe("a@b.com");
    expect(result.ok && result.value.instance_id).toBeNull();
  });

  it("stores type and message untrimmed, as router.ex does", () => {
    const result = validateSubmission({ type: "bug", message: "  hi  " });
    expect(result.ok && result.value.message).toBe("  hi  ");
  });
});

describe("sanitizeHeaderValue", () => {
  it("strips CR and LF so a crafted contact cannot inject mail headers", () => {
    expect(sanitizeHeaderValue("a@b.com\r\nBcc: victim@example.com")).not.toContain("\r");
    expect(sanitizeHeaderValue("a@b.com\r\nBcc: victim@example.com")).not.toContain("\n");
  });
});

// router.ex's feedback_rate_limit_instance_id/2, including its T-236
// anti-collision namespacing.
describe("feedbackInstanceRateLimitKey", () => {
  it("namespaces a supplied instance_id separately from the IP fallback", () => {
    expect(feedbackInstanceRateLimitKey("abc", "1.2.3.4")).toBe("instance:supplied:abc");
    expect(feedbackInstanceRateLimitKey(undefined, "1.2.3.4")).toBe("instance:fallback:1.2.3.4");
    expect(feedbackInstanceRateLimitKey(null, "1.2.3.4")).toBe("instance:fallback:1.2.3.4");
    expect(feedbackInstanceRateLimitKey("", "1.2.3.4")).toBe("instance:fallback:1.2.3.4");
  });

  // Regression guard for the exact T-236 attack router.ex's own test suite
  // covers: a caller-supplied instance_id crafted to look like the fallback
  // key format must not land in the same bucket as the real fallback.
  it("cannot be made to collide with another IP's fallback bucket by crafting instance_id", () => {
    const victimIp = "203.0.113.99";
    const attackerKey = feedbackInstanceRateLimitKey(`fallback:${victimIp}`, "203.0.113.1");
    const victimKey = feedbackInstanceRateLimitKey(undefined, victimIp);
    expect(attackerKey).not.toBe(victimKey);
  });
});

describe("checkFeedbackRateLimit", () => {
  // Feedback submissions carry no client-supplied timestamp (unlike crash
  // reports' occurred_at), so hour rollover is tested by calling the
  // exported function directly with explicit hour_bucket values rather than
  // faking the Workers runtime clock, which vi.useFakeTimers() cannot reach
  // inside workerd's own isolate.
  it("resets the count once the hour bucket advances", async () => {
    const ip = freshIp();
    const hourA = 500_000;
    const hourB = 500_001;

    for (let i = 0; i < FEEDBACK_RATE_LIMIT; i++) {
      const result = await checkFeedbackRateLimit(env.DB, ip, undefined, hourA);
      expect(result.allowed).toBe(true);
    }

    const saturated = await checkFeedbackRateLimit(env.DB, ip, undefined, hourA);
    expect(saturated.allowed).toBe(false);
    expect(saturated.writes).toBe(0);

    const nextHour = await checkFeedbackRateLimit(env.DB, ip, undefined, hourB);
    expect(nextHour.allowed).toBe(true);
  });
});

describe("POST /feedback", () => {
  it("stores a submission and returns 201 with the {status, id} shape router.ex sends", async () => {
    mockResendSuccess();

    const res = await SELF.fetch(FEEDBACK_URL, {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify({
        type: "bug",
        message: "Scanner missed a file",
        mydia_version: "1.2.3",
      }),
    });

    expect(res.status).toBe(201);
    const body = await res.json<CreatedResponse>();
    expect(body.status).toBe("created");
    expect(typeof body.id).toBe("string");

    const row = await getRowByVersion("1.2.3");
    expect(row).toMatchObject({ type: "bug", message: "Scanner missed a file", state: "unread" });
  });

  // Mydia.Feedback.Sender.post/1 pattern-matches on exactly {status: 400,
  // body: response} to extract {:validation_error, errors}. A 422 here (the
  // brief's original status) falls through Sender's case statement into the
  // generic {:http_error, status, body} branch instead, silently discarding
  // the structured validation errors for every caller that checks for
  // {:validation_error, _}.
  it("returns 400 (not 422) with router.ex's exact error shape for an invalid submission", async () => {
    const res = await SELF.fetch(FEEDBACK_URL, {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify({ type: "rant", message: "" }),
    });
    expect(res.status).toBe(400);
    const body = await res.json<ValidationErrorResponse>();
    expect(body.error).toBe("Validation failed");
    expect(body.errors).toContain("Missing required field: message");
    expect(body.errors).toContain("Invalid type: rant");
  });

  it("returns 400 with a distinct body when the message exceeds router.ex's 4096-byte limit", async () => {
    const res = await SELF.fetch(FEEDBACK_URL, {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify({ type: "bug", message: "a".repeat(4097) }),
    });
    expect(res.status).toBe(400);
    const body = await res.json<{ error: string; limit_bytes: number }>();
    expect(body).toEqual({ error: "Message too long", limit_bytes: 4096 });
  });

  it("accepts a message at exactly the 4096-byte limit", async () => {
    mockResendSuccess();
    const res = await SELF.fetch(FEEDBACK_URL, {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify({ type: "bug", message: "a".repeat(4096) }),
    });
    expect(res.status).toBe(201);
  });

  it("still stores the submission when the notification email fails", async () => {
    // Losing the row because a mail provider is down would be a worse
    // failure than a missed notification.
    fetchMock
      .get("https://api.resend.com")
      .intercept({ method: "POST", path: "/emails" })
      .reply(500, "provider down");

    const res = await SELF.fetch(FEEDBACK_URL, {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify({ type: "idea", message: "Keep the row", mydia_version: "9.9.9" }),
    });

    expect(res.status).toBe(201);
    const row = await getRowByVersion("9.9.9");
    expect(row).not.toBeNull();
  });

  it("sets reply-to only when contact looks like an email address, matching notifier.ex", async () => {
    let capturedBody = "";
    fetchMock
      .get("https://api.resend.com")
      .intercept({
        method: "POST",
        path: "/emails",
        body: (b) => {
          capturedBody = b;
          return true;
        },
      })
      .reply(200, { id: "email-2" });

    const res = await SELF.fetch(FEEDBACK_URL, {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify({
        type: "bug",
        message: "Subtitles are offset",
        contact: "  Reporter@Example.COM  ",
      }),
    });
    expect(res.status).toBe(201);

    const sent = JSON.parse(capturedBody) as { reply_to?: string; subject: string };
    expect(sent.reply_to).toBe("Reporter@Example.COM");
    expect(sent.subject).toContain("bug");
  });

  it("omits reply-to when contact is not an email address", async () => {
    let capturedBody = "";
    fetchMock
      .get("https://api.resend.com")
      .intercept({
        method: "POST",
        path: "/emails",
        body: (b) => {
          capturedBody = b;
          return true;
        },
      })
      .reply(200, { id: "email-3" });

    const res = await SELF.fetch(FEEDBACK_URL, {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify({
        type: "idea",
        message: "Add a dark theme",
        contact: "@some-github-handle",
      }),
    });
    expect(res.status).toBe(201);

    const sent = JSON.parse(capturedBody) as { reply_to?: string };
    expect(sent.reply_to).toBeUndefined();
  });

  it("returns 400 for a body that is not valid JSON at all, without touching the rate limiter", async () => {
    const res = await SELF.fetch(FEEDBACK_URL, {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: "not json",
    });
    expect(res.status).toBe(400);
    const body = await res.json<{ error: string }>();
    expect(body.error).toBe("Invalid JSON");
    // No rate-limit check ran at all for genuinely malformed syntax
    // (mirrors Plug.Parsers rejecting it before routing in the Elixir), so
    // no x-relay-d1-writes header is present.
    expect(res.headers.get("x-relay-d1-writes")).toBeNull();
  });

  it("still consumes a rate-limit slot for parseable-but-non-object JSON, matching router.ex's ordering", async () => {
    // router.ex checks rate limits inside handle_feedback/1, BEFORE
    // process_feedback/2 (where the is-this-a-map check actually lives) is
    // ever called -- so a syntactically valid but non-object body still
    // spends a slot, unlike genuinely malformed syntax above.
    const res = await SELF.fetch(FEEDBACK_URL, {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify([1, 2, 3]),
    });
    expect(res.status).toBe(400);
    const body = await res.json<{ error: string }>();
    expect(body.error).toBe("Invalid JSON");
    expect(res.headers.get("x-relay-d1-writes")).not.toBe("0");
  });
});

describe("POST /feedback rate limiting", () => {
  it("rejects the 6th submission from one IP within the hour with router.ex's exact 429 shape", async () => {
    const ip = freshIp();

    // Distinct instance_id per request so it's the IP bucket, not the
    // instance bucket, that saturates.
    for (let i = 0; i < FEEDBACK_RATE_LIMIT; i++) {
      mockResendSuccess();
      const res = await SELF.fetch(FEEDBACK_URL, {
        method: "POST",
        headers: { ...json, "cf-connecting-ip": ip },
        body: JSON.stringify({ type: "bug", message: `Message ${i}`, instance_id: `inst-${i}` }),
      });
      expect(res.status).toBe(201);
    }

    const before = await tableCounts();

    const res = await SELF.fetch(FEEDBACK_URL, {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": ip },
      body: JSON.stringify({ type: "bug", message: "Message 6", instance_id: "inst-6" }),
    });

    expect(res.status).toBe(429);
    expect(res.headers.get("retry-after")).toBe("3600");
    // The IP bucket is already saturated: the check costs a read, and the
    // `with`-style short-circuit means the instance check (and the D1
    // insert) is never even reached -- zero writes total, asserted both via
    // the write-count header (Task 11's instrument, since a table's row
    // COUNT(*) can't distinguish a skipped write from an unconditional
    // UPDATE that happens not to change a row) and via the row-count delta
    // across both tables below.
    expect(res.headers.get("x-relay-d1-writes")).toBe("0");
    const body = await res.json<RateLimitedResponse>();
    expect(body).toEqual({
      error: "Too many requests",
      message: "Rate limit exceeded. Please try again later.",
    });

    const after = await tableCounts();
    expect(after).toEqual(before);
  });

  it("rejects the 6th submission from one instance id even when the IP differs each time", async () => {
    const instanceId = `shared-${freshIp()}`;

    for (let i = 0; i < FEEDBACK_RATE_LIMIT; i++) {
      mockResendSuccess();
      const res = await SELF.fetch(FEEDBACK_URL, {
        method: "POST",
        headers: { ...json, "cf-connecting-ip": freshIp() },
        body: JSON.stringify({ type: "bug", message: `Message ${i}`, instance_id: instanceId }),
      });
      expect(res.status).toBe(201);
    }

    const res = await SELF.fetch(FEEDBACK_URL, {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": freshIp() },
      body: JSON.stringify({ type: "bug", message: "Message 6", instance_id: instanceId }),
    });

    expect(res.status).toBe(429);
    expect(res.headers.get("retry-after")).toBe("3600");
    const body = await res.json<RateLimitedResponse>();
    expect(body).toEqual({
      error: "Too many requests",
      message: "Rate limit exceeded. Please try again later.",
    });
  });

  // Integration-level version of the T-236 regression above: an attacker
  // spreading requests across throwaway IPs, all supplying instance_id
  // crafted to mimic the victim's fallback-key format, must not exhaust the
  // victim's real (no-instance_id) fallback bucket.
  it("does not let a crafted instance_id collide with another caller's IP-fallback bucket", async () => {
    const victimIp = freshIp();

    for (let i = 0; i < FEEDBACK_RATE_LIMIT; i++) {
      mockResendSuccess();
      const res = await SELF.fetch(FEEDBACK_URL, {
        method: "POST",
        headers: { ...json, "cf-connecting-ip": freshIp() },
        body: JSON.stringify({
          type: "bug",
          message: `Attacker ${i}`,
          instance_id: `fallback:${victimIp}`,
        }),
      });
      expect(res.status).toBe(201);
    }

    // The victim, sending from their own IP with no instance_id at all,
    // must still get through.
    mockResendSuccess();
    const res = await SELF.fetch(FEEDBACK_URL, {
      method: "POST",
      headers: { ...json, "cf-connecting-ip": victimIp },
      body: JSON.stringify({ type: "bug", message: "Victim" }),
    });
    expect(res.status).toBe(201);
  });
});
