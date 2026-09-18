import { describe, it, expect } from "vitest";
import { parseMode, parseRoutingConfig } from "../../src/routing/config";
import { routeGroupFor } from "../../src/routing/groups";
import { loggablePath } from "../../src/obs/log";

describe("routeGroupFor", () => {
  it.each([
    ["/tmdb/movies/550", "tmdb"],
    ["/configuration", "tmdb"],
    ["/tvdb/series/1/extended", "tvdb"],
    ["/music/search", "music"],
    ["/openlibrary/isbn/1", "openlibrary"],
    ["/api/v1/subtitles/search", "subtitles"],
    ["/client-config", "client_config"],
    ["/health", "health"],
    ["/stats", "health"],
    ["/pairing/claim/ABC", "pairing"],
    ["/pairing/v2/claim/xyz", "pairing"],
    ["/crashes/report", "crashes"],
    ["/feedback", "feedback"],
    ["/admin", "admin"],
    ["/admin/errors", "admin"],
    ["/metrics", "other"],
    ["/", "other"],
    ["/.env", "other"],
    // Prefix lookalikes stay out of the groups they resemble.
    ["/feedbackx", "other"],
    ["/administrator", "other"],
    ["/tmdbx", "other"],
  ])("%s -> %s", (path, group) => {
    expect(routeGroupFor(path)).toBe(group);
  });
});

describe("loggablePath", () => {
  it.each([
    ["/pairing/claim/ABCD", "/pairing/claim/*"],
    ["/pairing/v2/claim/lookup-key", "/pairing/v2/claim/*"],
    ["/pairing/claim", "/pairing/claim"],
    ["/pairing/v2/claim", "/pairing/v2/claim"],
    ["/tmdb/movies/550", "/tmdb/movies/550"],
  ])("%s -> %s", (path, logged) => {
    expect(loggablePath(path)).toBe(logged);
  });
});

describe("parseMode", () => {
  it.each([
    ["origin", { kind: "origin" }],
    ["worker", { kind: "worker" }],
    ["fallback", { kind: "fallback" }],
    ["shadow", { kind: "shadow", percent: 100 }],
    ["shadow:10", { kind: "shadow", percent: 10 }],
    ["split:0", { kind: "split", percent: 0 }],
    ["split:100", { kind: "split", percent: 100 }],
    [" worker ", { kind: "worker" }],
  ])("%j", (raw, mode) => {
    expect(parseMode(raw)).toEqual(mode);
  });

  it.each([["split"], ["split:101"], ["split:-1"], ["split:1.5"], ["worker:5"], ["shadow:5:1"], ["canary"], [""], [5], [null]])(
    "rejects %j",
    (raw) => {
      expect(parseMode(raw)).toBeNull();
    },
  );
});

describe("parseRoutingConfig", () => {
  it("sends everything to the origin when there is no config", () => {
    const { modes, warnings } = parseRoutingConfig(null);
    expect(Object.values(modes).every((m) => m.kind === "origin")).toBe(true);
    expect(warnings).toEqual([]);
  });

  it("sends everything to the origin when the config is not JSON", () => {
    const { modes, warnings } = parseRoutingConfig("{nope");
    expect(Object.values(modes).every((m) => m.kind === "origin")).toBe(true);
    expect(warnings).toEqual(["routing config is not valid JSON"]);
  });

  it("applies per-group modes and leaves the rest on the default", () => {
    const { modes, warnings } = parseRoutingConfig(
      JSON.stringify({ groups: { tmdb: "shadow:25", tvdb: "split:10", pairing: "fallback" } }),
    );
    expect(modes.tmdb).toEqual({ kind: "shadow", percent: 25 });
    expect(modes.tvdb).toEqual({ kind: "split", percent: 10 });
    expect(modes.pairing).toEqual({ kind: "fallback" });
    expect(modes.crashes).toEqual({ kind: "origin" });
    expect(warnings).toEqual([]);
  });

  it("refuses modes a group may not use and keeps that group on the origin", () => {
    const { modes, warnings } = parseRoutingConfig(
      JSON.stringify({
        groups: {
          subtitles: "shadow",
          pairing: "split:50",
          crashes: "split:50",
          feedback: "shadow",
          admin: "fallback",
        },
      }),
    );
    expect(modes.subtitles).toEqual({ kind: "origin" });
    expect(modes.pairing).toEqual({ kind: "origin" });
    expect(modes.crashes).toEqual({ kind: "origin" });
    expect(modes.feedback).toEqual({ kind: "origin" });
    expect(modes.admin).toEqual({ kind: "origin" });
    expect(warnings).toHaveLength(5);
  });

  it("applies a default only where each group allows it, without warnings", () => {
    const { modes, warnings } = parseRoutingConfig(JSON.stringify({ default: "shadow" }));
    expect(modes.tmdb).toEqual({ kind: "shadow", percent: 100 });
    expect(modes.health).toEqual({ kind: "shadow", percent: 100 });
    expect(modes.subtitles).toEqual({ kind: "origin" });
    expect(modes.pairing).toEqual({ kind: "origin" });
    expect(modes.other).toEqual({ kind: "origin" });
    expect(warnings).toEqual([]);
  });

  it("lets an explicit group mode override the default", () => {
    const { modes } = parseRoutingConfig(
      JSON.stringify({ default: "worker", groups: { admin: "origin" } }),
    );
    expect(modes.tmdb).toEqual({ kind: "worker" });
    expect(modes.pairing).toEqual({ kind: "worker" });
    expect(modes.admin).toEqual({ kind: "origin" });
  });

  it("warns about unknown groups and unparseable modes without dropping the rest", () => {
    const { modes, warnings } = parseRoutingConfig(
      JSON.stringify({ default: "bogus", groups: { tmdb: "worker", tvdbb: "worker", tvdb: "half" } }),
    );
    expect(modes.tmdb).toEqual({ kind: "worker" });
    expect(modes.tvdb).toEqual({ kind: "origin" });
    expect(warnings).toEqual([
      'default: unrecognised mode "bogus"',
      'unknown group "tvdbb"',
      'tvdb: unrecognised mode "half"',
    ]);
  });
});
