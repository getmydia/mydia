class LibraryData {
  final List<LibraryItem> items;
  final bool hasMore;
  final int? totalCount;

  /// Cursor for the next page, taken from the merged `pageInfo`. Null when
  /// there is nothing more to fetch.
  final String? endCursor;

  const LibraryData({
    required this.items,
    required this.hasMore,
    this.totalCount,
    this.endCursor,
  });

  bool get isEmpty => items.isEmpty;
}

class LibraryItem {
  final String id;
  final String title;
  final int? year;
  final String? posterUrl;
  final double? progressPercentage;

  /// TMDB's score on a 0 to 10 scale, or null when the server sent none.
  /// `0.0` is TMDB's value for a title nobody has voted on and is passed
  /// through as-is; deciding what that means is the UI's job, not the model's.
  final double? rating;
  final bool isFavorite;
  final String type;
  final String? subtitle;
  final int? seasonCount;
  final int? episodeCount;

  const LibraryItem({
    required this.id,
    required this.title,
    this.year,
    this.posterUrl,
    this.progressPercentage,
    this.rating,
    required this.isFavorite,
    required this.type,
    this.subtitle,
    this.seasonCount,
    this.episodeCount,
  });
}
