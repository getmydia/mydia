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
  PROXY_LIMITER: RateLimit;
  PAIRING_CREATE_LIMITER: RateLimit;
  PAIRING_READ_LIMITER: RateLimit;
}
