import type { Env } from "../env";
import { purgeExpiredClaims } from "../pairing/store";

// Elixir's MetadataRelay.RateLimiter is an ETS table with its own periodic
// cleaner, so it self-evicts; D1 has no equivalent, so a Worker port has to
// supply eviction explicitly rather than inherit it. Run on a Cron Trigger
// (wrangler.jsonc's triggers.crons), never on the request path.
//
// hour_bucket < currentHour - 1 (not <= currentHour) deliberately keeps the
// PREVIOUS hour's rows around for one extra sweep cycle rather than cutting
// exactly at the current hour: checkAndIncrementBucket (feedback/ingest.ts)
// already treats any row whose hour_bucket doesn't match the CURRENT hour
// as fully stale regardless of its count, so this can never delete a row a
// live request still depends on -- it only widens the margin between "no
// longer relevant" and "actually deleted" by one hour, which costs nothing
// and avoids a sweep landing exactly on an hour boundary racing a request
// in the window it's currently rolling out of.
export async function sweepStaleFeedbackRateLimits(env: Env): Promise<number> {
  const currentHour = Math.floor(Date.now() / 3_600_000);
  const result = await env.DB.prepare(
    "DELETE FROM feedback_rate_limits WHERE hour_bucket < ?",
  )
    .bind(currentHour - 1)
    .run();
  return result.meta.changes;
}

// The third table with no eviction path, missed when the other two were
// wired up. It is the worst of the three, because its primary key is
// (fingerprint, instance_key) rather than anything time-derived: rolling into
// a new hour RESETS an existing row (see incrementBucketAtomically's
// ON CONFLICT in src/crashes/ingest.ts), so a row is only ever abandoned,
// never superseded by a newer one that a later sweep would catch. Every
// install that ever reported a given crash and then stopped leaves its row
// behind forever, and the request path cannot reclaim any of them because it
// only ever touches the exact key it was handed.
//
// Same cutoff and the same reasoning as sweepStaleFeedbackRateLimits above:
// incrementBucketAtomically resets hits/written/saturated outright the moment
// hour_bucket doesn't match the current hour, so a row older than that
// carries no state any live request can read, and the extra hour of margin
// keeps a sweep landing on an hour boundary from racing a request rolling
// into it.
export async function sweepStaleIngestBuckets(env: Env): Promise<number> {
  const currentHour = Math.floor(Date.now() / 3_600_000);
  const result = await env.DB.prepare(
    "DELETE FROM ingest_buckets WHERE hour_bucket < ?",
  )
    .bind(currentHour - 1)
    .run();
  return result.meta.changes;
}

// Runs all three sweeps under one Cron Trigger. pairing/store.ts's
// purgeExpiredClaims was written when pairing landed and then never wired to
// anything -- the identical defect (a table with no eviction path) in a
// different table, closed here in the same commit rather than left to be
// rediscovered a third time.
// readClaim already refuses an expired row on read, so this, like the
// feedback sweep above, is housekeeping (bounding table growth), not a
// correctness fix.
export async function runScheduledSweep(env: Env): Promise<void> {
  await Promise.all([
    sweepStaleFeedbackRateLimits(env),
    sweepStaleIngestBuckets(env),
    purgeExpiredClaims(env),
  ]);
}
