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

  factory LibraryRef.fromJson(Map<String, Object?> json) => LibraryRef(
        sourceId: SourceId(json['sourceId']! as String),
        id: json['id']! as String,
      );

  Map<String, Object?> toJson() => {'sourceId': sourceId.value, 'id': id};

  @override
  bool operator ==(Object other) =>
      other is LibraryRef && other.sourceId == sourceId && other.id == id;

  @override
  int get hashCode => Object.hash(sourceId, id);
}

/// What a source's own sort option means across servers. The All servers
/// grids sort by these and ask each library for the option tagged with one.
enum SharedSort { title, added, released }

@immutable
class SortOption {
  const SortOption({
    required this.id,
    required this.label,
    this.descendingByDefault = false,
    this.shared,
  });

  final String id;
  final String label;
  final bool descendingByDefault;

  /// Null for an option with no cross-server meaning (rating, random).
  final SharedSort? shared;

  factory SortOption.fromJson(Map<String, Object?> json) => SortOption(
        id: json['id']! as String,
        label: json['label']! as String,
        descendingByDefault: json['descendingByDefault'] as bool? ?? false,
        shared: json['shared'] == null
            ? null
            : SharedSort.values.byName(json['shared']! as String),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'descendingByDefault': descendingByDefault,
        'shared': shared?.name,
      };
}

@immutable
class FilterOption {
  const FilterOption({required this.id, required this.label});

  final String id;
  final String label;

  factory FilterOption.fromJson(Map<String, Object?> json) => FilterOption(
        id: json['id']! as String,
        label: json['label']! as String,
      );

  Map<String, Object?> toJson() => {'id': id, 'label': label};
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

  factory Library.fromJson(Map<String, Object?> json) => Library(
        ref: LibraryRef.fromJson(json['ref']! as Map<String, Object?>),
        title: json['title']! as String,
        kind: LibraryKind.values.byName(json['kind']! as String),
        sortOptions: [
          for (final e in (json['sortOptions'] as List?) ?? const [])
            SortOption.fromJson(e as Map<String, Object?>),
        ],
        filterOptions: [
          for (final e in (json['filterOptions'] as List?) ?? const [])
            FilterOption.fromJson(e as Map<String, Object?>),
        ],
      );

  Map<String, Object?> toJson() => {
        'ref': ref.toJson(),
        'title': title,
        'kind': kind.name,
        'sortOptions': [for (final o in sortOptions) o.toJson()],
        'filterOptions': [for (final o in filterOptions) o.toJson()],
      };
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

  static Page<T> fromJson<T>(
    Map<String, Object?> json,
    T Function(Map<String, Object?> item) item,
  ) =>
      Page(
        items: [
          for (final e in (json['items'] as List?) ?? const [])
            item(e as Map<String, Object?>),
        ],
        nextCursor: json['nextCursor'] == null
            ? null
            : Cursor(json['nextCursor']! as String),
        total: json['total'] as int?,
      );

  Map<String, Object?> toJson(Object? Function(T item) item) => {
        'items': [for (final i in items) item(i)],
        'nextCursor': nextCursor?.value,
        'total': total,
      };
}
