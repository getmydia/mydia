// TTLs in seconds. Copied from metadata-relay/lib/metadata_relay/cache.ex:32-37.
const IMAGES_TTL = 7776000; // 90 days
const TRENDING_TTL = 3600; // 1 hour
const SEARCH_TTL = 604800; // 7 days
const DETAILS_TTL = 2592000; // 30 days
const SEASON_TTL = 1209600; // 14 days
const METADATA_TTL = 2592000; // 30 days

export const SUBTITLE_WIRE_FORMAT_VERSION = 1;
export const EMPTY_SUBTITLE_TTL_SECONDS = 3600;

const CACHEABLE_POST_PATH = "/api/v1/subtitles/search";

const DETAILS_PATTERN = /\/(movies|tv\/shows)\/\d+:(?!search)/;
const MUSIC_DETAILS_PATTERN = /\/music\/(artist|release|release-group|recording)\//;
const SEASON_PATTERN = /\/\d+\/\d+:/;

export function buildKey(
  method: string,
  path: string,
  queryString: string,
): string {
  return `${method}:${path}:${queryString}`;
}

// Order mirrors the `cond` in cache.ex exactly. Reordering changes which TTL
// a path gets: /tv/shows/1399/images matches both the images and details
// rules, and images must win.
export function ttlSecondsFor(key: string): number {
  if (key.includes("/images") || key.includes("/music/cover/")) return IMAGES_TTL;
  if (key.includes("/trending")) return TRENDING_TTL;
  if (key.includes("/search")) return SEARCH_TTL;
  if (DETAILS_PATTERN.test(key)) return DETAILS_TTL;
  if (MUSIC_DETAILS_PATTERN.test(key)) return DETAILS_TTL;
  if (key.includes("/tv/shows/") && SEASON_PATTERN.test(key)) return SEASON_TTL;
  return METADATA_TTL;
}

// Mirrors canonicalize/1 in plug/cache.ex: object keys stringified and sorted
// so two installs asking the same question share an entry even when their JSON
// serializers differ, list order preserved because it is meaningful in JSON.
export function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value !== null && typeof value === "object") {
    return Object.entries(value as Record<string, unknown>)
      .map(([k, v]) => [String(k), canonicalize(v)] as const)
      .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  }
  return value;
}

export async function bodyFingerprint(body: unknown): Promise<string> {
  const canonical = JSON.stringify(canonicalize(body));
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(canonical),
  );
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export function subtitleSearchCacheKey(
  fingerprint: string,
  version: number = SUBTITLE_WIRE_FORMAT_VERSION,
): string {
  return buildKey("POST", CACHEABLE_POST_PATH, `v${version}:${fingerprint}`);
}

// Episode data still being filled in. Mirrors
// metadata-relay/lib/metadata_relay/cache/settling.ex; change both together.
// TVDB publishes an upcoming episode as "TBA" and TMDB as "Episode 8", and a
// 14 or 30 day TTL pinned that placeholder for every install behind the relay.
const SETTLING_TTL = 21600; // 6 hours
const SETTLING_LOOKBACK_DAYS = 14;
// Mydia's EpisodePlaceholder.title?/1. The optional group also matches blank.
const PLACEHOLDER_NAME = /^(tba|tbd|tbc|episode\s*#?\d+)?$/;
const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;
const TVDB_SEASON_KEY = /^GET:\/tvdb\/seasons\/\d+\/extended:/;
const TVDB_EPISODE_KEY = /^GET:\/tvdb\/episodes\/\d+\/extended:/;
const TMDB_SEASON_KEY = /^GET:\/tmdb\/tv\/shows\/\d+\/\d+:/;

type EpisodeFields = { airDate: unknown; name: unknown };

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function pickEpisodes(list: unknown, dateField: string): EpisodeFields[] {
  if (!Array.isArray(list)) return [];
  return list
    .filter(isRecord)
    .map((episode) => ({ airDate: episode[dateField], name: episode.name }));
}

// Each shape reduces to air date and name. An unexpected shape yields no
// episodes, which keeps the path TTL.
function episodesOf(key: string, decoded: unknown): EpisodeFields[] {
  if (!isRecord(decoded)) return [];
  const data = decoded.data;

  if (TVDB_SEASON_KEY.test(key)) {
    return isRecord(data) ? pickEpisodes(data.episodes, "aired") : [];
  }
  if (TVDB_EPISODE_KEY.test(key)) {
    return isRecord(data) ? [{ airDate: data.aired, name: data.name }] : [];
  }
  if (TMDB_SEASON_KEY.test(key)) {
    return pickEpisodes(decoded.episodes, "air_date");
  }
  return [];
}

function isPlaceholderName(name: unknown): boolean {
  if (name === null || name === undefined) return true;
  if (typeof name !== "string") return false;
  return PLACEHOLDER_NAME.test(name.trim().toLowerCase());
}

// The settling TTL in seconds for a cache key and its response body, or null
// when the path-based TTL should stand.
export function settlingTtlSeconds(
  key: string,
  body: string,
  today: Date = new Date(),
): number | null {
  if (
    !TVDB_SEASON_KEY.test(key) &&
    !TVDB_EPISODE_KEY.test(key) &&
    !TMDB_SEASON_KEY.test(key)
  ) {
    return null;
  }

  let decoded: unknown;
  try {
    decoded = JSON.parse(body);
  } catch {
    return null;
  }

  const cutoff = new Date(
    Date.UTC(
      today.getUTCFullYear(),
      today.getUTCMonth(),
      today.getUTCDate() - SETTLING_LOOKBACK_DAYS,
    ),
  )
    .toISOString()
    .slice(0, 10);

  // A placeholder name counts as settling only when the episode has no air
  // date. An episode that aired more than SETTLING_LOOKBACK_DAYS ago and
  // still reads "TBA" or "Episode 8" is almost always named that way
  // permanently (daily and long-running shows on TMDB carry thousands of
  // numbered names), and Mydia's airing refresh stops asking about it 14 days
  // after air anyway.
  const settling = episodesOf(key, decoded).some(({ airDate, name }) =>
    typeof airDate === "string" && ISO_DATE.test(airDate)
      ? airDate >= cutoff
      : isPlaceholderName(name),
  );

  return settling ? SETTLING_TTL : null;
}

// The TTL for a response: settling episode data first, the path rule otherwise.
export function ttlSecondsForResponse(
  key: string,
  body: string,
  today: Date = new Date(),
): number {
  return settlingTtlSeconds(key, body, today) ?? ttlSecondsFor(key);
}
