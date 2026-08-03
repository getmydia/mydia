/// One item's playback position as this device knows it.
///
/// Written for downloaded media only. Streaming playback still writes
/// straight to the server, which is reachable by definition.
///
/// Serialized as a plain map rather than a generated Hive adapter, matching
/// `HiveCastSessionStore`: no build_runner step, and no type id to claim.
class LocalPlaybackProgress {
  final String mediaId;

  /// 'movie' or 'episode'. Decides which sync mutation the flush uses.
  final String mediaType;

  final int positionSeconds;
  final int durationSeconds;

  /// When this device last wrote the position. Compared against the server's
  /// `lastWatchedAt` to decide which side is newer.
  final DateTime updatedAt;

  /// When the server was last told. Null means it still does not know, which
  /// is what the reconnect flush looks for.
  final DateTime? syncedAt;

  const LocalPlaybackProgress({
    required this.mediaId,
    required this.mediaType,
    required this.positionSeconds,
    required this.durationSeconds,
    required this.updatedAt,
    this.syncedAt,
  });

  bool get isSynced => syncedAt != null;

  LocalPlaybackProgress copyWith({DateTime? syncedAt}) => LocalPlaybackProgress(
        mediaId: mediaId,
        mediaType: mediaType,
        positionSeconds: positionSeconds,
        durationSeconds: durationSeconds,
        updatedAt: updatedAt,
        syncedAt: syncedAt ?? this.syncedAt,
      );

  Map<String, dynamic> toMap() => {
        'mediaId': mediaId,
        'mediaType': mediaType,
        'positionSeconds': positionSeconds,
        'durationSeconds': durationSeconds,
        'updatedAt': updatedAt.toIso8601String(),
        'syncedAt': syncedAt?.toIso8601String(),
      };

  factory LocalPlaybackProgress.fromMap(Map<dynamic, dynamic> map) {
    final synced = map['syncedAt'] as String?;
    return LocalPlaybackProgress(
      mediaId: map['mediaId'] as String,
      mediaType: map['mediaType'] as String,
      positionSeconds: map['positionSeconds'] as int,
      durationSeconds: map['durationSeconds'] as int,
      updatedAt: DateTime.parse(map['updatedAt'] as String),
      syncedAt: synced == null ? null : DateTime.parse(synced),
    );
  }
}
