import 'artwork.dart';

class RecentlyAddedItem {
  final String id;
  final String type;
  final String title;
  final int? year;
  final Artwork? artwork;
  final String? addedAt;
  final int? newEpisodeCount;
  final int? latestSeasonNumber;
  final int? latestEpisodeNumber;

  const RecentlyAddedItem({
    required this.id,
    required this.type,
    required this.title,
    this.year,
    this.artwork,
    this.addedAt,
    this.newEpisodeCount,
    this.latestSeasonNumber,
    this.latestEpisodeNumber,
  });

  factory RecentlyAddedItem.fromJson(Map<String, dynamic> json) {
    return RecentlyAddedItem(
      id: json['id'].toString(),
      type: json['type'] as String,
      title: json['title'] as String,
      year: json['year'] as int?,
      artwork: json['artwork'] != null
          ? Artwork.fromJson(json['artwork'] as Map<String, dynamic>)
          : null,
      addedAt: json['addedAt'] as String?,
      newEpisodeCount: json['newEpisodeCount'] as int?,
      latestSeasonNumber: json['latestSeasonNumber'] as int?,
      latestEpisodeNumber: json['latestEpisodeNumber'] as int?,
    );
  }

  bool get isShow => type.toLowerCase() == 'tv_show';
  bool get isMovie => type.toLowerCase() == 'movie';

  String? get posterUrl => artwork?.posterUrl;
  String? get backdropUrl => artwork?.backdropUrl;
  // For compatibility with _HeroSection which checks showTitle
  String? get showTitle => null;

  String get displayTitle {
    if (year != null) {
      return '$title ($year)';
    }
    return title;
  }

  /// What arrived, for the card subtitle.
  ///
  /// Null for movies, for lists that are not windowed, and for a server too
  /// old to send the count. Names the episode when exactly one arrived and its
  /// numbers are known, since that is more useful than "1 new episode".
  String? get newContentLabel {
    final count = newEpisodeCount;
    if (count == null || count == 0) return null;

    if (count == 1 &&
        latestSeasonNumber != null &&
        latestEpisodeNumber != null) {
      final season = latestSeasonNumber!.toString().padLeft(2, '0');
      final episode = latestEpisodeNumber!.toString().padLeft(2, '0');
      return 'S${season}E$episode';
    }

    return count == 1 ? '1 new episode' : '$count new episodes';
  }
}
