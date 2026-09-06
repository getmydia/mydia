import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { escapeHtml } from "../../src/dashboards/layout";
import { MAX_OCCURRENCE_ROWS_PER_BUCKET } from "../../src/crashes/ingest";

// Resolve/unresolve now validate the :fingerprint path segment against
// fingerprintOf's real shape (32 lowercase hex chars) before touching D1 or
// building a redirect, so every fixture exercised through those two routes
// needs a realistic-looking fingerprint rather than a short mnemonic string.
// GET routes never validate shape (D1 handles an arbitrary string safely and
// simply returns no row), so list/detail/escaping-only tests keep their
// short fixture names below.
const FP1 = "a1b2c3d4e5f60718293a4b5c6d7e8f90";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  const now = Math.floor(Date.now() / 1000);
  await env.DB.prepare(
    `INSERT INTO errors (fingerprint, kind, message, source_file, source_line,
                         status, first_seen_at, last_seen_at, occurrence_count)
     VALUES (?, 'RuntimeError', 'boom', 'm.ex', 3, 'unresolved', ?, ?, 7)`,
  )
    .bind(FP1, now, now)
    .run();
});

describe("escapeHtml", () => {
  it("escapes the characters that would let a crash message inject markup", () => {
    expect(escapeHtml('<img src=x onerror="alert(1)">')).not.toContain("<img");
    expect(escapeHtml("a & b")).toContain("&amp;");
    expect(escapeHtml('"quoted"')).toContain("&quot;");
  });
});

describe("GET /admin/errors", () => {
  it("lists error groups with their occurrence counts", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/admin/errors");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");

    const html = await res.text();
    expect(html).toContain("RuntimeError");
    expect(html).toContain("boom");
    expect(html).toContain("7");
  });

  it("shows a single error group with its occurrences", async () => {
    const res = await SELF.fetch(`https://relay.mydia.dev/admin/errors/${FP1}`);
    expect(res.status).toBe(200);
    expect(await res.text()).toContain("RuntimeError");
  });

  it("returns 404 for an unknown fingerprint", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/admin/errors/nosuchfp");
    expect(res.status).toBe(404);
  });

  it("resolves a group and reflects the new status", async () => {
    // fetch()'s default `redirect: "follow"` would otherwise chase the 303
    // and hand back the followed page's 200, hiding the redirect status this
    // assertion cares about.
    const res = await SELF.fetch(`https://relay.mydia.dev/admin/errors/${FP1}/resolve`, {
      method: "POST",
      redirect: "manual",
    });
    expect(res.status).toBe(303);

    const row = await env.DB.prepare(
      "SELECT status FROM errors WHERE fingerprint = ?",
    )
      .bind(FP1)
      .first<{ status: string }>();
    expect(row!.status).toBe("resolved");
  });

  // MINOR fix-round-1 gap: only resolve had a test; unresolve is the other
  // half of the same write-mutating pair and got none.
  it("unresolves a group and reflects the new status", async () => {
    const resolveRes = await SELF.fetch(`https://relay.mydia.dev/admin/errors/${FP1}/resolve`, {
      method: "POST",
      redirect: "manual",
    });
    expect(resolveRes.status).toBe(303);

    const unresolveRes = await SELF.fetch(
      `https://relay.mydia.dev/admin/errors/${FP1}/unresolve`,
      { method: "POST", redirect: "manual" },
    );
    expect(unresolveRes.status).toBe(303);

    const row = await env.DB.prepare(
      "SELECT status FROM errors WHERE fingerprint = ?",
    )
      .bind(FP1)
      .first<{ status: string }>();
    expect(row!.status).toBe("unresolved");
  });

  it("never renders a crash message as raw HTML", async () => {
    const now = Math.floor(Date.now() / 1000);
    await env.DB.prepare(
      `INSERT INTO errors (fingerprint, kind, message, status,
                           first_seen_at, last_seen_at, occurrence_count)
       VALUES ('fpxss', 'RuntimeError', '<script>alert(1)</script>', 'unresolved', ?, ?, 1)`,
    )
      .bind(now, now)
      .run();

    const html = await (await SELF.fetch("https://relay.mydia.dev/admin/errors")).text();
    expect(html).not.toContain("<script>alert(1)</script>");
  });

  // Every value that ends up inside an HTML attribute (not just a tag body)
  // must also be escaped -- a message containing a quote could otherwise
  // break out of a title="" or similar attribute. Also covers the fingerprint
  // itself, which is attacker-influenced (derived from attacker-controlled
  // kind/stacktrace text) and lands inside an href.
  it("escapes an attribute-breaking payload in a crash message", async () => {
    const now = Math.floor(Date.now() / 1000);
    await env.DB.prepare(
      `INSERT INTO errors (fingerprint, kind, message, status,
                           first_seen_at, last_seen_at, occurrence_count)
       VALUES ('fpattr', 'RuntimeError', '"><svg onload=alert(1)>', 'unresolved', ?, ?, 1)`,
    )
      .bind(now, now)
      .run();

    const html = await (await SELF.fetch("https://relay.mydia.dev/admin/errors")).text();
    expect(html).not.toContain('"><svg onload=alert(1)>');
    expect(html).not.toContain("<svg onload=alert(1)>");
  });

  // A fingerprint is hex-derived (fingerprintOf hashes with SHA-256 and never
  // emits HTML-meta characters), but the link href built from it must still
  // be escaped defensively rather than trusted because "the input happens to
  // be safe today".
  it("escapes the fingerprint used to build occurrence links", async () => {
    const html = await (await SELF.fetch("https://relay.mydia.dev/admin/errors")).text();
    expect(html).toContain(`href="/admin/errors/${FP1}"`);
  });

  // Mirrors dashboards/feedback.test.ts's identical regression guard: GET
  // /errors must not be a second, unauthenticated way to reach maintainer
  // crash data now that the real dashboard lives at /admin/errors --
  // whatever this returns, it must not be the dashboard.
  // registerErrorDashboard only registers routes under /admin/errors, so
  // this falls through to the app-wide 404 catch-all in src/index.ts.
  it("no longer serves the dashboard at the old /errors path", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/errors");
    expect(res.status).toBe(404);
    const body = await res.text();
    expect(body).not.toContain("RuntimeError");
    expect(body).not.toContain("<table");
  });
});

// IMPORTANT-1 fix-round-1 finding: `Number(c.req.query("page") ?? "0")` fed
// straight into a D1 OFFSET with no guard. Each of these five inputs was
// confirmed to throw `D1_ERROR: datatype mismatch`, surfaced as an unhandled
// Hono 500, before the fix -- on an endpoint that is unauthenticated today.
describe("GET /admin/errors?page= guards against hostile input", () => {
  const hostileValues = ["abc", "NaN", "Infinity", "1e300", "99999999999999999999"];

  it.each(hostileValues)("does not 500 for page=%s", async (value) => {
    const res = await SELF.fetch(
      `https://relay.mydia.dev/admin/errors?page=${encodeURIComponent(value)}`,
    );
    expect(res.status).toBe(200);
  });

  it("still paginates normally for an ordinary page number", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/admin/errors?page=1");
    expect(res.status).toBe(200);
  });

  it("clamps a negative page to the first page instead of erroring", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/admin/errors?page=-5");
    expect(res.status).toBe(200);
  });
});

// IMPORTANT-2 fix-round-1 finding: c.redirect() builds the Location header
// from the raw, decoded :fingerprint param. A value containing a CRLF
// sequence made the underlying Headers implementation throw -- fails safe
// (no header injection actually lands; the runtime itself rejects the
// control characters, and the fixed "/admin/errors/" prefix rules out an open
// redirect either way) but still surfaced as an unhandled 500 rather than a
// clean 404, on an endpoint that is unauthenticated today.
describe("POST /admin/errors/:fingerprint/resolve validates the fingerprint shape first", () => {
  it("returns 404, not a 500, for a CRLF-injected fingerprint segment", async () => {
    const res = await SELF.fetch(
      "https://relay.mydia.dev/admin/errors/abc%0D%0AInjected/resolve",
      { method: "POST", redirect: "manual" },
    );
    expect(res.status).toBe(404);
  });

  it("returns 404 for a non-hex fingerprint", async () => {
    const res = await SELF.fetch(
      "https://relay.mydia.dev/admin/errors/not-a-real-fingerprint/resolve",
      { method: "POST", redirect: "manual" },
    );
    expect(res.status).toBe(404);
  });

  it("also validates on the unresolve route", async () => {
    const res = await SELF.fetch(
      "https://relay.mydia.dev/admin/errors/abc%0D%0AInjected/unresolve",
      { method: "POST", redirect: "manual" },
    );
    expect(res.status).toBe(404);
  });
});

// The ingest throttle stops counting (and stops writing new rows) once
// a fingerprint/instance/hour bucket saturates. errors.count_is_floor
// is the durable record of that, distinct from
// ingest_buckets.saturated, which resets the moment a fresh hour's write
// lands for the same fingerprint/instance -- see 0002_crash_reports.sql.
describe("GET /admin/errors occurrence count vs. ingest throttling", () => {
  const SATURATED_FP = "fpsaturated";

  beforeAll(async () => {
    const now = Math.floor(Date.now() / 1000);
    await env.DB.prepare(
      `INSERT INTO errors (fingerprint, kind, message, status,
                           first_seen_at, last_seen_at, occurrence_count, count_is_floor)
       VALUES (?, 'StormError', 'storm', 'unresolved', ?, ?, 3, 1)`,
    )
      .bind(SATURATED_FP, now, now)
      .run();
  });

  it("marks a saturated fingerprint's count as a floor on the list page", async () => {
    const html = await (await SELF.fetch("https://relay.mydia.dev/admin/errors")).text();
    // The saturated row's count must be visually distinguishable from an
    // exact count -- rendered as "at least" rather than a bare number.
    const rowStart = html.indexOf("StormError");
    expect(rowStart).toBeGreaterThan(-1);
    const rowSlice = html.slice(rowStart, rowStart + 600);
    expect(rowSlice).toMatch(/&ge;|≥|throttled|at least/i);
  });

  it("does not mark an unsaturated fingerprint's count as a floor", async () => {
    const html = await (await SELF.fetch("https://relay.mydia.dev/admin/errors")).text();
    // FP1's own row (found via its detail link), bounded to just that <tr>
    // so a neighbouring saturated row's markup can't leak into the slice.
    const linkIndex = html.indexOf(`href="/admin/errors/${FP1}"`);
    expect(linkIndex).toBeGreaterThan(-1);
    const rowEnd = html.indexOf("</tr>", linkIndex);
    const rowSlice = html.slice(linkIndex, rowEnd);
    expect(rowSlice).not.toMatch(/throttled/i);
  });

  it("marks the floor on the single error group's detail page too", async () => {
    const html = await (
      await SELF.fetch(`https://relay.mydia.dev/admin/errors/${SATURATED_FP}`)
    ).text();
    expect(html).toMatch(/&ge;|≥|throttled|at least/i);
  });
});

// The critical fix-round-1 finding, reproduced end-to-end through the real
// ingest route rather than by hand-inserting rows: a bucket saturates, the
// hour rolls over, and the same misbehaving install sends exactly one more
// crash. Before this fix that one further request reset
// ingest_buckets.saturated back to 0 in place, and the dashboard (which used
// to read that live flag) started rendering a bare, precise-looking number
// again -- permanently wrong, since the crashes dropped during the
// saturated hour are gone forever.
describe("the floor marker survives an hour rollover", () => {
  function postCrash(kind: string, ip: string, occurredAtSeconds: number) {
    return SELF.fetch("https://relay.mydia.dev/crashes/report", {
      method: "POST",
      headers: { "content-type": "application/json", "cf-connecting-ip": ip },
      body: JSON.stringify({
        error_type: kind,
        error_message: "loop",
        stacktrace: [{ module: "M", function: "f/0", file: "m.ex", line: 42 }],
        occurred_at: new Date(occurredAtSeconds * 1000).toISOString(),
      }),
    });
  }

  it("keeps rendering the floor after the hour rolls over and one more crash arrives from the same instance", async () => {
    const ip = "203.0.113.50";
    const kind = "RolloverStorm";
    const hourStart = 500_000 * 3600; // arbitrary hour, far from "now"

    // Saturate the bucket within the first hour.
    for (let i = 0; i < MAX_OCCURRENCE_ROWS_PER_BUCKET + 2; i++) {
      await postCrash(kind, ip, hourStart + 10);
    }

    const fingerprintRow = await env.DB.prepare(
      "SELECT fingerprint FROM errors WHERE kind = ?",
    )
      .bind(kind)
      .first<{ fingerprint: string }>();
    const fingerprint = fingerprintRow!.fingerprint;

    const beforeRollover = await env.DB.prepare(
      "SELECT count_is_floor, occurrence_count FROM errors WHERE fingerprint = ?",
    )
      .bind(fingerprint)
      .first<{ count_is_floor: number; occurrence_count: number }>();
    expect(beforeRollover!.count_is_floor).toBe(1);
    expect(beforeRollover!.occurrence_count).toBe(MAX_OCCURRENCE_ROWS_PER_BUCKET);

    // Roll the hour forward and send exactly ONE more crash from the SAME
    // fingerprint and instance.
    await postCrash(kind, ip, hourStart + 3600 + 10);

    // Sanity: the transient per-hour flag really did reset -- this is
    // precisely the scenario that used to erase the floor signal.
    const bucket = await env.DB.prepare(
      "SELECT hour_bucket, written, saturated FROM ingest_buckets WHERE fingerprint = ? AND instance_key = ?",
    )
      .bind(fingerprint, ip)
      .first<{ hour_bucket: number; written: number; saturated: number }>();
    expect(bucket!.saturated).toBe(0);
    expect(bucket!.written).toBe(1);

    const afterRollover = await env.DB.prepare(
      "SELECT count_is_floor, occurrence_count FROM errors WHERE fingerprint = ?",
    )
      .bind(fingerprint)
      .first<{ count_is_floor: number; occurrence_count: number }>();
    // The durable flag must NOT reset, and the count keeps advancing on top
    // of the floor it was already at.
    expect(afterRollover!.count_is_floor).toBe(1);
    expect(afterRollover!.occurrence_count).toBe(MAX_OCCURRENCE_ROWS_PER_BUCKET + 1);

    const html = await (await SELF.fetch("https://relay.mydia.dev/admin/errors")).text();
    const rowStart = html.indexOf(kind);
    expect(rowStart).toBeGreaterThan(-1);
    const rowEnd = html.indexOf("</tr>", rowStart);
    expect(html.slice(rowStart, rowEnd)).toMatch(/&ge;|≥|throttled|at least/i);
  });

  it("keeps rendering a plain exact count for a fingerprint that never saturates, across many hours", async () => {
    const ip = "203.0.113.51";
    const kind = "NeverSaturates";
    const baseHour = 600_000;

    // One crash per hour for several hours -- never enough in any single
    // hour to reach MAX_OCCURRENCE_ROWS_PER_BUCKET.
    for (let h = 0; h < 5; h++) {
      await postCrash(kind, ip, (baseHour + h) * 3600 + 10);
    }

    const row = await env.DB.prepare(
      "SELECT count_is_floor, occurrence_count FROM errors WHERE kind = ?",
    )
      .bind(kind)
      .first<{ count_is_floor: number; occurrence_count: number }>();
    expect(row!.count_is_floor).toBe(0);
    expect(row!.occurrence_count).toBe(5);

    const html = await (await SELF.fetch("https://relay.mydia.dev/admin/errors")).text();
    const rowStart = html.indexOf(kind);
    expect(rowStart).toBeGreaterThan(-1);
    const rowEnd = html.indexOf("</tr>", rowStart);
    expect(html.slice(rowStart, rowEnd)).not.toMatch(/throttled/i);
  });

  it("keeps the floor marker across a resolve/unresolve cycle", async () => {
    const ip = "203.0.113.52";
    const kind = "ResolveCycleStorm";
    const occurredAt = 700_000 * 3600 + 10;

    for (let i = 0; i < MAX_OCCURRENCE_ROWS_PER_BUCKET + 1; i++) {
      await postCrash(kind, ip, occurredAt);
    }

    const fingerprintRow = await env.DB.prepare(
      "SELECT fingerprint FROM errors WHERE kind = ?",
    )
      .bind(kind)
      .first<{ fingerprint: string }>();
    const fingerprint = fingerprintRow!.fingerprint;

    const hasFloorMarker = async (): Promise<boolean> => {
      const html = await (
        await SELF.fetch(`https://relay.mydia.dev/admin/errors/${fingerprint}`)
      ).text();
      return /&ge;|≥|throttled|at least/i.test(html);
    };

    expect(await hasFloorMarker()).toBe(true);

    const resolveRes = await SELF.fetch(
      `https://relay.mydia.dev/admin/errors/${fingerprint}/resolve`,
      { method: "POST", redirect: "manual" },
    );
    expect(resolveRes.status).toBe(303);
    expect(await hasFloorMarker()).toBe(true);

    const unresolveRes = await SELF.fetch(
      `https://relay.mydia.dev/admin/errors/${fingerprint}/unresolve`,
      { method: "POST", redirect: "manual" },
    );
    expect(unresolveRes.status).toBe(303);
    expect(await hasFloorMarker()).toBe(true);
  });
});

// Fix-round-1 finding on the hono/jsx conversion: the pager's "Next" link
// carries the `status` filter forward via `encodeURIComponent`, not the
// `escapeHtml` the pre-conversion file used at this spot. That is a
// deliberate improvement, not an oversight -- `status` is unvalidated caller
// input straight from `c.req.query("status")` (unlike `fingerprint`, it has
// no shape guard), and it lands inside a URL query string, not HTML markup.
// HTML-escaping a literal "&" produces "&amp;", which a browser decodes back
// to "&" before parsing the query string, silently splitting one parameter
// into two. Percent-encoding is the correct tool for this position, and this
// test pins that so a future refactor can't quietly regress it back to
// escapeHtml.
describe("GET /admin/errors pager link encodes the status filter for the URL, not for HTML", () => {
  const PAGER_STATUS = "custom&type";

  beforeAll(async () => {
    // PAGE_SIZE (50) rows sharing one status value the rest of this file
    // never uses, so the pager link only appears once a full page of exactly
    // this filtered result set is returned.
    const now = Math.floor(Date.now() / 1000);
    for (let i = 0; i < 50; i++) {
      await env.DB.prepare(
        `INSERT INTO errors (fingerprint, kind, message, status,
                             first_seen_at, last_seen_at, occurrence_count)
         VALUES (?, 'PagerFilterError', 'pager filter fixture', ?, ?, ?, 1)`,
      )
        .bind(`fppager${i}`, PAGER_STATUS, now, now)
        .run();
    }
  });

  it("percent-encodes the status filter in the pager link so an ampersand cannot split the query string", async () => {
    const res = await SELF.fetch(
      `https://relay.mydia.dev/admin/errors?status=${encodeURIComponent(PAGER_STATUS)}`,
    );
    expect(res.status).toBe(200);
    const html = await res.text();

    // The value's own "&" must survive as the URL-structural "%26", not be
    // turned into the HTML entity "&amp;" that a browser would decode back
    // into a literal "&" and treat as a second query parameter.
    expect(html).toContain("status=custom%26type");
    expect(html).not.toContain("status=custom&amp;type");
  });
});
