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

    // READ the bucket first. This is the fix for fix round 1's critical
    // finding: the original version upserted `errors` and `ingest_buckets`
    // UNCONDITIONALLY on every request, before ever checking the cap -- only
    // the `occurrences` insert was actually throttled. D1 counts an
    // `INSERT ... ON CONFLICT DO UPDATE` as a write on every call whether it
    // inserts or updates, so a storm of N requests performed ~2N writes
    // regardless of the cap: the install that could exhaust the daily
    // budget before this fix could still exhaust it after, needing only the
    // same order of magnitude of requests.
    //
    // A read is roughly a fiftieth the cost of a write on D1's free tier (5M
    // row reads/day vs. 100k row writes/day), so paying for one read per
    // request to decide whether to write at all is the trade that actually
    // bounds writes: once a bucket is saturated, this request performs NO
    // further D1 access at all -- no errors upsert, no bucket write, no
    // occurrence insert.
    const existing = await c.env.DB.prepare(
      "SELECT hour_bucket, written, saturated FROM ingest_buckets WHERE fingerprint = ? AND instance_key = ?",
    )
      .bind(fingerprint, instanceKey)
      .first<BucketRow>();

    // A stored hour_bucket different from the current one (including no row
    // at all) means this is a fresh budget window: reset to a clean count
    // rather than carrying the previous hour's total forward. This is also
    // what keeps ingest_buckets bounded by distinct (fingerprint,
    // instance_key) pairs instead of growing by one row per pair for every
    // hour that has ever elapsed -- the table's primary key no longer
    // includes hour_bucket at all (migrations/0002_crash_reports.sql).
    const isFreshWindow = !existing || existing.hour_bucket !== hourBucket;
    const priorWritten = isFreshWindow ? 0 : existing!.written;

    if (!isFreshWindow && priorWritten >= MAX_OCCURRENCE_ROWS_PER_BUCKET) {
      // Already saturated for this hour: perform no writes at all. The
      // producer still gets the 201 it expects (Sender only retries on a
      // non-201 status); the crash is simply not reflected in
      // occurrence_count or a new occurrences row. ingest_buckets.saturated
      // (set below, on the write that reached the cap) is what tells a
      // reader this count is a floor, not an exact total, for the rest of
      // this hour.
      return c.json(
        { status: "created", message: "Crash report received", id: fingerprint },
        201,
        { "x-relay-d1-writes": "0" },
      );
    }

    const written = priorWritten + 1;
    const saturated = written >= MAX_OCCURRENCE_ROWS_PER_BUCKET ? 1 : 0;
    let writes = 0;

    const errorsResult = await c.env.DB.prepare(
      `INSERT INTO errors (fingerprint, kind, message, source_file, source_line,
                           status, first_seen_at, last_seen_at, occurrence_count)
       VALUES (?, ?, ?, ?, ?, 'unresolved', ?, ?, 1)
       ON CONFLICT(fingerprint) DO UPDATE SET
         last_seen_at = excluded.last_seen_at,
         occurrence_count = errors.occurrence_count + 1,
         message = excluded.message`,
    )
      .bind(
        fingerprint,
        crash.kind,
        crash.message,
        crash.sourceFile,
        crash.sourceLine,
        crash.occurredAt,
        crash.occurredAt,
      )
      .run();
    writes += errorsResult.meta.rows_written;

    const bucketResult = await c.env.DB.prepare(
      `INSERT INTO ingest_buckets (fingerprint, instance_key, hour_bucket, written, saturated)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(fingerprint, instance_key) DO UPDATE SET
         hour_bucket = excluded.hour_bucket,
         written = excluded.written,
         saturated = excluded.saturated`,
    )
      .bind(fingerprint, instanceKey, hourBucket, written, saturated)
      .run();
    writes += bucketResult.meta.rows_written;

    const occurrenceResult = await c.env.DB.prepare(
      `INSERT INTO occurrences
         (id, fingerprint, occurred_at, version, environment, instance_key, context, stacktrace)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    )
      .bind(
        crypto.randomUUID(),
        fingerprint,
        crash.occurredAt,
        crash.version,
        crash.environment,
        instanceKey,
        JSON.stringify(crash.context),
        JSON.stringify(crash.stacktrace),
      )
      .run();
    writes += occurrenceResult.meta.rows_written;

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
