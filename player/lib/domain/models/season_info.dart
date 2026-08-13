import 'watch_status.dart';

class SeasonInfo {
  final int seasonNumber;
  final int episodeCount;
  final int airedEpisodeCount;
  final bool hasFiles;
  final WatchStatus? watchStatus;

  const SeasonInfo({
    required this.seasonNumber,
    required this.episodeCount,
    required this.airedEpisodeCount,
    required this.hasFiles,
    this.watchStatus,
  });

  factory SeasonInfo.fromJson(Map<String, dynamic> json) {
    return SeasonInfo(
      seasonNumber: json['seasonNumber'] as int,
      episodeCount: json['episodeCount'] as int? ?? 0,
      airedEpisodeCount: json['airedEpisodeCount'] as int? ?? 0,
      hasFiles: json['hasFiles'] as bool? ?? false,
      watchStatus: json['watchStatus'] == null
          ? null
          : WatchStatus.fromJson(json['watchStatus'] as Map<String, dynamic>),
    );
  }
}
