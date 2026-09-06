import type { MiddlewareHandler } from "hono";
import type { Env } from "../env";

// Paths that are never throttled here. /health and /stats are polled by
// deployed monitoring, and throttling those would turn a busy relay into an
// apparently dead one.
const EXEMPT = new Set(["/health", "/stats"]);

// Prefixes that carry their own, tighter limiter and must not also be charged
// against the 300/min proxy budget. Pairing uses 10/min create and 30/min read;
// charging both would let a normal pairing flow exhaust the proxy budget for
// the same IP and break metadata for that install.
const EXEMPT_PREFIXES = ["/pairing/", "/crashes/", "/feedback", "/errors"];

// Applied on a cache miss only, matching ProxyRateLimit's placement after the
// cache plug. A cache hit costs no upstream quota, so throttling one buys
// nothing and hurts a legitimate "refresh all metadata" pass.
export function rateLimitMiddleware(): MiddlewareHandler<{ Bindings: Env }> {
  return async (c, next) => {
    const path = new URL(c.req.url).pathname;
    if (EXEMPT.has(path)) return next();
    if (EXEMPT_PREFIXES.some((prefix) => path.startsWith(prefix))) return next();

    await next();

    if (c.res.headers.get("x-relay-cache") === "HIT") return;

    const ip = c.req.header("cf-connecting-ip") ?? "unknown";
    const { success } = await c.env.PROXY_LIMITER.limit({ key: `proxy:${ip}` });

    if (!success) {
      // Exact parity with metadata_relay/plug/proxy_rate_limit.ex's enforce/1:
      // {"error": "Too many requests", "message": "Rate limit exceeded. Please
      // try again later."}, retry-after 60 (window_ms / 1000). This is
      // deliberately NOT router.ex's separate send_rate_limited/2 helper (used
      // by pairing/feedback/crash-report routes), which answers with a
      // differently-cased "rate_limited" error string -- the two are
      // different limiters in the Elixir codebase with different response
      // bodies, and this one replaces ProxyRateLimit specifically.
      c.res = new Response(
        JSON.stringify({
          error: "Too many requests",
          message: "Rate limit exceeded. Please try again later.",
        }),
        {
          status: 429,
          headers: {
            "content-type": "application/json",
            "retry-after": "60",
          },
        },
      );
    }
  };
}
