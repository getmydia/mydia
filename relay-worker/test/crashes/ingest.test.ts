import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { normalizeCrashReport } from "../../src/crashes/ingest";

const json = { "content-type": "application/json" };

interface ReportResponse {
  status: string;
  message: string;
  id: string;
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
  it("accepts a report and creates the error group", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/crashes/report", {
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
  });

  it("groups two identical crashes under one fingerprint", async () => {
    const payload = {
      error_type: "GroupMe",
      error_message: "same",
      stacktrace: [{ module: "M", function: "f/0", file: "m.ex", line: 7 }],
    };

    for (let i = 0; i < 2; i++) {
      await SELF.fetch("https://relay.mydia.dev/crashes/report", {
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

  it("counts a crash storm but stops writing occurrence rows for it", async () => {
    const payload = {
      error_type: "StormError",
      error_message: "loop",
      stacktrace: [{ module: "M", function: "f/0", file: "m.ex", line: 9 }],
    };

    for (let i = 0; i < 50; i++) {
      await SELF.fetch("https://relay.mydia.dev/crashes/report", {
        method: "POST",
        headers: { ...json, "cf-connecting-ip": "198.51.100.7" },
        body: JSON.stringify(payload),
      });
    }

    const error = await env.DB.prepare(
      "SELECT occurrence_count FROM errors WHERE kind = ?",
    )
      .bind("StormError")
      .first<{ occurrence_count: number }>();

    const occurrences = await env.DB.prepare(
      `SELECT COUNT(*) AS n FROM occurrences
       WHERE fingerprint = (SELECT fingerprint FROM errors WHERE kind = ?)`,
    )
      .bind("StormError")
      .first<{ n: number }>();

    // Every crash is counted.
    expect(error!.occurrence_count).toBe(50);
    // But the write budget is bounded: far fewer rows than reports.
    expect(occurrences!.n).toBeLessThan(10);
  });

  it("rejects a body that is not JSON", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/crashes/report", {
      method: "POST",
      headers: json,
      body: "not json",
    });
    expect(res.status).toBe(400);
  });
});
