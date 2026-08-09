import '../../presentation/screens/library/library_sort.dart';

/// Which of the two media lists a filter draws from.
///
/// Singular by design. `movies` and `tvShows` are separate paginated
/// connections, so a filter spanning both would mean reconciling two cursors.
enum MediaKind {
  movies('MOVIE'),
  shows('TV_SHOW');

  const MediaKind(this.wireName);

  final String wireName;

  static MediaKind fromName(String? name) => MediaKind.values.firstWhere(
        (kind) => kind.name == name,
        orElse: () => MediaKind.movies,
      );
}

/// Mirrors the server's `MediaCategory` enum.
enum MediaCategoryFilter {
  movie('MOVIE', 'Movies', MediaKind.movies),
  animeMovie('ANIME_MOVIE', 'Anime Movies', MediaKind.movies),
  cartoonMovie('CARTOON_MOVIE', 'Cartoon Movies', MediaKind.movies),
  tvShow('TV_SHOW', 'TV Shows', MediaKind.shows),
  animeSeries('ANIME_SERIES', 'Anime Series', MediaKind.shows),
  cartoonSeries('CARTOON_SERIES', 'Cartoon Series', MediaKind.shows);

  const MediaCategoryFilter(this.wireName, this.displayName, this.kind);

  final String wireName;
  final String displayName;
  final MediaKind kind;

  static List<MediaCategoryFilter> forKind(MediaKind kind) =>
      MediaCategoryFilter.values.where((c) => c.kind == kind).toList();

  static MediaCategoryFilter? fromName(String? name) {
    if (name == null) return null;
    for (final category in MediaCategoryFilter.values) {
      if (category.name == name) return category;
    }
    return null;
  }
}

/// Watch state, which decides which query backs the filter.
enum WatchScope {
  all,
  unwatched,
  favorites;

  static WatchScope fromName(String? name) => WatchScope.values.firstWhere(
        (scope) => scope.name == name,
        orElse: () => WatchScope.all,
      );
}

/// A saved slice of the library.
///
/// Deliberately narrow: genre, year and rating are out of scope because each
/// needs a new argument on both `list_movies` and `list_tv_shows`.
class MediaFilter {
  const MediaFilter({
    required this.kind,
    required this.category,
    required this.watch,
    required this.sort,
  });

  final MediaKind kind;
  final MediaCategoryFilter? category;
  final WatchScope watch;
  final LibrarySort sort;

  static const MediaFilter allMovies = MediaFilter(
    kind: MediaKind.movies,
    category: null,
    watch: WatchScope.all,
    sort: LibrarySort.defaultSort,
  );

  static const MediaFilter allShows = MediaFilter(
    kind: MediaKind.shows,
    category: null,
    watch: WatchScope.all,
    sort: LibrarySort.defaultSort,
  );

  /// The `category` GraphQL variable, or null for "every category".
  String? get categoryVariable => category?.wireName;

  /// The `types` GraphQL variable used by the unwatched and favorites queries.
  List<String> get typesVariable => [kind.wireName];

  MediaFilter copyWith({
    MediaKind? kind,
    MediaCategoryFilter? category,
    bool clearCategory = false,
    WatchScope? watch,
    LibrarySort? sort,
  }) {
    return MediaFilter(
      kind: kind ?? this.kind,
      category: clearCategory ? null : (category ?? this.category),
      watch: watch ?? this.watch,
      sort: sort ?? this.sort,
    );
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'category': category?.name,
        'watch': watch.name,
        'sort': sort.encode(),
      };

  factory MediaFilter.fromJson(Map<String, dynamic> json) {
    final kind = MediaKind.fromName(json['kind'] as String?);
    final category = MediaCategoryFilter.fromName(json['category'] as String?);

    return MediaFilter(
      kind: kind,
      // A category belonging to the other kind is discarded rather than
      // honoured: it would produce a query that always returns nothing.
      category: category?.kind == kind ? category : null,
      watch: WatchScope.fromName(json['watch'] as String?),
      sort: LibrarySort.decode(json['sort'] as String?),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MediaFilter &&
      other.kind == kind &&
      other.category == category &&
      other.watch == watch &&
      other.sort == sort;

  @override
  int get hashCode => Object.hash(kind, category, watch, sort);

  @override
  String toString() =>
      'MediaFilter(${kind.name}, ${category?.name}, ${watch.name}, $sort)';
}
