/// Libraries and paging, as every source presents them.
library;

import 'package:flutter/foundation.dart';

import '../../core/sources/source.dart';
import '../navigation/media_filter.dart';

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

/// What a sort option is called. The viewer's language is chosen where the
/// option is drawn (`AppFormatters.sortName`), so a cached library survives a
/// language change.
enum SortName {
  title,
  year,
  recentlyAdded,
  dateAdded,
  rating,
  duration,
  popularity,
  contentRating,
  releaseDate,
  date,
  lastPlayed,
  lastWatched,
  mostPlayed,
  watchState,
  random,
}

/// What a source's own filter chip is called, apart from a Mydia category,
/// which is named by [MediaCategoryFilter]. Worded by `AppFormatters.filterName`.
enum FilterName { unwatched, unplayed, favorites, inProgress }

@immutable
class SortOption {
  const SortOption({
    required this.id,
    required this.name,
    this.descendingByDefault = false,
    this.shared,
  });

  final String id;
  final SortName name;
  final bool descendingByDefault;

  /// Null for an option with no cross-server meaning (rating, random).
  final SharedSort? shared;

  /// Null for an entry cached before options were typed (it has a `label`,
  /// not a `name`): the library then shows no such option until it is
  /// refetched, instead of the whole cached answer being dropped.
  static SortOption? tryFromJson(Map<String, Object?> json) {
    final name = SortName.values.asNameMap()[json['name']];
    final id = json['id'];
    if (name == null || id is! String) return null;
    return SortOption(
      id: id,
      name: name,
      descendingByDefault: json['descendingByDefault'] as bool? ?? false,
      shared: json['shared'] == null
          ? null
          : SharedSort.values.byName(json['shared']! as String),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name.name,
        'descendingByDefault': descendingByDefault,
        'shared': shared?.name,
      };
}

/// A filter chip: either one of [FilterName] or a Mydia [category].
@immutable
class FilterOption {
  const FilterOption({required this.id, this.name, this.category})
      : assert((name == null) != (category == null));

  final String id;
  final FilterName? name;
  final MediaCategoryFilter? category;

  /// Null for an entry cached before filters were typed; see
  /// [SortOption.tryFromJson].
  static FilterOption? tryFromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = FilterName.values.asNameMap()[json['name']];
    final category = MediaCategoryFilter.values.asNameMap()[json['category']];
    if (id is! String || (name == null) == (category == null)) return null;
    return FilterOption(id: id, name: name, category: category);
  }

  Map<String, Object?> toJson() =>
      {'id': id, 'name': name?.name, 'category': category?.name};
}

/// A library as its source describes it. The sorts and filters are the
/// source's own; the screens render whatever comes back.
@immutable
class Library {
  const Library({
    required this.ref,
    this.title,
    required this.kind,
    this.scenes = false,
    this.sortOptions = const [],
    this.filterOptions = const [],
  });

  final LibraryRef ref;

  /// The server's name for the library, never translated. Null when the
  /// server gave none, or the source has fixed libraries: the screens then
  /// name it from [kind] (`AppFormatters.libraryTitle`).
  final String? title;
  final LibraryKind kind;

  /// A Stash library, whose videos are called scenes.
  final bool scenes;
  final List<SortOption> sortOptions;
  final List<FilterOption> filterOptions;

  factory Library.fromJson(Map<String, Object?> json) => Library(
        ref: LibraryRef.fromJson(json['ref']! as Map<String, Object?>),
        title: json['title'] as String?,
        kind: LibraryKind.values.byName(json['kind']! as String),
        scenes: json['scenes'] as bool? ?? false,
        sortOptions: [
          for (final e in (json['sortOptions'] as List?) ?? const [])
            if (SortOption.tryFromJson(e as Map<String, Object?>) case final o?)
              o,
        ],
        filterOptions: [
          for (final e in (json['filterOptions'] as List?) ?? const [])
            if (FilterOption.tryFromJson(e as Map<String, Object?>)
                case final o?)
              o,
        ],
      );

  Map<String, Object?> toJson() => {
        'ref': ref.toJson(),
        'title': title,
        'kind': kind.name,
        'scenes': scenes,
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
