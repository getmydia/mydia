// Route groups for the cutover traffic layer (src/routing/router.ts). Each
// group gets its own mode in the routing config, so a group is the unit that
// moves between the Elixir relay and this Worker.
//
// Groups follow what can safely be split, not the URL tree alone. Pairing is
// one group because a claim created on one backend must be read back from
// the same one. Subtitles stand apart from the other proxy routes because
// their SubDL key has a shared daily quota that shadowing would spend twice.
export const ROUTE_GROUPS = [
  "tmdb",
  "tvdb",
  "music",
  "openlibrary",
  "client_config",
  "health",
  "subtitles",
  "pairing",
  "crashes",
  "feedback",
  "admin",
  "other",
] as const;

export type RouteGroup = (typeof ROUTE_GROUPS)[number];

export function routeGroupFor(pathname: string): RouteGroup {
  if (pathname.startsWith("/tmdb/") || pathname === "/configuration") return "tmdb";
  if (pathname.startsWith("/tvdb/")) return "tvdb";
  if (pathname.startsWith("/music/")) return "music";
  if (pathname.startsWith("/openlibrary/")) return "openlibrary";
  if (pathname.startsWith("/api/v1/subtitles/")) return "subtitles";
  if (pathname === "/client-config") return "client_config";
  if (pathname === "/health" || pathname === "/stats") return "health";
  if (pathname.startsWith("/pairing/")) return "pairing";
  if (pathname.startsWith("/crashes/")) return "crashes";
  if (pathname === "/feedback") return "feedback";
  if (pathname === "/admin" || pathname.startsWith("/admin/")) return "admin";
  // `/`, the Elixir-only `/metrics` Prometheus endpoint, and scanner noise.
  return "other";
}
