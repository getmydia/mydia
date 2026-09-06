import { Hono } from "hono";
import type { Env } from "./env";
import { registerTmdbRoutes } from "./proxy/tmdb";
import { registerTvdbRoutes } from "./proxy/tvdb";
import { registerSubdlRoutes, subdlApiKey } from "./proxy/subdl";
import { registerPassthroughRoutes } from "./proxy/passthrough";
import { rateLimitMiddleware } from "./obs/ratelimit";
import { logRequest } from "./obs/log";

export const app = new Hono<{ Bindings: Env }>();

// Registered before every route (including /health and /stats below) so the
// EXEMPT set inside rateLimitMiddleware is what actually protects those
// routes, not an accident of Hono's registration-order middleware
// composition -- app.use() only wraps routes registered after it, so a
// health-check route defined ahead of this would otherwise never reach
// either middleware at all.
app.use("*", rateLimitMiddleware());

app.use("*", async (c, next) => {
  await next();
  const cache = c.res.headers.get("x-relay-cache") === "HIT" ? "HIT" : "MISS";
  logRequest(new URL(c.req.url).pathname, c.res.status, cache);
});

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

// 404 catch-all, matching the Elixir router's behaviour.
app.all("*", (c) => c.json({ error: "Not found" }, 404));

export default app;
