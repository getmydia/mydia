/// Libraries and paging, as every source presents them.
library;

import 'package:flutter/foundation.dart';

import '../../core/sources/source.dart';

enum LibraryKind { movies, shows, videos }

@immutable
class LibraryRef {
  const LibraryRef({required this.sourceId, required this.id});

  final SourceId sourceId;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is LibraryRef && other.sourceId == sourceId && other.id == id;

  @override
  int get hashCode => Object.hash(sourceId, id);
}

@immutable
class SortOption {
  const SortOption({
    required this.id,
    required this.label,
    this.descendingByDefault = false,
  });

  final String id;
  final String label;
  final bool descendingByDefault;
}

@immutable
class FilterOption {
  const FilterOption({required this.id, required this.label});

  final String id;
  final String label;
}

/// A library as its source describes it. The sorts and filters are the
/// source's own; the screens render whatever comes back.
@immutable
class Library {
  const Library({
    required this.ref,
    required this.title,
    required this.kind,
    this.sortOptions = const [],
    this.filterOptions = const [],
  });

  final LibraryRef ref;
  final String title;
  final LibraryKind kind;
  final List<SortOption> sortOptions;
  final List<FilterOption> filterOptions;
}

@immutable
class BrowseQuery {
  const BrowseQuery({
    this.sortId,
    this.descending,
    this.filterIds = const {},
    this.pageSize = 60,
  });

  /// Null uses the library's first sort option.
  final String? sortId;

  /// Null uses the sort option's default direction.
  final bool? descending;
  final Set<String> filterIds;
  final int pageSize;

  BrowseQuery copyWith({
    String? sortId,
    bool? descending,
    Set<String>? filterIds,
  }) =>
      BrowseQuery(
        sortId: sortId ?? this.sortId,
        descending: descending ?? this.descending,
        filterIds: filterIds ?? this.filterIds,
        pageSize: pageSize,
      );

  @override
  bool operator ==(Object other) =>
      other is BrowseQuery &&
      other.sortId == sortId &&
      other.descending == descending &&
      setEquals(other.filterIds, filterIds) &&
      other.pageSize == pageSize;

  @override
  int get hashCode => Object.hash(
        sortId,
        descending,
        Object.hashAllUnordered(filterIds),
        pageSize,
      );
}

/// Opaque to callers: an offset for Plex, a page number for Stash.
@immutable
class Cursor {
  const Cursor(this.value);

  final String value;
}

@immutable
class Page<T> {
  const Page({required this.items, this.nextCursor, this.total});

  final List<T> items;
  final Cursor? nextCursor;
  final int? total;

  bool get hasMore => nextCursor != null;
}
