/// What a cast plays: a Mydia file, or an item on a third-party source.
library;

import 'package:flutter/foundation.dart';

import '../../domain/sources/item.dart';
import '../sources/source.dart';

sealed class CastContent {
  const CastContent();

  /// Flat keys merged into the persisted record. `contentKind` names the
  /// subtype; a record without it was written before sources could cast and
  /// is Mydia.
  Map<String, dynamic> toMap();

  static CastContent fromMap(Map<dynamic, dynamic> map) =>
      switch (map['contentKind']) {
        'source' => SourceCastContent(
            item: ItemRef(
              sourceId: SourceId(map['sourceId'] as String),
              kind: ItemKind.values.byName(map['itemKind'] as String),
              externalId: map['externalId'] as String,
            ),
            versionId: map['versionId'] as String,
          ),
        _ => MydiaCastContent(
            fileId: map['fileId'] as String,
            mediaId: map['mediaId'] as String,
            mediaType: map['mediaType'] as String,
            showId: map['showId'] as String?,
          ),
      };
}

@immutable
final class MydiaCastContent extends CastContent {
  const MydiaCastContent({
    required this.fileId,
    required this.mediaId,
    required this.mediaType,
    this.showId,
  });

  final String fileId;
  final String mediaId;
  final String mediaType;
  final String? showId;

  bool get isEpisode => mediaType == 'episode';

  MydiaCastContent withShowId(String? showId) => MydiaCastContent(
        fileId: fileId,
        mediaId: mediaId,
        mediaType: mediaType,
        showId: showId ?? this.showId,
      );

  @override
  Map<String, dynamic> toMap() => {
        'contentKind': 'mydia',
        'mediaId': mediaId,
        'mediaType': mediaType,
        'fileId': fileId,
        'showId': showId,
      };

  @override
  bool operator ==(Object other) =>
      other is MydiaCastContent &&
      other.fileId == fileId &&
      other.mediaId == mediaId &&
      other.mediaType == mediaType &&
      other.showId == showId;

  @override
  int get hashCode => Object.hash(fileId, mediaId, mediaType, showId);
}

@immutable
final class SourceCastContent extends CastContent {
  const SourceCastContent({required this.item, required this.versionId});

  final ItemRef item;

  /// The version the viewer picked: a Plex part id, a Jellyfin media source
  /// id, a Stash file id.
  final String versionId;

  @override
  Map<String, dynamic> toMap() => {
        'contentKind': 'source',
        'sourceId': item.sourceId.value,
        'itemKind': item.kind.name,
        'externalId': item.externalId,
        'versionId': versionId,
      };

  @override
  bool operator ==(Object other) =>
      other is SourceCastContent &&
      other.item == item &&
      other.versionId == versionId;

  @override
  int get hashCode => Object.hash(item, versionId);
}
