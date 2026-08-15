import '../../domain/models/cast_device.dart';
import 'cast_capabilities.dart';

/// How the receiver should interpret the media URL.
enum CastMediaKind { hls, progressive }

/// Everything a receiver needs to start playing one item.
class CastMediaRequest {
  final String url;
  final CastMediaKind kind;
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final Duration? startPosition;
  final List<CastSubtitleTrack> subtitles;

  const CastMediaRequest({
    required this.url,
    required this.kind,
    required this.title,
    this.subtitle,
    this.imageUrl,
    this.startPosition,
    this.subtitles = const [],
  });
}

/// Why a cast operation failed, in terms the UI can act on.
enum CastFailureKind {
  /// The receiver could not reach the media URL. Retry via the LAN bridge.
  unreachable,

  /// The receiver rejected the media itself, usually a codec problem.
  mediaLoadFailed,

  /// The session dropped mid-playback.
  connectionLost,

  /// The OS refused discovery (iOS local network denied, multicast lock failed).
  discoveryDenied,

  /// The OS refused this app access to the local network, so the receiver
  /// cannot be reached even though it is on the network.
  ///
  /// Distinct from [unreachable], which means the *receiver* could not reach
  /// our media. This one is a block on our own side, so no alternate media
  /// route fixes it.
  localNetworkDenied,

  unknown,
}

class CastBackendException implements Exception {
  final String message;
  final CastFailureKind kind;

  const CastBackendException(this.message, this.kind);

  @override
  String toString() => 'CastBackendException($kind): $message';
}

/// Protocol-agnostic cast transport.
///
/// This exists so the `dart_cast` dependency can be replaced with hand-written
/// protocol code without touching the session manager or any UI.
abstract class CastBackend {
  Stream<List<CastDevice>> startDiscovery({
    required CastCapabilities capabilities,
    Duration timeout = const Duration(seconds: 10),
  });

  void stopDiscovery();

  Future<void> connect(CastDevice device);
  Future<void> disconnect();

  /// What the receiver is currently playing, *without* taking it over.
  ///
  /// Returns the content URL the receiver reports, or null when the answer
  /// cannot be obtained without launching an app on it. Callers must treat
  /// null as "do not touch this receiver": on Chromecast, connecting sends
  /// `LAUNCH CC1AD845`, which evicts whatever the user is currently watching.
  Future<String?> probeReceiverContentUrl(CastDevice device);

  Future<void> loadMedia(CastMediaRequest request);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> selectSubtitle(CastSubtitleTrack? track);

  Stream<CastPlaybackState> get stateStream;
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;

  /// Failures that arrive outside a method call — chiefly the receiver
  /// dropping off the network mid-playback, which must surface as a stale
  /// session rather than a UI that silently stops updating.
  Stream<CastFailureKind> get failureStream;

  CastDevice? get connectedDevice;

  Future<void> dispose();
}
