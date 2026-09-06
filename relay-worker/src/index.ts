import { Hono } from "hono";
import type { Env } from "./env";
import { registerTmdbRoutes } from "./proxy/tmdb";

export const app = new Hono<{ Bindings: Env }>();

app.get("/health", (c) =>
  c.json({
    status: "ok",
    service: "metadata-relay",
    version: c.env.RELAY_VERSION ?? "0.0.0",
    subtitles_configured: Boolean(c.env.SUBDL_API_KEY),
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

// 404 catch-all, matching the Elixir router's behaviour.
app.all("*", (c) => c.json({ error: "Not found" }, 404));

export default app;
