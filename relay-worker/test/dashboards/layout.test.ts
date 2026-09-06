import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { when, parsePage, MAX_PAGE } from "../../src/dashboards/layout";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

describe("when", () => {
  it("formats a normal unix timestamp as a readable UTC string", () => {
    expect(when(Date.parse("2026-01-15T10:30:00Z") / 1000)).toBe("2026-01-15 10:30:00");
  });

  // `toISOString()` throws RangeError past Date's +/-8.64e15ms range, and this
  // runs while BUILDING the page -- so without the guard one row does not
  // render as a bad cell, it takes /admin/errors down with a 500.
  it("returns a placeholder instead of throwing on an out-of-range timestamp", () => {
    expect(() => when(1e300)).not.toThrow();
    expect(when(1e300)).toBe("invalid date");
    expect(when(-1e300)).toBe("invalid date");
  });

  it("still renders a timestamp at the very edge of the representable range", () => {
    expect(() => when(8_640_000_000_000)).not.toThrow();
    expect(when(8_640_000_000_000)).not.toBe("invalid date");
  });
});

describe("parsePage", () => {
  it("clamps to the documented maximum and floors anything nonsensical at 0", () => {
    expect(parsePage(undefined)).toBe(0);
    expect(parsePage("not-a-number")).toBe(0);
    expect(parsePage("-5")).toBe(0);
    expect(parsePage("3")).toBe(3);
    expect(parsePage(String(MAX_PAGE + 1_000))).toBe(MAX_PAGE);
  });
});

// The end-to-end version of the `when` guard: a row whose occurred_at is
// already stored out of range (written before parseOccurredAt started
// clamping) must not be able to break the dashboard the maintainer would use
// to find it.
describe("/admin/errors with an out-of-range stored timestamp", () => {
  it("renders the page instead of returning a 500", async () => {
    const fingerprint = "ffffffffffffffffffffffffffffffff";
    await env.DB.prepare(
      `INSERT INTO errors (fingerprint, kind, message, source_file, source_line,
                           status, first_seen_at, last_seen_at, occurrence_count)
       VALUES (?, 'RuntimeError', 'stored before the clamp', 'm.ex', 1, 'unresolved', ?, ?, 1)
       ON CONFLICT(fingerprint) DO UPDATE SET last_seen_at = excluded.last_seen_at`,
    )
      .bind(fingerprint, 1e300, 1e300)
      .run();

    const res = await SELF.fetch("https://relay.mydia.dev/admin/errors");

    expect(res.status).toBe(200);
    expect(await res.text()).toContain("invalid date");
  });
});
