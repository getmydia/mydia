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
