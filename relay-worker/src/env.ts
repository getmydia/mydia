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

  // Bindings
  CACHE_KV: KVNamespace;
  DB: D1Database;
  PROXY_LIMITER: RateLimit;
  PAIRING_CREATE_LIMITER: RateLimit;
  PAIRING_READ_LIMITER: RateLimit;
  // Burst guards in front of the two D1-backed hourly budgets (crash ingest,
  // feedback ingest). See src/crashes/ingest.ts and src/feedback/ingest.ts
  // for why a D1 read-then-write sequence needs an atomic gate ahead of it
  // that a `ratelimit` binding's 10s/60s period can't itself replace.
  CRASH_INGEST_LIMITER: RateLimit;
  FEEDBACK_INGEST_LIMITER: RateLimit;
}
