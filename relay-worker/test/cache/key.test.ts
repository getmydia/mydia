import { describe, it, expect } from "vitest";
import {
  buildKey,
  ttlSecondsFor,
  settlingTtlSeconds,
  ttlSecondsForResponse,
  canonicalize,
  bodyFingerprint,
  subtitleSearchCacheKey,
} from "../../src/cache/key";

describe("buildKey", () => {
  it("matches the Elixir format method:path:query", () => {
    expect(buildKey("GET", "/tmdb/movies/550", "language=en")).toBe(
      "GET:/tmdb/movies/550:language=en",
    );
  });

  it("keeps an empty query string as an empty segment", () => {
    expect(buildKey("GET", "/configuration", "")).toBe("GET:/configuration:");
  });
});

describe("ttlSecondsFor", () => {
  it("gives images 90 days", () => {
    expect(ttlSecondsFor("GET:/tmdb/movies/550/images:")).toBe(7776000);
  });

  it("gives music cover art 90 days", () => {
    expect(ttlSecondsFor("GET:/music/cover/abc:")).toBe(7776000);
  });

  it("gives trending 1 hour", () => {
    expect(ttlSecondsFor("GET:/tmdb/movies/trending:")).toBe(3600);
  });

  it("gives search 7 days", () => {
    expect(ttlSecondsFor("GET:/tmdb/movies/search:query=x")).toBe(604800);
  });

  it("gives movie details 30 days", () => {
    expect(ttlSecondsFor("GET:/tmdb/movies/550:")).toBe(2592000);
  });

  it("gives tv show details 30 days", () => {
    expect(ttlSecondsFor("GET:/tmdb/tv/shows/1399:")).toBe(2592000);
  });

  it("gives music details 30 days", () => {
    expect(ttlSecondsFor("GET:/music/artist/abc:")).toBe(2592000);
  });

  it("gives season data 14 days", () => {
    expect(ttlSecondsFor("GET:/tmdb/tv/shows/1399/2:")).toBe(1209600);
  });

  it("defaults to 30 days", () => {
    expect(ttlSecondsFor("GET:/tvdb/series/331753/extended:")).toBe(2592000);
  });

  it("prefers images over details when both could match", () => {
    // Elixir's cond checks images first, so a details path ending in
    // /images must not fall through to details_ttl.
    expect(ttlSecondsFor("GET:/tmdb/tv/shows/1399/images:")).toBe(7776000);
  });

  it("prefers trending over search for a trending path", () => {
    expect(ttlSecondsFor("GET:/tmdb/tv/trending:")).toBe(3600);
  });
});

describe("canonicalize", () => {
  it("sorts object keys so serializer order does not split the cache", () => {
    expect(canonicalize({ b: 1, a: 2 })).toEqual([
      ["a", 2],
      ["b", 1],
    ]);
  });

  it("preserves list order because JSON list order is meaningful", () => {
    expect(canonicalize([3, 1, 2])).toEqual([3, 1, 2]);
  });

  it("recurses into nested structures", () => {
    expect(canonicalize({ z: { y: 1, x: 2 } })).toEqual([
      ["z", [["x", 2], ["y", 1]]],
    ]);
  });
});

describe("bodyFingerprint", () => {
  it("gives the same digest regardless of key order", async () => {
    const a = await bodyFingerprint({ film_name: "x", languages: ["en"] });
    const b = await bodyFingerprint({ languages: ["en"], film_name: "x" });
    expect(a).toBe(b);
  });

  it("gives a different digest for different list order", async () => {
    const a = await bodyFingerprint({ languages: ["en", "fr"] });
    const b = await bodyFingerprint({ languages: ["fr", "en"] });
    expect(a).not.toBe(b);
  });

  it("returns lowercase hex", async () => {
    const digest = await bodyFingerprint({ a: 1 });
    expect(digest).toMatch(/^[0-9a-f]{64}$/);
  });
});

describe("subtitleSearchCacheKey", () => {
  it("folds the wire format version into the key", () => {
    expect(subtitleSearchCacheKey("abc")).toBe(
      "POST:/api/v1/subtitles/search:v1:abc",
    );
  });

  it("changes when the version changes, so a shape change self-invalidates", () => {
    expect(subtitleSearchCacheKey("abc", 2)).not.toBe(
      subtitleSearchCacheKey("abc", 1),
    );
  });
});

// Mirrors metadata-relay/test/metadata_relay/cache/settling_test.exs case for case.
describe("settlingTtlSeconds", () => {
  const today = new Date("2026-09-14T12:00:00Z");
  const tvdbSeasonKey = "GET:/tvdb/seasons/2247557/extended:meta=translations";
  const tvdbEpisodeKey = "GET:/tvdb/episodes/11767188/extended:meta=translations";
  const tmdbSeasonKey = "GET:/tmdb/tv/shows/97546/4:";
  const tvdbSeason = (episodes: unknown[]) =>
    JSON.stringify({ data: { id: 1, episodes } });

  it("gives a TVDB season with an upcoming placeholder episode 6 hours", () => {
    const body = tvdbSeason([{ aired: "2026-09-23", name: "TBA " }]);
    expect(settlingTtlSeconds(tvdbSeasonKey, body, today)).toBe(21600);
  });

  it("still counts an episode aired 14 days ago", () => {
    const body = tvdbSeason([{ aired: "2026-08-31", name: "Harbor Lights" }]);
    expect(settlingTtlSeconds(tvdbSeasonKey, body, today)).toBe(21600);
  });

  it("returns null once every episode aired more than 14 days ago", () => {
    const body = tvdbSeason([{ aired: "2026-08-30", name: "Harbor Lights" }]);
    expect(settlingTtlSeconds(tvdbSeasonKey, body, today)).toBeNull();
  });

  it("treats an undated placeholder episode as settling", () => {
    const body = tvdbSeason([{ aired: null, name: "TBA" }]);
    expect(settlingTtlSeconds(tvdbSeasonKey, body, today)).toBe(21600);
  });

  it("does not treat an undated special with a real name as settling", () => {
    const body = tvdbSeason([{ aired: null, name: "Behind the Lighthouse" }]);
    expect(settlingTtlSeconds(tvdbSeasonKey, body, today)).toBeNull();
  });

  it("applies to a single TVDB episode", () => {
    const upcoming = JSON.stringify({ data: { aired: "2026-09-23", name: "TBA " } });
    const old = JSON.stringify({ data: { aired: "2019-03-01", name: "Quiet Tide" } });
    expect(settlingTtlSeconds(tvdbEpisodeKey, upcoming, today)).toBe(21600);
    expect(settlingTtlSeconds(tvdbEpisodeKey, old, today)).toBeNull();
  });

  it("applies to a TMDB season", () => {
    const upcoming = JSON.stringify({
      episodes: [{ air_date: "2026-09-22", name: "Episode 8" }],
    });
    const finished = JSON.stringify({
      episodes: [{ air_date: "2019-03-01", name: "Quiet Tide" }],
    });
    expect(settlingTtlSeconds(tmdbSeasonKey, upcoming, today)).toBe(21600);
    expect(settlingTtlSeconds(tmdbSeasonKey, finished, today)).toBeNull();
  });

  it("ignores other paths even with an upcoming episode in the body", () => {
    const body = tvdbSeason([{ aired: "2026-09-23", name: "TBA" }]);
    expect(settlingTtlSeconds("GET:/tvdb/series/1/extended:", body, today)).toBeNull();
    expect(settlingTtlSeconds("GET:/tmdb/tv/shows/97546:", body, today)).toBeNull();
    expect(settlingTtlSeconds("GET:/tmdb/tv/shows/97546/images:", body, today)).toBeNull();
  });

  it("ignores an undecodable or unexpected body", () => {
    expect(settlingTtlSeconds(tvdbSeasonKey, "not json", today)).toBeNull();
    expect(settlingTtlSeconds(tvdbSeasonKey, "[1,2]", today)).toBeNull();
    expect(
      settlingTtlSeconds(tvdbSeasonKey, JSON.stringify({ data: { episodes: "nope" } }), today),
    ).toBeNull();
  });
});

describe("ttlSecondsForResponse", () => {
  it("falls back to the path TTL when the body has settled", () => {
    const body = JSON.stringify({ episodes: [{ air_date: "2001-01-01", name: "Quiet Tide" }] });
    expect(
      ttlSecondsForResponse("GET:/tmdb/tv/shows/97546/4:", body, new Date("2026-09-14T00:00:00Z")),
    ).toBe(1209600);
  });
});
