/// Represents an available AirPlay device on the network.
class AirPlayDevice {
  final String id;
  final String name;
  final String? model;

  const AirPlayDevice({required this.id, required this.name, this.model});

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AirPlayDevice && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'AirPlayDevice(id: $id, name: $name, model: $model)';
}

/// Represents the current state of AirPlay playback.
enum AirPlayPlaybackState { idle, buffering, playing, paused }

/// Information about the media being sent to AirPlay.
class AirPlayMediaInfo {
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final Duration duration;
  final Duration position;

  const AirPlayMediaInfo({
    required this.title,
    this.subtitle,
    this.imageUrl,
    required this.duration,
    required this.position,
  });

  AirPlayMediaInfo copyWith({
    String? title,
    String? subtitle,
    String? imageUrl,
    Duration? duration,
    Duration? position,
  }) {
    return AirPlayMediaInfo(
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      imageUrl: imageUrl ?? this.imageUrl,
      duration: duration ?? this.duration,
      position: position ?? this.position,
    );
  }
}

/// Represents an active AirPlay session.
class AirPlaySession {
  final AirPlayDevice device;
  final AirPlayMediaInfo? mediaInfo;
  final AirPlayPlaybackState playbackState;

  const AirPlaySession({
    required this.device,
    this.mediaInfo,
    required this.playbackState,
  });

  AirPlaySession copyWith({
    AirPlayDevice? device,
    AirPlayMediaInfo? mediaInfo,
    AirPlayPlaybackState? playbackState,
  }) {
    return AirPlaySession(
      device: device ?? this.device,
      mediaInfo: mediaInfo ?? this.mediaInfo,
      playbackState: playbackState ?? this.playbackState,
    );
  }
}
