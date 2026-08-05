import 'artwork.dart';
import 'media_file.dart';
import 'progress.dart';

class ContinueWatchingItem {
  final String id;
  final String type;
  final String title;
  final Artwork? artwork;
  final Progress? progress;
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

  String? get posterUrl => artwork?.posterUrl;
  String? get backdropUrl => artwork?.backdropUrl;
}
