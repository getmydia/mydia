import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;

import '../../native/lib.dart';
import '../sources/files/files_ids.dart';

typedef WirePeerMember = FlutterWirePeerMember;
typedef WireWatchRecord = FlutterWireWatchRecord;
typedef WirePinRecord = FlutterWirePinRecord;

String tmdbMovieSyncKey(int tmdbId) => 'tmdb:movie:$tmdbId';

String tmdbEpisodeSyncKey(int tmdbId, int season, int episode) =>
    'tmdb:ep:$tmdbId:$season:$episode';

String unmatchedFileSyncKey(String accountId, String fileKey) =>
    'file:$accountId:$fileKey';

String pinSyncKey({required bool isShow, required String groupKey}) =>
    'pin:${isShow ? 's' : 'm'}:$groupKey';

/// Returns the canonical sync key for an [externalId] in [accountId], or null
/// when [externalId] is a provisional `p<sha16>` key or unparseable.
String? syncKeyForFilesItem({
  required String accountId,
  required String externalId,
  required bool isEpisode,
}) {
  final parsed = parseFilesId(externalId);
  if (parsed == null || parsed.isProvisional) return null;
  if (parsed.isUnmatchedFile) {
    return unmatchedFileSyncKey(accountId, parsed.fileKey!);
  }
  final tmdbId = parsed.tmdbId;
  if (tmdbId == null) return null;
  if (isEpisode) {
    if (parsed.season == null || parsed.episode == null) return null;
    return tmdbEpisodeSyncKey(tmdbId, parsed.season!, parsed.episode!);
  }
  return tmdbMovieSyncKey(tmdbId);
}

class PeerMember {
  const PeerMember({
    required this.nodeId,
    required this.deviceName,
    required this.platform,
    this.endpointAddrJson,
    required this.updatedAt,
    this.revoked = false,
  });

  final String nodeId;
  final String deviceName;
  final String platform;
  final String? endpointAddrJson;
  final int updatedAt;
  final bool revoked;

  PeerMember copyWith({
    String? nodeId,
    String? deviceName,
    String? platform,
    String? endpointAddrJson,
    int? updatedAt,
    bool? revoked,
  }) {
    return PeerMember(
      nodeId: nodeId ?? this.nodeId,
      deviceName: deviceName ?? this.deviceName,
      platform: platform ?? this.platform,
      endpointAddrJson: endpointAddrJson ?? this.endpointAddrJson,
      updatedAt: updatedAt ?? this.updatedAt,
      revoked: revoked ?? this.revoked,
    );
  }

  Map<String, dynamic> toMap() => {
        'nodeId': nodeId,
        'deviceName': deviceName,
        'platform': platform,
        'endpointAddrJson': endpointAddrJson,
        'updatedAt': updatedAt,
        'revoked': revoked,
      };

  factory PeerMember.fromMap(Map<dynamic, dynamic> map) {
    return PeerMember(
      nodeId: map['nodeId'] as String,
      deviceName: map['deviceName'] as String,
      platform: map['platform'] as String,
      endpointAddrJson: map['endpointAddrJson'] as String?,
      updatedAt: (map['updatedAt'] as num).toInt(),
      revoked: map['revoked'] as bool? ?? false,
    );
  }

  FlutterWirePeerMember toWire() => FlutterWirePeerMember(
        nodeId: nodeId,
        deviceName: deviceName,
        platform: platform,
        endpointAddrJson: endpointAddrJson,
        updatedAtMs: PlatformInt64Util.from(updatedAt),
        revoked: revoked,
      );

  factory PeerMember.fromWire(FlutterWirePeerMember wire) => PeerMember(
        nodeId: wire.nodeId,
        deviceName: wire.deviceName,
        platform: wire.platform,
        endpointAddrJson: wire.endpointAddrJson,
        updatedAt: wire.updatedAtMs.toInt(),
        revoked: wire.revoked,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeerMember &&
          nodeId == other.nodeId &&
          deviceName == other.deviceName &&
          platform == other.platform &&
          endpointAddrJson == other.endpointAddrJson &&
          updatedAt == other.updatedAt &&
          revoked == other.revoked;

  @override
  int get hashCode =>
      nodeId.hashCode ^
      deviceName.hashCode ^
      platform.hashCode ^
      endpointAddrJson.hashCode ^
      updatedAt.hashCode ^
      revoked.hashCode;

  @override
  String toString() =>
      'PeerMember(nodeId: $nodeId, deviceName: $deviceName, platform: $platform, updatedAt: $updatedAt, revoked: $revoked)';
}

class PeerWatchRecord {
  const PeerWatchRecord({
    required this.key,
    required this.watched,
    this.positionSeconds,
    this.durationSeconds,
    required this.updatedAt,
    required this.landedAt,
  });

  final String key;
  final bool watched;
  final int? positionSeconds;
  final int? durationSeconds;
  final int updatedAt;
  final int landedAt;

  Map<String, dynamic> toMap() => {
        'key': key,
        'watched': watched,
        'positionSeconds': positionSeconds,
        'durationSeconds': durationSeconds,
        'updatedAt': updatedAt,
        'landedAt': landedAt,
      };

  factory PeerWatchRecord.fromMap(Map<dynamic, dynamic> map) {
    return PeerWatchRecord(
      key: map['key'] as String,
      watched: map['watched'] as bool,
      positionSeconds: (map['positionSeconds'] as num?)?.toInt(),
      durationSeconds: (map['durationSeconds'] as num?)?.toInt(),
      updatedAt: (map['updatedAt'] as num).toInt(),
      landedAt: (map['landedAt'] as num).toInt(),
    );
  }

  FlutterWireWatchRecord toWire() => FlutterWireWatchRecord(
        key: key,
        watched: watched,
        positionSeconds: positionSeconds != null
            ? PlatformInt64Util.from(positionSeconds!)
            : null,
        durationSeconds: durationSeconds != null
            ? PlatformInt64Util.from(durationSeconds!)
            : null,
        updatedAtMs: PlatformInt64Util.from(updatedAt),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeerWatchRecord &&
          key == other.key &&
          watched == other.watched &&
          positionSeconds == other.positionSeconds &&
          durationSeconds == other.durationSeconds &&
          updatedAt == other.updatedAt &&
          landedAt == other.landedAt;

  @override
  int get hashCode =>
      key.hashCode ^
      watched.hashCode ^
      positionSeconds.hashCode ^
      durationSeconds.hashCode ^
      updatedAt.hashCode ^
      landedAt.hashCode;

  @override
  String toString() =>
      'PeerWatchRecord(key: $key, watched: $watched, pos: $positionSeconds, dur: $durationSeconds, updatedAt: $updatedAt, landedAt: $landedAt)';
}

class PeerPinRecord {
  const PeerPinRecord({
    required this.key,
    required this.groupKey,
    required this.isShow,
    this.tmdbId,
    required this.pinned,
    required this.updatedAt,
    required this.landedAt,
  });

  final String key;
  final String groupKey;
  final bool isShow;
  final int? tmdbId;
  final bool pinned;
  final int updatedAt;
  final int landedAt;

  Map<String, dynamic> toMap() => {
        'key': key,
        'groupKey': groupKey,
        'isShow': isShow,
        'tmdbId': tmdbId,
        'pinned': pinned,
        'updatedAt': updatedAt,
        'landedAt': landedAt,
      };

  factory PeerPinRecord.fromMap(Map<dynamic, dynamic> map) {
    return PeerPinRecord(
      key: map['key'] as String,
      groupKey: map['groupKey'] as String,
      isShow: map['isShow'] as bool,
      tmdbId: (map['tmdbId'] as num?)?.toInt(),
      pinned: map['pinned'] as bool,
      updatedAt: (map['updatedAt'] as num).toInt(),
      landedAt: (map['landedAt'] as num).toInt(),
    );
  }

  FlutterWirePinRecord toWire() => FlutterWirePinRecord(
        key: key,
        groupKey: groupKey,
        isShow: isShow,
        tmdbId: tmdbId != null ? PlatformInt64Util.from(tmdbId!) : null,
        pinned: pinned,
        updatedAtMs: PlatformInt64Util.from(updatedAt),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeerPinRecord &&
          key == other.key &&
          groupKey == other.groupKey &&
          isShow == other.isShow &&
          tmdbId == other.tmdbId &&
          pinned == other.pinned &&
          updatedAt == other.updatedAt &&
          landedAt == other.landedAt;

  @override
  int get hashCode =>
      key.hashCode ^
      groupKey.hashCode ^
      isShow.hashCode ^
      tmdbId.hashCode ^
      pinned.hashCode ^
      updatedAt.hashCode ^
      landedAt.hashCode;

  @override
  String toString() =>
      'PeerPinRecord(key: $key, groupKey: $groupKey, isShow: $isShow, tmdbId: $tmdbId, pinned: $pinned, updatedAt: $updatedAt, landedAt: $landedAt)';
}

class PeerWatermark {
  const PeerWatermark({
    required this.lastSentLandedAt,
    required this.lastPeerNowMs,
    required this.lastSyncedAt,
  });

  final int lastSentLandedAt;
  final int lastPeerNowMs;
  final int lastSyncedAt;

  PeerWatermark copyWith({
    int? lastSentLandedAt,
    int? lastPeerNowMs,
    int? lastSyncedAt,
  }) {
    return PeerWatermark(
      lastSentLandedAt: lastSentLandedAt ?? this.lastSentLandedAt,
      lastPeerNowMs: lastPeerNowMs ?? this.lastPeerNowMs,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
    );
  }

  Map<String, dynamic> toMap() => {
        'lastSentLandedAt': lastSentLandedAt,
        'lastPeerNowMs': lastPeerNowMs,
        'lastSyncedAt': lastSyncedAt,
      };

  factory PeerWatermark.fromMap(Map<dynamic, dynamic> map) {
    return PeerWatermark(
      lastSentLandedAt: (map['lastSentLandedAt'] as num).toInt(),
      lastPeerNowMs: (map['lastPeerNowMs'] as num).toInt(),
      lastSyncedAt: (map['lastSyncedAt'] as num).toInt(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeerWatermark &&
          lastSentLandedAt == other.lastSentLandedAt &&
          lastPeerNowMs == other.lastPeerNowMs &&
          lastSyncedAt == other.lastSyncedAt;

  @override
  int get hashCode =>
      lastSentLandedAt.hashCode ^
      lastPeerNowMs.hashCode ^
      lastSyncedAt.hashCode;

  @override
  String toString() =>
      'PeerWatermark(lastSentLandedAt: $lastSentLandedAt, lastPeerNowMs: $lastPeerNowMs, lastSyncedAt: $lastSyncedAt)';
}
