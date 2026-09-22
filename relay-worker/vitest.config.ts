import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";
import path from "node:path";

// Read once at config load so every test file's beforeAll can apply the same
// migration set via applyD1Migrations(env.DB, env.TEST_MIGRATIONS) rather
// than each reading migrations/ off disk itself.
const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));

// Two projects, because they need genuinely different runtimes:
//
// - Everything under src/ is exercised inside workerd itself (the
//   cloudflareTest() plugin below, @cloudflare/vitest-pool-workers) so tests
//   see the real Cache API, KV, and rate-limit bindings the Worker will run
//   against in production.
//
// - test/contract treats both the Worker and the live Elixir relay as opaque
//   HTTP services reached over the real network by URL. It needs none of the
//   above -- no bindings, no SELF.fetch, no Cache API -- and workerd's
//   self-contained root CA store does not trust every TLS-intercepting proxy
//   a given network puts in front of outbound HTTPS (observed directly in
//   this sandbox: plain Node/curl reach https://relay.mydia.dev fine, but the
//   same fetch() from inside a workerd test fails with "TLS peer's
//   certificate is not trusted"). Running this project under plain Node
//   sidesteps that risk entirely and is also just the more honest runtime for
//   a black-box HTTP diff that has nothing to do with the Worker's own code.
//
// This was a vitest.workspace.ts until Vitest 4 removed workspace files;
// `test.projects` in the root config is the replacement, and the Workers
// integration became a Vite plugin (cloudflareTest()) in
// @cloudflare/vitest-pool-workers 0.13.0, replacing the removed
// defineWorkersConfig()/defineWorkersProject() helpers.
export default defineConfig({
  test: {
    projects: [
      {
        plugins: [
          cloudflareTest({
            wrangler: { configPath: "./wrangler.jsonc" },
            miniflare: {
              // The pool bundles its own workerd, whose newest supported
              // compatibility date trails the one wrangler.jsonc declares for
              // production (2026-09-01). workerd refuses to start a Worker whose
              // date is newer than its own, so the suite has to name the newest
              // date this runtime accepts or the run dies at startup:
              //
              //   service core:user:vitest-pool-workers-runner-0: This Worker
              //   requires compatibility date "2026-09-01", but the newest date
              //   supported by this server binary is "2026-08-22".
              //
              // This is not a new divergence, and it is smaller than the one it
              // replaces. The previous pool defaulted the runner to the latest
              // date its own bundled workerd supported, ignoring wrangler.jsonc
              // entirely -- ~2026-03-17 on the workerd 1.20260310.1 this repo
              // ran before. The suite therefore moves closer to production's
              // date (2026-08-22 instead of ~2026-03-17), and the ceiling is now
              // stated here instead of being an implicit pool default.
              //
              // Read wrangler.jsonc's date as production's contract and this
              // constant as the test runtime's ceiling. Nothing in this suite
              // asserts behaviour gated on a compatibility date in the gap, so
              // raising this to match production (or deleting it, once the
              // integration's bundled workerd passes that date) is safe as soon
              // as the runtime allows it.
              compatibilityDate: "2026-08-22",
              // Test-only secret so upstream-proxying tests (fetch-mock
              // intercepted) exercise the real forwarding path instead of the
              // "not configured" 503. Production keys are set with
              // `wrangler secret put` and never live in source.
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
              // Overrides wrangler.jsonc's PROXY_LIMITER (5000/60s) and
              // SUBTITLE_LIMITER (300/60s) for tests only. These entries take
              // precedence over the ones the `wrangler` block above loads, so
              // production is untouched -- the deployed Worker still gets its
              // numbers from wrangler.jsonc.
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
              // ONLY the two upstream limiters differ from wrangler.jsonc. The
              // other four are repeated here at their exact production values, not
              // because they need overriding, but because this key may replace the
              // wrangler-derived set rather than merge into it -- listing all five
              // is correct either way, and omitting any of them would silently
              // delete those bindings if it replaces.
              //
              // Do not "tidy" the other four to round numbers. Tests depend on
              // their exact values: the crash and feedback suites assert D1 write
              // counts that follow directly from the 10/10s burst guards, and the
              // pairing suite deliberately exhausts the 10/min create budget.
              // Changing one of those is a test-expectation change, not a config
              // tweak. The two upstream limiters are the only ones no test asserts
              // a count against -- every loop that spends them stops at the
              // first 429.
              //
              // `namespace_id` is required here as of the miniflare that
              // @cloudflare/vitest-pool-workers 0.22.0 bundles; the older
              // miniflare defaulted it. The ids are the top level's 1001-1006,
              // matching the values the four untouched limiters already claim
              // to carry.
              ratelimits: {
                PROXY_LIMITER: { namespace_id: "1001", simple: { limit: 25, period: 60 } },
                SUBTITLE_LIMITER: { namespace_id: "1006", simple: { limit: 25, period: 60 } },
                PAIRING_CREATE_LIMITER: { namespace_id: "1002", simple: { limit: 10, period: 60 } },
                PAIRING_READ_LIMITER: { namespace_id: "1003", simple: { limit: 30, period: 60 } },
                CRASH_INGEST_LIMITER: { namespace_id: "1004", simple: { limit: 10, period: 10 } },
                FEEDBACK_INGEST_LIMITER: { namespace_id: "1005", simple: { limit: 10, period: 10 } },
              },
            },
          }),
        ],
        test: {
          // test/contract is the other project below: a plain-Node HTTP diff
          // against two external services, not a workerd test. Excluded here
          // so this project's workerd pool never tries to load it.
          exclude: ["test/contract/**", "**/node_modules/**"],
        },
      },
      {
        test: {
          name: "contract",
          include: ["test/contract/**/*.test.ts"],
          environment: "node",
          // Real network round trips to a live service (two in parallel per
          // route) rather than the sub-millisecond in-process calls the rest of
          // the suite makes. OpenLibrary search alone can take several seconds.
          // MusicBrainz-backed routes (search, artist, release, release-group,
          // recording) are the slowest and least predictable of all: observed
          // 500ms-20s+ across otherwise-identical runs, most likely MusicBrainz's
          // documented ~1req/s courtesy rate limit applied per source IP, shared
          // across every mydia install this relay serves in production plus this
          // test's own doubled (Worker+relay) concurrent calls. The two timeouts
          // this was raised to fix were both slow responses, not body mismatches:
          // the same routes passed on a rerun with no code change.
          testTimeout: 60_000,
        },
      },
    ],
  },
});
