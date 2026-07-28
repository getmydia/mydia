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

  const CastDevice({
    required this.id,
    required this.name,
    required this.protocol,
    this.model,
    this.host,
    this.port,
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
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'protocol': protocol == CastProtocolKind.dlna ? 'dlna' : 'chromecast',
        'model': model,
        'host': host,
        'port': port,
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

/// Represents an active casting session.
class CastSession {
  final CastDevice device;
  final CastMediaInfo? mediaInfo;
  final CastPlaybackState playbackState;

  /// True once the receiver has dropped off the network. The UI offers a
  /// reconnect rather than showing controls that silently do nothing.
  final bool isStale;

  const CastSession({
    required this.device,
    this.mediaInfo,
    required this.playbackState,
    this.isStale = false,
  });

  CastSession copyWith({
    CastDevice? device,
    CastMediaInfo? mediaInfo,
    CastPlaybackState? playbackState,
    bool? isStale,
  }) {
    return CastSession(
      device: device ?? this.device,
      mediaInfo: mediaInfo ?? this.mediaInfo,
      playbackState: playbackState ?? this.playbackState,
      isStale: isStale ?? this.isStale,
    );
  }
}
