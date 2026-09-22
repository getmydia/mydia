export interface Env {
  // Secrets (set with `wrangler secret put`)
  TMDB_API_KEY?: string;
  TVDB_API_KEY?: string;
  SUBDL_API_KEY?: string;
  RESEND_API_KEY?: string;

  // Vars
  RELAY_VERSION: string;
  FEEDBACK_FROM: string;
  FEEDBACK_TO: string;

  // The single `*.workers.dev` hostname where a Cloudflare Access application
  // is known to cover `/admin*`. Set on `env.staging` only (wrangler.jsonc),
  // so the maintainer dashboards are reachable on the staging deploy
  // subdomain and nowhere else under workers.dev. Optional on purpose: an
  // absent value makes src/dashboards/hostname-guard.ts fail closed, which is
  // exactly the behaviour production and local dev want.
  ADMIN_ACCESS_HOSTNAME?: string;

  // The cutover traffic layer (src/routing/router.ts). On TRAFFIC_HOSTNAME,
  // each route group is answered by TRAFFIC_ORIGIN (the Elixir relay), by
  // this Worker, or by both, per the routing config in CACHE_KV. Both unset,
  // or any other hostname, and this Worker answers everything itself.
  TRAFFIC_HOSTNAME?: string;
  TRAFFIC_ORIGIN?: string;

  // Bindings
  CACHE_KV: KVNamespace;
  DB: D1Database;
  // Upstream-call budgets, charged only on a cache miss. See
  // src/obs/ratelimit.ts for why SubDL has one of its own.
  PROXY_LIMITER: RateLimit;
  SUBTITLE_LIMITER: RateLimit;
  PAIRING_CREATE_LIMITER: RateLimit;
  PAIRING_READ_LIMITER: RateLimit;
  // Burst guards in front of the two D1-backed hourly budgets (crash ingest,
  // feedback ingest). See src/crashes/ingest.ts and src/feedback/ingest.ts
  // for why a D1 read-then-write sequence needs an atomic gate ahead of it
  // that a `ratelimit` binding's 10s/60s period can't itself replace.
  CRASH_INGEST_LIMITER: RateLimit;
  FEEDBACK_INGEST_LIMITER: RateLimit;
}
