import { describe, it, expect } from "vitest";
import { env, applyD1Migrations } from "cloudflare:test";
import { beforeAll } from "vitest";
import { parseWindow, WINDOWS, DEFAULT_WINDOW, loadOverviewStats } from "../../src/stats/queries";

describe("parseWindow", () => {
  it("accepts each known key", () => {
    expect(parseWindow("24h")).toBe("24h");
    expect(parseWindow("7d")).toBe("7d");
    expect(parseWindow("30d")).toBe("30d");
  });

  it("falls back to the default for anything unrecognised", () => {
    for (const raw of [undefined, "", "  ", "1d", "7D", "-7d", "1e300", "NaN"]) {
      expect(parseWindow(raw)).toBe(DEFAULT_WINDOW);
    }
  });

  // The lookup must not answer from Object.prototype. A plain `raw in WINDOWS`
  // returns true for "toString" and "constructor", which would hand a
  // WindowKey the rest of the module cannot map to a duration.
  it("does not treat inherited object properties as windows", () => {
    for (const raw of ["toString", "constructor", "hasOwnProperty", "__proto__"]) {
      expect(parseWindow(raw)).toBe(DEFAULT_WINDOW);
    }
  });

  it("maps every key to a distinct positive duration", () => {
    const values = Object.values(WINDOWS);
    expect(values.every((seconds) => Number.isInteger(seconds) && seconds > 0)).toBe(true);
    expect(new Set(values).size).toBe(values.length);
  });

  it("defaults to 7d", () => {
    expect(DEFAULT_WINDOW).toBe("7d");
  });
});

// Every fixture id is prefixed so these rows cannot collide with another test
// file's, and every title is invented rather than a real show or film.
const FP_HOT = "aa00000000000000000000000000stat";
const FP_COLD = "bb00000000000000000000000000stat";
const FP_DONE = "cc00000000000000000000000000stat";

const now = Math.floor(Date.now() / 1000);
const HOUR = 3_600;
const DAY = 86_400;

async function seed(): Promise<void> {
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO errors (fingerprint, kind, message, status, first_seen_at,
                           last_seen_at, occurrence_count, count_is_floor)
       VALUES (?, 'RuntimeError', 'Nebula Drift scan failed', 'unresolved', ?, ?, 9, 1)`,
    ).bind(FP_HOT, now - 10 * DAY, now - HOUR),
    env.DB.prepare(
      `INSERT INTO errors (fingerprint, kind, message, status, first_seen_at,
                           last_seen_at, occurrence_count, count_is_floor)
       VALUES (?, 'ArgumentError', 'Harbour Lights probe failed', 'unresolved', ?, ?, 2, 0)`,
    ).bind(FP_COLD, now - 10 * DAY, now - 2 * HOUR),
    env.DB.prepare(
      `INSERT INTO errors (fingerprint, kind, message, status, first_seen_at,
                           last_seen_at, occurrence_count, count_is_floor)
       VALUES (?, 'KeyError', 'Resolved already', 'resolved', ?, ?, 40, 0)`,
    ).bind(FP_DONE, now - 10 * DAY, now - HOUR),
  ]);

  // FP_HOT: 3 in-window occurrences from 2 distinct sources, on two versions.
  // FP_COLD: 1 in-window occurrence.
  // FP_DONE: 5 in-window occurrences, but the group is resolved.
  // One FP_HOT occurrence sits 40 days back, outside every window.
  const occurrences: [string, number, string | null, string][] = [
    [FP_HOT, now - HOUR, "1.4.0", "198.51.100.1"],
    [FP_HOT, now - 2 * HOUR, "1.4.0", "198.51.100.2"],
    [FP_HOT, now - 3 * HOUR, "1.5.0", "198.51.100.1"],
    [FP_HOT, now - 40 * DAY, "1.0.0", "198.51.100.9"],
    [FP_COLD, now - HOUR, null, "198.51.100.3"],
    ...Array.from({ length: 5 }, (_, i): [string, number, string | null, string] => [
      FP_DONE,
      now - HOUR,
      "1.4.0",
      `198.51.100.1${i}`,
    ]),
  ];

  await env.DB.batch(
    occurrences.map(([fingerprint, occurredAt, version, instanceKey], i) =>
      env.DB.prepare(
        `INSERT INTO occurrences (id, fingerprint, occurred_at, version, instance_key)
         VALUES (?, ?, ?, ?, ?)`,
      ).bind(`stat-occ-${i}`, fingerprint, occurredAt, version, instanceKey),
    ),
  );

  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO feedback_submissions (id, type, message, state, inserted_at, updated_at)
       VALUES ('stat-fb-1', 'bug', 'Scanner skipped a folder', 'unread', ?, ?)`,
    ).bind(now - HOUR, now - HOUR),
    env.DB.prepare(
      `INSERT INTO feedback_submissions (id, type, message, state, inserted_at, updated_at)
       VALUES ('stat-fb-2', 'idea', 'Add a compact list view', 'read', ?, ?)`,
    ).bind(now - 2 * HOUR, now - 2 * HOUR),
    env.DB.prepare(
      `INSERT INTO pairing_claims (key, value, expires_at) VALUES ('stat:live', 'v', ?)`,
    ).bind(now + HOUR),
    env.DB.prepare(
      `INSERT INTO pairing_claims (key, value, expires_at) VALUES ('stat:dead', 'v', ?)`,
    ).bind(now - HOUR),
    env.DB.prepare(
      `INSERT INTO sweep_runs (ran_at, feedback_rate_limits_deleted,
                               ingest_buckets_deleted, pairing_claims_deleted, duration_ms)
       VALUES (?, 4, 2, 1, 37)`,
    ).bind(now - HOUR),
  ]);
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  await seed();
});

describe("loadOverviewStats", () => {
  it("counts crashes and distinct sources inside the window only", async () => {
    const stats = await loadOverviewStats(env, "7d");

    // 3 FP_HOT + 1 FP_COLD + 5 FP_DONE = 9. The 40-day-old row is excluded.
    expect(stats.crashes).toBe(9);
    // 198.51.100.1, .2, .3 plus the five .1x sources = 8 distinct, and the
    // 40-day-old .9 is outside the window.
    expect(stats.crashSources).toBe(8);
  });

  it("excludes rows outside a narrower window", async () => {
    const wide = await loadOverviewStats(env, "30d");
    const narrow = await loadOverviewStats(env, "24h");
    expect(wide.crashes).toBe(narrow.crashes);

    // Nothing here is between 30 and 40 days old, so 30d must still exclude
    // the 40-day row. This is the assertion that catches a window constant
    // being wrong by an order of magnitude.
    expect(wide.crashes).toBe(9);
  });

  it("counts unresolved groups and the throttled subset of them", async () => {
    const stats = await loadOverviewStats(env, "7d");
    expect(stats.unresolvedGroups).toBe(2);
    // Only FP_HOT has count_is_floor set, and FP_DONE is resolved.
    expect(stats.throttledGroups).toBe(1);
  });

  it("groups versions, folding a NULL version into 'unknown'", async () => {
    const stats = await loadOverviewStats(env, "7d");
    const byVersion = Object.fromEntries(stats.versions.map((v) => [v.version, v]));

    expect(byVersion["1.4.0"].occurrences).toBe(7);
    expect(byVersion["1.4.0"].sources).toBe(7);
    expect(byVersion["1.5.0"].occurrences).toBe(1);
    expect(byVersion["unknown"].occurrences).toBe(1);
  });

  it("orders versions by occurrence count, most first", async () => {
    const stats = await loadOverviewStats(env, "7d");
    const counts = stats.versions.map((v) => v.occurrences);
    expect(counts).toEqual([...counts].sort((a, b) => b - a));
  });

  it("ranks unresolved errors by in-window occurrences and excludes resolved ones", async () => {
    const stats = await loadOverviewStats(env, "7d");
    const fingerprints = stats.topErrors.map((e) => e.fingerprint);

    expect(fingerprints).toEqual([FP_HOT, FP_COLD]);
    expect(fingerprints).not.toContain(FP_DONE);
    expect(stats.topErrors[0].recent).toBe(3);
    expect(stats.topErrors[0].count_is_floor).toBe(1);
    expect(stats.topErrors[0].kind).toBe("RuntimeError");
    expect(stats.topErrors[0].last_seen_at).toBe(now - HOUR);
  });

  it("counts only unexpired pairing claims as live", async () => {
    const stats = await loadOverviewStats(env, "7d");
    expect(stats.livePairingClaims).toBe(1);
  });

  it("reports feedback by state and by type", async () => {
    const stats = await loadOverviewStats(env, "7d");
    expect(stats.feedbackByState.unread).toBe(1);
    expect(stats.feedbackByState.read).toBe(1);
    expect(stats.feedbackByType.bug).toBe(1);
    expect(stats.feedbackByType.idea).toBe(1);
  });

  it("reports a row count for every table", async () => {
    const stats = await loadOverviewStats(env, "7d");
    for (const key of [
      "errors",
      "occurrences",
      "feedback_submissions",
      "ingest_buckets",
      "feedback_rate_limits",
      "pairing_claims",
      "sweep_runs",
    ] as const) {
      expect(typeof stats.tableCounts[key]).toBe("number");
    }
    expect(stats.tableCounts.errors).toBeGreaterThanOrEqual(3);
  });

  it("returns the most recent sweep run", async () => {
    const stats = await loadOverviewStats(env, "7d");
    expect(stats.lastSweep?.feedback_rate_limits_deleted).toBe(4);
    expect(stats.lastSweep?.duration_ms).toBe(37);
  });

  it("echoes the window it was asked for", async () => {
    expect((await loadOverviewStats(env, "24h")).window).toBe("24h");
  });
});

// An empty relay is the first thing a fresh deploy shows. Every field must be
// a real zero or an empty collection, never undefined and never a throw,
// because the page renders all of them unconditionally.
describe("loadOverviewStats on an empty database", () => {
  it("returns zeros and empty collections rather than throwing", async () => {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM occurrences"),
      env.DB.prepare("DELETE FROM errors"),
      env.DB.prepare("DELETE FROM feedback_submissions"),
      env.DB.prepare("DELETE FROM pairing_claims"),
      env.DB.prepare("DELETE FROM sweep_runs"),
    ]);

    const stats = await loadOverviewStats(env, "7d");

    expect(stats.crashes).toBe(0);
    expect(stats.crashSources).toBe(0);
    expect(stats.unresolvedGroups).toBe(0);
    expect(stats.throttledGroups).toBe(0);
    expect(stats.livePairingClaims).toBe(0);
    expect(stats.versions).toEqual([]);
    expect(stats.topErrors).toEqual([]);
    expect(stats.feedbackByState).toEqual({});
    expect(stats.feedbackByType).toEqual({});
    expect(stats.lastSweep).toBeNull();
    expect(stats.tableCounts.occurrences).toBe(0);
  });
});
