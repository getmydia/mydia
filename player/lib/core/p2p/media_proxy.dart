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
}
