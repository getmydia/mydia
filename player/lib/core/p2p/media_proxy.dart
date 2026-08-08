/// Serves media bytes to the platform's video pipeline from a p2p connection.
///
/// Native runs a loopback HTTP server. A browser cannot, so it registers a
/// Service Worker that claims the same paths. Both expose the same URL
/// contract through [baseUrl], so call sites build one URL for both.
abstract class MediaProxy {
  /// Begin serving, targeting [targetPeer].
  Future<void> start({required String targetPeer, String? authToken});

  /// Stop serving. Safe to call more than once.
  Future<void> stop();

  bool get isRunning;

  /// Origin and prefix to build media URLs against, with no trailing slash.
  ///
  /// Native: `http://127.0.0.1:52341`, or `http://192.168.1.5:52341/g/<token>`
  /// while LAN-exposed. Web: `/p2p`.
  String get baseUrl;

  /// URL of a session's HLS manifest.
  ///
  /// Declared here, rather than left to each implementation's own API, so a
  /// playback call site can hold a [MediaProxy] and not know which one it has.
  /// Both implementations build it with `MediaRoutes`, which is also what
  /// takes the path apart again on the serving side.
  String buildHlsUrl(String sessionId);

  /// URL that streams a media file's own bytes, with no transcoding.
  String buildDirectStreamUrl(String fileId);
}
