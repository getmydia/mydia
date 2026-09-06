import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        wrangler: { configPath: "./wrangler.jsonc" },
        // Test-only secret so upstream-proxying tests (fetchMock-intercepted)
        // exercise the real forwarding path instead of the "not configured"
        // 503. Production keys are set with `wrangler secret put` and never
        // live in source.
        miniflare: {
          bindings: {
            TMDB_API_KEY: "test-tmdb-key",
            TVDB_API_KEY: "test-tvdb-key",
          },
        },
      },
    },
  },
});
