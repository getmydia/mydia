import type { Hono } from "hono";
import type { Env } from "../env";
import { buildKey, ttlSecondsFor } from "../cache/key";
import { cacheUrl } from "../cache/store";
import { proxyJson } from "./forward";

// Source of truth: metadata-relay/lib/metadata_relay/music/client.ex and
// metadata-relay/lib/metadata_relay/open_library/client.ex. Music and Books
// are deprecated product areas -- installs in the field still call these,
// there is no origin left to send them to once the Elixir relay retires, and
// they need no credentials, so this is a faithful port, not a redesign.

const MUSICBRAINZ_BASE = "https://musicbrainz.org/ws/2";
const COVERART_BASE = "https://coverartarchive.org";
const OPENLIBRARY_BASE = "https://openlibrary.org";

// Exact value from music/client.ex:9. MusicBrainz rejects requests with no
// User-Agent and keys its rate limiting on the string, so this is copied
// verbatim (including the internal spacing) rather than reworded.
const MUSICBRAINZ_USER_AGENT =
  "MetadataRelay/1.0 ( https://github.com/mydia-org/mydia )";

// Exact value from open_library/client.ex:17. Deliberately a different
// string from MusicBrainz's -- the two Elixir clients never shared one.
const OPENLIBRARY_USER_AGENT =
  "MetadataRelay/1.0 (https://github.com/my-org/metadata-relay)";

// get_mb/2 in music/client.ex sends both of these on every MusicBrainz call.
const MUSICBRAINZ_HEADERS = {
  "user-agent": MUSICBRAINZ_USER_AGENT,
  accept: "application/json",
};

// get_caa/1 in music/client.ex sends only a User-Agent -- no accept header,
// unlike the MusicBrainz JSON client above.
const COVERART_HEADERS = { "user-agent": MUSICBRAINZ_USER_AGENT };

// Client.new/0 in open_library/client.ex sends both of these on every call.
const OPENLIBRARY_HEADERS = {
  "user-agent": OPENLIBRARY_USER_AGENT,
  accept: "application/json",
};

function cacheKeyFor(url: URL): string {
  return buildKey("GET", url.pathname, url.searchParams.toString());
}

// -- MusicBrainz ----------------------------------------------------------

// music/handler.ex's search/1 requires both params and picks the upstream
// resource straight from the caller's `type` (Client.get_mb("/#{type}",
// ...)) -- there is no fixed search endpoint, and no whitelist of `type`
// values on the Elixir side either.
function registerMusicSearch(app: Hono<{ Bindings: Env }>): void {
  app.get("/music/search", async (c) => {
    const url = new URL(c.req.url);
    // is_nil/1 in the Elixir, not a truthiness check: an explicit empty
    // string is "present" there and must be here too.
    const query = url.searchParams.get("query");
    const type = url.searchParams.get("type");
    if (query === null || type === null) {
      return c.json(
        { error: "Missing required parameters: query, type" },
        400,
      );
    }

    const cacheKey = cacheKeyFor(url);
    const upstreamQuery = new URLSearchParams({ query, fmt: "json" });
    const upstream = `${MUSICBRAINZ_BASE}/${encodeURIComponent(type)}?${upstreamQuery.toString()}`;

    return proxyJson(c.env, upstream, cacheKey, {
      headers: MUSICBRAINZ_HEADERS,
    });
  });
}

interface MbDetailRoute {
  path: string;
  resource: string;
  // The exact `inc=` comment value from the matching handler.ex function.
  inc: string;
}

// get_artist/2, get_release/2, get_release_group/2 and get_recording/2 in
// music/handler.ex all declare `_params` -- the caller's query string is
// never forwarded -- and each injects its own fixed `inc=` value instead.
const MB_DETAIL_ROUTES: MbDetailRoute[] = [
  {
    path: "/music/artist/:id",
    resource: "artist",
    inc: "url-rels+genres+release-groups",
  },
  {
    path: "/music/release/:id",
    resource: "release",
    inc: "recordings+artist-credits+labels+release-groups+genres",
  },
  {
    path: "/music/release-group/:id",
    resource: "release-group",
    inc: "releases+artist-credits+genres",
  },
  {
    path: "/music/recording/:id",
    resource: "recording",
    inc: "releases+artist-credits+genres",
  },
];

function registerMbDetailRoutes(app: Hono<{ Bindings: Env }>): void {
  for (const route of MB_DETAIL_ROUTES) {
    app.get(route.path, async (c) => {
      const params: Record<string, string> = c.req.param();
      const id = params.id;
      const url = new URL(c.req.url);
      const cacheKey = cacheKeyFor(url);
      const upstreamQuery = new URLSearchParams({
        fmt: "json",
        inc: route.inc,
      });
      const upstream = `${MUSICBRAINZ_BASE}/${route.resource}/${encodeURIComponent(id)}?${upstreamQuery.toString()}`;

      return proxyJson(c.env, upstream, cacheKey, {
        headers: MUSICBRAINZ_HEADERS,
      });
    });
  }
}

// -- Cover Art Archive ------------------------------------------------------
//
// get_cover_art/1 in music/handler.ex tries the 500px cover first and falls
// back to the full-size cover only on a 404 from the 500px request; any
// other error short-circuits without a second request. router.ex's
// handle_image_request/2 then answers with a fixed "image/jpeg" content
// type regardless of what the upstream actually sent.
//
// This can't reuse proxyJson/cachePut: both read the upstream body with
// `.text()`, which corrupts binary image bytes that aren't valid UTF-8 on
// the way back out. This route reads and caches raw bytes instead.

async function fetchCoverArt(id: string): Promise<Response> {
  const primary = await fetch(
    `${COVERART_BASE}/release/${encodeURIComponent(id)}/front-500`,
    { headers: COVERART_HEADERS },
  );
  if (primary.status !== 404) return primary;

  return fetch(`${COVERART_BASE}/release/${encodeURIComponent(id)}/front`, {
    headers: COVERART_HEADERS,
  });
}

function registerCoverArt(app: Hono<{ Bindings: Env }>): void {
  app.get("/music/cover/:id", async (c) => {
    const id = c.req.param("id");
    const url = new URL(c.req.url);
    const cacheKey = cacheKeyFor(url);

    const cached = await caches.default.match(cacheUrl(cacheKey));
    if (cached) {
      const res = new Response(cached.body, cached);
      res.headers.set("x-relay-cache", "HIT");
      return res;
    }

    let upstream: Response;
    try {
      upstream = await fetchCoverArt(id);
    } catch (err) {
      // Mirrors router.ex's `{:error, reason} -> send_resp(conn, 500, inspect(reason))`.
      return new Response(err instanceof Error ? err.message : String(err), {
        status: 500,
      });
    }

    if (upstream.status === 404) {
      return new Response("Not found", { status: 404 });
    }
    if (upstream.status < 200 || upstream.status >= 300) {
      return new Response("Upstream error", { status: upstream.status });
    }

    const bytes = await upstream.arrayBuffer();
    const ttl = ttlSecondsFor(cacheKey);
    const res = new Response(bytes, {
      status: 200,
      headers: {
        "content-type": "image/jpeg",
        "cache-control": `public, s-maxage=${ttl}, stale-while-revalidate=86400, stale-if-error=604800`,
      },
    });

    await caches.default.put(cacheUrl(cacheKey), res.clone());
    res.headers.set("x-relay-cache", "MISS");
    return res;
  });
}

// -- OpenLibrary ------------------------------------------------------------

// get_by_isbn/2 in open_library/handler.ex does not hit an /isbn/*.json
// path (Open Library has no such endpoint) -- it calls the Books API at
// /api/books with bibkeys=ISBN:<isbn>, jscmd=data and format=json. The
// caller's own query string (`_params`) is ignored.
function registerOpenLibraryIsbn(app: Hono<{ Bindings: Env }>): void {
  app.get("/openlibrary/isbn/:isbn", async (c) => {
    const isbn = c.req.param("isbn");
    const url = new URL(c.req.url);
    const cacheKey = cacheKeyFor(url);
    const upstreamQuery = new URLSearchParams({
      bibkeys: `ISBN:${isbn}`,
      jscmd: "data",
      format: "json",
    });
    const upstream = `${OPENLIBRARY_BASE}/api/books?${upstreamQuery.toString()}`;

    return proxyJson(c.env, upstream, cacheKey, {
      headers: OPENLIBRARY_HEADERS,
    });
  });
}

// search/1 in open_library/handler.ex forwards the caller's params
// untouched: `Client.get("/search.json", params: params)`.
function registerOpenLibrarySearch(app: Hono<{ Bindings: Env }>): void {
  app.get("/openlibrary/search", async (c) => {
    const url = new URL(c.req.url);
    const cacheKey = cacheKeyFor(url);
    const upstream = `${OPENLIBRARY_BASE}/search.json?${url.searchParams.toString()}`;

    return proxyJson(c.env, upstream, cacheKey, {
      headers: OPENLIBRARY_HEADERS,
    });
  });
}

// get_work/2 and get_author/2 in open_library/handler.ex both declare
// `_params` and call Client.get/1 with no :params option -- the caller's
// query string is never forwarded.
function registerOpenLibraryWorks(app: Hono<{ Bindings: Env }>): void {
  app.get("/openlibrary/works/:id", async (c) => {
    const id = c.req.param("id");
    const url = new URL(c.req.url);
    const cacheKey = cacheKeyFor(url);
    const upstream = `${OPENLIBRARY_BASE}/works/${encodeURIComponent(id)}.json`;

    return proxyJson(c.env, upstream, cacheKey, {
      headers: OPENLIBRARY_HEADERS,
    });
  });
}

function registerOpenLibraryAuthors(app: Hono<{ Bindings: Env }>): void {
  app.get("/openlibrary/authors/:id", async (c) => {
    const id = c.req.param("id");
    const url = new URL(c.req.url);
    const cacheKey = cacheKeyFor(url);
    const upstream = `${OPENLIBRARY_BASE}/authors/${encodeURIComponent(id)}.json`;

    return proxyJson(c.env, upstream, cacheKey, {
      headers: OPENLIBRARY_HEADERS,
    });
  });
}

export function registerPassthroughRoutes(app: Hono<{ Bindings: Env }>): void {
  registerMusicSearch(app);
  registerMbDetailRoutes(app);
  registerCoverArt(app);
  registerOpenLibraryIsbn(app);
  registerOpenLibrarySearch(app);
  registerOpenLibraryWorks(app);
  registerOpenLibraryAuthors(app);
}
