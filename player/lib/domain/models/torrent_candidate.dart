import 'package:flutter/foundation.dart';

@immutable
class TorrentCandidate {
  final String title;
  final int size;
  final int? seeders;
  final int? leechers;
  final String magnetLink;
  final String indexer;
  final String? quality;
  final double healthScore;

  const TorrentCandidate({
    required this.title,
    required this.size,
    this.seeders,
    this.leechers,
    required this.magnetLink,
    required this.indexer,
    this.quality,
    required this.healthScore,
  });

  factory TorrentCandidate.fromJson(Map<String, dynamic> json) {
    return TorrentCandidate(
      title: json['title'] as String,
      size: json['size'] as int,
      seeders: json['seeders'] as int?,
      leechers: json['leechers'] as int?,
      magnetLink: json['magnetLink'] as String,
      indexer: json['indexer'] as String,
      quality: json['quality'] as String?,
      healthScore: (json['healthScore'] as num).toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TorrentCandidate &&
          runtimeType == other.runtimeType &&
          title == other.title &&
          size == other.size &&
          seeders == other.seeders &&
          leechers == other.leechers &&
          magnetLink == other.magnetLink &&
          indexer == other.indexer &&
          quality == other.quality &&
          healthScore == other.healthScore;

  @override
  int get hashCode =>
      title.hashCode ^
      size.hashCode ^
      seeders.hashCode ^
      leechers.hashCode ^
      magnetLink.hashCode ^
      indexer.hashCode ^
      quality.hashCode ^
      healthScore.hashCode;

  String get formattedSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
