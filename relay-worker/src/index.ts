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
import { registerFeedbackDashboard } from "./dashboards/feedback";
import { adminHostnameBlocked } from "./dashboards/hostname-guard";
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

// Cloudflare Access is the real gate on /admin/*, and it is configured per
// hostname. Access CAN cover a workers.dev hostname: Cloudflare documents
// hostname-based applications on `<worker>.<subdomain>.workers.dev`
// explicitly, and shipped one-click Access for workers.dev in October 2025.
// An earlier revision of this comment claimed the opposite and used it to
// justify a blanket deny; that claim was wrong.
//
// What no per-hostname application covers is the versioned PREVIEW URLs
// Cloudflare mints alongside every deploy, each on a hostname nobody named in
// advance. That is this middleware's real and continuing justification.
//
// So: an allowlist of exactly one hostname, ADMIN_ACCESS_HOSTNAME, set on
// env.staging only (wrangler.jsonc). The dashboards are reachable on
// `mydia-relay-staging.<subdomain>.workers.dev`, where a staging Access
// application gates them, and nowhere else under workers.dev -- not on
// preview URLs, and not on production's `mydia-relay.<subdomain>.workers.dev`,
// whose dashboards wait for the relay.mydia.dev Access application at
// cutover. It fails closed when the var is absent or blank; see
// src/dashboards/hostname-guard.ts for why that needs no branch.
//
// Every other hostname -- the eventual production custom domain, local dev,
// Miniflare in tests -- is unaffected, and none of test/contract/routes.json's
// routes are under /admin, so the staging contract diff still exercises
// everything it did before.
//
// This is not authentication and must never grow into it: it removes
// UNPROTECTED hostnames from reach, it does not decide who may look. Access
// still decides that, and the README's "the Worker holds no dashboard
// credentials, and none should ever be added" rule stands unchanged.
//
// Registered before the dashboards it guards, since app.use() only wraps
// routes registered after it (same composition rule as the two middlewares
// above).
app.use("/admin/*", async (c, next) => {
  const hostname = new URL(c.req.url).hostname;
  if (adminHostnameBlocked(hostname, c.env.ADMIN_ACCESS_HOSTNAME)) {
    return c.json({ error: "Not found" }, 404);
  }
  await next();
});

registerTmdbRoutes(app);
registerTvdbRoutes(app);
registerSubdlRoutes(app);
registerPassthroughRoutes(app);
registerPairingRoutes(app);
registerCrashRoutes(app);
// GET/POST /admin/errors and /admin/errors/:fingerprint -- the maintainer
// dashboard replacing error_tracker's LiveView UI. Deliberately under
// /admin/* (not the bare /errors a naive port would use) so one Cloudflare
// Access application scoped to /admin* covers this AND the feedback
// dashboard below with no per-route decision -- see
// relay-worker/README.md's runbook for why that matters: Access, like a
// Worker route, matches on path only, with no HTTP-method dimension, so a
// dashboard sharing a path with a public endpoint could never be gated
// without also gating the public one. Creating that Access application is
// still a manual step; until it exists, this route has no auth at all on any
// hostname Access does not cover -- which is why the workers.dev deny above
// exists, and why it is not a substitute for doing Step 1.
registerErrorDashboard(app);
// POST /feedback is the public ingest endpoint every mydia install calls --
// a wire contract that must never move. registerFeedbackDashboard below
// registers the maintainer dashboard's GET at the entirely separate
// /admin/feedback path, not at /feedback, precisely so the two can be
// governed independently: Access can cover /admin/feedback without ever
// seeing a POST /feedback request, since Access (like Hono's router) has no
// way to gate one HTTP method on a path while leaving another method on
// that same path alone.
registerFeedbackRoutes(app);
// GET /admin/feedback plus the state/github mutation routes. See the
// registerErrorDashboard comment above: /admin/* is deliberate, and
// deploying this to a public hostname before the /admin* Access application
// exists (runbook, relay-worker/README.md) would expose maintainer data.
registerFeedbackDashboard(app);

// 404 catch-all. Deliberately NOT a match for the Elixir router's own
// behaviour here: router.ex's fallback returns a plain-text 404 body, this
// returns JSON -- a considered divergence, not an oversight, kept because
// every other error path in this Worker (validation failures, rate limits,
// crash/feedback ingest) already answers JSON, and a mixed-format 404 would
// be the odd one out for no benefit. Do not "fix" this to match the Elixir;
// that would be introducing a regression, not correcting one.
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
