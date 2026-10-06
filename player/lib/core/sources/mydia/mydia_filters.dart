/// What a Mydia library offers to sort and filter by, and the query each
/// combination runs.
library;

import 'dart:convert';

import 'package:gql/ast.dart' show DocumentNode;

import '../../../domain/navigation/media_filter.dart';
import '../../../domain/sources/library.dart';
import '../../../graphql/queries/mydia_queries.dart';
import '../../../presentation/screens/library/library_sort.dart';
import '../capabilities.dart';
import '../source.dart';

const mydiaMoviesLibrary = 'movies';
const mydiaShowsLibrary = 'shows';

const _watchPrefix = 'watch:';
const _categoryPrefix = 'category:';
const _unwatchedId = '${_watchPrefix}unwatched';
const _favoritesId = '${_watchPrefix}favorites';

const _descendingByDefault = {
  SortField.addedAt,
  SortField.year,
  SortField.rating,
  SortField.popularity,
  SortField.releaseDate,
  SortField.lastPlayed,
};

const _shared = {
  SortField.title: SharedSort.title,
  SortField.addedAt: SharedSort.added,
  SortField.releaseDate: SharedSort.released,
};

/// One option per `SortField` but random, which has no direction.
final List<SortOption> mydiaSortOptions = [
  for (final f in SortField.values)
    if (f != SortField.random)
      SortOption(
        id: f.wireName,
        label: f.displayName,
        descendingByDefault: _descendingByDefault.contains(f),
        shared: _shared[f],
      ),
];

List<FilterOption> mydiaFilterOptions(LibraryKind kind) {
  final mediaKind = switch (kind) {
    LibraryKind.movies => MediaKind.movies,
    LibraryKind.shows => MediaKind.shows,
    LibraryKind.videos => null,
  };
  return [
    const FilterOption(id: _unwatchedId, label: 'Unwatched'),
    const FilterOption(id: _favoritesId, label: 'Favorites'),
    if (mediaKind != null)
      for (final c in MediaCategoryFilter.forKind(mediaKind))
        FilterOption(id: '$_categoryPrefix${c.wireName}', label: c.displayName),
  ];
}

SavedFilterQuery? mydiaFilterQuery(SourceId sid, MediaFilter filter) {
  final library = switch (filter.kind) {
    MediaKind.movies => mydiaMoviesLibrary,
    MediaKind.shows => mydiaShowsLibrary,
  };
  return (
    library: LibraryRef(sourceId: sid, id: library),
    query: BrowseQuery(
      sortId: filter.sort.field.wireName,
      descending: filter.sort.direction == SortDirection.desc,
      filterIds: {
        switch (filter.watch) {
          WatchScope.unwatched => _unwatchedId,
          WatchScope.favorites => _favoritesId,
          WatchScope.all => null,
        },
        if (filter.category case final c?) '$_categoryPrefix${c.wireName}',
      }.whereType<String>().toSet(),
    ),
  );
}

/// Which document to run, which field of its result holds the items, and the
/// variables. The flat listings (`unwatched`, `favorites`) hold a bare list,
/// the filtered browse queries a connection.
({DocumentNode doc, String field, Map<String, dynamic> vars}) mydiaBrowsePlan({
  required bool movies,
  required BrowseQuery query,
  Cursor? cursor,
}) {
  final sort =
      mydiaSortOptions.where((o) => o.id == query.sortId).firstOrNull ??
          mydiaSortOptions.first;
  final descending = query.descending ?? sort.descendingByDefault;
  final category = query.filterIds
      .where((id) => id.startsWith(_categoryPrefix))
      .map((id) => id.substring(_categoryPrefix.length))
      .firstOrNull;
  final vars = <String, dynamic>{
    'first': query.pageSize,
    'after': cursor?.value,
    'category': category,
    'sort': {'field': sort.id, 'direction': descending ? 'DESC' : 'ASC'},
  };
  final types = [movies ? 'MOVIE' : 'TV_SHOW'];
  if (query.filterIds.contains(_unwatchedId)) {
    return (
      doc: documentNodeQueryUnwatchedListing,
      field: 'unwatched',
      vars: {...vars, 'types': types},
    );
  }
  if (query.filterIds.contains(_favoritesId)) {
    return (
      doc: documentNodeQueryFavoritesListing,
      field: 'favorites',
      vars: {...vars, 'types': types},
    );
  }
  return movies
      ? (
          doc: documentNodeQueryMoviesFiltered,
          field: 'movies',
          vars: vars,
        )
      : (
          doc: documentNodeQueryTvShowsFiltered,
          field: 'tvShows',
          vars: vars,
        );
}

/// The flat listings have no cursor connection, so they page with the
/// server's offset cursor.
String offsetCursor(int offset) => base64Encode(utf8.encode('cursor:$offset'));

/// The offset an [offsetCursor] carries: the index of the last item seen,
/// or -1 before the first page.
int offsetOf(Cursor? cursor) {
  if (cursor == null) return -1;
  try {
    final text = utf8.decode(base64Decode(cursor.value));
    return int.tryParse(text.replaceFirst('cursor:', '')) ?? -1;
  } on FormatException {
    return -1;
  }
}
