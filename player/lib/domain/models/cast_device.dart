/// The wire protocol a cast receiver speaks.
enum CastProtocolKind { chromecast, dlna }

/// Represents a discovered cast receiver on the network.
class CastDevice {
  final String id;
  final String name;
  final CastProtocolKind protocol;
  final String? model;

  /// Resolved network address, when known. Persisted so a stored session can
  /// be reconnected without waiting for a full discovery sweep.
  final String? host;
  final int? port;

  /// Raw protocol metadata carried over from the `dart_cast` device this was
  /// mapped from (see `toDomainDevice` in `dart_cast_backend.dart`).
  ///
  /// Persisted alongside [host]/[port] so `DartCastBackend.connect` can
  /// reconstruct a session target after a fresh app launch, before this
  /// process has run its own discovery sweep. DLNA in particular needs this:
  /// `DlnaSession.fromDevice` reads the AVTransport/RenderingControl/
  /// ConnectionManager control URLs back out of this map.
  final Map<String, String> metadata;

  const CastDevice({
    required this.id,
    required this.name,
    required this.protocol,
    this.model,
    this.host,
    this.port,
    this.metadata = const {},
  });

  factory CastDevice.fromJson(Map<String, dynamic> json) {
    return CastDevice(
      id: json['id'] as String,
      name: json['name'] as String,
      protocol: json['protocol'] == 'dlna'
          ? CastProtocolKind.dlna
          : CastProtocolKind.chromecast,
      model: json['model'] as String?,
      host: json['host'] as String?,
      port: json['port'] as int?,
      metadata: (json['metadata'] as Map?)?.map(
            (k, v) => MapEntry(k as String, v.toString()),
          ) ??
          const {},
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'protocol': protocol == CastProtocolKind.dlna ? 'dlna' : 'chromecast',
        'model': model,
        'host': host,
        'port': port,
        'metadata': metadata,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CastDevice && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'CastDevice(id: $id, name: $name, protocol: $protocol, model: $model)';
}

/// Represents the current state of casting playback.
enum CastPlaybackState {
  idle,
  buffering,
  playing,
  paused,
}

/// Information about the media being cast.
class CastMediaInfo {
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final Duration duration;
  final Duration position;

  const CastMediaInfo({
    required this.title,
    this.subtitle,
    this.imageUrl,
    required this.duration,
    required this.position,
  });

  CastMediaInfo copyWith({
    String? title,
    String? subtitle,
    String? imageUrl,
    Duration? duration,
    Duration? position,
  }) {
    return CastMediaInfo(
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      imageUrl: imageUrl ?? this.imageUrl,
      duration: duration ?? this.duration,
      position: position ?? this.position,
    );
  }
}

/// How far the app has got with the *receiver*, independent of what is playing.
///
/// Distinct from [CastPlaybackState], which describes the media. A session can
/// be [connected] with no media at all — that is exactly what choosing a device
/// while nothing is playing produces, and it is what lets the cast icon claim
/// "connected" honestly before playback starts.
enum CastConnectionState { connecting, connected, lost }

/// A sidecar subtitle track offered to the receiver.
class CastSubtitleTrack {
  /// Mydia's own id for the track: an ffprobe stream index for an embedded
  /// track, a UUID for a sidecar one.
  ///
  /// Distinct from the numeric id the Chromecast assigns at LOAD time, which
  /// dart_cast keeps to itself. This one survives a session restart and a
  /// route change, so it is what gets persisted and what builds the
  /// session-relative URL.
  final String trackId;

  final String url;
  final String label;
  final String language;

  const CastSubtitleTrack({
    required this.trackId,
    required this.url,
    required this.label,
    required this.language,
  });

  /// Whether `id` is a shape the server can actually serve as a session
  /// subtitle.
  ///
  /// Mirrors `Mydia.Streaming.SessionSubtitles`'s `@filename_pattern`
  /// exactly (an ffprobe stream index, or a sidecar UUID) — the two must
  /// agree, because `CastRouteResolver._sessionSubtitles` builds the request
  /// URL as `subs_<trackId>.vtt` for *every* track it is handed, with no
  /// validation of its own. An id this predicate admits but the server
  /// pattern rejects (or vice versa) means a receiver either gets a 404 with
  /// no subtitles, or a track that should have worked gets silently dropped
  /// before it ever reaches the request.
  ///
  /// This is what keeps a `mk_<n>` id — media_kit's own synthetic id for a
  /// direct-play embedded track, built in `_detectTracks`, which the server
  /// has never heard of — out of a cast request, while still letting through
  /// a freshly downloaded sidecar (`SubtitleTrack.fromDownload`), whose id is
  /// a real UUID but whose `url` is deliberately null.
  static final RegExp _servableIdPattern = RegExp(
    r'^([0-9]+|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$',
  );

  static bool isServableTrackId(String id) => _servableIdPattern.hasMatch(id);

  CastSubtitleTrack copyWith({String? url}) => CastSubtitleTrack(
        trackId: trackId,
        url: url ?? this.url,
        label: label,
        language: language,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CastSubtitleTrack &&
          runtimeType == other.runtimeType &&
          trackId == other.trackId &&
          url == other.url;

  @override
  int get hashCode => Object.hash(trackId, url);
}

/// Represents a connection to a receiver, with or without media on it.
class CastSession {
  final CastDevice device;
  final CastMediaInfo? mediaInfo;
  final CastPlaybackState playbackState;
  final CastConnectionState connectionState;

  /// Subtitle tracks offered to the receiver for whatever is loaded.
  ///
  /// Empty when nothing is loaded, or the loaded item carried none.
  final List<CastSubtitleTrack> subtitles;

  /// The track currently showing on the receiver, or null when subtitles are
  /// off — which is what a cast defaults to (see `orderSubtitlesForLoad`'s
  /// dartdoc in `cast_session_manager.dart`).
  final CastSubtitleTrack? selectedSubtitle;

  const CastSession({
    required this.device,
    this.mediaInfo,
    required this.playbackState,
    this.connectionState = CastConnectionState.connected,
    this.subtitles = const [],
    this.selectedSubtitle,
  });

  /// True once the receiver has dropped off the network. The UI offers a
  /// reconnect rather than showing controls that silently do nothing.
  ///
  /// Derived rather than stored so it can never disagree with
  /// [connectionState].
  bool get isStale => connectionState == CastConnectionState.lost;

  /// [clearSelectedSubtitle] is what lets a caller set [selectedSubtitle]
  /// back to null — a plain `selectedSubtitle: null` argument is
  /// indistinguishable from "leave it alone" under the `?? this.field`
  /// pattern every other field here uses, and null is a real, reachable
  /// state (subtitles off).
  CastSession copyWith({
    CastDevice? device,
    CastMediaInfo? mediaInfo,
    CastPlaybackState? playbackState,
    CastConnectionState? connectionState,
    List<CastSubtitleTrack>? subtitles,
    CastSubtitleTrack? selectedSubtitle,
    bool clearSelectedSubtitle = false,
  }) {
    return CastSession(
      device: device ?? this.device,
      mediaInfo: mediaInfo ?? this.mediaInfo,
      playbackState: playbackState ?? this.playbackState,
      connectionState: connectionState ?? this.connectionState,
      subtitles: subtitles ?? this.subtitles,
      selectedSubtitle: clearSelectedSubtitle
          ? null
          : (selectedSubtitle ?? this.selectedSubtitle),
    );
  }
}
