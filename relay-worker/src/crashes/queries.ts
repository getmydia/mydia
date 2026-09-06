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

// Whether occurrence_count is exact lives on errors.count_is_floor itself
// (a sticky flag ingest.ts sets and never clears -- see
// 0002_crash_reports.sql), not on ingest_buckets.saturated (a transient,
// per-hour flag that resets the moment a fresh hour's crash arrives, even
// though the total it left behind is still permanently short). Because
// count_is_floor already comes back on every `SELECT *` in listErrors and
// getError above, no separate query is needed here -- a caller reads
// `row.count_is_floor` directly off the ErrorRow.
