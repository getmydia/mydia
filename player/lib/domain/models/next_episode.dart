import 'media_file.dart';

class NextEpisode {
  final String id;
  final int seasonNumber;
  final int episodeNumber;
  final String? title;
  final String? airDate;
  final List<MediaFile> files;

  const NextEpisode({
    required this.id,
    required this.seasonNumber,
    required this.episodeNumber,
    this.title,
    this.airDate,
    this.files = const [],
  });

  factory NextEpisode.fromJson(Map<String, dynamic> json) {
    return NextEpisode(
      id: json['id'].toString(),
      seasonNumber: json['seasonNumber'] as int,
      episodeNumber: json['episodeNumber'] as int,
      title: json['title'] as String?,
      airDate: json['airDate'] as String?,
      files:
          (json['files'] as List<dynamic>?)
              ?.map((e) => MediaFile.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  String get episodeCode =>
      'S${seasonNumber.toString().padLeft(2, '0')}E${episodeNumber.toString().padLeft(2, '0')}';
}
