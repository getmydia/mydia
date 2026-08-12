import 'artwork.dart';
import 'media_file.dart';
import 'progress.dart';

class ContinueWatchingItem {
  final String id;
  final String type;
  final String title;
  final Artwork? artwork;
  final Progress? progress;
  final String? state;
  final String? showId;
  final String? showTitle;
  final int? seasonNumber;
  final int? episodeNumber;
  final List<MediaFile> files;

  const ContinueWatchingItem({
    required this.id,
    required this.type,
    required this.title,
    this.artwork,
    this.progress,
    this.state,
    this.showId,
    this.showTitle,
    this.seasonNumber,
    this.episodeNumber,
    this.files = const [],
  });

  factory ContinueWatchingItem.fromJson(Map<String, dynamic> json) {
    return ContinueWatchingItem(
      id: json['id'].toString(),
      type: json['type'] as String,
      title: json['title'] as String,
      artwork: json['artwork'] != null
          ? Artwork.fromJson(json['artwork'] as Map<String, dynamic>)
          : null,
      progress: json['progress'] != null
          ? Progress.fromJson(json['progress'] as Map<String, dynamic>)
          : null,
      state: json['state'] as String?,
      showId: json['showId'] as String?,
      showTitle: json['showTitle'] as String?,
      seasonNumber: json['seasonNumber'] as int?,
      episodeNumber: json['episodeNumber'] as int?,
      files: (json['files'] as List<dynamic>?)
              ?.map((e) => MediaFile.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  bool get isEpisode => type.toLowerCase() == 'episode';
  bool get isMovie => type.toLowerCase() == 'movie';

  String get displayTitle {
    final show = showTitle;
    final season = seasonNumber;
    final episode = episodeNumber;

    if (isEpisode && show != null && season != null && episode != null) {
      // Zero-padded to match NextUpEpisode, NextEpisode, Episode and
      // EpisodeDetail. This string becomes the player title, so an unpadded
      // form here would show the same episode as S2E5 from this rail and
      // S02E05 from the show detail hero.
      final code = 'S${season.toString().padLeft(2, '0')}'
          'E${episode.toString().padLeft(2, '0')}';
      return '$show - $code';
    }
    return title;
  }

  /// The zero-padded season and episode code, or null for a movie.
  String? get episodeCode {
    final season = seasonNumber;
    final episode = episodeNumber;
    if (!isEpisode || season == null || episode == null) return null;

    return 'S${season.toString().padLeft(2, '0')}'
        'E${episode.toString().padLeft(2, '0')}';
  }

  /// Whether this card is the next episode rather than a resume point.
  ///
  /// Falls back to inferring from a zero saved position because a server older
  /// than the merged rail does not send `state` at all, and the player reaches
  /// those through the legacy query document.
  bool get isNext {
    final state = this.state;
    if (state != null) return state == 'next';

    return (progress?.positionSeconds ?? 0) == 0;
  }

  /// The rail card's second line. Null for movies, which carry their title
  /// alone.
  String? get railSubtitle {
    final code = episodeCode;
    if (code == null) return null;

    if (isNext) return 'Next up · $code';

    final show = showTitle;
    return show == null ? code : '$show · $code';
  }

  String? get posterUrl => artwork?.posterUrl;
  String? get backdropUrl => artwork?.backdropUrl;
}
