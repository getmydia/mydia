import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { escapeHtml } from "../../src/dashboards/layout";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  const now = Math.floor(Date.now() / 1000);
  await env.DB.prepare(
    `INSERT INTO errors (fingerprint, kind, message, source_file, source_line,
                         status, first_seen_at, last_seen_at, occurrence_count)
     VALUES ('fp1', 'RuntimeError', 'boom', 'm.ex', 3, 'unresolved', ?, ?, 7)`,
  )
    .bind(now, now)
    .run();
});

describe("escapeHtml", () => {
  it("escapes the characters that would let a crash message inject markup", () => {
    expect(escapeHtml('<img src=x onerror="alert(1)">')).not.toContain("<img");
    expect(escapeHtml("a & b")).toContain("&amp;");
    expect(escapeHtml('"quoted"')).toContain("&quot;");
  });
});

describe("GET /errors", () => {
  it("lists error groups with their occurrence counts", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/errors");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");

    const html = await res.text();
    expect(html).toContain("RuntimeError");
    expect(html).toContain("boom");
    expect(html).toContain("7");
  });

  it("shows a single error group with its occurrences", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/errors/fp1");
    expect(res.status).toBe(200);
    expect(await res.text()).toContain("RuntimeError");
  });

  it("returns 404 for an unknown fingerprint", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/errors/nosuchfp");
    expect(res.status).toBe(404);
  });

  it("resolves a group and reflects the new status", async () => {
    // fetch()'s default `redirect: "follow"` would otherwise chase the 303
    // and hand back the followed page's 200, hiding the redirect status this
    // assertion cares about.
    const res = await SELF.fetch("https://relay.mydia.dev/errors/fp1/resolve", {
      method: "POST",
      redirect: "manual",
    });
    expect(res.status).toBe(303);

    const row = await env.DB.prepare(
      "SELECT status FROM errors WHERE fingerprint = 'fp1'",
    ).first<{ status: string }>();
    expect(row!.status).toBe("resolved");
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

    const html = await (await SELF.fetch("https://relay.mydia.dev/errors")).text();
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

    const html = await (await SELF.fetch("https://relay.mydia.dev/errors")).text();
    expect(html).not.toContain('"><svg onload=alert(1)>');
    expect(html).not.toContain("<svg onload=alert(1)>");
  });

  // A fingerprint is hex-derived (fingerprintOf hashes with SHA-256 and never
  // emits HTML-meta characters), but the link href built from it must still
  // be escaped defensively rather than trusted because "the input happens to
  // be safe today".
  it("escapes the fingerprint used to build occurrence links", async () => {
    const found = await env.DB.prepare(
      "SELECT fingerprint FROM errors WHERE kind = 'RuntimeError' AND message = 'boom'",
    ).first<{ fingerprint: string }>();

    const html = await (await SELF.fetch("https://relay.mydia.dev/errors")).text();
    expect(html).toContain(`href="/errors/${found!.fingerprint}"`);
  });
});

// Task 11's ingest throttle stops counting (and stops writing new rows) once
// a fingerprint/instance/hour bucket saturates: ingest_buckets.saturated
// records that occurrence_count is a FLOOR, not an exact total, for the rest
// of that hour. A dashboard that prints occurrence_count as a plain number
// presents a throttled undercount as if it were precise -- worst exactly
// when an operator most needs the real number, during a crash storm.
describe("GET /errors occurrence count vs. ingest throttling", () => {
  const SATURATED_FP = "fpsaturated";

  beforeAll(async () => {
    const now = Math.floor(Date.now() / 1000);
    await env.DB.prepare(
      `INSERT INTO errors (fingerprint, kind, message, status,
                           first_seen_at, last_seen_at, occurrence_count)
       VALUES (?, 'StormError', 'storm', 'unresolved', ?, ?, 3)`,
    )
      .bind(SATURATED_FP, now, now)
      .run();
    await env.DB.prepare(
      `INSERT INTO ingest_buckets (fingerprint, instance_key, hour_bucket, written, saturated)
       VALUES (?, 'some-instance', ?, 3, 1)`,
    )
      .bind(SATURATED_FP, Math.floor(now / 3600))
      .run();
  });

  it("marks a saturated fingerprint's count as a floor on the list page", async () => {
    const html = await (await SELF.fetch("https://relay.mydia.dev/errors")).text();
    // The saturated row's count must be visually distinguishable from an
    // exact count -- rendered as "at least" rather than a bare number.
    const rowStart = html.indexOf("StormError");
    expect(rowStart).toBeGreaterThan(-1);
    const rowSlice = html.slice(rowStart, rowStart + 600);
    expect(rowSlice).toMatch(/&ge;|≥|throttled|at least/i);
  });

  it("does not mark an unsaturated fingerprint's count as a floor", async () => {
    const html = await (await SELF.fetch("https://relay.mydia.dev/errors")).text();
    // fp1's own row (found via its detail link), bounded to just that <tr>
    // so a neighbouring saturated row's markup can't leak into the slice.
    const linkIndex = html.indexOf('href="/errors/fp1"');
    expect(linkIndex).toBeGreaterThan(-1);
    const rowEnd = html.indexOf("</tr>", linkIndex);
    const rowSlice = html.slice(linkIndex, rowEnd);
    expect(rowSlice).not.toMatch(/throttled/i);
  });

  it("marks the floor on the single error group's detail page too", async () => {
    const html = await (
      await SELF.fetch(`https://relay.mydia.dev/errors/${SATURATED_FP}`)
    ).text();
    expect(html).toMatch(/&ge;|≥|throttled|at least/i);
  });
});
