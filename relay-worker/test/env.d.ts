import type { Env } from "../src/env";
import type { D1Migration } from "@cloudflare/vitest-pool-workers/config";

// `cloudflare:test`'s `env` export is typed as an empty `ProvidedEnv` until a
// test augments it via declaration merging (see the comment in
// @cloudflare/vitest-pool-workers/types/cloudflare-test.d.ts). Without this,
// `import { env } from "cloudflare:test"` types as `{}` and every binding
// access fails to typecheck.
//
// TEST_MIGRATIONS is injected only by vitest.config.ts's miniflare bindings
// (see readD1Migrations there) and applied in test setup via
// applyD1Migrations -- it has no production equivalent, so it lives on this
// test-only interface rather than on Env, where production code could reach
// for it.
declare module "cloudflare:test" {
  interface ProvidedEnv extends Env {
    TEST_MIGRATIONS: D1Migration[];
  }
}
