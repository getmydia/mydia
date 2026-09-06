import type { Env } from "../src/env";

// `cloudflare:test`'s `env` export is typed as an empty `ProvidedEnv` until a
// test augments it via declaration merging (see the comment in
// @cloudflare/vitest-pool-workers/types/cloudflare-test.d.ts). Without this,
// `import { env } from "cloudflare:test"` types as `{}` and every binding
// access fails to typecheck.
declare module "cloudflare:test" {
  interface ProvidedEnv extends Env {}
}
