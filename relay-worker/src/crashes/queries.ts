import type { Env } from "../env";
import type { ErrorRow, OccurrenceRow } from "./ingest";

export async function listErrors(
  env: Env,
  opts: { status?: string; limit: number; offset: number },
): Promise<ErrorRow[]> {
  const stmt = opts.status
    ? env.DB.prepare(
        `SELECT * FROM errors WHERE status = ?
         ORDER BY last_seen_at DESC LIMIT ? OFFSET ?`,
      ).bind(opts.status, opts.limit, opts.offset)
    : env.DB.prepare(
        `SELECT * FROM errors ORDER BY last_seen_at DESC LIMIT ? OFFSET ?`,
      ).bind(opts.limit, opts.offset);

  const { results } = await stmt.all<ErrorRow>();
  return results;
}

export async function getError(
  env: Env,
  fingerprint: string,
): Promise<{ error: ErrorRow; occurrences: OccurrenceRow[] } | null> {
  const error = await env.DB.prepare("SELECT * FROM errors WHERE fingerprint = ?")
    .bind(fingerprint)
    .first<ErrorRow>();
  if (!error) return null;

  const { results } = await env.DB.prepare(
    `SELECT * FROM occurrences WHERE fingerprint = ?
     ORDER BY occurred_at DESC LIMIT 50`,
  )
    .bind(fingerprint)
    .all<OccurrenceRow>();

  return { error, occurrences: results };
}

export async function setErrorStatus(
  env: Env,
  fingerprint: string,
  status: "unresolved" | "resolved",
): Promise<void> {
  await env.DB.prepare("UPDATE errors SET status = ? WHERE fingerprint = ?")
    .bind(status, fingerprint)
    .run();
}

// ingest.ts's throttle (MAX_OCCURRENCE_ROWS_PER_BUCKET) stops both writing
// new occurrences AND advancing errors.occurrence_count once a
// fingerprint/instance/hour bucket saturates -- from that point on,
// occurrence_count is a FLOOR for the rest of that hour, not an exact total.
// ingest_buckets.saturated is set on the write that reached the cap and is
// never cleared retroactively for that hour (it only resets to 0 the next
// time a *fresh* hour's write lands for the same fingerprint/instance pair,
// per 0002_crash_reports.sql's schema comment), so a lingering saturated=1
// row is exactly the record that some of this fingerprint's crashes were
// dropped rather than counted -- permanently, since the count is never
// backfilled once the hour has passed.
//
// A fingerprint can have multiple instance_key buckets (different installs,
// or the same install across IP changes); ANY of them ever saturating means
// the fingerprint's total occurrence_count is not exact, so this checks
// across all of a fingerprint's buckets rather than a single one.
export async function getSaturatedFingerprints(
  env: Env,
  fingerprints: string[],
): Promise<Set<string>> {
  if (fingerprints.length === 0) return new Set();

  const placeholders = fingerprints.map(() => "?").join(",");
  const { results } = await env.DB.prepare(
    `SELECT DISTINCT fingerprint FROM ingest_buckets
     WHERE saturated = 1 AND fingerprint IN (${placeholders})`,
  )
    .bind(...fingerprints)
    .all<{ fingerprint: string }>();

  return new Set(results.map((row) => row.fingerprint));
}
