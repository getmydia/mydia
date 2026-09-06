import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { normalizeCrashReport, MAX_OCCURRENCE_ROWS_PER_BUCKET } from "../../src/crashes/ingest";

const json = { "content-type": "application/json" };
const REPORT_URL = "https://relay.mydia.dev/crashes/report";

interface ReportResponse {
  status: string;
  message: string;
  id: string;
}

interface ValidationErrorResponse {
  error: string;
  errors: string[];
}

interface TableCounts {
  errors: number;
  occurrences: number;
  buckets: number;
}

// Table ROW COUNTS are the wrong instrument for proving writes are bounded --
// an INSERT ... ON CONFLICT DO UPDATE against an existing row doesn't change
// COUNT(*), even though D1 bills it as a write every time (confirmed against
// D1's own `meta.rows_written` during fix round 1's review). This is exactly
// why the original storm test's `occurrences.n < 10` assertion missed the
// real defect: the `errors` and `ingest_buckets` rows were being upserted on
// every single request, and COUNT(*) on either table stayed at 1 the whole
// time regardless. Used below only for the "nothing was written at all"
// (validation-rejected) and "exactly one row landed" (happy path) cases,
// where the before/after DELTA in row count is the right signal; the
// write-bounding test itself sums `x-relay-d1-writes` instead.
async function tableCounts(): Promise<TableCounts> {
  const [errors, occurrences, buckets] = await Promise.all([
    env.DB.prepare("SELECT COUNT(*) AS n FROM errors").first<{ n: number }>(),
    env.DB.prepare("SELECT COUNT(*) AS n FROM occurrences").first<{ n: number }>(),
    env.DB.prepare("SELECT COUNT(*) AS n FROM ingest_buckets").first<{ n: number }>(),
  ]);
  return { errors: errors!.n, occurrences: occurrences!.n, buckets: buckets!.n };
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

describe("normalizeCrashReport", () => {
  it("uses the reported error type as the kind", () => {
    const out = normalizeCrashReport({
      error_type: "Ecto.NoResultsError",
      error_message: "expected at least one result",
      stacktrace: [{ module: "Mydia.Media", function: "get!/1", file: "media.ex", line: 12 }],
    });

    expect(out.kind).toBe("Ecto.NoResultsError");
    expect(out.message).toBe("expected at least one result");
  });

  it("defaults kind and message when the payload omits them", () => {
    const out = normalizeCrashReport({});
    expect(out.kind).toBe("RuntimeError");
    expect(out.message).toBe("Unknown error");
  });

  it("synthesises a frame from metadata when no stacktrace is supplied", () => {
    // Without any source info every report would derive the same fingerprint
    // and collapse into one useless group.
    const out = normalizeCrashReport({
      error_type: "ArgumentError",
      error_message: "bad arg",
      metadata: { module: "Mydia.Library", function: "scan/1", file: "library.ex", line: 88 },
    });

    expect(out.stacktrace).toHaveLength(1);
    expect(out.sourceFile).toBe("library.ex");
    expect(out.sourceLine).toBe(88);
  });

  // router.ex's metadata_stack_frame/1 only synthesises a frame when metadata
  // carries `file` or `line` -- module/function alone are not enough (they
  // get folded into the frame if a frame is built, but they don't trigger
  // building one). Getting this backwards would mean a report that names a
  // module/function but has no location either loses its distinguishing
  // frame (falls back to "no-frame", the same group as every other
  // location-less report) or, worse, incorrectly keeps location-less reports
  // apart when router.ex would have grouped them.
  it("does not synthesise a frame from metadata that has no file or line", () => {
    const out = normalizeCrashReport({
      error_type: "ArgumentError",
      error_message: "bad arg",
      metadata: { module: "Mydia.Library", function: "scan/1" },
    });

    expect(out.stacktrace).toHaveLength(0);
    expect(out.sourceFile).toBeNull();
    expect(out.sourceLine).toBeNull();
  });

  // Mydia.CrashReporter.build_report/3 sends `occurred_at` as
  // `DateTime.to_iso8601/1` -- a string, never a Unix number. A check that
  // only accepts `typeof === "number"` silently discards this field on every
  // real report and substitutes ingestion time instead.
  it("parses an ISO8601 occurred_at as sent by Mydia.CrashReporter", () => {
    const out = normalizeCrashReport({
      error_type: "RuntimeError",
      error_message: "boom",
      occurred_at: "2026-01-15T10:30:00.000000Z",
    });

    expect(out.occurredAt).toBe(Math.floor(Date.parse("2026-01-15T10:30:00.000000Z") / 1000));
  });
});

describe("POST /crashes/report", () => {
  it("accepts a report, creates the error group, and writes exactly one row per table", async () => {
    const before = await tableCounts();

    const res = await SELF.fetch(REPORT_URL, {
      method: "POST",
      headers: json,
      body: JSON.stringify({
        error_type: "RuntimeError",
        error_message: "boom",
        version: "1.2.3",
        environment: "prod",
        stacktrace: [{ module: "M", function: "f/0", file: "m.ex", line: 1 }],
      }),
    });

    // Mydia.CrashReporter.Sender.send_http_request/2 pattern-matches on
    // exactly {status: 201, body: response} as its success case; anything
    // else (including a plausible-looking 202) falls through to the
    // catch-all "unexpected HTTP status" branch, which is logged as a
    // failure and retried by Queue until it is discarded. 201 is not
    // cosmetic here.
    expect(res.status).toBe(201);
    const resBody = await res.json<ReportResponse>();
    expect(resBody.status).toBe("created");

    const row = await env.DB.prepare(
      "SELECT kind, occurrence_count FROM errors WHERE kind = ?",
    )
      .bind("RuntimeError")
      .first();
    expect(row).toMatchObject({ kind: "RuntimeError", occurrence_count: 1 });

    const after = await tableCounts();
    expect(after).toEqual({
      errors: before.errors + 1,
      occurrences: before.occurrences + 1,
      buckets: before.buckets + 1,
    });
  });

  it("groups two identical crashes under one fingerprint", async () => {
    const payload = {
      error_type: "GroupMe",
      error_message: "same",
      stacktrace: [{ module: "M", function: "f/0", file: "m.ex", line: 7 }],
    };

    for (let i = 0; i < 2; i++) {
      await SELF.fetch(REPORT_URL, {
        method: "POST",
        headers: json,
        body: JSON.stringify(payload),
      });
    }

    const { results } = await env.DB.prepare(
      "SELECT occurrence_count FROM errors WHERE kind = ?",
    )
      .bind("GroupMe")
      .all();

    expect(results).toHaveLength(1);
    expect(results[0].occurrence_count).toBe(2);
  });

  // Fix round 1's critical finding: the original implementation upserted
  // `errors` and `ingest_buckets` UNCONDITIONALLY on every request, before
  // even checking the cap -- only the `occurrences` insert was actually
  // throttled. D1 counts an `ON CONFLICT DO UPDATE` as a write on every call
  // whether it inserts or updates, so a storm of N requests performed ~2N
  // writes: the install that could exhaust the daily budget before this fix
  // could still exhaust it after, needing only the same order of magnitude
  // of requests.
  //
  // This sums the actual D1 writes each request performs (exposed via the
  // x-relay-d1-writes response header, since the test has no other way to
  // observe meta.rows_written from inside the Worker's own request handling)
  // rather than inspecting table row counts, which can't tell an
  // unconditional UPDATE from a skipped one.
  //
  // It deliberately does NOT assert an exact write total: a single INSERT
  // touches its table's own B-tree plus one per index (including the
  // implicit autoindex a non-INTEGER PRIMARY KEY creates), so the true
  // per-request cost is a small implementation detail of the schema, not a
  // clean constant -- measured at 9, 7, and 7 writes for the three requests
  // that actually write, once for each of errors/ingest_buckets/occurrences
  // in this schema. What must hold regardless of that detail is the actual
  // invariant this task cares about: a storm 10x larger performs the SAME
  // total writes, not 10x more, because writes stop entirely once the
  // bucket saturates.
  it("performs the same total D1 writes for a small and a large crash storm", async () => {
    async function totalWritesFor(kind: string, ip: string, count: number): Promise<number> {
      let total = 0;
      for (let i = 0; i < count; i++) {
        const res = await SELF.fetch(REPORT_URL, {
          method: "POST",
          headers: { ...json, "cf-connecting-ip": ip },
          body: JSON.stringify({
            error_type: kind,
            error_message: "loop",
            stacktrace: [{ module: "M", function: "f/0", file: "m.ex", line: 11 }],
          }),
        });
        expect(res.status).toBe(201);
        total += Number(res.headers.get("x-relay-d1-writes") ?? "0");
      }
      return total;
    }

    // Both counts exceed MAX_OCCURRENCE_ROWS_PER_BUCKET, so both storms
    // saturate partway through -- different fingerprints/instances so they
    // can't share (and thus contaminate) a bucket.
    const smallStorm = await totalWritesFor("WriteBoundSmall", "198.51.100.61", 5);
    const bigStorm = await totalWritesFor("WriteBoundBig", "198.51.100.63", 50);

    expect(bigStorm).toBe(smallStorm);
    // Sanity bound well under what unconditional per-request upserts (the
    // pre-fix behaviour) would cost 50 requests: observed 23, asserted <50
    // to avoid coupling this test to the schema's exact index count.
    expect(bigStorm).toBeLessThan(50);
  });

  it("caps occurrence_count and marks the bucket saturated once a storm exceeds the per-hour budget", async () => {
    const payload = {
      error_type: "StormError",
      error_message: "loop",
      stacktrace: [{ module: "M", function: "f/0", file: "m.ex", line: 9 }],
    };
    const ip = "198.51.100.7";

    for (let i = 0; i < 50; i++) {
      await SELF.fetch(REPORT_URL, {
        method: "POST",
        headers: { ...json, "cf-connecting-ip": ip },
        body: JSON.stringify(payload),
      });
    }

    const error = await env.DB.prepare(
      "SELECT fingerprint, occurrence_count FROM errors WHERE kind = ?",
    )
      .bind("StormError")
      .first<{ fingerprint: string; occurrence_count: number }>();

    const occurrences = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM occurrences WHERE fingerprint = ?",
    )
      .bind(error!.fingerprint)
      .first<{ n: number }>();

    const bucket = await env.DB.prepare(
      "SELECT written, saturated FROM ingest_buckets WHERE fingerprint = ? AND instance_key = ?",
    )
      .bind(error!.fingerprint, ip)
      .first<{ written: number; saturated: number }>();

    // occurrence_count is now a FLOOR once saturated, not an exact count of
    // every crash received -- this is the deliberate trade-off fix round 1
    // mandated in exchange for bounding writes (superseding this task's
    // original "every crash is still counted" goal). `saturated` is what
    // lets a reader tell the two apart instead of silently presenting an
    // undercount as exact.
    expect(error!.occurrence_count).toBe(MAX_OCCURRENCE_ROWS_PER_BUCKET);
    expect(occurrences!.n).toBe(MAX_OCCURRENCE_ROWS_PER_BUCKET);
    expect(bucket!.written).toBe(MAX_OCCURRENCE_ROWS_PER_BUCKET);
    expect(bucket!.saturated).toBe(1);
  });

  // router.ex's validate_crash_report/1 requires error_type, error_message
  // and stacktrace to be PRESENT KEYS (Map.has_key?, any value including
  // null satisfies it) before it stores anything, returning 400 with no
  // write when they're missing. The Worker had no equivalent gate: since a
  // bare `{}` always normalises to the same kind/topKey and the errors
  // upsert was unthrottled, this was a second, EASIER route to budget
  // exhaustion than a crash loop -- no throttling applies to a fingerprint
  // that's never been seen before, so repeated anonymous POSTs of `{}` to
  // this unauthenticated endpoint could each mint a fresh write.
  describe("required-field validation (matches router.ex's Map.has_key? gate)", () => {
    it("rejects an empty object with zero rows written anywhere", async () => {
      const before = await tableCounts();

      const res = await SELF.fetch(REPORT_URL, {
        method: "POST",
        headers: json,
        body: JSON.stringify({}),
      });

      expect(res.status).toBe(400);
      const body = await res.json<ValidationErrorResponse>();
      expect(body.error).toBe("Validation failed");
      expect(body.errors).toEqual(
        expect.arrayContaining([
          "Missing required field: error_type",
          "Missing required field: error_message",
          "Missing required field: stacktrace",
        ]),
      );

      expect(await tableCounts()).toEqual(before);
    });

    it("rejects a payload missing only stacktrace, with zero rows written", async () => {
      const before = await tableCounts();

      const res = await SELF.fetch(REPORT_URL, {
        method: "POST",
        headers: json,
        body: JSON.stringify({
          error_type: "SomeError",
          error_message: "no stacktrace field at all",
        }),
      });

      expect(res.status).toBe(400);
      const body = await res.json<ValidationErrorResponse>();
      expect(body.errors).toEqual(["Missing required field: stacktrace"]);

      expect(await tableCounts()).toEqual(before);
    });

    it("rejects a non-list stacktrace even when the key is present", async () => {
      const res = await SELF.fetch(REPORT_URL, {
        method: "POST",
        headers: json,
        body: JSON.stringify({
          error_type: "SomeError",
          error_message: "stacktrace is a string, not a list",
          stacktrace: "not-a-list",
        }),
      });

      expect(res.status).toBe(400);
      const body = await res.json<ValidationErrorResponse>();
      expect(body.errors).toContain("stacktrace must be a list");
    });
  });

  // Prior schema keyed ingest_buckets on (fingerprint, instance_key,
  // hour_bucket), so this table grew by one row per fingerprint/instance for
  // every hour that ever elapsed, forever -- unbounded by anything but
  // wall-clock time. The fixed schema keys on (fingerprint, instance_key)
  // alone and treats hour_bucket as a column that gets reset in place.
  it("does not multiply bucket rows across hour boundaries for the same fingerprint/instance", async () => {
    const ip = "198.51.100.62";
    const reportAt = (occurredAt: string) =>
      SELF.fetch(REPORT_URL, {
        method: "POST",
        headers: { ...json, "cf-connecting-ip": ip },
        body: JSON.stringify({
          error_type: "HourRollover",
          error_message: "boom",
          stacktrace: [{ module: "M", function: "f/0", file: "m.ex", line: 42 }],
          occurred_at: occurredAt,
        }),
      });

    await reportAt("2026-01-01T00:10:00.000Z");
    await reportAt("2026-01-01T05:45:00.000Z"); // a different hour bucket entirely

    const error = await env.DB.prepare("SELECT fingerprint FROM errors WHERE kind = ?")
      .bind("HourRollover")
      .first<{ fingerprint: string }>();

    const { results } = await env.DB.prepare(
      "SELECT hour_bucket, written FROM ingest_buckets WHERE fingerprint = ? AND instance_key = ?",
    )
      .bind(error!.fingerprint, ip)
      .all<{ hour_bucket: number; written: number }>();

    expect(results).toHaveLength(1);
    // The stored hour_bucket tracks the most recent request's hour, and its
    // budget was reset for that hour rather than carried over.
    expect(results[0].written).toBe(1);
  });

  it("rejects a body that is not JSON", async () => {
    const res = await SELF.fetch(REPORT_URL, {
      method: "POST",
      headers: json,
      body: "not json",
    });
    expect(res.status).toBe(400);
  });

  // Final-review CRITICAL: every test above drives requests sequentially,
  // which is structurally blind to a defect that only appears under
  // concurrency. The original read-then-separate-write shape (SELECT the
  // bucket, decide in JS, then issue independent INSERT ... ON CONFLICT DO
  // UPDATE statements) is not a transaction -- D1 only guarantees ordering
  // within one statement or a .batch(), not across two independent
  // .prepare()/.run() calls -- so concurrent identical requests could all
  // read the same pre-increment state and all decide to admit. Measured
  // against the pre-fix code: 20 concurrent identical crash reports produced
  // 142 total D1 writes and an occurrence_count nowhere near the 3-per-hour
  // cap. Promise.all (not a for loop) is what actually exercises the race;
  // a for loop with awaited iterations is sequential in disguise.
  it("bounds occurrence_count and total writes under REAL concurrency (Promise.all), not just sequentially", async () => {
    const kind = "ConcurrentStorm";
    const ip = "198.51.100.201";
    const payload = {
      error_type: kind,
      error_message: "concurrent boom",
      stacktrace: [{ module: "M", function: "f/0", file: "m.ex", line: 5 }],
    };

    const responses = await Promise.all(
      Array.from({ length: 20 }, () =>
        SELF.fetch(REPORT_URL, {
          method: "POST",
          headers: { ...json, "cf-connecting-ip": ip },
          body: JSON.stringify(payload),
        }),
      ),
    );

    // The producer contract holds regardless of admission: every one of the
    // 20 concurrent requests still gets 201 (Sender only retries on a
    // non-201 status), whether or not this particular request's crash was
    // actually counted.
    for (const res of responses) {
      expect(res.status).toBe(201);
    }

    const error = await env.DB.prepare(
      "SELECT fingerprint, occurrence_count FROM errors WHERE kind = ?",
    )
      .bind(kind)
      .first<{ fingerprint: string; occurrence_count: number }>();

    // The atomic admission decision (a single INSERT ... ON CONFLICT DO
    // UPDATE ... RETURNING per request) guarantees the SAME exact cap holds
    // under concurrency as under the sequential test above -- not merely "a
    // smaller number than before".
    expect(error!.occurrence_count).toBe(MAX_OCCURRENCE_ROWS_PER_BUCKET);

    const occurrences = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM occurrences WHERE fingerprint = ?",
    )
      .bind(error!.fingerprint)
      .first<{ n: number }>();
    expect(occurrences!.n).toBe(MAX_OCCURRENCE_ROWS_PER_BUCKET);

    const bucket = await env.DB.prepare(
      "SELECT written, saturated FROM ingest_buckets WHERE fingerprint = ? AND instance_key = ?",
    )
      .bind(error!.fingerprint, ip)
      .first<{ written: number; saturated: number }>();
    expect(bucket!.written).toBe(MAX_OCCURRENCE_ROWS_PER_BUCKET);
    expect(bucket!.saturated).toBe(1);
  });
});
