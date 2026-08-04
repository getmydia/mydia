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
    if (isEpisode &&
        showTitle != null &&
        seasonNumber != null &&
        episodeNumber != null) {
      return '$showTitle - S${seasonNumber}E${episodeNumber}';
    }
    return title;
  }

  String? get posterUrl => artwork?.posterUrl;
  String? get backdropUrl => artwork?.backdropUrl;
}
