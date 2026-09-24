import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cache/poster_cache_manager.dart';
import '../remote/remote_target_controller.dart';
import '../window/desktop_window.dart';
import 'media_session_state.dart';
import 'now_playing_metadata_resolver.dart';
import 'platform_media_session.dart';
import 'system_media_session.dart';

/// Downloads a poster and returns an absolute local path, or null.
typedef ArtworkLoader = Future<String?> Function(String url);

/// Mirrors whatever player is attached to [RemoteTargetController] onto the
/// OS media session, and feeds OS commands back through the same controller
/// p2p remote control uses.
class MediaSessionBridge {
  MediaSessionBridge({
    required RemoteTargetController controller,
    required Future<SystemMediaSession> Function() createSession,
    required NowPlayingMetadataResolver resolver,
    required ArtworkLoader loadArtwork,
    required Future<void> Function() raiseWindow,
  })  : _controller = controller,
        _createSession = createSession,
        _resolver = resolver,
        _loadArtwork = loadArtwork,
        _raiseWindow = raiseWindow;

  final RemoteTargetController _controller;
  final Future<SystemMediaSession> Function() _createSession;
  final NowPlayingMetadataResolver _resolver;
  final ArtworkLoader _loadArtwork;
  final Future<void> Function() _raiseWindow;

  SystemMediaSession _session = NoopMediaSession();
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _artwork = <String, Future<String?>>{};
  int _generation = 0;
  bool _disposed = false;

  Future<void> start() async {
    try {
      _session = await _createSession();
    } catch (e) {
      debugPrint('[MediaSession] unavailable, continuing without it: $e');
      _session = NoopMediaSession();
    }
    if (_disposed) {
      await _session.dispose();
      return;
    }
    // No OS session to mirror onto (every non-Linux platform today, or a
    // Linux session that failed to connect): skip subscribing to player
    // changes entirely, so a no-op session never triggers metadata lookups
    // or artwork downloads for a "now playing" surface nobody can see.
    if (_session is NoopMediaSession) return;
    _subscriptions
      ..add(_controller.changes.listen((_) => unawaited(_refresh())))
      ..add(_session.commands.listen(_controller.submit))
      ..add(_session.raiseRequests.listen((_) => unawaited(_raise())));
    await _refresh();
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    final first = _controller.snapshot();
    NowPlayingMetadata? metadata;
    String? artworkPath;
    if (first != null) {
      metadata = await _resolver.resolve(
          mediaItemId: first.mediaItemId, episodeId: first.episodeId);
      final url = metadata?.posterUrl;
      if (url != null) {
        final load = _artwork.putIfAbsent(url, () => _safeLoad(url));
        artworkPath = await load;
        // A transient failure must not be cached forever: drop it so the
        // next change event retries, unless a newer load already replaced
        // this entry.
        if (artworkPath == null && _artwork[url] == load) {
          _artwork.remove(url);
        }
      }
    }
    // A newer change arrived while this one awaited; it will push instead.
    if (_disposed || generation != _generation) return;

    // Re-read after the awaits so status and position are current. A player
    // swapped in meanwhile would have bumped the generation above.
    final state = mediaSessionStateFrom(_controller.snapshot(),
        metadata: metadata, artworkPath: artworkPath);
    try {
      await _session.update(state);
    } catch (e) {
      debugPrint('[MediaSession] update failed: $e');
    }
  }

  Future<String?> _safeLoad(String url) async {
    try {
      return await _loadArtwork(url);
    } catch (e) {
      debugPrint('[MediaSession] artwork unavailable: $e');
      return null;
    }
  }

  Future<void> _raise() async {
    try {
      await _raiseWindow();
    } catch (e) {
      debugPrint('[MediaSession] raise failed: $e');
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    await _session.dispose();
  }
}

/// One bridge for the app's lifetime; `app.dart` starts it.
final mediaSessionBridgeProvider = Provider<MediaSessionBridge>((ref) {
  final controller = ref.read(remoteTargetControllerProvider);
  final bridge = MediaSessionBridge(
    controller: controller,
    createSession: () => createPlatformMediaSession(
      position: () => Duration(
          milliseconds: controller.snapshot()?.positionMs.toInt() ?? 0),
    ),
    resolver: ref.read(nowPlayingMetadataResolverProvider),
    // The same cache and fetch the poster grid uses, so a poster the user
    // just saw is already on disk. Flatpak keeps it under
    // ~/.var/app/dev.mydia.player/cache, which the host shell can read.
    loadArtwork: (url) async =>
        (await PosterCacheManager().getSingleFile(url)).path,
    raiseWindow: raiseDesktopWindow,
  );
  ref.onDispose(() => unawaited(bridge.dispose()));
  return bridge;
});
