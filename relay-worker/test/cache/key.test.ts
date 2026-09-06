import { describe, it, expect } from "vitest";
import {
  buildKey,
  ttlSecondsFor,
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
