/// What Home shows for a set of servers, built from each server's cached
/// feeds. Pure, so the rules are testable without widgets or providers.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/source.dart';
import '../../../domain/merged/merge_rows.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../../../domain/sources/source_error.dart';
import '../all_servers/all_servers_providers.dart' show isMovieRow;

/// Continue Watching keeps 20 cards. Recently Added keeps 40, so each half of
/// the movies and TV split has room.
const homeContinueLimit = 20;
const homeRecentLimit = 40;

/// One server's Home feeds, as its providers last reported them.
@immutable
class HomeFeeds {
  const HomeFeeds({
    required this.id,
    required this.name,
    required this.continueWatching,
    required this.recentlyAdded,
    required this.favorites,
    required this.libraries,
    this.previews = const {},
  });

  final SourceId id;
  final String name;
  final AsyncValue<List<ItemSummary>> continueWatching;
  final AsyncValue<List<ItemSummary>> recentlyAdded;
  final AsyncValue<List<ItemSummary>> favorites;
  final AsyncValue<List<Library>> libraries;

  /// The preview row of each library in [libraries].
  final Map<LibraryRef, AsyncValue<List<ItemSummary>>> previews;
}

@immutable
class HomeLibraryRow {
  const HomeLibraryRow({
    required this.library,
    required this.title,
    required this.items,
  });

  final LibraryRef library;

  /// The library's title, with its server's name when two or more servers
  /// are in scope.
  final String title;

  /// Empty while the preview loads.
  final List<ItemSummary> items;
}

@immutable
class HomeRows {
  const HomeRows({
    this.loading = false,
    this.hero,
    this.continueWatching = const [],
    this.recentMovies = const [],
    this.recentShows = const [],
    this.favorites = const [],
    this.libraries = const [],
    this.unavailable = const [],
    this.error,
    this.extraCopies = const {},
    this.names = const {},
  });

  /// Some server in scope has not answered its libraries, Continue Watching
  /// or Recently Added yet.
  final bool loading;
  final ItemSummary? hero;
  final List<ItemSummary> continueWatching;
  final List<ItemSummary> recentMovies;
  final List<ItemSummary> recentShows;
  final List<ItemSummary> favorites;
  final List<HomeLibraryRow> libraries;

  /// Servers in scope whose items are left out this time.
  final List<SourceId> unavailable;

  /// Set when every server in scope is unavailable: the first one's error.
  final Object? error;

  /// For each kept card that stands in for copies on other servers, how many.
  final Map<ItemRef, int> extraCopies;

  /// Display name of every server in scope, in scope order.
  final Map<SourceId, String> names;

  /// Two or more servers in scope: cards and library rows name their server.
  bool get labelled => names.length > 1;

  bool get isEmpty =>
      continueWatching.isEmpty &&
      recentMovies.isEmpty &&
      recentShows.isEmpty &&
      favorites.isEmpty &&
      libraries.isEmpty;
}

/// Riverpod keeps the previous error on an invalidated provider, so a retry
/// is `isLoading` with `hasError` still true: it is neither settled nor
/// failed until it answers again.
bool _failed(AsyncValue<Object?> a) => a.hasError && !a.isLoading;

bool _settled(AsyncValue<Object?> a) => a.hasValue || _failed(a);

List<T> _valueOf<T>(AsyncValue<List<T>> a) =>
    a.hasValue ? a.requireValue : <T>[];

/// A server is unavailable when it cannot list its libraries, or when it
/// answers neither of the two rows Home opens with.
bool _down(HomeFeeds f) =>
    _failed(f.libraries) ||
    (_failed(f.continueWatching) && _failed(f.recentlyAdded));

HomeRows buildHomeRows(List<HomeFeeds> feeds) {
  final names = {for (final f in feeds) f.id: f.name};
  if (feeds.any((f) =>
      !_settled(f.libraries) ||
      !_settled(f.continueWatching) ||
      !_settled(f.recentlyAdded))) {
    return HomeRows(loading: true, names: names);
  }
  final up = [
    for (final f in feeds)
      if (!_down(f)) f
  ];
  final unavailable = [
    for (final f in feeds)
      if (_down(f)) f.id
  ];
  if (feeds.isNotEmpty && up.isEmpty) {
    final first = feeds.first;
    return HomeRows(
      names: names,
      unavailable: unavailable,
      error: (_failed(first.libraries) ? first.libraries.error : null) ??
          (_failed(first.continueWatching)
              ? first.continueWatching.error
              : null) ??
          const SourceException.unreachable(),
    );
  }

  final order = [for (final f in up) f.id];
  final resuming = mergeNewest([
    for (final f in up) _valueOf(f.continueWatching)
  ], order, (i) => i.lastPlayedAt, limit: homeContinueLimit);
  final recent = mergeNewest(
      [for (final f in up) _valueOf(f.recentlyAdded)], order, (i) => i.addedAt,
      limit: homeRecentLimit);
  final favorites =
      mergeAlphabetical([for (final f in up) _valueOf(f.favorites)], order);
  final movies = [
    for (final i in recent.items)
      if (isMovieRow(i)) i
  ];
  final shows = [
    for (final i in recent.items)
      if (!isMovieRow(i)) i
  ];
  final labelled = feeds.length > 1;

  return HomeRows(
    hero: resuming.items.firstOrNull ??
        movies.firstOrNull ??
        recent.items.firstOrNull,
    continueWatching: resuming.items,
    recentMovies: movies,
    recentShows: shows,
    favorites: favorites.items,
    libraries: [
      for (final f in up)
        for (final library in _valueOf(f.libraries))
          if (_libraryRow(f, library, labelled: labelled) case final row?) row,
    ],
    unavailable: unavailable,
    extraCopies: {
      ...favorites.extraCopies,
      ...recent.extraCopies,
      ...resuming.extraCopies,
    },
    names: names,
  );
}

/// Null once the preview has loaded empty: an empty library has no row.
HomeLibraryRow? _libraryRow(HomeFeeds f, Library library,
    {required bool labelled}) {
  final preview = f.previews[library.ref];
  final items = preview == null ? const <ItemSummary>[] : _valueOf(preview);
  if (preview != null && preview.hasValue && items.isEmpty) return null;
  return HomeLibraryRow(
    library: library.ref,
    title: labelled ? '${library.title} · ${f.name}' : library.title,
    items: items,
  );
}
