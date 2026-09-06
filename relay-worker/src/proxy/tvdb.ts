import type { Hono } from "hono";
import type { Env } from "../env";
import { buildKey } from "../cache/key";
import { forwardParams, proxyJson } from "./forward";
import { getTvdbToken } from "./tvdb-auth";

const TVDB_BASE = "https://api4.thetvdb.com/v4";

type UpstreamPath = (
  params: Record<string, string>,
  query: URLSearchParams,
) => string;

interface TvdbRoute {
  path: string;
  toUpstream: UpstreamPath;
  // handler.ex's plain lookups (get_series/2, get_season/2, get_episode/2,
  // get_artwork/2, get_series_episodes/2) declare `_params \\ []` (or, for
  // episodes, consume `page` into the path) and call Client.get(path) with no
  // :params option, so nothing forwards upstream. Only search and the
  // *_extended handlers pass `params: params` through to Client.get.
  forwardQuery: boolean;
}

// Source of truth: metadata-relay/lib/metadata_relay/tvdb/handler.ex.
const ROUTES: TvdbRoute[] = [
  { path: "/tvdb/search", toUpstream: () => "/search", forwardQuery: true },
  {
    path: "/tvdb/series/:id",
    toUpstream: (p) => `/series/${p.id}`,
    forwardQuery: false,
  },
  {
    path: "/tvdb/series/:id/extended",
    toUpstream: (p) => `/series/${p.id}/extended`,
    forwardQuery: true,
  },
  // get_series_episodes/2 reads `page` (default 0) out of the params map and
  // bakes it into the path as .../episodes/default/page/N — not simply
  // /series/{id}/episodes, and the page number is never also sent as a query
  // parameter.
  {
    path: "/tvdb/series/:id/episodes",
    toUpstream: (p, query) =>
      `/series/${p.id}/episodes/default/page/${query.get("page") ?? "0"}`,
    forwardQuery: false,
  },
  {
    path: "/tvdb/seasons/:id",
    toUpstream: (p) => `/seasons/${p.id}`,
    forwardQuery: false,
  },
  {
    path: "/tvdb/seasons/:id/extended",
    toUpstream: (p) => `/seasons/${p.id}/extended`,
    forwardQuery: true,
  },
  {
    path: "/tvdb/episodes/:id",
    toUpstream: (p) => `/episodes/${p.id}`,
    forwardQuery: false,
  },
  {
    path: "/tvdb/episodes/:id/extended",
    toUpstream: (p) => `/episodes/${p.id}/extended`,
    forwardQuery: true,
  },
  {
    path: "/tvdb/artwork/:id",
    toUpstream: (p) => `/artwork/${p.id}`,
    forwardQuery: false,
  },
];

export function registerTvdbRoutes(app: Hono<{ Bindings: Env }>): void {
  for (const route of ROUTES) {
    app.get(route.path, async (c) => {
      if (!c.env.TVDB_API_KEY) {
        return c.json({ error: "TVDB not configured" }, 503);
      }

      let token: string;
      try {
        token = await getTvdbToken(c.env);
      } catch {
        return c.json({ error: "TVDB authentication failed" }, 502);
      }

      const url = new URL(c.req.url);
      const cacheKey = buildKey(
        "GET",
        url.pathname,
        url.searchParams.toString(),
      );
      const upstreamPath = route.toUpstream(c.req.param(), url.searchParams);
      const query = route.forwardQuery
        ? forwardParams(url.searchParams, {}).toString()
        : "";
      const upstream = `${TVDB_BASE}${upstreamPath}${query ? `?${query}` : ""}`;

      return proxyJson(c.env, upstream, cacheKey, {
        headers: { authorization: `Bearer ${token}` },
      });
    });
  }
}
