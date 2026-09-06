import { defineWorkersConfig, readD1Migrations } from "@cloudflare/vitest-pool-workers/config";
import path from "node:path";

// Read once at config load so every test file's beforeAll can apply the same
// migration set via applyD1Migrations(env.DB, env.TEST_MIGRATIONS) rather
// than each reading migrations/ off disk itself.
const migrations = await readD1Migrations(path.join(__dirname, "migrations"));

export default defineWorkersConfig({
  test: {
    // test/contract is a separate Vitest project (vitest.workspace.ts): a
    // plain-Node HTTP diff against two external services, not a workerd test.
    // Excluded here so this project's workerd pool never tries to load it.
    exclude: ["test/contract/**", "**/node_modules/**"],
    poolOptions: {
      workers: {
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          // Test-only secret so upstream-proxying tests (fetchMock-intercepted)
          // exercise the real forwarding path instead of the "not configured"
          // 503. Production keys are set with `wrangler secret put` and never
          // live in source.
          bindings: {
            TMDB_API_KEY: "test-tmdb-key",
            TVDB_API_KEY: "test-tvdb-key",
            SUBDL_API_KEY: "test-subdl-key",
            RESEND_API_KEY: "test-resend-key",
            // The one workers.dev hostname /admin/* is served on. Real value
            // lives in wrangler.jsonc's env.staging; this stand-in follows the
            // `someacct` convention the hostname tests already use. Note the
            // `-staging` in the worker name: the pre-existing cases in
            // test/dashboards/hostname.test.ts use `mydia-relay.someacct...`
            // and must keep 404ing against this.
            ADMIN_ACCESS_HOSTNAME: "mydia-relay-staging.someacct.workers.dev",
            TEST_MIGRATIONS: migrations,
          },
          // Overrides wrangler.jsonc's PROXY_LIMITER (300/60s) for tests only.
          // These entries take precedence over the ones the `wrangler` block
          // above loads, so production is untouched -- the deployed Worker
          // still gets 300/60s from wrangler.jsonc.
          //
          // The production number is unreachable in a test. Nothing in
          // Miniflare can spend the budget except real requests, so proving a
          // 429 costs `limit + 1` round trips through the whole Hono stack,
          // and test/obs/ratelimit.test.ts needs that four times over. At 300
          // that was ~17s locally and over the 30s per-test timeout on CI
          // hardware, which is how the suite came to fail the deploy job on
          // master (2026-09-06). Raising the timeout would only have moved the
          // threshold; the loops are the cost.
          //
          // It also shrinks the OTHER flake that file documents at length.
          // Miniflare's simulator clears its buckets on a wall-clock epoch
          // boundary rather than on consumption, so a 60s boundary landing
          // mid-loop wipes the in-flight count and the loop has to start over.
          // A loop that takes ~50ms instead of several seconds is far less
          // likely to span one at all.
          //
          // ONLY PROXY_LIMITER's limit differs from wrangler.jsonc. The other
          // four are repeated here at their exact production values, not
          // because they need overriding, but because this key may replace the
          // wrangler-derived set rather than merge into it -- listing all five
          // is correct either way, and omitting four of them would silently
          // delete those bindings if it replaces.
          //
          // Do not "tidy" the other four to round numbers. Tests depend on
          // their exact values: the crash and feedback suites assert D1 write
          // counts that follow directly from the 10/10s burst guards, and the
          // pairing suite deliberately exhausts the 10/min create budget.
          // Changing one of those is a test-expectation change, not a config
          // tweak. PROXY_LIMITER is the only one no test asserts a count
          // against -- every loop that spends it stops at the first 429.
          ratelimits: {
            PROXY_LIMITER: { simple: { limit: 25, period: 60 } },
            PAIRING_CREATE_LIMITER: { simple: { limit: 10, period: 60 } },
            PAIRING_READ_LIMITER: { simple: { limit: 30, period: 60 } },
            CRASH_INGEST_LIMITER: { simple: { limit: 10, period: 10 } },
            FEEDBACK_INGEST_LIMITER: { simple: { limit: 10, period: 10 } },
          },
        },
      },
    },
  },
});
