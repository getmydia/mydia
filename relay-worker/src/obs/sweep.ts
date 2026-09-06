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

// Runs both sweeps under one Cron Trigger. pairing/store.ts's
// purgeExpiredClaims was written in Task 10 and never wired to anything --
// the identical defect (a table with no eviction path) in a different
// table, closed here in the same commit rather than left for a third round.
// readClaim already refuses an expired row on read, so this, like the
// feedback sweep above, is housekeeping (bounding table growth), not a
// correctness fix.
export async function runScheduledSweep(env: Env): Promise<void> {
  await Promise.all([sweepStaleFeedbackRateLimits(env), purgeExpiredClaims(env)]);
}
