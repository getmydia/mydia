import 'dart:collection';

/// Serves media bytes to the platform's video pipeline from a p2p connection.
///
/// Native runs a loopback HTTP server. A browser cannot, so it registers a
/// Service Worker that claims the same paths. Both expose the same URL
/// contract through [baseUrl], so call sites build one URL for both.
///
/// One proxy is shared by every call site that needs it — playback and
/// downloads alike — so it is started and stopped against an *owner* rather
/// than outright. See [start] and [stop].
abstract class MediaProxy {
  /// Begin serving for [owner], targeting [targetPeer].
  ///
  /// [owner] is any object with a stable identity that stands for the call
  /// site relying on the proxy — a `PlayerScreen` state, a download service.
  /// Repeat calls from the same owner re-target an already running proxy and
  /// still leave it held exactly once, which is what makes this safe to call
  /// from a path that re-runs (a session restart, a cast rebind).
  Future<void> start({
    required Object owner,
    required String targetPeer,
    String? authToken,
  });

  /// Release [owner]'s hold. Serving stops once the last owner lets go.
  ///
  /// Ownership, rather than an unconditional teardown, is what keeps a screen
  /// being disposed from cutting off the screen that replaced it. Flutter
  /// mounts the incoming route before it disposes the outgoing one, so on a
  /// next-episode navigation the new screen has already started the proxy and
  /// taken its URL by the time the old screen's `dispose()` runs. An
  /// unconditional stop there closed the server underneath the episode that
  /// was just starting, and mpv opened a dead URL.
  ///
  /// Safe to call more than once, and safe to call from something that never
  /// started the proxy: both are no-ops.
  Future<void> stop(Object owner);

  /// Stop serving outright, whoever still holds it.
  ///
  /// For tearing the whole thing down — provider disposal, app shutdown —
  /// where there is no later owner left to serve.
  Future<void> shutdown();

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

/// Tracks which call sites currently need the proxy up.
///
/// Shared by both implementations so the ownership rules in [MediaProxy.start]
/// and [MediaProxy.stop] are written once. An implementation supplies only the
/// binding and teardown; when those run is decided here.
mixin MediaProxyLeases {
  /// Identity-keyed on purpose: an owner is "this particular object", never
  /// "something equal to it". A `State` that implemented `==` in terms of its
  /// route arguments would otherwise collide with its own replacement across a
  /// next-episode navigation — the exact handoff this exists to protect.
  final Set<Object> _owners = LinkedHashSet<Object>(
    equals: identical,
    hashCode: identityHashCode,
  );

  /// Whether any call site still needs the proxy up.
  bool get hasOwners => _owners.isNotEmpty;

  /// Records [owner] as needing the proxy. Idempotent per owner.
  void acquireLease(Object owner) => _owners.add(owner);

  /// Drops [owner]'s hold, reporting whether that was the last one.
  ///
  /// False when [owner] never held it, so a stray stop cannot tear down a
  /// proxy someone else is using.
  bool releaseLease(Object owner) => _owners.remove(owner) && _owners.isEmpty;

  /// Forgets every owner, for an unconditional [MediaProxy.shutdown].
  void clearLeases() => _owners.clear();
}
