import type { Env as WorkerEnv } from "../src/env";
import type { D1Migration } from "@cloudflare/vitest-pool-workers";

// `cloudflare:test`'s `env` export is typed as the global `Cloudflare.Env`
// namespace as of @cloudflare/vitest-pool-workers 0.13.0 -- it was a test-only
// `ProvidedEnv` interface before -- so the suite's bindings are declared by
// merging into that namespace, the same shape `wrangler types` generates.
// Without this, `import { env } from "cloudflare:test"` types as the empty
// `Cloudflare.Env` and every binding access fails to typecheck.
//
// TEST_MIGRATIONS is injected only by vitest.config.ts's miniflare bindings
// (see readD1Migrations there) and applied in test setup via
// applyD1Migrations -- it has no production equivalent, so it lives on this
// test-only augmentation rather than on src/env.ts's Env, where production
// code could reach for it.
declare global {
  namespace Cloudflare {
    interface Env extends WorkerEnv {
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}
