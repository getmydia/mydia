/// A single library-search hit: a movie, TV show, episode, or collection.
class SearchResult {
  final String id;
  final SearchResultType type;
  final String title;
  final int? year;

  /// Parent show title for episodes, item count for collections.
  final String? subtitle;
  final int? seasonNumber;
  final int? episodeNumber;

  /// Owning show ID, episodes only.
  final String? parentId;
  final String? posterUrl;
  final String? backdropUrl;
  final String? thumbnailUrl;
  final double? score;

  const SearchResult({
    required this.id,
    required this.type,
    required this.title,
    this.year,
    this.subtitle,
    this.seasonNumber,
    this.episodeNumber,
    this.parentId,
    this.posterUrl,
    this.backdropUrl,
    this.thumbnailUrl,
    this.score,
  });

  factory SearchResult.fromJson(Map<String, dynamic> json) {
    final artwork = json['artwork'] as Map<String, dynamic>?;

    return SearchResult(
      id: json['id'].toString(),
      type: SearchResultType.fromString(json['type'] as String? ?? 'MOVIE'),
      title: json['title'] as String? ?? 'Unknown',
      year: json['year'] as int?,
      subtitle: json['subtitle'] as String?,
      seasonNumber: json['seasonNumber'] as int?,
      episodeNumber: json['episodeNumber'] as int?,
      parentId: json['parentId'] as String?,
      posterUrl: artwork?['posterUrl'] as String?,
      backdropUrl: artwork?['backdropUrl'] as String?,
      thumbnailUrl: artwork?['thumbnailUrl'] as String?,
      score: (json['score'] as num?)?.toDouble(),
    );
  }

  /// Year display string.
  String get yearDisplay => year?.toString() ?? '';

  /// `S01E03` for episodes, null for everything else.
  String? get episodeCode {
    final season = seasonNumber;
    final episode = episodeNumber;
    if (season == null || episode == null) return null;
    return 'S${season.toString().padLeft(2, '0')}'
        'E${episode.toString().padLeft(2, '0')}';
  }

  /// Route path for this result's detail screen.
  String get routePath {
    switch (type) {
      case SearchResultType.movie:
        return '/movie/$id';
      case SearchResultType.tvShow:
        return '/show/$id';
      case SearchResultType.episode:
        return '/episode/$id';
      case SearchResultType.collection:
        return '/collection/$id';
    }
  }
}

/// Type of search result. Mirrors the server's `SearchResultType` enum.
enum SearchResultType {
  movie,
  tvShow,
  episode,
  collection;

  static SearchResultType fromString(String value) {
    switch (value.toUpperCase()) {
      case 'MOVIE':
        return SearchResultType.movie;
      case 'TV_SHOW':
        return SearchResultType.tvShow;
      case 'EPISODE':
        return SearchResultType.episode;
      case 'COLLECTION':
        return SearchResultType.collection;
      default:
        return SearchResultType.movie;
    }
  }

  /// Parses the `type` URL query parameter. Returns null when absent or unknown.
  static SearchResultType? fromQueryValue(String? value) {
    if (value == null) return null;
    for (final type in SearchResultType.values) {
      if (type.queryValue == value.toLowerCase()) return type;
    }
    return null;
  }

  /// The GraphQL enum literal.
  String get apiValue {
    switch (this) {
      case SearchResultType.movie:
        return 'MOVIE';
      case SearchResultType.tvShow:
        return 'TV_SHOW';
      case SearchResultType.episode:
        return 'EPISODE';
      case SearchResultType.collection:
        return 'COLLECTION';
    }
  }

  /// The `type` URL query parameter value, as in `/search?q=alien&type=episode`.
  String get queryValue => apiValue.toLowerCase();

  /// Singular label, used on result badges.
  String get displayName {
    switch (this) {
      case SearchResultType.movie:
        return 'Movie';
      case SearchResultType.tvShow:
        return 'TV Show';
      case SearchResultType.episode:
        return 'Episode';
      case SearchResultType.collection:
        return 'Collection';
    }
  }

  /// Plural label, used on section headers and filter chips.
  String get sectionTitle {
    switch (this) {
      case SearchResultType.movie:
        return 'Movies';
      case SearchResultType.tvShow:
        return 'TV Shows';
      case SearchResultType.episode:
        return 'Episodes';
      case SearchResultType.collection:
        return 'Collections';
    }
  }
}

/// One grouped section of results.
class SearchSection {
  final SearchResultType type;
  final List<SearchResult> results;

  /// True number of matches, which may exceed [results].length.
  final int totalCount;

  const SearchSection({
    required this.type,
    required this.results,
    required this.totalCount,
  });

  factory SearchSection.fromJson(Map<String, dynamic> json) {
    return SearchSection(
      type: SearchResultType.fromString(json['type'] as String? ?? 'MOVIE'),
      results: (json['results'] as List<dynamic>?)
              ?.map((e) => SearchResult.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      totalCount: json['totalCount'] as int? ?? 0,
    );
  }
}

/// Container for grouped search results.
class SearchResults {
  final List<SearchSection> sections;
  final int totalCount;

  const SearchResults({
    required this.sections,
    required this.totalCount,
  });

  factory SearchResults.fromJson(Map<String, dynamic> json) {
    return SearchResults(
      sections: (json['sections'] as List<dynamic>?)
              ?.map((e) => SearchSection.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      totalCount: json['totalCount'] as int? ?? 0,
    );
  }

  static const empty = SearchResults(sections: [], totalCount: 0);

  bool get isEmpty => sections.isEmpty;
}
