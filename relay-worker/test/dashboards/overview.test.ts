import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";

const FP = "dd00000000000000000000000000view";
const now = Math.floor(Date.now() / 1000);

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);

  await env.DB.prepare(
    `INSERT INTO errors (fingerprint, kind, message, status, first_seen_at,
                         last_seen_at, occurrence_count, count_is_floor)
     VALUES (?, 'RuntimeError', 'Nebula Drift scan failed', 'unresolved', ?, ?, 9, 1)`,
  )
    .bind(FP, now - 86_400, now - 3_600)
    .run();

  await env.DB.prepare(
    `INSERT INTO occurrences (id, fingerprint, occurred_at, version, instance_key)
     VALUES ('view-occ-1', ?, ?, '1.4.0', '198.51.100.7')`,
  )
    .bind(FP, now - 3_600)
    .run();

  await env.DB.prepare(
    `INSERT INTO feedback_submissions (id, type, message, state, inserted_at, updated_at)
     VALUES ('view-fb-1', 'bug', 'Scanner skipped a folder', 'unread', ?, ?)`,
  )
    .bind(now - 3_600, now - 3_600)
    .run();
});

describe("GET /admin overview", () => {
  it("renders the headline cards", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/admin");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");

    const html = await res.text();
    expect(html).toContain("Crashes");
    expect(html).toContain("Crash sources");
    expect(html).toContain("Unresolved groups");
    expect(html).toContain("Unread feedback");
    expect(html).toContain("Live pairing claims");
  });

  it("says the crash-source count is IP-derived rather than an install count", async () => {
    const html = await (await SELF.fetch("https://relay.mydia.dev/admin")).text();
    expect(html).toContain("stat-hint");
    expect(html.toLowerCase()).toContain("ip-derived");
    // The number is a count of instance_key values, and instance_key holds a
    // client IP. The IPs themselves must never reach the page.
    expect(html).not.toContain("198.51.100.7");
  });

  it("marks a throttled crash total rather than showing it as exact", async () => {
    const html = await (await SELF.fetch("https://relay.mydia.dev/admin")).text();
    expect(html).toContain("throttled");
  });

  it("shows the version breakdown and links the top errors", async () => {
    const html = await (await SELF.fetch("https://relay.mydia.dev/admin")).text();
    expect(html).toContain("1.4.0");
    expect(html).toContain("Nebula Drift scan failed");
    expect(html).toContain(`href="/admin/errors/${FP}"`);
  });

  it("shows service health", async () => {
    const html = await (await SELF.fetch("https://relay.mydia.dev/admin")).text();
    expect(html).toContain("Service health");
    expect(html).toContain("occurrences");
    expect(html).toContain("Last sweep");
  });

  // The active tab is the whole assertion, and "7d" appears as a tab label
  // whichever window is active, so a bare toContain("7d") would pass against
  // a page that had defaulted to the wrong one. Match the anchor itself.
  const ACTIVE_7D = '<a href="/admin?window=7d" aria-current="page">';
  const ACTIVE_24H = '<a href="/admin?window=24h" aria-current="page">';

  it("offers all three windows and marks 7d active by default", async () => {
    const html = await (await SELF.fetch("https://relay.mydia.dev/admin")).text();
    expect(html).toContain('href="/admin?window=24h"');
    expect(html).toContain('href="/admin?window=30d"');
    expect(html).toContain(ACTIVE_7D);
    expect(html).not.toContain(ACTIVE_24H);
  });

  it("falls back to the default window for a garbage query param", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/admin?window=%00bogus");
    expect(res.status).toBe(200);
    expect(await res.text()).toContain(ACTIVE_7D);
  });

  it("honours an explicit window", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/admin?window=24h");
    expect(res.status).toBe(200);
    expect(await res.text()).toContain(ACTIVE_24H);
  });

  it("escapes a version string a remote install controls", async () => {
    await env.DB.prepare(
      `INSERT INTO occurrences (id, fingerprint, occurred_at, version, instance_key)
       VALUES ('view-occ-xss', ?, ?, '<script>alert(1)</script>', '198.51.100.8')`,
    )
      .bind(FP, now - 3_600)
      .run();

    const html = await (await SELF.fetch("https://relay.mydia.dev/admin")).text();
    expect(html).not.toContain("<script>alert(1)</script>");
    expect(html).toContain("&lt;script&gt;");
  });

  it("links to all three dashboards from the nav", async () => {
    const html = await (await SELF.fetch("https://relay.mydia.dev/admin")).text();
    expect(html).toContain('href="/admin"');
    expect(html).toContain('href="/admin/errors"');
    expect(html).toContain('href="/admin/feedback"');
  });
});

// Deletes the fixtures, so this must stay the last describe in the file.
// Vitest runs suites in declaration order within a file.
//
// A fresh deploy shows exactly this page. The overview renders every card
// unconditionally, so a zero that arrives as undefined would reach the
// formatter, and a missing lastSweep row would reach LastSweep.
describe("GET /admin on an empty database", () => {
  it("renders the page rather than 500ing", async () => {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM occurrences"),
      env.DB.prepare("DELETE FROM errors"),
      env.DB.prepare("DELETE FROM feedback_submissions"),
      env.DB.prepare("DELETE FROM pairing_claims"),
      env.DB.prepare("DELETE FROM sweep_runs"),
    ]);

    const res = await SELF.fetch("https://relay.mydia.dev/admin");
    expect(res.status).toBe(200);

    const html = await res.text();
    expect(html).toContain("Crashes");
    expect(html).toContain("Last sweep: never");
    expect(html).not.toContain("NaN");
    expect(html).not.toContain("undefined");
  });
});
