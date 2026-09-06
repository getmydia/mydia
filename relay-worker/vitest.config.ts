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
            TEST_MIGRATIONS: migrations,
          },
        },
      },
    },
  },
});
