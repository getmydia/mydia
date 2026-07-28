import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/models/cast_device.dart';
import '../player/progress_service.dart';
import 'cast_backend.dart';
import 'cast_route_resolver.dart';
import 'cast_session_store.dart';

/// Everything the UI knows about the item it wants to cast.
class CastLaunchRequest {
  final String fileId;
  final String mediaId;
  final String mediaType;
  final String title;
  final String? subtitleLabel;
  final String? imageUrl;
  final Duration? startPosition;
  final List<CastSubtitleTrack> subtitles;

  const CastLaunchRequest({
    required this.fileId,
    required this.mediaId,
    required this.mediaType,
    required this.title,
    this.subtitleLabel,
    this.imageUrl,
    this.startPosition,
    this.subtitles = const [],
  });
}

/// Owns the active cast session: routing, playback, progress and persistence.
class CastSessionManager {
  final CastBackend _backend;
  final CastSessionStore _store;
  final ProgressService _progressService;
  final CastRouteResolver Function() _resolverFactory;
  final Future<void> Function(bool enabled) _setLanAccess;
  final DateTime Function() _clock;

  final _sessions = StreamController<CastSession?>.broadcast();

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<CastPlaybackState>? _stateSub;
  StreamSubscription<CastFailureKind>? _failureSub;

  CastSession? _current;
  PersistedCastSession? _persisted;
  Duration _lastDuration = Duration.zero;
  DateTime? _lastProgressSync;
  bool _lanEnabled = false;

  /// How often receiver position is pushed to the server, matching the
  /// cadence local playback uses.
  static const _progressInterval = Duration(seconds: 10);

  CastSessionManager({
    required CastBackend backend,
    required CastSessionStore store,
    required ProgressService progressService,
    required CastRouteResolver Function() resolverFactory,
    required Future<void> Function(bool enabled) setLanAccess,
    DateTime Function()? clock,
  })  : _backend = backend,
        _store = store,
        _progressService = progressService,
        _resolverFactory = resolverFactory,
        _setLanAccess = setLanAccess,
        _clock = clock ?? DateTime.now;

  Stream<CastSession?> get sessionStream => _sessions.stream;
  CastSession? get currentSession => _current;

  Future<void> startCast({
    required CastDevice device,
    required CastLaunchRequest request,
  }) async {
    final resolver = _resolverFactory();

    final route = resolver.resolve(
      fileId: request.fileId,
      protocol: device.protocol,
    );

    if (route == null) {
      throw const CastBackendException(
        'No usable route to the receiver: the server is unreachable and this '
        'device has no LAN address to serve from.',
        CastFailureKind.unreachable,
      );
    }

    await _backend.connect(device);
    _listenToBackend(request);

    try {
      await _loadOnRoute(resolver, route, device, request);
    } on CastBackendException catch (e) {
      final retryRoute = _retryRouteFor(e, route, resolver, device, request);
      if (retryRoute == null) rethrow;

      await _loadOnRoute(resolver, retryRoute, device, request);
    }
  }

  /// Pick a second attempt for a failed load, or null to give up.
  ///
  /// Two distinct failures need two distinct remedies: an unreachable URL
  /// needs a *different route*, while a rejected file needs a *different
  /// encoding*. Retrying the wrong one wastes the user's time.
  CastRoute? _retryRouteFor(
    CastBackendException e,
    CastRoute attempted,
    CastRouteResolver resolver,
    CastDevice device,
    CastLaunchRequest request,
  ) {
    switch (e.kind) {
      case CastFailureKind.unreachable:
        // Usually AP isolation, a VLAN, or guest wifi. Serve it ourselves.
        if (attempted.kind == CastRouteKind.localBridge) return null;

        debugPrint('[CastSessionManager] Direct route failed, retrying via bridge');
        return resolver.resolve(
          fileId: request.fileId,
          protocol: device.protocol,
          forceBridge: true,
        );

      case CastFailureKind.mediaLoadFailed:
        // The receiver rejected the file itself — nearly always a codec it
        // cannot decode. Escalate to a full transcode.
        if (attempted.mediaUrl.contains('strategy=TRANSCODE')) return null;

        debugPrint('[CastSessionManager] Media rejected, retrying with TRANSCODE');
        return resolver.resolve(
          fileId: request.fileId,
          protocol: device.protocol,
          forceBridge: attempted.kind == CastRouteKind.localBridge,
          forceTranscode: true,
        );

      case CastFailureKind.connectionLost:
      case CastFailureKind.discoveryDenied:
      case CastFailureKind.unknown:
        return null;
    }
  }

  Future<void> _loadOnRoute(
    CastRouteResolver resolver,
    CastRoute route,
    CastDevice device,
    CastLaunchRequest request,
  ) async {
    if (route.kind == CastRouteKind.localBridge && !_lanEnabled) {
      await _setLanAccess(true);
      _lanEnabled = true;
    }

    final subtitles = route.subtitlesSupported
        ? request.subtitles
            .map((track) => CastSubtitleTrack(
                  url: resolver.resolveSubtitleUrl(route, track.url) ?? track.url,
                  label: track.label,
                  language: track.language,
                ))
            .toList()
        : const <CastSubtitleTrack>[];

    await _backend.loadMedia(CastMediaRequest(
      url: route.mediaUrl,
      kind: route.mediaKind,
      title: request.title,
      subtitle: request.subtitleLabel,
      imageUrl: request.imageUrl,
      startPosition: request.startPosition,
      subtitles: subtitles,
    ));

    _persisted = PersistedCastSession(
      device: device,
      mediaId: request.mediaId,
      mediaType: request.mediaType,
      fileId: request.fileId,
      title: request.title,
      position: request.startPosition ?? Duration.zero,
      routeKind: route.kind,
      savedAt: _clock(),
    );
    await _store.save(_persisted!);

    _publish(CastSession(
      device: device,
      playbackState: CastPlaybackState.buffering,
      mediaInfo: CastMediaInfo(
        title: request.title,
        subtitle: request.subtitleLabel,
        imageUrl: request.imageUrl,
        duration: Duration.zero,
        position: request.startPosition ?? Duration.zero,
      ),
    ));
  }

  void _listenToBackend(CastLaunchRequest request) {
    _cancelSubscriptions();

    _durationSub = _backend.durationStream.listen((duration) {
      _lastDuration = duration;
      _updateMediaInfo(duration: duration);
    });

    _positionSub = _backend.positionStream.listen((position) {
      _updateMediaInfo(position: position);
      unawaited(_syncProgress(request, position));
    });

    _stateSub = _backend.stateStream.listen((state) {
      final current = _current;
      if (current == null) return;
      _publish(current.copyWith(playbackState: state));
    });

    // A receiver that disappears must not leave controls that quietly do
    // nothing. The stored session is deliberately kept so the user can
    // reconnect to it.
    _failureSub = _backend.failureStream.listen((failure) {
      if (failure != CastFailureKind.connectionLost) return;

      final current = _current;
      if (current == null) return;

      debugPrint('[CastSessionManager] Receiver lost; marking session stale');
      _publish(current.copyWith(
        isStale: true,
        playbackState: CastPlaybackState.idle,
      ));
    });
  }

  Future<void> _syncProgress(CastLaunchRequest request, Duration position) async {
    if (_lastDuration == Duration.zero) return;

    final now = _clock();
    final last = _lastProgressSync;
    if (last != null && now.difference(last) < _progressInterval) return;
    _lastProgressSync = now;

    final persisted = _persisted;
    if (persisted != null) {
      _persisted = persisted.copyWith(position: position, savedAt: now);
      await _store.save(_persisted!);
    }

    if (request.mediaType == 'episode') {
      await _progressService.syncEpisodePosition(
        request.mediaId,
        position,
        _lastDuration,
      );
    } else {
      await _progressService.syncMoviePosition(
        request.mediaId,
        position,
        _lastDuration,
      );
    }
  }

  void _updateMediaInfo({Duration? position, Duration? duration}) {
    final current = _current;
    final info = current?.mediaInfo;
    if (current == null || info == null) return;

    _publish(current.copyWith(
      mediaInfo: info.copyWith(position: position, duration: duration),
    ));
  }

  Future<void> play() => _backend.play();
  Future<void> pause() => _backend.pause();
  Future<void> seek(Duration position) => _backend.seek(position);

  Future<void> stopCast() async {
    _cancelSubscriptions();

    try {
      await _backend.stop();
    } catch (e) {
      debugPrint('[CastSessionManager] Ignoring stop error: $e');
    }

    await _backend.disconnect();
    await _store.clear();

    if (_lanEnabled) {
      await _setLanAccess(false);
      _lanEnabled = false;
    }

    _persisted = null;
    _lastDuration = Duration.zero;
    _lastProgressSync = null;
    _publish(null);
  }

  /// Reattach to a session left running by a previous app launch.
  ///
  /// Returns true when a session was restored. Anything that goes wrong
  /// clears the stored session rather than leaving a phantom in the UI.
  Future<bool> restoreSession() async {
    final stored = await _store.load();
    if (stored == null) return false;

    if (stored.isExpired(_clock())) {
      await _store.clear();
      return false;
    }

    try {
      await _backend.connect(stored.device);
    } catch (e) {
      debugPrint('[CastSessionManager] Reconnect failed: $e');
      await _store.clear();
      return false;
    }

    _persisted = stored;
    _publish(CastSession(
      device: stored.device,
      playbackState: CastPlaybackState.buffering,
      mediaInfo: CastMediaInfo(
        title: stored.title,
        duration: Duration.zero,
        position: stored.position,
      ),
    ));

    return true;
  }

  void _publish(CastSession? session) {
    _current = session;
    _sessions.add(session);
  }

  void _cancelSubscriptions() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    _failureSub?.cancel();
    _positionSub = null;
    _durationSub = null;
    _stateSub = null;
    _failureSub = null;
  }

  void dispose() {
    _cancelSubscriptions();
    _sessions.close();
  }
}
