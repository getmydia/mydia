import 'package:flutter/material.dart';

import 'media_filter.dart';

/// One row in the sidebar.
///
/// Builtins and saved filters are the same kind of thing and differ only by
/// what backs them, which is the whole point of the flat list.
sealed class NavDestination {
  const NavDestination();

  String get id;
  String get label;
  IconData get icon;
  IconData get selectedIcon;
  String get route;

  /// Anchored rows cannot be reordered or hidden.
  bool get isAnchored => false;

  /// Whether [location] should render this row as selected.
  bool matches(String location) => location.startsWith(route);
}

/// A destination the app ships.
class BuiltinDestination extends NavDestination {
  const BuiltinDestination({
    required this.id,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.route,
    required this.defaultIndex,
    this.isAnchored = false,
    this.extraRoutes = const [],
    this.requiresDownloadSupport = false,
  });

  @override
  final String id;
  @override
  final String label;
  @override
  final IconData icon;
  @override
  final IconData selectedIcon;
  @override
  final String route;
  @override
  final bool isAnchored;

  /// Placement for a user who has never reordered. Also where this row is
  /// inserted for an existing user when a later release adds it.
  final int defaultIndex;

  /// Additional prefixes that also select this row. Home owns several.
  final List<String> extraRoutes;

  /// Downloads only exists on platforms with download support.
  final bool requiresDownloadSupport;

  @override
  bool matches(String location) {
    if (route == '/') {
      if (location == '/') return true;
    } else if (location.startsWith(route)) {
      return true;
    }
    return extraRoutes.any(location.startsWith);
  }
}

/// A destination the user created.
class FilterDestination extends NavDestination {
  const FilterDestination({
    required this.id,
    required this.label,
    required this.filter,
  });

  @override
  final String id;
  @override
  final String label;
  final MediaFilter filter;

  @override
  IconData get icon => Icons.filter_alt_outlined;
  @override
  IconData get selectedIcon => Icons.filter_alt_rounded;
  @override
  String get route => '/filter/$id';

  @override
  bool matches(String location) =>
      location == route || location.startsWith('$route/');

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'filter': filter.toJson(),
      };

  factory FilterDestination.fromJson(Map<String, dynamic> json) {
    return FilterDestination(
      id: json['id'] as String,
      label: json['label'] as String,
      filter: MediaFilter.fromJson(
        Map<String, dynamic>.from(json['filter'] as Map),
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FilterDestination &&
      other.id == id &&
      other.label == label &&
      other.filter == filter;

  @override
  int get hashCode => Object.hash(id, label, filter);
}

/// The destinations the app ships, in their default order.
///
/// `defaultIndex` is deliberately sparse so a later release can slot a new
/// destination between two existing ones without renumbering.
const List<BuiltinDestination> builtinDestinations = [
  BuiltinDestination(
    id: 'search',
    label: 'Search',
    icon: Icons.search_outlined,
    selectedIcon: Icons.search_rounded,
    route: '/search',
    defaultIndex: 0,
    isAnchored: true,
  ),
  BuiltinDestination(
    id: 'home',
    label: 'Home',
    icon: Icons.home_outlined,
    selectedIcon: Icons.home_rounded,
    route: '/',
    defaultIndex: 100,
    extraRoutes: [
      '/recently-added',
      '/unwatched',
      '/favorites',
      '/collections'
    ],
  ),
  BuiltinDestination(
    id: 'continue_watching',
    label: 'Continue Watching',
    icon: Icons.play_circle_outline,
    selectedIcon: Icons.play_circle_rounded,
    route: '/continue-watching',
    defaultIndex: 110,
  ),
  BuiltinDestination(
    id: 'movies',
    label: 'Movies',
    icon: Icons.movie_outlined,
    selectedIcon: Icons.movie_rounded,
    route: '/movies',
    defaultIndex: 120,
  ),
  BuiltinDestination(
    id: 'shows',
    label: 'TV Shows',
    icon: Icons.tv_outlined,
    selectedIcon: Icons.tv_rounded,
    route: '/shows',
    defaultIndex: 130,
  ),
  BuiltinDestination(
    id: 'recently_added',
    label: 'Recently Added',
    icon: Icons.fiber_new_outlined,
    selectedIcon: Icons.fiber_new_rounded,
    route: '/recently-added',
    defaultIndex: 140,
  ),
  BuiltinDestination(
    id: 'unwatched',
    label: 'Unwatched',
    icon: Icons.visibility_off_outlined,
    selectedIcon: Icons.visibility_off_rounded,
    route: '/unwatched',
    defaultIndex: 150,
  ),
  BuiltinDestination(
    id: 'favorites',
    label: 'Favorites',
    icon: Icons.favorite_outline_rounded,
    selectedIcon: Icons.favorite_rounded,
    route: '/favorites',
    defaultIndex: 160,
  ),
  BuiltinDestination(
    id: 'collections',
    label: 'Collections',
    icon: Icons.collections_bookmark_outlined,
    selectedIcon: Icons.collections_bookmark_rounded,
    route: '/collections',
    defaultIndex: 170,
  ),
  BuiltinDestination(
    id: 'downloads',
    label: 'Downloads',
    icon: Icons.download_outlined,
    selectedIcon: Icons.download_rounded,
    route: '/downloads',
    defaultIndex: 900,
    isAnchored: true,
    requiresDownloadSupport: true,
  ),
  BuiltinDestination(
    id: 'settings',
    label: 'Settings',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings_rounded,
    route: '/settings',
    defaultIndex: 910,
    isAnchored: true,
  ),
];
