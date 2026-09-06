import { defineWorkspace } from "vitest/config";

// Two projects, because they need genuinely different runtimes:
//
// - Everything under src/ is exercised inside workerd itself (vitest.config.ts,
//   @cloudflare/vitest-pool-workers) so tests see the real Cache API, KV, and
//   rate-limit bindings the Worker will run against in production.
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
export default defineWorkspace([
  "vitest.config.ts",
  {
    test: {
      name: "contract",
      include: ["test/contract/**/*.test.ts"],
      environment: "node",
      // Real network round trips to a live service (two in parallel per
      // route, one of which -- OpenLibrary search -- routinely takes longer
      // than Vitest's 5s default) rather than the sub-millisecond in-process
      // calls the rest of the suite makes.
      testTimeout: 20_000,
    },
  },
]);
