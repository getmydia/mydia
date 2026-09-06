import type { Hono } from "hono";
import type { Env } from "../env";

export interface CrashFrame {
  module: string | null;
  function: string | null;
  file: string | null;
  line: number | null;
}

export interface NormalizedCrash {
  kind: string;
  message: string;
  stacktrace: CrashFrame[];
  sourceFile: string | null;
  sourceLine: number | null;
  version: string | null;
  environment: string | null;
  occurredAt: number;
  context: Record<string, unknown>;
}

export interface ErrorRow {
  fingerprint: string;
  kind: string;
  message: string;
  source_file: string | null;
  source_line: number | null;
  status: string;
  first_seen_at: number;
  last_seen_at: number;
  occurrence_count: number;
  // Sticky: set to 1 the moment any bucket for this fingerprint ever
  // saturates, never reset back to 0. See 0002_crash_reports.sql for why
  // this can't be answered from ingest_buckets.saturated alone.
  count_is_floor: number;
}

export interface OccurrenceRow {
  id: string;
  fingerprint: string;
  occurred_at: number;
  version: string | null;
  environment: string | null;
  instance_key: string | null;
  context: string;
  stacktrace: string;
}

// Occurrence rows written per fingerprint per instance per hour. Beyond this
// the crash is still counted, but no new row is written.
export const MAX_OCCURRENCE_ROWS_PER_BUCKET = 3;

function frame(
  module: unknown,
  fn: unknown,
  file: unknown,
  line: unknown,
): CrashFrame {
  return {
    module: typeof module === "string" ? module : null,
    function: typeof fn === "string" ? fn : null,
    file: typeof file === "string" ? file : null,
    line: typeof line === "number" ? line : null,
  };
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

// Mirrors Elixir truthiness (only nil/false are falsy -- 0 and "" are NOT),
// since router.ex's `if file || line do` and `parse_stacktrace_entry`'s
// required-key match are both Elixir-side checks this ports.
function elixirTruthy(value: unknown): boolean {
  return value !== undefined && value !== null && value !== false;
}

// router.ex's parse_stacktrace_entry/1: `%{"file" => file, "line" => line} =
// entry` requires BOTH keys to be present in the entry (any value, including
// null, satisfies the match) -- an entry missing either key is dropped
// entirely rather than kept with nulls filled in. Mydia.CrashReporter's own
// format_stacktrace/1 always emits both keys (possibly null) for every
// frame, so this never actually fires against real traffic, but a stray
// third-party client sending a bare {module, function} entry should not
// silently keep a frame router.ex would have discarded.
function parseStacktraceEntry(entry: unknown): CrashFrame | null {
  if (!isPlainObject(entry)) return null;
  if (!("file" in entry) || !("line" in entry)) return null;
  return frame(entry.module, entry.function, entry.file, entry.line);
}

// router.ex's metadata_stack_frame/1: builds a frame from `metadata` only
// when `file` or `line` is present (Elixir truthy), not when only
// module/function are given. Getting this backwards was the brief's own bug
// (it gated on module || function || file): a report describing only which
// function crashed, with no file/line, would otherwise still fingerprint
// distinctly from another report with genuinely no metadata at all, or
// worse, a report with only module/function would collapse into one bucket
// with every other module/function-less report instead of being dropped to
// the safe "no-frame" case router.ex uses.
function metadataStackFrame(metadata: unknown): CrashFrame | null {
  if (!isPlainObject(metadata)) return null;
  const file = metadata.file;
  const line = metadata.line;
  if (!elixirTruthy(file) && !elixirTruthy(line)) return null;
  return frame(metadata.module, metadata.function, file, line);
}

// Mydia.CrashReporter.build_report/3 sends `occurred_at` via
// `DateTime.to_iso8601/1` -- always a string, never a Unix number. Accepting
// only `typeof === "number"` (the brief's original check) would silently
// discard this field on every real report and substitute ingestion time
// instead. A Unix-seconds number is still accepted for callers other than
// the Elixir producer (e.g. direct API use, tests).
function parseOccurredAt(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.floor(value);
  }
  if (typeof value === "string") {
    const parsed = Date.parse(value);
    if (!Number.isNaN(parsed)) return Math.floor(parsed / 1000);
  }
  return Math.floor(Date.now() / 1000);
}

export function normalizeCrashReport(
  body: Record<string, unknown>,
): NormalizedCrash {
  const kind =
    typeof body.error_type === "string" ? body.error_type : "RuntimeError";
  const message =
    typeof body.error_message === "string" ? body.error_message : "Unknown error";

  const rawStack = Array.isArray(body.stacktrace) ? body.stacktrace : [];
  let stacktrace = rawStack
    .map(parseStacktraceEntry)
    .filter((f): f is CrashFrame => f !== null);

  // Without any source info every report derives the same fingerprint and
  // collapses into one useless group, so metadata stands in for a frame.
  if (stacktrace.length === 0) {
    const synthesized = metadataStackFrame(body.metadata);
    if (synthesized) stacktrace = [synthesized];
  }

  const top = stacktrace[0];

  return {
    kind,
    message,
    stacktrace,
    sourceFile: top?.file ?? null,
    sourceLine: top?.line ?? null,
    version: typeof body.version === "string" ? body.version : null,
    environment: typeof body.environment === "string" ? body.environment : null,
    occurredAt: parseOccurredAt(body.occurred_at),
    context: isPlainObject(body.metadata) ? body.metadata : {},
  };
}

export async function fingerprintOf(
  kind: string,
  topFrame: string,
): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${kind}|${topFrame}`),
  );
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
    .slice(0, 32);
}

// router.ex's validate_crash_report/1: these three keys must be PRESENT
// (Map.has_key?; any value, including null, satisfies it) or the request is
// rejected with 400 before anything is stored. normalizeCrashReport's
// lenient defaulting is correct for the pure function -- the Elixir also
// normalises leniently once past this gate -- so this replicates the GATE
// itself, run at the route, strictly before any D1 access. A well-formed but
// empty `{}` always maps to the same fingerprint, and that fingerprint's
// first-ever request is never throttled (there's no bucket row yet), so
// without this gate, repeated anonymous POSTs of `{}` to this
// unauthenticated endpoint would be an easier route to budget exhaustion
// than an actual crash loop.
const REQUIRED_FIELDS = ["error_type", "error_message", "stacktrace"] as const;

function validateCrashReportShape(body: Record<string, unknown>): string[] {
  const errors = REQUIRED_FIELDS.filter((field) => !(field in body)).map(
    (field) => `Missing required field: ${field}`,
  );
  if ("stacktrace" in body && !Array.isArray(body.stacktrace)) {
    errors.push("stacktrace must be a list");
  }
  return errors;
}

interface BucketRow {
  hour_bucket: number;
  written: number;
  saturated: number;
}

interface AtomicBucketRow {
  hits: number;
  written: number;
  saturated: number;
  writes: number;
}

const ALREADY_HANDLED = {
  status: "created",
  message: "Crash report received",
} as const;

// Final-review fix round: the burst guard in front of the D1 accounting
// below. See wrangler.jsonc's CRASH_INGEST_LIMITER comment for the numbers
// and rationale. This binding is atomic and costs no D1 access at all, so a
// flood that never gets past it never touches the racy path below -- but its
// 10s window is a genuine behaviour divergence from the original design: a
// request rejected here still returns 201 with zero writes, identical to the
// "already saturated" response below, so the producer (which only retries on
// a non-201 status) is never told anything went wrong.
async function admittedByBurstGuard(
  env: Env,
  fingerprint: string,
  instanceKey: string,
): Promise<boolean> {
  const { success } = await env.CRASH_INGEST_LIMITER.limit({
    key: `crash:${fingerprint}:${instanceKey}`,
  });
  return success;
}

// Final-review fix round: replaces the old read-then-separate-write shape
// that let concurrent requests race. THE key fix is one atomic
// `INSERT ... ON CONFLICT DO UPDATE ... RETURNING` statement per request --
// D1 only guarantees ordering within a single statement (or a .batch()), not
// across two independent .prepare()/.run() calls, so a SELECT followed later
// by a separate write left a window where N concurrent requests could all
// read the pre-increment state and all decide to write. Measured, before this
// fix: 20 concurrent identical crash reports produced 142 D1 writes against a
// cap the sequential-only test suite asserted was always 23.
//
// `hits` is an UNCAPPED, monotonic-within-the-hour counter advanced by this
// one statement; SQLite serialises writers to the same row even without an
// explicit transaction wrapper, so the Nth request to actually commit is
// guaranteed a unique `hits = N` -- "admitted" is simply `hits <= cap`,
// decided from the RETURNED value, with no stale read involved. `written`
// (MIN(hits, cap)) and `saturated` are still maintained for the existing
// dashboard-facing meaning of those columns (an exact write BUDGET, capped),
// computed from the same CASE expression as `hits` inside this one
// statement -- not from a separate read.
//
// A cheap read-only pre-check still runs BEFORE this (see registerCrashRoutes
// below) purely to skip the write entirely once a bucket is already solidly
// saturated for the hour -- the same optimisation the original design relied
// on to keep a saturating storm's total write cost roughly constant instead
// of scaling with request count. That pre-check is never the source of truth
// for admission; a stale read there can only cause a few extra calls to
// reach this statement, never let more than `cap` actually get admitted.
async function incrementBucketAtomically(
  db: D1Database,
  fingerprint: string,
  instanceKey: string,
  hourBucket: number,
  cap: number,
): Promise<AtomicBucketRow> {
  const result = await db
    .prepare(
      `INSERT INTO ingest_buckets (fingerprint, instance_key, hour_bucket, hits, written, saturated)
       VALUES (?, ?, ?, 1, 1, 0)
       ON CONFLICT(fingerprint, instance_key) DO UPDATE SET
         hits = CASE
           WHEN ingest_buckets.hour_bucket != excluded.hour_bucket THEN 1
           ELSE ingest_buckets.hits + 1
         END,
         hour_bucket = excluded.hour_bucket,
         written = MIN(
           CASE
             WHEN ingest_buckets.hour_bucket != excluded.hour_bucket THEN 1
             ELSE ingest_buckets.hits + 1
           END,
           ?
         ),
         saturated = CASE
           WHEN ingest_buckets.hour_bucket != excluded.hour_bucket THEN 0
           WHEN (ingest_buckets.hits + 1) >= ? THEN 1
           ELSE ingest_buckets.saturated
         END
       RETURNING hits, written, saturated`,
    )
    .bind(fingerprint, instanceKey, hourBucket, cap, cap)
    .run<Pick<AtomicBucketRow, "hits" | "written" | "saturated">>();

  const row = result.results[0];
  if (!row) {
    // RETURNING always yields exactly one row for a single-row upsert; this
    // is unreachable in practice and exists only so the return type doesn't
    // need a nullable escape hatch at every call site.
    throw new Error("ingest_buckets upsert returned no row");
  }
  return { ...row, writes: result.meta.rows_written };
}

export function registerCrashRoutes(app: Hono<{ Bindings: Env }>): void {
  app.post("/crashes/report", async (c) => {
    const body = (await c.req.json().catch(() => null)) as Record<
      string,
      unknown
    > | null;
    if (!body) return c.json({ error: "Invalid JSON body" }, 400);

    const validationErrors = validateCrashReportShape(body);
    if (validationErrors.length > 0) {
      return c.json({ error: "Validation failed", errors: validationErrors }, 400);
    }

    const crash = normalizeCrashReport(body);
    const top = crash.stacktrace[0];
    const topKey = top
      ? `${top.module ?? ""}:${top.function ?? ""}:${top.file ?? ""}:${top.line ?? ""}`
      : "no-frame";
    const fingerprint = await fingerprintOf(crash.kind, topKey);

    const instanceKey =
      c.req.header("cf-connecting-ip") ?? crash.version ?? "unknown";
    const hourBucket = Math.floor(crash.occurredAt / 3600);

    // Layer 1: the atomic, D1-free burst guard. A rejection here means this
    // exact (fingerprint, instance) pair has already sent CRASH_INGEST_LIMITER's
    // worth of requests in the last 10 seconds -- far more than the client-side
    // throttle (Mydia.CrashReporter.Throttle, 10/min per instance across ALL
    // fingerprints) could produce legitimately. No D1 access happens at all.
    if (!(await admittedByBurstGuard(c.env, fingerprint, instanceKey))) {
      return c.json({ ...ALREADY_HANDLED, id: fingerprint }, 201, {
        "x-relay-d1-writes": "0",
      });
    }

    // Layer 2: a cheap, non-authoritative pre-check. Once a bucket is
    // solidly saturated for the current hour, this skips the atomic write
    // entirely (0 further D1 access) -- the same trade fix round 1 made,
    // preserved here so a long-running storm's total write cost still stays
    // roughly constant instead of growing with however many requests the
    // burst guard admits over the storm's full duration. A stale read here
    // is harmless: it can only let a few extra requests reach layer 3, never
    // let more than the cap actually get admitted, since layer 3 is what
    // makes the real decision.
    const existing = await c.env.DB.prepare(
      "SELECT hour_bucket, written, saturated FROM ingest_buckets WHERE fingerprint = ? AND instance_key = ?",
    )
      .bind(fingerprint, instanceKey)
      .first<BucketRow>();

    const solidlySaturated =
      existing &&
      existing.hour_bucket === hourBucket &&
      existing.written >= MAX_OCCURRENCE_ROWS_PER_BUCKET;

    if (solidlySaturated) {
      return c.json({ ...ALREADY_HANDLED, id: fingerprint }, 201, {
        "x-relay-d1-writes": "0",
      });
    }

    // Layer 3: the atomic admission decision. See incrementBucketAtomically's
    // own comment for why this -- not the read above -- is what actually
    // bounds occurrence_count exactly, even under real concurrency.
    const bucket = await incrementBucketAtomically(
      c.env.DB,
      fingerprint,
      instanceKey,
      hourBucket,
      MAX_OCCURRENCE_ROWS_PER_BUCKET,
    );
    const admitted = bucket.hits <= MAX_OCCURRENCE_ROWS_PER_BUCKET;

    if (!admitted) {
      return c.json({ ...ALREADY_HANDLED, id: fingerprint }, 201, {
        "x-relay-d1-writes": String(bucket.writes),
      });
    }

    // count_is_floor is bound to the SAME `saturated` value the atomic
    // upsert above just computed for THIS bucket -- the moment this write is
    // the one that pushes the bucket to the cap. ON CONFLICT's
    // `MAX(errors.count_is_floor, excluded.count_is_floor)` is what makes it
    // sticky: once a prior write has set it to 1, a later write binding 0
    // (an ordinary, unsaturated crash from a *different* hour or instance)
    // can never flip it back. Unlike ingest_buckets.saturated, this column
    // is never told to reset -- see 0002_crash_reports.sql for why that
    // distinction is load-bearing.
    //
    // Batched together (not two separate .run() calls) so the error-group
    // upsert and the occurrence row it describes always land as one unit --
    // each statement is individually safe under concurrency on its own
    // (both are plain atomic upserts/inserts), but batching removes any
    // possibility of another concurrent request's statements interleaving
    // between these two specifically.
    const [errorsResult, occurrenceResult] = await c.env.DB.batch([
      c.env.DB.prepare(
        `INSERT INTO errors (fingerprint, kind, message, source_file, source_line,
                             status, first_seen_at, last_seen_at, occurrence_count,
                             count_is_floor)
         VALUES (?, ?, ?, ?, ?, 'unresolved', ?, ?, 1, ?)
         ON CONFLICT(fingerprint) DO UPDATE SET
           last_seen_at = excluded.last_seen_at,
           occurrence_count = errors.occurrence_count + 1,
           message = excluded.message,
           count_is_floor = MAX(errors.count_is_floor, excluded.count_is_floor)`,
      ).bind(
        fingerprint,
        crash.kind,
        crash.message,
        crash.sourceFile,
        crash.sourceLine,
        crash.occurredAt,
        crash.occurredAt,
        bucket.saturated,
      ),
      c.env.DB.prepare(
        `INSERT INTO occurrences
           (id, fingerprint, occurred_at, version, environment, instance_key, context, stacktrace)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        crypto.randomUUID(),
        fingerprint,
        crash.occurredAt,
        crash.version,
        crash.environment,
        instanceKey,
        JSON.stringify(crash.context),
        JSON.stringify(crash.stacktrace),
      ),
    ]);
    const writes = bucket.writes + errorsResult.meta.rows_written + occurrenceResult.meta.rows_written;

    // Mydia.CrashReporter.Sender.send_http_request/2 pattern-matches on
    // exactly {status: 201, body: response} as its only success case (see
    // lib/mydia/crash_reporter/sender.ex). Any other status -- including a
    // plausible-looking 202 Accepted -- falls into its catch-all branch,
    // which logs the send as failed and hands it to Queue for exponential
    // backoff retry, eventually discarding it after 10 attempts or 24 hours.
    // Returning 201 here is load-bearing, not cosmetic parity with the old
    // Elixir relay.
    //
    // x-relay-d1-writes exposes the actual write count this request
    // performed. It's not part of the producer's contract (Sender only
    // checks the status code), but it's the only way to observe
    // meta.rows_written from outside the Worker's own request handling, and
    // is what test/crashes/ingest.test.ts's write-bounding regression test
    // asserts on -- table row counts can't distinguish a skipped write from
    // an unconditional UPDATE that happens not to change a row count.
    return c.json(
      { status: "created", message: "Crash report received", id: fingerprint },
      201,
      { "x-relay-d1-writes": String(writes) },
    );
  });
}
