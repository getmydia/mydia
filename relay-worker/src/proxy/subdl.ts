import type { Hono } from "hono";
import type { Env } from "../env";
import {
  bodyFingerprint,
  subtitleSearchCacheKey,
  EMPTY_SUBTITLE_TTL_SECONDS,
} from "../cache/key";
import { cacheGet, cachePut } from "../cache/store";
import { encodeFileId, decodeFileId, extractSubtitle } from "../archive/zip";

const SEARCH_URL = "https://api.subdl.com/api/v1/subtitles";
const DOWNLOAD_HOST = "https://dl.subdl.com";
const SUBS_PER_PAGE = "30";

// -- Search query construction ------------------------------------------
//
// Ported from build_query/1, identity/1, type_params/1 and languages/1 in
// metadata-relay/lib/metadata_relay/subdl/handler.ex. The relay's JSON body
// keys (query, imdb_id, tmdb_id, media_type, season_number, episode_number,
// languages) are NOT the same names SubDL's own query string wants
// (film_name, imdb_id-with-"tt"-prefix, tmdb_id, type, season_number,
// episode_number, upper-cased comma-joined languages) -- this section is the
// translation between the two.

interface SearchBody {
  tmdb_id?: unknown;
  imdb_id?: unknown;
  query?: unknown;
  media_type?: unknown;
  season_number?: unknown;
  episode_number?: unknown;
  languages?: unknown;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function asSearchBody(body: unknown): SearchBody {
  return isPlainObject(body) ? (body as SearchBody) : {};
}

// Elixir's present?/1: not nil and not "". A JSON 0 or false is present.
function present(value: unknown): value is string | number {
  return value !== null && value !== undefined && value !== "";
}

function imdbWithPrefix(id: string | number): string {
  const asString = String(id);
  return asString.startsWith("tt") ? asString : `tt${asString}`;
}

// SubDL accepts one identity per search: tmdb_id is preferred because it is
// unambiguous for both films and series, imdb_id next, and a free-text query
// (sent to SubDL as "film_name") is the last resort. Returns null when none
// of the three are present, matching identity/1 returning nil.
function buildIdentity(body: SearchBody): [string, string] | null {
  if (present(body.tmdb_id)) return ["tmdb_id", String(body.tmdb_id)];
  if (present(body.imdb_id)) return ["imdb_id", imdbWithPrefix(body.imdb_id)];
  if (present(body.query)) return ["film_name", String(body.query)];
  return null;
}

function buildTypeParams(body: SearchBody): Array<[string, string]> {
  if (body.media_type === "episode") {
    const params: Array<[string, string]> = [["type", "tv"]];
    if (present(body.season_number)) {
      params.push(["season_number", String(body.season_number)]);
    }
    if (present(body.episode_number)) {
      params.push(["episode_number", String(body.episode_number)]);
    }
    return params;
  }
  if (body.media_type === "movie") return [["type", "movie"]];
  return [];
}

// SubDL expects uppercase two-letter codes, comma joined. Defaults to "en"
// when absent, matching Map.get(params, "languages", "en").
function buildLanguages(value: unknown): string {
  const raw = Array.isArray(value) ? value.join(",") : String(value ?? "en");
  return raw
    .split(",")
    .map((code) => code.trim())
    .filter((code) => code.length > 0)
    .map((code) => code.toUpperCase())
    .join(",");
}

// -- transform_subtitle/2 port -------------------------------------------

// Shaped like handler.ex's feature map: feature_type, title, year, imdb_id,
// tmdb_id, each nullable. Kept as Record<string, unknown> (rather than a named
// interface) so it composes with transformSubtitle's own Record-typed feature
// parameter without a cast that TS's structural checker flags as unsound.
function emptyFeature(): Record<string, unknown> {
  return {
    feature_type: null,
    title: null,
    year: null,
    imdb_id: null,
    tmdb_id: null,
  };
}

// Ported from feature_context/1 in handler.ex: the first entry of the
// upstream response's "results" array describes the film/show the search
// matched, independent of which subtitle is being transformed. Any shape
// other than a non-empty array whose first element is an object falls back
// to all-null, matching every non-matching clause in the Elixir falling
// through to empty_feature/0.
function featureContext(results: unknown): Record<string, unknown> {
  if (Array.isArray(results) && results.length > 0) {
    const first: unknown = results[0];
    if (first !== null && typeof first === "object" && !Array.isArray(first)) {
      const r = first as Record<string, unknown>;
      return {
        feature_type: r.type ?? null,
        title: r.name ?? null,
        year: r.year ?? null,
        imdb_id: r.imdb_id ?? null,
        tmdb_id: r.tmdb_id ?? null,
      };
    }
  }
  return emptyFeature();
}

// Elixir's `||`: falls through to `fallback` only when `value` is nil or
// false, otherwise returns `value` unchanged (even if it is not the type one
// might expect, e.g. a truthy non-boolean "hi" flag).
function elixirOr(value: unknown, fallback: unknown): unknown {
  return value === null || value === undefined || value === false
    ? fallback
    : value;
}

function normalizeLanguage(value: unknown): string {
  if (value === null || value === undefined) return "en";
  return String(value).slice(0, 2).toLowerCase();
}

// Ported field for field from transform_subtitle/2 in
// metadata-relay/lib/metadata_relay/subdl/handler.ex:175-199, including the
// keys always set to null. Mydia's Provider.Relay consumes "moviehash_match",
// "season", "episode" and the feature_* keys directly (see
// lib/mydia/subtitles/provider/relay.ex), so dropping any of them silently
// breaks a client already relying on their presence.
export function transformSubtitle(
  subtitle: Record<string, unknown>,
  feature: unknown,
): Record<string, unknown> {
  const f: Record<string, unknown> = isPlainObject(feature)
    ? feature
    : emptyFeature();

  return {
    source: "SubDL",
    id: encodeFileId(String(elixirOr(subtitle.url, ""))),
    language: normalizeLanguage(elixirOr(subtitle.language, subtitle.lang)),
    format: "srt",
    rating: null,
    download_count: null,
    release: elixirOr(subtitle.release_name, ""),
    uploader: elixirOr(subtitle.author, ""),
    hearing_impaired: elixirOr(subtitle.hi, false),
    foreign_parts_only: false,
    moviehash_match: false,
    season: subtitle.season ?? null,
    episode: subtitle.episode ?? null,
    feature_type: f.feature_type ?? null,
    title: f.title ?? null,
    year: f.year ?? null,
    imdb_id: f.imdb_id ?? null,
    tmdb_id: f.tmdb_id ?? null,
  };
}

// A rejected key is the relay's problem, not the caller's: reporting 401
// would tell every install its own credentials failed. Anything else keeps
// its upstream status when that status is already a client-facing one.
// Ported from client_status/1 in router.ex.
function clientStatus(status: number): number {
  if (status === 401 || status === 403) return 502;
  if (status >= 400 && status <= 599) return status;
  return 502;
}

function errorJson(message: string, status: number, extraHeaders?: HeadersInit): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "content-type": "application/json", ...extraHeaders },
  });
}

// Ported from Client.api_key/0 in metadata-relay/lib/metadata_relay/subdl/
// client.ex: a blank or whitespace-only key is a common deployment accident
// and is treated as absent, same as an unset one, rather than being sent to
// SubDL and getting back an opaque rejection. Exported standalone (mirroring
// tvdb-auth.ts's getTvdbToken) because Hono's request context can't be
// constructed directly in a test -- this is what a "key absent" test exercises.
export function subdlApiKey(env: Env): string | null {
  const key = env.SUBDL_API_KEY;
  if (key === undefined || key === null) return null;
  return key.trim() === "" ? null : key;
}

export function registerSubdlRoutes(app: Hono<{ Bindings: Env }>): void {
  app.post("/api/v1/subtitles/search", async (c) => {
    const apiKey = subdlApiKey(c.env);
    if (!apiKey) {
      return c.json(
        {
          error: "Service not configured",
          message:
            "SubDL integration is not configured. Please set the SUBDL_API_KEY environment variable.",
        },
        503,
      );
    }

    let rawBody: unknown;
    try {
      rawBody = await c.req.json();
    } catch {
      return c.json({ error: "Invalid JSON body" }, 400);
    }

    const body = asSearchBody(rawBody);
    const identity = buildIdentity(body);
    if (!identity) {
      return c.json({ error: "Insufficient search criteria" }, 400);
    }

    const cacheKey = subtitleSearchCacheKey(await bodyFingerprint(rawBody));
    const hit = await cacheGet(c.env, cacheKey, { kv: true });
    if (hit) return hit;

    const query = new URLSearchParams();
    query.set("api_key", apiKey);
    query.set("languages", buildLanguages(body.languages));
    query.set("subs_per_page", SUBS_PER_PAGE);
    query.set(identity[0], identity[1]);
    for (const [key, value] of buildTypeParams(body)) query.set(key, value);

    const upstream = await fetch(`${SEARCH_URL}?${query.toString()}`);

    if (upstream.status === 429) {
      const retryAfter = upstream.headers.get("retry-after") ?? "60";
      return errorJson("Too many requests", 429, { "retry-after": retryAfter });
    }

    if (!upstream.ok) {
      // api.subdl.com is the one host the relay's shared key is sent to, so
      // its error text is the one place that key could come back echoed.
      // Never forwarded; a fixed message only.
      return errorJson("Subtitle provider error", clientStatus(upstream.status));
    }

    const rawText = await upstream.text();
    let payload: unknown;
    try {
      payload = JSON.parse(rawText);
    } catch {
      // A binary or HTML body (captcha, CDN block) rather than JSON.
      return errorJson("Unexpected upstream response", 502);
    }

    if (!isPlainObject(payload)) {
      return errorJson("Unexpected upstream response", 502);
    }

    let subtitles: unknown[];
    if (Array.isArray(payload.subtitles)) {
      const feature = featureContext(payload.results);
      subtitles = (payload.subtitles as Record<string, unknown>[]).map((s) =>
        transformSubtitle(s, feature),
      );
    } else if (payload.status === false) {
      // A miss, not an anomaly. SubDL answers a miss with status:false plus
      // an error string rather than an empty list.
      subtitles = [];
    } else {
      // Anything else is an upstream anomaly, not a search that found
      // nothing, and the two must not answer alike: caching an anomaly as
      // empty would pin "this title has no subtitles" on every install for
      // the full search TTL, with nothing to invalidate it.
      return errorJson("Unexpected upstream response", 502);
    }

    const result = { subtitles };
    const res = new Response(JSON.stringify(result), {
      status: 200,
      headers: { "content-type": "application/json" },
    });

    // An empty result is a claim about today, and subtitles for a new
    // release land within hours. Holding it for the full search TTL would
    // hide a fresh upload from every install for as long as the entry lives.
    const ttlSeconds =
      subtitles.length === 0 ? EMPTY_SUBTITLE_TTL_SECONDS : undefined;
    await cachePut(c.env, cacheKey, res.clone(), { ttlSeconds, kv: true });

    return res;
  });

  app.get("/api/v1/subtitles/download-url/:id", (c) => {
    const path = decodeFileId(c.req.param("id"));
    if (!path) return c.json({ error: "Invalid subtitle id" }, 400);

    const fileName =
      path
        .split("/")
        .pop()
        ?.replace(/\.zip$/, ".srt") ?? "subtitle.srt";

    // Points back at this relay, not at SubDL: clients expect plain
    // subtitle bytes and do no archive handling of their own.
    return c.json({
      download_url: `${new URL(c.req.url).origin}/api/v1/subtitles/download/${c.req.param("id")}`,
      file_name: fileName,
      // SubDL publishes no quota headers. Reporting null is honest;
      // reporting a number would be invention.
      requests_used: null,
      requests_remaining: null,
    });
  });

  app.get("/api/v1/subtitles/download/:id", async (c) => {
    const path = decodeFileId(c.req.param("id"));
    if (!path) return c.json({ error: "Invalid subtitle id" }, 400);

    const upstream = await fetch(`${DOWNLOAD_HOST}${path}`);

    if (upstream.status === 404) {
      // A subtitle pulled from SubDL after it was indexed. "Gone" is a
      // different answer from "the relay is broken", and only a 404 lets
      // the client tell them apart.
      return c.json(
        {
          error: "Subtitle not found",
          message: "This subtitle is no longer available from the provider.",
        },
        404,
      );
    }

    if (!upstream.ok) {
      // No upstream body is forwarded here, ever. dl.subdl.com is fetched
      // unauthenticated, but its error body is still never this relay's to
      // hand back verbatim.
      return c.json(
        {
          error: "Subtitle unavailable",
          message: "The subtitle could not be retrieved from the provider.",
        },
        502,
      );
    }

    const bytes = new Uint8Array(await upstream.arrayBuffer());
    const subtitle = extractSubtitle(bytes);
    if (!subtitle) {
      return c.json(
        {
          error: "Subtitle unavailable",
          message: "The subtitle could not be retrieved from the provider.",
        },
        502,
      );
    }

    return new Response(subtitle, {
      status: 200,
      headers: {
        "content-type": "application/octet-stream",
        "content-disposition": 'attachment; filename="subtitle.srt"',
      },
    });
  });
}
