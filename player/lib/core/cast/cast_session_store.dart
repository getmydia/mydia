import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../../domain/models/cast_device.dart';
import 'cast_route_resolver.dart';

/// Enough state to reattach to a cast session after the app restarts.
class PersistedCastSession {
  final CastDevice device;
  final String mediaId;
  final String mediaType;
  final String fileId;
  final String title;
  final Duration position;
  final CastRouteKind routeKind;
  final DateTime savedAt;

  /// The item's runtime as the *app* knows it, not as the receiver reports it.
  ///
  /// Persisted because a Chromecast never learns the length of the live-style
  /// HLS playlists Mydia serves — so a reconnect that did not carry this
  /// across would come back with an unknown duration and a scrub bar that
  /// cannot be dragged. Zero means "was not known when this was saved".
  final Duration duration;

  /// The exact URL handed to the receiver.
  ///
  /// Persisted so a restore can ask the receiver what it is playing and
  /// compare, instead of connecting blind and evicting whatever app the user
  /// started in the meantime.
  final String mediaUrl;

  /// The track the viewer had showing, by Mydia's own track id.
  ///
  /// The id alone, not the list: the list is rebuilt from the route on
  /// restore, and a persisted copy would go stale the moment the file's
  /// subtitles changed. Null means off, which is also what a record written
  /// before this field existed restores as.
  final String? selectedSubtitleTrackId;

  const PersistedCastSession({
    required this.device,
    required this.mediaId,
    required this.mediaType,
    required this.fileId,
    required this.title,
    required this.position,
    required this.routeKind,
    required this.savedAt,
    this.mediaUrl = '',
    this.duration = Duration.zero,
    this.selectedSubtitleTrackId,
  });

  /// Sessions older than this are discarded without a reconnect attempt.
  static const maxAge = Duration(hours: 12);

  bool isExpired(DateTime now) => now.difference(savedAt) > maxAge;

  Map<String, dynamic> toMap() => {
        'device': device.toJson(),
        'mediaId': mediaId,
        'mediaType': mediaType,
        'fileId': fileId,
        'title': title,
        'positionSeconds': position.inSeconds,
        'routeKind':
            routeKind == CastRouteKind.localBridge ? 'bridge' : 'direct',
        'savedAt': savedAt.toIso8601String(),
        'mediaUrl': mediaUrl,
        'durationSeconds': duration.inSeconds,
        'selectedSubtitleTrackId': selectedSubtitleTrackId,
      };

  factory PersistedCastSession.fromMap(Map<dynamic, dynamic> map) {
    return PersistedCastSession(
      device: CastDevice.fromJson(
        Map<String, dynamic>.from(map['device'] as Map),
      ),
      mediaId: map['mediaId'] as String,
      mediaType: map['mediaType'] as String,
      fileId: map['fileId'] as String,
      title: map['title'] as String,
      position: Duration(seconds: map['positionSeconds'] as int),
      routeKind: map['routeKind'] == 'bridge'
          ? CastRouteKind.localBridge
          : CastRouteKind.directServer,
      savedAt: DateTime.parse(map['savedAt'] as String),
      // Records written before cast restore learned to probe the receiver
      // carry no URL; an empty one can never match, so they are discarded
      // rather than restored blind.
      mediaUrl: map['mediaUrl'] as String? ?? '',
      // Records written before the cast session carried a duration have no
      // such key; zero reads as "unknown", which the UI already handles.
      duration: Duration(seconds: map['durationSeconds'] as int? ?? 0),
      // Records written before subtitle selection was persisted carry no
      // such key at all; that reads the same as an explicit off.
      selectedSubtitleTrackId: map['selectedSubtitleTrackId'] as String?,
    );
  }

  /// [selectedSubtitleTrackId] can't just be `String?`, because passing null
  /// would then be ambiguous between "leave unchanged" and "turn subtitles
  /// off" — [clearSelectedSubtitle] says the latter, mirroring
  /// `CastLaunchRequest.copyWith`.
  PersistedCastSession copyWith({
    Duration? position,
    DateTime? savedAt,
    Duration? duration,
    String? selectedSubtitleTrackId,
    bool clearSelectedSubtitle = false,
  }) {
    return PersistedCastSession(
      device: device,
      mediaId: mediaId,
      mediaType: mediaType,
      fileId: fileId,
      title: title,
      position: position ?? this.position,
      routeKind: routeKind,
      savedAt: savedAt ?? this.savedAt,
      mediaUrl: mediaUrl,
      duration: duration ?? this.duration,
      selectedSubtitleTrackId: clearSelectedSubtitle
          ? null
          : (selectedSubtitleTrackId ?? this.selectedSubtitleTrackId),
    );
  }
}

abstract class CastSessionStore {
  Future<void> save(PersistedCastSession session);
  Future<PersistedCastSession?> load();
  Future<void> clear();
}

/// Hive-backed store. Uses a plain `Box<Map>` with no type adapter, matching
/// the pattern in `core/downloads/collection_sync_providers.dart`.
class HiveCastSessionStore implements CastSessionStore {
  static const boxName = 'cast_session';
  static const _key = 'session';

  final Box<Map> _box;

  const HiveCastSessionStore(this._box);

  @override
  Future<void> save(PersistedCastSession session) async {
    await _box.put(_key, session.toMap());
  }

  @override
  Future<PersistedCastSession?> load() async {
    final raw = _box.get(_key);
    if (raw == null) return null;

    try {
      return PersistedCastSession.fromMap(raw);
    } catch (e) {
      // A malformed record must never block startup.
      debugPrint('[CastSessionStore] Discarding unreadable session: $e');
      await clear();
      return null;
    }
  }

  @override
  Future<void> clear() async => _box.delete(_key);
}

class InMemoryCastSessionStore implements CastSessionStore {
  PersistedCastSession? _session;

  @override
  Future<void> save(PersistedCastSession session) async => _session = session;

  @override
  Future<PersistedCastSession?> load() async => _session;

  @override
  Future<void> clear() async => _session = null;
}
