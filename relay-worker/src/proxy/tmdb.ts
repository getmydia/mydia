import type { Hono } from "hono";
import type { Env } from "../env";
import { buildKey } from "../cache/key";
import { forwardParams, proxyJson } from "./forward";

const TMDB_BASE = "https://api.themoviedb.org/3";

// Relay path -> TMDB path. Keys with :id use the Hono param of the same name.
// Source of truth: metadata-relay/lib/metadata_relay/tmdb/handler.ex.
const ROUTES: Array<[string, (p: Record<string, string>) => string]> = [
  ["/configuration", () => "/configuration"],
  ["/tmdb/movies/search", () => "/search/movie"],
  ["/tmdb/tv/search", () => "/search/tv"],
  ["/tmdb/movies/trending", () => "/trending/movie/week"],
  ["/tmdb/movies/popular", () => "/movie/popular"],
  ["/tmdb/movies/upcoming", () => "/movie/upcoming"],
  ["/tmdb/movies/now_playing", () => "/movie/now_playing"],
  ["/tmdb/tv/trending", () => "/trending/tv/week"],
  ["/tmdb/tv/popular", () => "/tv/popular"],
  ["/tmdb/tv/on_the_air", () => "/tv/on_the_air"],
  ["/tmdb/tv/airing_today", () => "/tv/airing_today"],
  ["/tmdb/movies/discover", () => "/discover/movie"],
  ["/tmdb/tv/discover", () => "/discover/tv"],
  ["/tmdb/genre/movie", () => "/genre/movie/list"],
  ["/tmdb/genre/tv", () => "/genre/tv/list"],
  ["/tmdb/list/:id", (p) => `/list/${p.id}`],
  ["/tmdb/collections/:id", (p) => `/collection/${p.id}`],
  ["/tmdb/movies/:id", (p) => `/movie/${p.id}`],
  ["/tmdb/tv/shows/:id", (p) => `/tv/${p.id}`],
  ["/tmdb/movies/:id/images", (p) => `/movie/${p.id}/images`],
  ["/tmdb/tv/shows/:id/images", (p) => `/tv/${p.id}/images`],
  ["/tmdb/tv/shows/:id/:season", (p) => `/tv/${p.id}/season/${p.season}`],
];

export function registerTmdbRoutes(app: Hono<{ Bindings: Env }>): void {
  for (const [relayPath, toUpstream] of ROUTES) {
    app.get(relayPath, async (c) => {
      const apiKey = c.env.TMDB_API_KEY;
      if (!apiKey) return c.json({ error: "TMDB not configured" }, 503);

      const url = new URL(c.req.url);
      const params = forwardParams(url.searchParams, { api_key: apiKey });

      // The cache key uses the caller-facing path and the caller's query
      // string, never the injected key, so the key never lands in KV.
      const callerQuery = new URLSearchParams(url.searchParams);
      callerQuery.delete("api_key");
      const cacheKey = buildKey("GET", url.pathname, callerQuery.toString());

      const upstream = `${TMDB_BASE}${toUpstream(c.req.param())}?${params}`;
      return proxyJson(c.env, upstream, cacheKey);
    });
  }
}
