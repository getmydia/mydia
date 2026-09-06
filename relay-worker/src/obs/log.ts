// Mirrors service_from_path/1 in plug/cache.ex.
export function serviceFromPath(path: string): string | null {
  if (path.startsWith("/tmdb/")) return "tmdb";
  if (path.startsWith("/tvdb/")) return "tvdb";
  if (path.startsWith("/music/")) return "music";
  if (path.startsWith("/openlibrary/")) return "openlibrary";
  if (path.startsWith("/api/v1/subtitles/")) return "subdl";
  return null;
}

// One structured line per request, retained by Workers Logs. The old
// metadata_relay_requests_total{status="ok"|"error"} counter was dominated by
// benign upstream 404s for TMDB ids that do not exist, which read as a 61%
// error rate while the pod logged nothing. Recording the real status code lets
// a query bucket by it instead of trusting a misleading binary.
export function logRequest(
  path: string,
  status: number,
  cache: "HIT" | "MISS",
): void {
  console.log(
    JSON.stringify({
      service: serviceFromPath(path) ?? "other",
      path,
      status,
      cache,
    }),
  );
}
