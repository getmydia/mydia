/// Which locations are item detail pages, and what the shell's navigation
/// shows while one is open.
library;

/// The path segments of `/s/:sourceId/<kind>/:itemId` that open a detail page.
const _detailSegments = {'movie', 'show', 'season', 'episode'};

/// Whether [location] is a movie, show, season or episode detail page.
///
/// Matches the path only, so a query string or fragment never hides one.
/// `/s/:sourceId/item/...` is not a detail location: it redirects to one.
bool isDetailLocation(String location) {
  final path = Uri.tryParse(location)?.path ?? location;
  final segments = path.split('/');
  // ['', 's', sourceId, kind, itemId]
  return segments.length == 5 &&
      segments[0].isEmpty &&
      segments[1] == 's' &&
      segments[2].isNotEmpty &&
      _detailSegments.contains(segments[3]) &&
      segments[4].isNotEmpty;
}

/// The location the shell's rail, drawer and bottom bar should read.
///
/// A detail page belongs to no navigation row of its own, so it borrows the
/// page the viewer opened it from ([origin], the last non-detail location the
/// shell showed): that row stays selected, as it does in Plex and Apple TV.
/// With no origin (a deep link straight to a detail page) the detail location
/// itself is returned, which matches no row; the rail then falls back to its
/// first row for focus and selects nothing, and the entries are still those of
/// the source the location names.
///
/// An origin on a different source than the detail page (a remote command
/// opening another server's item) is ignored, so the rows never describe a
/// source other than the one on screen.
String shellNavLocation(String location, {String? origin}) {
  if (!isDetailLocation(location)) return location;
  if (origin == null) return location;
  final originSource = _sourceSegment(origin);
  if (originSource != null && originSource != _sourceSegment(location)) {
    return location;
  }
  return origin;
}

String? _sourceSegment(String location) {
  final segments = (Uri.tryParse(location)?.path ?? location).split('/');
  return segments.length > 2 && segments[1] == 's' ? segments[2] : null;
}
