import type { Hono } from "hono";
import type { Env } from "../env";
import { buildKey } from "../cache/key";
import { forwardParams, pathSegment, proxyJson } from "./forward";
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
// `page` is the one caller-controlled value here that is NOT a Hono path
// param, and it is spliced into the upstream path rather than sent as a query
// parameter (see the get_series_episodes note below). pathSegment would make
// it safe, but a percent-encoded non-number is still a nonsense TVDB path, so
// this rejects outright instead: anything that is not a run of digits becomes
// the same "0" an absent `page` already produces. That keeps this route
// bug-compatible with handler.ex for every input either side would treat as
// real -- both still answer 400, for the reason recorded in
// test/contract/routes.json -- while removing the traversal.
const PAGE_PATTERN = /^\d+$/;

function pagePathValue(query: URLSearchParams): string {
  const raw = query.get("page");
  return raw !== null && PAGE_PATTERN.test(raw) ? raw : "0";
}

// Every `:id` below goes through pathSegment (see forward.ts for why): Hono
// percent-decodes path params, so interpolating one raw lets the caller
// choose which TVDB endpoint the relay's own bearer token is spent on.
const ROUTES: TvdbRoute[] = [
  { path: "/tvdb/search", toUpstream: () => "/search", forwardQuery: true },
  {
    path: "/tvdb/series/:id",
    toUpstream: (p) => `/series/${pathSegment(p.id)}`,
    forwardQuery: false,
  },
  {
    path: "/tvdb/series/:id/extended",
    toUpstream: (p) => `/series/${pathSegment(p.id)}/extended`,
    forwardQuery: true,
  },
  // get_series_episodes/2 reads `page` (default 0) out of the params map and
  // bakes it into the path as .../episodes/default/page/N — not simply
  // /series/{id}/episodes, and the page number is never also sent as a query
  // parameter.
  {
    path: "/tvdb/series/:id/episodes",
    toUpstream: (p, query) =>
      `/series/${pathSegment(p.id)}/episodes/default/page/${pagePathValue(query)}`,
    forwardQuery: false,
  },
  {
    path: "/tvdb/seasons/:id",
    toUpstream: (p) => `/seasons/${pathSegment(p.id)}`,
    forwardQuery: false,
  },
  {
    path: "/tvdb/seasons/:id/extended",
    toUpstream: (p) => `/seasons/${pathSegment(p.id)}/extended`,
    forwardQuery: true,
  },
  {
    path: "/tvdb/episodes/:id",
    toUpstream: (p) => `/episodes/${pathSegment(p.id)}`,
    forwardQuery: false,
  },
  {
    path: "/tvdb/episodes/:id/extended",
    toUpstream: (p) => `/episodes/${pathSegment(p.id)}/extended`,
    forwardQuery: true,
  },
  {
    path: "/tvdb/artwork/:id",
    toUpstream: (p) => `/artwork/${pathSegment(p.id)}`,
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
