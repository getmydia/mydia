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
const MAX_OCCURRENCE_ROWS_PER_BUCKET = 3;

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

export function registerCrashRoutes(app: Hono<{ Bindings: Env }>): void {
  app.post("/crashes/report", async (c) => {
    const body = (await c.req.json().catch(() => null)) as Record<
      string,
      unknown
    > | null;
    if (!body) return c.json({ error: "Invalid JSON body" }, 400);

    const crash = normalizeCrashReport(body);
    const top = crash.stacktrace[0];
    const topKey = top
      ? `${top.module ?? ""}:${top.function ?? ""}:${top.file ?? ""}:${top.line ?? ""}`
      : "no-frame";
    const fingerprint = await fingerprintOf(crash.kind, topKey);

    const instanceKey =
      c.req.header("cf-connecting-ip") ?? crash.version ?? "unknown";
    const hourBucket = Math.floor(crash.occurredAt / 3600);

    // Always count. This is one small upsert regardless of storm volume.
    await c.env.DB.prepare(
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

    // Write a full occurrence row only while this fingerprint/instance/hour
    // is under budget. A crash-looping install keeps being counted but stops
    // consuming D1's daily write allowance for everybody else.
    const bucket = await c.env.DB.prepare(
      `INSERT INTO ingest_buckets (fingerprint, instance_key, hour_bucket, written)
       VALUES (?, ?, ?, 1)
       ON CONFLICT(fingerprint, instance_key, hour_bucket) DO UPDATE SET
         written = ingest_buckets.written + 1
       RETURNING written`,
    )
      .bind(fingerprint, instanceKey, hourBucket)
      .first<{ written: number }>();

    if ((bucket?.written ?? 0) <= MAX_OCCURRENCE_ROWS_PER_BUCKET) {
      await c.env.DB.prepare(
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
    }

    // Mydia.CrashReporter.Sender.send_http_request/2 pattern-matches on
    // exactly {status: 201, body: response} as its only success case (see
    // lib/mydia/crash_reporter/sender.ex). Any other status -- including a
    // plausible-looking 202 Accepted -- falls into its catch-all branch,
    // which logs the send as failed and hands it to Queue for exponential
    // backoff retry, eventually discarding it after 10 attempts or 24 hours.
    // Returning 201 here is load-bearing, not cosmetic parity with the old
    // Elixir relay.
    return c.json(
      { status: "created", message: "Crash report received", id: fingerprint },
      201,
    );
  });
}
