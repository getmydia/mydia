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
