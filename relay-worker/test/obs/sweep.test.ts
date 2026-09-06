import {
  env,
  applyD1Migrations,
  createScheduledController,
  createExecutionContext,
  waitOnExecutionContext,
} from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import worker from "../../src/index";
import {
  sweepStaleFeedbackRateLimits,
  sweepStaleIngestBuckets,
} from "../../src/obs/sweep";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function insertRateLimitBucket(
  bucketKey: string,
  hourBucket: number,
  count: number,
): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO feedback_rate_limits (bucket_key, hour_bucket, count) VALUES (?, ?, ?)
     ON CONFLICT(bucket_key) DO UPDATE SET hour_bucket = excluded.hour_bucket, count = excluded.count`,
  )
    .bind(bucketKey, hourBucket, count)
    .run();
}

async function insertPairingClaim(key: string, expiresAt: number): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO pairing_claims (key, value, expires_at) VALUES (?, ?, ?)
     ON CONFLICT(key) DO UPDATE SET value = excluded.value, expires_at = excluded.expires_at`,
  )
    .bind(key, "test-value", expiresAt)
    .run();
}

async function rateLimitBucketExists(bucketKey: string): Promise<boolean> {
  const row = await env.DB.prepare("SELECT 1 FROM feedback_rate_limits WHERE bucket_key = ?")
    .bind(bucketKey)
    .first();
  return row !== null;
}

async function pairingClaimExists(key: string): Promise<boolean> {
  const row = await env.DB.prepare("SELECT 1 FROM pairing_claims WHERE key = ?").bind(key).first();
  return row !== null;
}

async function insertIngestBucket(
  fingerprint: string,
  instanceKey: string,
  hourBucket: number,
): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO ingest_buckets (fingerprint, instance_key, hour_bucket, hits, written, saturated)
     VALUES (?, ?, ?, 1, 1, 0)
     ON CONFLICT(fingerprint, instance_key) DO UPDATE SET hour_bucket = excluded.hour_bucket`,
  )
    .bind(fingerprint, instanceKey, hourBucket)
    .run();
}

async function ingestBucketExists(
  fingerprint: string,
  instanceKey: string,
): Promise<boolean> {
  const row = await env.DB.prepare(
    "SELECT 1 FROM ingest_buckets WHERE fingerprint = ? AND instance_key = ?",
  )
    .bind(fingerprint, instanceKey)
    .first();
  return row !== null;
}

describe("sweepStaleFeedbackRateLimits", () => {
  it("deletes rows from a stale hour bucket and leaves the current hour's rows alone", async () => {
    const currentHour = Math.floor(Date.now() / 3_600_000);
    await insertRateLimitBucket("sweep-unit:stale", currentHour - 5, 5);
    await insertRateLimitBucket("sweep-unit:current", currentHour, 3);

    const deleted = await sweepStaleFeedbackRateLimits(env);

    expect(deleted).toBeGreaterThanOrEqual(1);
    expect(await rateLimitBucketExists("sweep-unit:stale")).toBe(false);
    expect(await rateLimitBucketExists("sweep-unit:current")).toBe(true);
  });

  // hour_bucket < currentHour - 1, not <= currentHour: the previous hour's
  // rows are kept for one extra sweep cycle rather than cut exactly at the
  // current hour, since checkAndIncrementBucket already treats any
  // non-current hour_bucket as fully stale regardless.
  it("leaves the previous hour's rows alone for one extra cycle", async () => {
    const currentHour = Math.floor(Date.now() / 3_600_000);
    await insertRateLimitBucket("sweep-unit:previous", currentHour - 1, 2);

    await sweepStaleFeedbackRateLimits(env);

    expect(await rateLimitBucketExists("sweep-unit:previous")).toBe(true);
  });
});

describe("sweepStaleIngestBuckets", () => {
  it("deletes rows from a stale hour bucket and leaves the current hour's rows alone", async () => {
    const currentHour = Math.floor(Date.now() / 3_600_000);
    await insertIngestBucket("sweep-unit-fp", "stale-instance", currentHour - 5);
    await insertIngestBucket("sweep-unit-fp", "current-instance", currentHour);

    const deleted = await sweepStaleIngestBuckets(env);

    expect(deleted).toBeGreaterThanOrEqual(1);
    expect(await ingestBucketExists("sweep-unit-fp", "stale-instance")).toBe(false);
    expect(await ingestBucketExists("sweep-unit-fp", "current-instance")).toBe(true);
  });

  it("leaves the previous hour's rows alone for one extra cycle", async () => {
    const currentHour = Math.floor(Date.now() / 3_600_000);
    await insertIngestBucket("sweep-unit-fp", "previous-instance", currentHour - 1);

    await sweepStaleIngestBuckets(env);

    expect(await ingestBucketExists("sweep-unit-fp", "previous-instance")).toBe(true);
  });

  // The reason this table needs a sweep at all, stated as a test: the primary
  // key is (fingerprint, instance_key), so a new hour RESETS an existing row
  // rather than adding a second one. A row belonging to an instance that
  // stopped reporting is therefore never superseded, only abandoned, and
  // nothing on the request path can ever reach it again.
  it("reclaims rows left behind by instances that stopped reporting", async () => {
    const currentHour = Math.floor(Date.now() / 3_600_000);
    for (let i = 0; i < 5; i++) {
      await insertIngestBucket("sweep-abandoned-fp", `gone-instance-${i}`, currentHour - 3);
    }
    await insertIngestBucket("sweep-abandoned-fp", "still-reporting", currentHour);

    await sweepStaleIngestBuckets(env);

    const remaining = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM ingest_buckets WHERE fingerprint = ?",
    )
      .bind("sweep-abandoned-fp")
      .first<{ n: number }>();
    expect(remaining?.n).toBe(1);
    expect(await ingestBucketExists("sweep-abandoned-fp", "still-reporting")).toBe(true);
  });
});

describe("scheduled() handler", () => {
  it("sweeps stale feedback_rate_limits, ingest_buckets and expired pairing_claims rows, leaving live ones alone", async () => {
    const currentHour = Math.floor(Date.now() / 3_600_000);
    const now = Math.floor(Date.now() / 1000);

    await insertRateLimitBucket("sweep-scheduled:stale", currentHour - 10, 5);
    await insertRateLimitBucket("sweep-scheduled:current", currentHour, 1);
    await insertIngestBucket("sweep-scheduled-fp", "stale-instance", currentHour - 10);
    await insertIngestBucket("sweep-scheduled-fp", "current-instance", currentHour);
    await insertPairingClaim("sweep-scheduled:expired", now - 3600);
    await insertPairingClaim("sweep-scheduled:live", now + 3600);

    if (!worker.scheduled) throw new Error("scheduled handler is not wired");

    const controller = createScheduledController();
    const ctx = createExecutionContext();
    await worker.scheduled(controller, env, ctx);
    await waitOnExecutionContext(ctx);

    expect(await rateLimitBucketExists("sweep-scheduled:stale")).toBe(false);
    expect(await rateLimitBucketExists("sweep-scheduled:current")).toBe(true);
    expect(await ingestBucketExists("sweep-scheduled-fp", "stale-instance")).toBe(false);
    expect(await ingestBucketExists("sweep-scheduled-fp", "current-instance")).toBe(true);
    // pairing/store.ts's purgeExpiredClaims, written when pairing landed and
    // never wired to anything until this handler -- the identical "table with no
    // eviction path" defect in a different table.
    expect(await pairingClaimExists("sweep-scheduled:expired")).toBe(false);
    expect(await pairingClaimExists("sweep-scheduled:live")).toBe(true);
  });
});
