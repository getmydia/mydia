import type { Env } from "../env";

// The three windows GET /admin offers. Values are seconds, subtracted from
// the current unix second to produce the `since` bound every windowed query
// binds. The key never reaches a query as text: it selects one of these
// integers, which is why parseWindow below is about rendering a coherent page
// and not about injection.
export const WINDOWS = {
  "24h": 86_400,
  "7d": 604_800,
  "30d": 2_592_000,
} as const;

export type WindowKey = keyof typeof WINDOWS;

// Landing on the overview with no explicit window shows a week, which is wide
// enough that a quiet relay still has something on the page and narrow enough
// that a spike from three weeks ago does not read as current.
export const DEFAULT_WINDOW: WindowKey = "7d";

// Same shape of guard as layout.tsx's parsePage, for the same reason: this is
// arbitrary caller-supplied text on a route whose page must render regardless.
//
// hasOwnProperty rather than `raw in WINDOWS`: the `in` operator walks the
// prototype chain, so "toString" and "constructor" would both pass and return
// a WindowKey that WINDOWS[key] cannot resolve to a number.
export function parseWindow(raw: string | undefined): WindowKey {
  if (raw !== undefined && Object.prototype.hasOwnProperty.call(WINDOWS, raw)) {
    return raw as WindowKey;
  }
  return DEFAULT_WINDOW;
}

export interface VersionRow {
  version: string;
  occurrences: number;
  sources: number;
}

export interface TopErrorRow {
  fingerprint: string;
  kind: string;
  message: string;
  count_is_floor: number;
  last_seen_at: number;
  recent: number;
}

export interface TableCounts {
  errors: number;
  occurrences: number;
  feedback_submissions: number;
  ingest_buckets: number;
  feedback_rate_limits: number;
  pairing_claims: number;
  sweep_runs: number;
}

export interface SweepRunRow {
  id: number;
  ran_at: number;
  feedback_rate_limits_deleted: number;
  ingest_buckets_deleted: number;
  pairing_claims_deleted: number;
  duration_ms: number;
}

export interface OverviewStats {
  window: WindowKey;
  crashes: number;
  crashSources: number;
  unresolvedGroups: number;
  throttledGroups: number;
  feedbackByState: Record<string, number>;
  feedbackByType: Record<string, number>;
  versions: VersionRow[];
  topErrors: TopErrorRow[];
  livePairingClaims: number;
  tableCounts: TableCounts;
  lastSweep: SweepRunRow | null;
}

const VERSION_LIMIT = 10;
const TOP_ERROR_LIMIT = 5;

// The batch's statement order. Reading results back by index is fragile, so
// these names are the single place the order is written down; every accessor
// below indexes through one of them.
const enum Q {
  Crashes = 0,
  CrashSources = 1,
  UnresolvedGroups = 2,
  ThrottledGroups = 3,
  FeedbackByState = 4,
  FeedbackByType = 5,
  Versions = 6,
  TopErrors = 7,
  LivePairingClaims = 8,
  TableCounts = 9,
  LastSweep = 10,
}

function rows<T>(result: D1Result | undefined): T[] {
  return (result?.results as T[] | undefined) ?? [];
}

// A count that cannot be read comes back 0 rather than undefined, so a single
// missing aggregate cannot propagate NaN through the page. The dashboard has
// its own placeholder for a value it genuinely cannot render; this keeps the
// type honest before it ever gets there.
function scalar(result: D1Result | undefined): number {
  const value = rows<{ n: unknown }>(result)[0]?.n;
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function grouped(result: D1Result | undefined, key: string): Record<string, number> {
  const out: Record<string, number> = {};
  for (const row of rows<Record<string, unknown>>(result)) {
    const label = row[key];
    const n = row.n;
    if (typeof label === "string" && typeof n === "number") out[label] = n;
  }
  return out;
}

// Every aggregate on GET /admin, as ONE batch. Eleven sequential
// prepare()/first() calls would be eleven round trips to build one page; D1's
// batch runs them in a single transaction and one trip.
export async function loadOverviewStats(
  env: Env,
  window: WindowKey,
): Promise<OverviewStats> {
  const now = Math.floor(Date.now() / 1000);
  const since = now - WINDOWS[window];

  const results = await env.DB.batch([
    env.DB.prepare("SELECT COUNT(*) AS n FROM occurrences WHERE occurred_at >= ?").bind(since),
    env.DB.prepare(
      "SELECT COUNT(DISTINCT instance_key) AS n FROM occurrences WHERE occurred_at >= ?",
    ).bind(since),
    env.DB.prepare("SELECT COUNT(*) AS n FROM errors WHERE status = 'unresolved'"),
    // Drives the "throttled" badge on the crash card. Reads count_is_floor,
    // the sticky flag ingest sets and never clears, and NOT
    // ingest_buckets.saturated, which resets on the next hour and would show
    // a precise-looking number at exactly the moment after a storm when
    // someone is most likely to be looking. See 0002_crash_reports.sql.
    env.DB.prepare(
      "SELECT COUNT(*) AS n FROM errors WHERE status = 'unresolved' AND count_is_floor = 1",
    ),
    env.DB.prepare("SELECT state, COUNT(*) AS n FROM feedback_submissions GROUP BY state"),
    env.DB.prepare(
      "SELECT type, COUNT(*) AS n FROM feedback_submissions WHERE inserted_at >= ? GROUP BY type",
    ).bind(since),
    env.DB.prepare(
      `SELECT COALESCE(version, 'unknown') AS version,
              COUNT(*) AS occurrences,
              COUNT(DISTINCT instance_key) AS sources
       FROM occurrences WHERE occurred_at >= ?
       GROUP BY 1 ORDER BY 2 DESC LIMIT ?`,
    ).bind(since, VERSION_LIMIT),
    env.DB.prepare(
      `SELECT e.fingerprint, e.kind, e.message, e.count_is_floor, e.last_seen_at,
              COUNT(o.id) AS recent
       FROM errors e
       JOIN occurrences o ON o.fingerprint = e.fingerprint AND o.occurred_at >= ?
       WHERE e.status = 'unresolved'
       GROUP BY e.fingerprint
       ORDER BY recent DESC, e.last_seen_at DESC LIMIT ?`,
    ).bind(since, TOP_ERROR_LIMIT),
    env.DB.prepare("SELECT COUNT(*) AS n FROM pairing_claims WHERE expires_at > ?").bind(now),
    // Seven counts as one statement of scalar subqueries rather than seven
    // more entries in this batch. Nothing here is windowed: these are "how big
    // is the database right now".
    //
    // sweep_runs belongs here even though it is bounded: the count is how you
    // see that its self-eviction still works. Three tables in this Worker
    // needed an eviction path retrofitted, so a sweep_runs count far above the
    // ~168 the retention window implies is the signal that a fourth has
    // started growing without one.
    env.DB.prepare(
      `SELECT (SELECT COUNT(*) FROM errors)               AS errors,
              (SELECT COUNT(*) FROM occurrences)          AS occurrences,
              (SELECT COUNT(*) FROM feedback_submissions) AS feedback_submissions,
              (SELECT COUNT(*) FROM ingest_buckets)       AS ingest_buckets,
              (SELECT COUNT(*) FROM feedback_rate_limits) AS feedback_rate_limits,
              (SELECT COUNT(*) FROM pairing_claims)       AS pairing_claims,
              (SELECT COUNT(*) FROM sweep_runs)           AS sweep_runs`,
    ),
    env.DB.prepare("SELECT * FROM sweep_runs ORDER BY ran_at DESC LIMIT 1"),
  ]);

  const counts = rows<Partial<TableCounts>>(results[Q.TableCounts])[0] ?? {};
  const zeroed = (value: number | undefined): number =>
    typeof value === "number" && Number.isFinite(value) ? value : 0;

  return {
    window,
    crashes: scalar(results[Q.Crashes]),
    crashSources: scalar(results[Q.CrashSources]),
    unresolvedGroups: scalar(results[Q.UnresolvedGroups]),
    throttledGroups: scalar(results[Q.ThrottledGroups]),
    feedbackByState: grouped(results[Q.FeedbackByState], "state"),
    feedbackByType: grouped(results[Q.FeedbackByType], "type"),
    versions: rows<VersionRow>(results[Q.Versions]),
    topErrors: rows<TopErrorRow>(results[Q.TopErrors]),
    livePairingClaims: scalar(results[Q.LivePairingClaims]),
    tableCounts: {
      errors: zeroed(counts.errors),
      occurrences: zeroed(counts.occurrences),
      feedback_submissions: zeroed(counts.feedback_submissions),
      ingest_buckets: zeroed(counts.ingest_buckets),
      feedback_rate_limits: zeroed(counts.feedback_rate_limits),
      pairing_claims: zeroed(counts.pairing_claims),
      sweep_runs: zeroed(counts.sweep_runs),
    },
    lastSweep: rows<SweepRunRow>(results[Q.LastSweep])[0] ?? null,
  };
}
