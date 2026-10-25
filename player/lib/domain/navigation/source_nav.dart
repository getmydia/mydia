/// The sidebar and bottom bar rows for one source: the viewer's layout,
/// resolved against what that source can do. Pure, so the rules are testable
/// without a widget tree.
library;

import 'package:flutter/material.dart';

import '../../core/sources/media_source.dart';
import '../../core/sources/source.dart';
import '../../presentation/screens/detail/detail_links.dart';
import '../sources/library.dart';
import 'all_servers_locations.dart';
import 'nav_destination.dart';

@immutable
class SourceNavEntry {
  const SourceNavEntry({
    required this.id,
    this.label,
    this.libraryKind,
    required this.icon,
    required this.selectedIcon,
    required this.route,
    this.anchored = false,
    this.shortLabel = false,
  });

  /// The kind of the library this entry opens, so a library its server left
  /// unnamed is still named. Null for every other entry.
  final LibraryKind? libraryKind;

  /// Whether the bottom bar uses the short form of the name, when the full
  /// one does not fit.
  final bool shortLabel;

  final String id;

  /// A library's own name, which is the server's and never translated. Null
  /// for a builtin row, which is named from [id] by
  /// `AppFormatters.navEntryLabel`.
  final String? label;
  final IconData icon;
  final IconData selectedIcon;
  final String route;
  final bool anchored;

  /// Whether [location] is this entry's route or something under it.
  ///
  /// A source's home route is the prefix of all its pages, so it matches
  /// exactly; otherwise Home would stay selected everywhere in the source.
  bool matches(String location) {
    if (location == route) return true;
    if (id == 'home') return false;
    return location.startsWith('$route/') || location.startsWith('$route?');
  }

  @override
  bool operator ==(Object other) =>
      other is SourceNavEntry &&
      other.id == id &&
      other.label == label &&
      other.libraryKind == libraryKind &&
      other.icon == icon &&
      other.selectedIcon == selectedIcon &&
      other.route == route &&
      other.anchored == anchored &&
      other.shortLabel == shortLabel;

  @override
  int get hashCode => Object.hash(
      id, label, libraryKind, icon, selectedIcon, route, anchored, shortLabel);
}

/// The source id in a `/s/<id>/...` location, or null elsewhere.
String? sourceIdFromLocation(String location) {
  if (!location.startsWith('/s/')) return null;
  final rest = location.substring(3);
  final end = rest.indexOf('/');
  final id = end == -1 ? rest : rest.substring(0, end);
  try {
    return id.isEmpty ? null : Uri.decodeComponent(id);
  } on FormatException {
    return null;
  } on ArgumentError {
    // A truncated escape such as `%E0%A4%A` throws this, not FormatException.
    return null;
  }
}

/// The entries that belong to the app, not to a source: Downloads and
/// Settings. They are all a viewer has when no source exists.
List<SourceNavEntry> anchoredNavEntries(List<NavDestination> layout) => [
      for (final d in layout)
        if (d.isAnchored && d.id != 'search')
          SourceNavEntry(
            id: d.id,
            icon: d.icon,
            selectedIcon: d.selectedIcon,
            route: d.route,
            anchored: true,
          ),
    ];

/// The viewer's sidebar layout, resolved against the merged All servers
/// views. Rows with no merged view (Calendar, Unwatched, saved filters) are
/// left out here and still show on a single server.
List<SourceNavEntry> resolveAllServersNav(List<NavDestination> layout) {
  String? routeFor(NavDestination d) => switch (d) {
        FilterDestination() => null,
        BuiltinDestination() => switch (d.id) {
            'search' => allServersSearchLocation,
            'home' => allServersRoot,
            'continue_watching' => allServersContinueWatchingLocation,
            'movies' => allServersMoviesLocation,
            'shows' => allServersShowsLocation,
            'recently_added' => allServersRecentlyAddedLocation,
            'favorites' => allServersFavoritesLocation,
            'collections' => allServersCollectionsLocation,
            'downloads' || 'settings' => d.route,
            _ => null,
          },
      };
  return [
    for (final d in layout)
      if (routeFor(d) case final route?)
        SourceNavEntry(
          id: d.id,
          icon: d.icon,
          selectedIcon: d.selectedIcon,
          route: route,
          anchored: d.isAnchored,
          shortLabel: d.id == 'shows',
        ),
  ];
}

/// The viewer's sidebar layout, resolved against one source. A builtin
/// destination appears only when the source can serve it; libraries the
/// layout has no entry for follow the Shows entry.
List<SourceNavEntry> resolveSourceNav({
  required List<NavDestination> layout,
  required SourceId source,
  required Set<SourceCapability> capabilities,
  required List<Library> libraries,
}) {
  Library? firstOf(LibraryKind kind) =>
      libraries.where((l) => l.kind == kind).firstOrNull;
  final movies = firstOf(LibraryKind.movies);
  final shows = firstOf(LibraryKind.shows);

  String? listing(SourceListing l, SourceCapability needs) =>
      capabilities.contains(needs) ? sourceListingLocation(source, l) : null;

  String? routeFor(NavDestination d) => switch (d) {
        FilterDestination() =>
          capabilities.contains(SourceCapability.savedFilters)
              ? filterLocation(source, d.id)
              : null,
        BuiltinDestination() => switch (d.id) {
            'search' => capabilities.contains(SourceCapability.searchable)
                ? sourceSearchLocation(source)
                : null,
            'home' => sourceHomeLocation(source),
            'continue_watching' => listing(SourceListing.continueWatching,
                SourceCapability.continueWatching),
            'movies' =>
              movies == null ? null : sourceLibraryLocation(movies.ref),
            'shows' => shows == null ? null : sourceLibraryLocation(shows.ref),
            'calendar' =>
              listing(SourceListing.calendar, SourceCapability.calendar),
            'recently_added' => listing(
                SourceListing.recentlyAdded, SourceCapability.recentlyAdded),
            'unwatched' => listing(
                SourceListing.unwatched, SourceCapability.unwatchedListing),
            'favorites' => listing(
                SourceListing.favorites, SourceCapability.favoritesListing),
            'collections' =>
              listing(SourceListing.collections, SourceCapability.collections),
            'downloads' || 'settings' => d.route,
            _ => null,
          },
      };

  final entries = <SourceNavEntry>[];
  var afterLibraries = -1;
  for (final d in layout) {
    final route = routeFor(d);
    if (route == null) continue;
    entries.add(SourceNavEntry(
      id: d.id,
      icon: d.icon,
      selectedIcon: d.selectedIcon,
      route: route,
      anchored: d.isAnchored,
      shortLabel: d.id == 'shows',
    ));
    if (d.id == 'shows' || (d.id == 'movies' && afterLibraries == -1)) {
      afterLibraries = entries.length;
    }
  }

  final extras = [
    for (final l in libraries)
      if (!identical(l, movies) && !identical(l, shows))
        SourceNavEntry(
          id: 'library-${l.ref.id}',
          label: l.title,
          libraryKind: l.kind,
          icon: Icons.video_library_outlined,
          selectedIcon: Icons.video_library,
          route: sourceLibraryLocation(l.ref),
        ),
  ];
  if (extras.isEmpty) return entries;

  var at = afterLibraries;
  if (at == -1) {
    at = entries.indexWhere((e) => e.anchored && e.id != 'search');
    if (at == -1) at = entries.length;
  }
  return [...entries.take(at), ...extras, ...entries.skip(at)];
}
