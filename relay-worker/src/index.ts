import { Hono } from "hono";
import type { Env } from "./env";
import { registerTmdbRoutes } from "./proxy/tmdb";
import { registerTvdbRoutes } from "./proxy/tvdb";
import { registerSubdlRoutes, subdlApiKey } from "./proxy/subdl";
import { registerPassthroughRoutes } from "./proxy/passthrough";
import { registerPairingRoutes } from "./pairing/routes";
import { registerCrashRoutes } from "./crashes/ingest";
import { registerErrorDashboard } from "./dashboards/errors";
import { registerFeedbackRoutes } from "./feedback/ingest";
import { rateLimitMiddleware } from "./obs/ratelimit";
import { logRequest } from "./obs/log";
import { runScheduledSweep } from "./obs/sweep";

export const app = new Hono<{ Bindings: Env }>();

// Both registered before every route (including /health and /stats below) so
// the EXEMPT set inside rateLimitMiddleware is what actually protects those
// routes, not an accident of Hono's registration-order middleware
// composition -- app.use() only wraps routes registered after it, so a
// health-check route defined ahead of this would otherwise never reach
// either middleware at all.
//
// Order between the two matters, and it is the OPPOSITE of what it looks
// like it should be: Hono composes middleware as an onion, so whichever is
// registered SECOND runs as the INNER layer, closer to the route. The
// logging middleware must be outermost (registered first) so its
// `await next()` only returns once rateLimitMiddleware has had its own turn
// to replace c.res with a 429 -- otherwise the log line records the route's
// pre-throttle status (e.g. a plain 200/404) instead of what the client
// actually received.
app.use("*", async (c, next) => {
  await next();
  const cache = c.res.headers.get("x-relay-cache") === "HIT" ? "HIT" : "MISS";
  logRequest(new URL(c.req.url).pathname, c.res.status, cache);
});

app.use("*", rateLimitMiddleware());

app.get("/health", (c) =>
  c.json({
    status: "ok",
    service: "metadata-relay",
    version: c.env.RELAY_VERSION ?? "0.0.0",
    // subdlApiKey treats a blank/whitespace-only key as absent, same as the
    // search route does, so this can't report "configured" for a value that
    // would 503 on the first real search.
    subtitles_configured: Boolean(subdlApiKey(c.env)),
  }),
);

// The Elixir /stats reported ETS cache counters that reset on every restart.
// The Worker has no equivalent in-process counter, and Workers Logs plus the
// dashboard hold the real history, so this reports what the edge can answer
// cheaply and keeps the route alive for anything already polling it.
app.get("/stats", (c) =>
  c.json({
    service: "metadata-relay",
    version: c.env.RELAY_VERSION ?? "0.0.0",
    cache: { backend: "cloudflare-cache-api+kv" },
  }),
);

registerTmdbRoutes(app);
registerTvdbRoutes(app);
registerSubdlRoutes(app);
registerPassthroughRoutes(app);
registerPairingRoutes(app);
registerCrashRoutes(app);
// GET/POST /errors and /errors/:fingerprint -- the maintainer dashboard
// replacing error_tracker's LiveView UI. Unauthenticated until Task 15 puts
// Cloudflare Access in front of it; do not deploy this to a public hostname
// before that lands.
registerErrorDashboard(app);
// POST only -- Task 14 adds GET /feedback (the maintainer dashboard) as a
// separate route registration, and Hono matches by path AND method, so the
// two coexist without either swallowing the other.
registerFeedbackRoutes(app);

// 404 catch-all, matching the Elixir router's behaviour.
app.all("*", (c) => c.json({ error: "Not found" }, 404));

export default {
  fetch: app.fetch,
  // Cron Trigger (wrangler.jsonc's triggers.crons), never the request path.
  // Sweeps two tables that grow without an eviction path otherwise:
  // feedback_rate_limits (src/obs/sweep.ts's justification for why this is
  // required, not optional, for that table specifically) and
  // pairing_claims via pairing/store.ts's purgeExpiredClaims.
  async scheduled(_controller: ScheduledController, env: Env, _ctx: ExecutionContext): Promise<void> {
    await runScheduledSweep(env);
  },
} satisfies ExportedHandler<Env>;
