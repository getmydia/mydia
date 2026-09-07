import { env, applyD1Migrations } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

// The windowed overview queries filter on occurred_at alone. The only
// pre-existing index is (fingerprint, occurred_at DESC), which cannot serve
// that, so without a dedicated index every one of them full-scans the table
// and reads every column of every row, which is exactly what D1 bills. The
// three trailing columns exist so the scan never has to touch the table at
// all.
async function queryPlan(sql: string): Promise<string> {
  const { results } = await env.DB.prepare(`EXPLAIN QUERY PLAN ${sql}`)
    .bind(0)
    .all<{ detail: string }>();
  return results.map((row) => row.detail).join(" | ");
}

describe("0004_admin_overview migration", () => {
  it("serves the windowed crash count from a covering index", async () => {
    const plan = await queryPlan(
      "SELECT COUNT(*) AS n FROM occurrences WHERE occurred_at >= ?",
    );
    expect(plan).toContain("COVERING INDEX occurrences_occurred_at_idx");
  });

  it("serves the distinct-sources count from the same covering index", async () => {
    const plan = await queryPlan(
      "SELECT COUNT(DISTINCT instance_key) AS n FROM occurrences WHERE occurred_at >= ?",
    );
    expect(plan).toContain("COVERING INDEX occurrences_occurred_at_idx");
  });

  it("serves the version breakdown from the same covering index", async () => {
    const plan = await queryPlan(
      `SELECT COALESCE(version, 'unknown') AS version, COUNT(*) AS occurrences,
              COUNT(DISTINCT instance_key) AS sources
       FROM occurrences WHERE occurred_at >= ? GROUP BY 1`,
    );
    expect(plan).toContain("COVERING INDEX occurrences_occurred_at_idx");
  });

  it("creates sweep_runs with every column the overview reads", async () => {
    const { results } = await env.DB.prepare(
      "SELECT name FROM pragma_table_info('sweep_runs')",
    ).all<{ name: string }>();
    const names = results.map((row) => row.name);

    expect(names).toEqual(
      expect.arrayContaining([
        "id",
        "ran_at",
        "feedback_rate_limits_deleted",
        "ingest_buckets_deleted",
        "pairing_claims_deleted",
        "duration_ms",
      ]),
    );
  });

  it("indexes sweep_runs by ran_at, which both the read and the eviction need", async () => {
    const { results } = await env.DB.prepare(
      "SELECT name FROM pragma_index_list('sweep_runs')",
    ).all<{ name: string }>();
    expect(results.map((row) => row.name)).toContain("sweep_runs_ran_at_idx");
  });
});
