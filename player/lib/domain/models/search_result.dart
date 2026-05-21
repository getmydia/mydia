/// Represents a search result item (movie or TV show).
class SearchResult {
  final String id;
  final SearchResultType type;
  final String title;
  final int? year;
  final String? overview;
  final String? posterUrl;
  final String? backdropUrl;
  final double? score;

  const SearchResult({
    required this.id,
    required this.type,
    required this.title,
    this.year,
    this.overview,
    this.posterUrl,
    this.backdropUrl,
    this.score,
  });

  factory SearchResult.fromJson(Map<String, dynamic> json) {
    return SearchResult(
      id: json['id'].toString(),
      type: SearchResultType.fromString(json['type'] as String),
      title: json['title'] as String? ?? 'Unknown',
      year: json['year'] as int?,
      overview: json['overview'] as String?,
      posterUrl: json['posterUrl'] as String?,
      backdropUrl: json['backdropUrl'] as String?,
      score: (json['score'] as num?)?.toDouble(),
    );
  }

  /// Year display string
  String get yearDisplay => year?.toString() ?? '';

  /// Route path for this result
  String get routePath =>
      type == SearchResultType.movie ? '/movie/$id' : '/show/$id';
}

/// Type of search result
enum SearchResultType {
  movie,
  tvShow;

  static SearchResultType fromString(String value) {
    switch (value.toUpperCase()) {
      case 'MOVIE':
        return SearchResultType.movie;
      case 'TV_SHOW':
        return SearchResultType.tvShow;
      default:
        return SearchResultType.movie;
    }
  }

  String get apiValue {
    switch (this) {
      case SearchResultType.movie:
        return 'MOVIE';
      case SearchResultType.tvShow:
        return 'TV_SHOW';
    }
  }

  String get displayName {
    switch (this) {
      case SearchResultType.movie:
        return 'Movie';
      case SearchResultType.tvShow:
        return 'TV Show';
    }
  }
}

/// Container for search results
class SearchResults {
  final List<SearchResult> results;
  final int totalCount;

  const SearchResults({
    required this.results,
    required this.totalCount,
  });

  factory SearchResults.fromJson(Map<String, dynamic> json) {
    return SearchResults(
      results: (json['results'] as List<dynamic>?)
              ?.map((e) => SearchResult.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      totalCount: json['totalCount'] as int? ?? 0,
    );
  }

  static const empty = SearchResults(results: [], totalCount: 0);
}
