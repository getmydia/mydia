import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/models/cast_device.dart';
import '../player/progress_service.dart';
import '../player/stream_timeline.dart';
import 'cast_backend.dart';
import 'cast_route_resolver.dart';
import 'cast_seek_restart.dart';
import 'cast_session_store.dart';
import 'cast_streaming_session_service.dart';

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

  /// The item's runtime, as the app already knows it.
  ///
  /// Required for a usable scrub bar: a Chromecast fed one of Mydia's
  /// live-style HLS playlists answers `duration: -1` forever, so the receiver
  /// is not a source of truth for length. Null means the caller genuinely
  /// does not know it yet, and the UI degrades to controls that only move
  /// relative to the current position.
  final Duration? duration;

  const CastLaunchRequest({
    required this.fileId,
    required this.mediaId,
    required this.mediaType,
    required this.title,
    this.subtitleLabel,
    this.imageUrl,
    this.startPosition,
    this.subtitles = const [],
    this.duration,
  });

  /// The same request, resumed from somewhere else.
  ///
  /// Only [startPosition] can be replaced, and passing null keeps the current
  /// one. Everything else is carried across verbatim, which is the whole
  /// point: a seek restart rebuilds the cast from this, and anything dropped
  /// here disappears from the receiver for the rest of the session.
  CastLaunchRequest copyWith({Duration? startPosition}) => CastLaunchRequest(
        fileId: fileId,
        mediaId: mediaId,
        mediaType: mediaType,
        title: title,
        subtitleLabel: subtitleLabel,
        imageUrl: imageUrl,
        startPosition: startPosition ?? this.startPosition,
        subtitles: subtitles,
        duration: duration,
      );
}

/// Owns the active cast session: routing, playback, progress and persistence.
class CastSessionManager {
  final CastBackend _backend;
  final CastSessionStore _store;
  final ProgressService _progressService;
  final CastRouteResolver Function() _resolverFactory;
  final CastStreamingSessionService _streamingSessions;
  final Future<void> Function(bool enabled) _setLanAccess;
  final DateTime Function() _clock;

  final _sessions = StreamController<CastSession?>.broadcast();

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<CastPlaybackState>? _stateSub;
  StreamSubscription<CastFailureKind>? _failureSub;

  CastSession? _current;
  PersistedCastSession? _persisted;

  /// The full request behind whatever is on the receiver right now.
  ///
  /// Kept alongside [_persisted] because the two answer different questions.
  /// [PersistedCastSession] is what has to survive the app being killed, so
  /// it carries only what a cold restore can act on; this carries everything
  /// the *live* session was launched with — subtitle tracks, artwork, the
  /// subtitle label. A seek restart rebuilds the cast from this rather than
  /// from the persisted record, which would silently drop all three for the
  /// rest of the session.
  ///
  /// Set wherever a cast actually loads ([_loadOnRoute], so every retry and
  /// escalation included) and by [restoreSession] for the branch that adopts
  /// a receiver already playing, so it is never out of step with
  /// [_persisted].
  CastLaunchRequest? _lastRequest;

  Duration _lastDuration = Duration.zero;
  DateTime? _lastProgressSync;
  bool _lanEnabled = false;

  /// Server-side HLS session backing the media currently on the receiver.
  String? _activeHlsSessionId;

  /// True while a cast-seek restart (`startCast`) is running.
  ///
  /// `startCast` re-runs the whole route-resolution/load path and mutates
  /// shared state — `_persisted`, `_activeHlsSessionId`, the backend
  /// listeners re-armed by `_listenToBackend` — across several `await`
  /// points. A user dragging a scrub bar fires `seek` faster than one
  /// restart completes; without this guard a second call reads the same
  /// stale `_persisted`/`_current` the first call already decided to act on,
  /// so both restart concurrently, and whichever call's `_adoptHlsSession`
  /// runs last tears down the session the other one just adopted — killing
  /// whatever actually ended up loaded on the receiver. Mirrors
  /// `_PlayerScreenState._isRestartingSession` in player_screen.dart, which
  /// guards the equivalent local-playback restart the same way.
  bool _isRestartingForSeek = false;

  /// Maps receiver-reported positions onto real media positions.
  ///
  /// Non-zero offset whenever a cast was resumed mid-item on an HLS route:
  /// the offset is baked into FFmpeg's `-ss`, so the receiver's zero is that
  /// far into the media. Everything that reads a receiver position goes
  /// through this, because a raw position reaching `_syncProgress` would
  /// overwrite the user's real watch position with zero.
  StreamTimeline _timeline = StreamTimeline.zero;

  /// How often receiver position is pushed to the server, matching the
  /// cadence local playback uses.
  static const _progressInterval = Duration(seconds: 10);

  CastSessionManager({
    required CastBackend backend,
    required CastSessionStore store,
    required ProgressService progressService,
    required CastRouteResolver Function() resolverFactory,
    required CastStreamingSessionService streamingSessions,
    required Future<void> Function(bool enabled) setLanAccess,
    DateTime Function()? clock,
  })  : _backend = backend,
        _store = store,
        _progressService = progressService,
        _resolverFactory = resolverFactory,
        _streamingSessions = streamingSessions,
        _setLanAccess = setLanAccess,
        _clock = clock ?? DateTime.now;

  Stream<CastSession?> get sessionStream => _sessions.stream;
  CastSession? get currentSession => _current;

  /// The item the active (or last) session is playing, for a UI that needs to
  /// re-cast it — a stale session's "Reconnect" must target the media that
  /// session was playing, not whatever screen happens to be open.
  PersistedCastSession? get persistedSession => _persisted;

  Future<void> startCast({
    required CastDevice device,
    required CastLaunchRequest request,
  }) async {
    final resolver = _resolverFactory();

    // Captured before any attempt so rollback can tell whether *this* call
    // turned LAN access on, versus it already being on from a session that
    // was mid-switch when this one started.
    final lanEnabledBeforeCall = _lanEnabled;

    // Every server-side HLS session opened while resolving routes for this
    // call. All but the one actually playing get torn down at the end.
    final startedHlsSessions = <String>[];

    CastRoute? route;
    try {
      route =
          await _resolveRoute(resolver, request, device, startedHlsSessions);
    } catch (e) {
      await _abandonStart(lanEnabledBeforeCall, startedHlsSessions);
      rethrow;
    }

    if (route == null) {
      await _abandonStart(lanEnabledBeforeCall, startedHlsSessions);
      throw const CastBackendException(
        'No usable route to the receiver: the server is unreachable and this '
        'device has no LAN address to serve from.',
        CastFailureKind.unreachable,
      );
    }

    try {
      await _backend.connect(device);
    } catch (e) {
      await _abandonStart(lanEnabledBeforeCall, startedHlsSessions);
      rethrow;
    }

    _listenToBackend(request);

    final CastRoute loaded;
    try {
      loaded = await _loadWithRetries(
        resolver,
        route,
        device,
        request,
        startedHlsSessions,
      );
    } catch (e) {
      // Nothing succeeded: leaving the backend connected, the listeners
      // live, and the LAN proxy exposed would strand the app in a state
      // with no session but an active connection and (per the Security
      // requirement) a listener with no cast in progress.
      _cancelSubscriptions();
      try {
        await _backend.disconnect();
      } catch (e) {
        debugPrint(
            '[CastSessionManager] Ignoring disconnect error during rollback: $e');
      }
      await _abandonStart(lanEnabledBeforeCall, startedHlsSessions);
      rethrow;
    }

    await _adoptHlsSession(loaded.hlsSessionId, startedHlsSessions);

    // The Security requirement is that the LAN listener exists only while a
    // bridged cast needs it. An escalation that started on the bridge and
    // ended on a direct route must not leave the proxy exposed.
    if (loaded.kind != CastRouteKind.localBridge && !lanEnabledBeforeCall) {
      await _disableLanQuietly();
    }
  }

  /// Connect to [device] with no media on it.
  ///
  /// This is what makes the cast icon's "connected" claim true before anything
  /// plays, and it moves failure to the moment the user picks a device instead
  /// of the moment they press play.
  ///
  /// Deliberately resolves **no route** and enables **no LAN access**: both
  /// need a [CastLaunchRequest], and nothing is being served yet. That is also
  /// what keeps the security rule — the LAN listener exists only while a cast
  /// is in progress — true by construction here.
  ///
  /// On failure the session is cleared and the exception rethrown. The caller
  /// keeps the chosen device, so the UI lands on "chosen, not connected" and
  /// can offer a reconnect.
  Future<void> connectTo(CastDevice device) async {
    _publish(CastSession(
      device: device,
      playbackState: CastPlaybackState.idle,
      connectionState: CastConnectionState.connecting,
    ));

    try {
      await _backend.connect(device);
    } catch (e) {
      _publish(null);
      rethrow;
    }

    _listenForConnectionLoss();

    _publish(CastSession(
      device: device,
      playbackState: CastPlaybackState.idle,
      connectionState: CastConnectionState.connected,
    ));
  }

  /// Failure-only subscription for an idle connection.
  ///
  /// A media-less session has no positions or durations worth tracking, but it
  /// must still notice the receiver going away: Google's Default Media Receiver
  /// idle-times-out after a few minutes with nothing loaded, so this fires on
  /// an ordinary browse session, not just on a network fault.
  ///
  /// `_listenToBackend` replaces this wholesale (it calls
  /// `_cancelSubscriptions` first) when media is later loaded on the same
  /// connection.
  void _listenForConnectionLoss() {
    _cancelSubscriptions();

    _failureSub = _backend.failureStream.listen((failure) {
      if (failure != CastFailureKind.connectionLost) return;

      final current = _current;
      if (current == null) return;

      debugPrint('[CastSessionManager] Receiver lost while idle');
      _publish(current.copyWith(connectionState: CastConnectionState.lost));
    });
  }

  /// Resolve a route, enabling LAN access first when the route will be a
  /// bridge one.
  ///
  /// Ordering is the whole point: `lanBaseUrl` does not exist until the proxy
  /// is LAN-bound, so asking the resolver for a bridge URL before enabling
  /// access can only ever produce null. If the bridge turns out to be
  /// impossible anyway (no LAN interface, no running proxy), access is turned
  /// straight back off rather than left on for nothing.
  Future<CastRoute?> _resolveRoute(
    CastRouteResolver resolver,
    CastLaunchRequest request,
    CastDevice device,
    List<String> startedHlsSessions, {
    bool forceBridge = false,
    bool forceTranscode = false,
  }) async {
    final wantsBridge = resolver.usesBridge(forceBridge: forceBridge);
    final enabledHere = wantsBridge && !_lanEnabled;

    if (wantsBridge) await _enableLan();

    final route = await resolver.resolve(
      fileId: request.fileId,
      protocol: device.protocol,
      forceBridge: forceBridge,
      forceTranscode: forceTranscode,
      startPosition: request.startPosition ?? Duration.zero,
    );

    if (route == null) {
      if (enabledHere) await _disableLanQuietly();
      return null;
    }

    final sessionId = route.hlsSessionId;
    if (sessionId != null) startedHlsSessions.add(sessionId);

    return route;
  }

  /// Loads media on [route], escalating through at most two further
  /// remedies before giving up. Returns the route that actually loaded.
  ///
  /// Deliberately three sequential, explicitly nested attempts and nothing
  /// more — no loop, so the bound is obvious by inspection:
  ///
  ///   1. [route] as resolved.
  ///   2. Whichever remedy [_retryRouteFor] picks for the failure. For most
  ///      failure kinds this is the only retry, and a bridge route never
  ///      gets one for `mediaLoadFailed` — dart_cast would just resend the
  ///      identical URL that just failed.
  ///   3. Only reached when attempt 1 was a *direct* route that failed with
  ///      `mediaLoadFailed` and attempt 2 was therefore a bridge retry: one
  ///      final attempt back on the *original* route with `forceTranscode`.
  ///      `mediaLoadFailed` is dart_cast's one kind for both "the receiver
  ///      couldn't reach the media" and "the receiver rejected the codec"
  ///      (see `DartCastBackend.failureKindFor`) — having ruled out the
  ///      former by trying the bridge, the codec explanation is the only
  ///      one left, regardless of why attempt 2 itself failed.
  Future<CastRoute> _loadWithRetries(
    CastRouteResolver resolver,
    CastRoute route,
    CastDevice device,
    CastLaunchRequest request,
    List<String> startedHlsSessions,
  ) async {
    try {
      await _loadOnRoute(resolver, route, device, request);
      return route;
    } on CastBackendException catch (firstFailure) {
      final secondRoute = await _retryRouteFor(
        firstFailure,
        route,
        resolver,
        device,
        request,
        startedHlsSessions,
      );
      if (secondRoute == null) rethrow;

      try {
        await _loadOnRoute(resolver, secondRoute, device, request);
        return secondRoute;
      } on CastBackendException {
        final isBridgeEscalationFromDirectMediaLoadFailed =
            firstFailure.kind == CastFailureKind.mediaLoadFailed &&
                route.kind == CastRouteKind.directServer &&
                secondRoute.kind == CastRouteKind.localBridge;

        if (!isBridgeEscalationFromDirectMediaLoadFailed) rethrow;

        final transcodeRoute = await _resolveRoute(
          resolver,
          request,
          device,
          startedHlsSessions,
          forceTranscode: true,
        );
        if (transcodeRoute == null) rethrow;

        debugPrint(
          '[CastSessionManager] Bridge retry also failed, retrying with TRANSCODE',
        );
        await _loadOnRoute(resolver, transcodeRoute, device, request);
        return transcodeRoute;
      }
    }
  }

  /// Undo the LAN exposure and server-side sessions a failed (or abandoned)
  /// [startCast] created.
  Future<void> _abandonStart(
    bool lanEnabledBeforeCall,
    List<String> startedHlsSessions,
  ) async {
    for (final id in startedHlsSessions) {
      await _streamingSessions.end(id);
    }
    startedHlsSessions.clear();

    if (!lanEnabledBeforeCall) await _disableLanQuietly();
  }

  /// Keep the session that loaded, tear down the ones that didn't — including
  /// whatever the previously cast item was using.
  Future<void> _adoptHlsSession(
    String? loadedSessionId,
    List<String> startedHlsSessions,
  ) async {
    final previous = _activeHlsSessionId;
    if (previous != null && previous != loadedSessionId) {
      await _streamingSessions.end(previous);
    }

    for (final id in startedHlsSessions) {
      if (id != loadedSessionId) await _streamingSessions.end(id);
    }
    startedHlsSessions.clear();

    _activeHlsSessionId = loadedSessionId;
  }

  /// Pick a second attempt for a failed load, or null to give up.
  ///
  /// Two distinct failures need two distinct remedies: an unreachable URL
  /// needs a *different route*, while a rejected file needs a *different
  /// encoding*. Retrying the wrong one wastes the user's time.
  Future<CastRoute?> _retryRouteFor(
    CastBackendException e,
    CastRoute attempted,
    CastRouteResolver resolver,
    CastDevice device,
    CastLaunchRequest request,
    List<String> startedHlsSessions,
  ) async {
    switch (e.kind) {
      case CastFailureKind.unreachable:
        // Usually AP isolation, a VLAN, or guest wifi. Serve it ourselves.
        if (attempted.kind == CastRouteKind.localBridge) return null;

        debugPrint(
            '[CastSessionManager] Direct route failed, retrying via bridge');
        return _resolveRoute(
          resolver,
          request,
          device,
          startedHlsSessions,
          forceBridge: true,
        );

      case CastFailureKind.mediaLoadFailed:
        // CastRouteResolver ignores forceTranscode on the bridge branch for
        // DLNA, so retrying there would just resend the identical URL that
        // just failed — a guaranteed-futile extra receiver round-trip.
        if (attempted.kind == CastRouteKind.localBridge) return null;

        // `mediaLoadFailed` is overloaded: dart_cast's Chromecast and DLNA
        // backends both surface a receiver-side LOAD failure this way
        // whether the true cause is an unsupported codec *or* the receiver
        // simply being unable to reach the media URL at all (see
        // DartCastBackend.failureKindFor). We can't tell those apart from
        // the exception alone, so try the bridge first: it fixes the
        // unreachable case. If the bridge attempt also fails, the caller
        // (_loadWithRetries) escalates once more to a transcode on the
        // original route — this function only decides the *second*
        // attempt, not the third.
        final bridgeRetry = await _resolveRoute(
          resolver,
          request,
          device,
          startedHlsSessions,
          forceBridge: true,
        );
        if (bridgeRetry != null) {
          debugPrint(
            '[CastSessionManager] Media rejected on direct route, retrying via bridge',
          );
          return bridgeRetry;
        }

        // No bridge available — this must be a genuine codec rejection.
        // Escalate to a full transcode.
        if (attempted.mediaUrl.contains('strategy=TRANSCODE')) return null;

        debugPrint(
            '[CastSessionManager] Media rejected, retrying with TRANSCODE');
        return _resolveRoute(
          resolver,
          request,
          device,
          startedHlsSessions,
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
    final subtitles = route.subtitlesSupported
        ? request.subtitles
            .map((track) => CastSubtitleTrack(
                  url: resolver.resolveSubtitleUrl(route, track.url) ??
                      track.url,
                  label: track.label,
                  language: track.language,
                ))
            .toList()
        : const <CastSubtitleTrack>[];

    _useTimeline(StreamTimeline(
      startOffset: route.startOffset,
      totalDuration: request.duration,
    ));

    await _backend.loadMedia(CastMediaRequest(
      url: route.mediaUrl,
      kind: route.mediaKind,
      title: request.title,
      subtitle: request.subtitleLabel,
      imageUrl: request.imageUrl,
      // Already baked into the stream on an HLS route, so asking the receiver
      // to seek there as well would land at twice the offset. On a
      // progressive route `startOffset` is zero and this is the whole
      // position, which is a valid byte-range seek.
      startPosition: _timeline.toPlayer(request.startPosition ?? Duration.zero),
      subtitles: subtitles,
    ));

    _lastRequest = request;

    _persisted = PersistedCastSession(
      device: device,
      mediaId: request.mediaId,
      mediaType: request.mediaType,
      fileId: request.fileId,
      title: request.title,
      position: request.startPosition ?? Duration.zero,
      routeKind: route.kind,
      savedAt: _clock(),
      mediaUrl: route.mediaUrl,
      duration: request.duration ?? Duration.zero,
    );
    await _store.save(_persisted!);

    _publish(CastSession(
      device: device,
      playbackState: CastPlaybackState.buffering,
      mediaInfo: CastMediaInfo(
        title: request.title,
        subtitle: request.subtitleLabel,
        imageUrl: request.imageUrl,
        // Seeded from what the app knows, not left at zero to wait on the
        // receiver: on HLS the receiver never reports a length at all.
        duration: request.duration ?? Duration.zero,
        position: request.startPosition ?? Duration.zero,
      ),
    ));
  }

  /// Points this manager *and* the shared [ProgressService] at [timeline].
  ///
  /// One setter because the two must never disagree: the manager translates
  /// receiver positions for the UI and for persistence, `resolveSync`
  /// translates them for the server, and a stale value on either side writes
  /// a wrong position into the user's watch history.
  void _useTimeline(StreamTimeline timeline) {
    _timeline = timeline;
    _progressService.timeline = timeline;
  }

  Future<void> _enableLan() async {
    if (_lanEnabled) return;
    await _setLanAccess(true);
    _lanEnabled = true;
  }

  /// Turn LAN exposure off, keeping `_lanEnabled` true if that fails.
  ///
  /// Clearing the flag on failure would mean a still-exposed proxy is never
  /// retried — the app would believe it had closed a listener that is in fact
  /// still serving media to the network.
  Future<void> _disableLanQuietly() async {
    if (!_lanEnabled) return;
    try {
      await _setLanAccess(false);
      _lanEnabled = false;
    } catch (e) {
      debugPrint('[CastSessionManager] Failed to disable LAN access: $e');
    }
  }

  void _listenToBackend(CastLaunchRequest request) {
    _cancelSubscriptions();

    // Casting a new item — whether via startCast or restoreSession — must
    // not inherit the previous item's duration or throttle timestamp.
    // Otherwise the first position event for the new item can sync against
    // a stale duration, writing a wrong durationSeconds (and potentially a
    // false "watched" verdict) to the user's history.
    _lastDuration = request.duration ?? Duration.zero;
    _lastProgressSync = null;

    // `_progressService` is a single long-lived instance (this manager is a
    // keep-alive provider, reused across every cast target for the life of
    // the app), so its `timeline` must be re-pointed at whatever item is
    // cast now — the same duration authority `request.duration` already
    // gives the receiver's own scrub bar (see `CastLaunchRequest.duration`'s
    // dartdoc).
    //
    // No offset yet: which route will actually load, and therefore what
    // offset the server baked in, is not known until `_loadOnRoute` runs.
    // Starting from zero rather than leaving the previous item's offset in
    // place is the safe default — an item cast after a resumed one must not
    // inherit its offset.
    _useTimeline(StreamTimeline(totalDuration: request.duration));

    _durationSub = _backend.durationStream.listen((duration) {
      // Non-positive is the receiver saying "I don't know" (Chromecast sends
      // -1 for the live-style HLS playlists Mydia serves), not a length.
      // `DartCastBackend` already filters these; the guard is repeated here
      // because the manager is backend-agnostic and a bad duration corrupts
      // both the scrub bar and the watch-history sync below.
      if (duration <= Duration.zero) return;

      _lastDuration = duration;
      _updateMediaInfo(duration: duration);
    });

    _positionSub = _backend.positionStream.listen((position) {
      // Raw to `_syncProgress`: `ProgressService.resolveSync` applies
      // `timeline.toReal` itself, and `_progressService.timeline` is the same
      // offset timeline `_useTimeline` set. Translating here as well would
      // add the offset twice.
      _updateMediaInfo(position: _timeline.toReal(position));
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
        connectionState: CastConnectionState.lost,
        playbackState: CastPlaybackState.idle,
      ));
    });
  }

  Future<void> _syncProgress(
      CastLaunchRequest request, Duration position) async {
    // `<=` rather than `== Duration.zero`: a receiver that reports -1 would
    // otherwise clear this guard and write `durationSeconds: -1` into the
    // user's watch history, along with whatever watched verdict follows from
    // dividing by it.
    if (_lastDuration <= Duration.zero) return;

    final now = _clock();
    final last = _lastProgressSync;
    if (last != null && now.difference(last) < _progressInterval) return;
    _lastProgressSync = now;

    final persisted = _persisted;
    if (persisted != null) {
      // Translated, unlike the value handed to `_progressService` below:
      // `reconnectStoredSession` feeds this straight back as `startPosition`,
      // so a receiver-relative value would compound the offset on every
      // reconnect.
      _persisted = persisted.copyWith(
        position: _timeline.toReal(position),
        savedAt: now,
      );
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

  /// Seeks to a real media position, restarting the session when the target
  /// is outside what the receiver can reach.
  ///
  /// [position] is a real media position, matching what `mediaInfo` publishes
  /// and what the scrub bar computes against `request.duration`.
  Future<void> seek(Duration position) async {
    // A restart already in flight is dropped outright, not queued: this
    // call's target is superseded either way, and the machinery it would
    // otherwise re-enter is not safe to run twice at once (see
    // `_isRestartingForSeek`'s dartdoc).
    if (_isRestartingForSeek) return;

    final session = _persisted;
    final request = _lastRequest;

    if (session == null ||
        request == null ||
        !shouldRestartCastForSeek(
          mediaKind: CastRouteResolver.mediaKindFor(session.device.protocol),
          target: position,
          currentPosition: _current?.mediaInfo?.position ?? Duration.zero,
          startOffset: _timeline.startOffset,
        )) {
      return _backend.seek(_timeline.toPlayer(position));
    }

    // Out of reach in the current stream: start a new session at the target
    // and reload the receiver on it. A visible blip, and strictly better than
    // the silent snap-back the receiver would otherwise do.
    //
    // Rebuilt from the live request, not from `session`: the persisted record
    // carries no subtitle tracks, subtitle label or artwork, so restarting
    // from it would strip all three off the receiver for the rest of the
    // session.
    _isRestartingForSeek = true;
    try {
      await startCast(
        device: session.device,
        request: request.copyWith(startPosition: position),
      );
    } finally {
      _isRestartingForSeek = false;
    }
  }

  /// Re-cast whatever the stored session was playing.
  ///
  /// The stale-session UI needs this: a "Reconnect" that re-casts the screen
  /// the user happens to be on would silently start a different item.
  Future<void> reconnectStoredSession() async {
    final stored = _persisted ?? await _store.load();
    if (stored == null) {
      throw const CastBackendException(
        'There is no cast session to reconnect to.',
        CastFailureKind.unknown,
      );
    }

    await startCast(
      device: stored.device,
      request: CastLaunchRequest(
        fileId: stored.fileId,
        mediaId: stored.mediaId,
        mediaType: stored.mediaType,
        title: stored.title,
        startPosition: stored.position,
        duration: stored.duration,
      ),
    );
  }

  Future<void> stopCast() async {
    _cancelSubscriptions();

    try {
      await _backend.stop();
    } catch (e) {
      debugPrint('[CastSessionManager] Ignoring stop error: $e');
    }

    await _backend.disconnect();
    await _store.clear();

    final hlsSessionId = _activeHlsSessionId;
    _activeHlsSessionId = null;
    if (hlsSessionId != null) await _streamingSessions.end(hlsSessionId);

    await _disableLanQuietly();

    _persisted = null;
    _lastRequest = null;
    _lastDuration = Duration.zero;
    _lastProgressSync = null;
    _publish(null);
  }

  /// Reattach to a session left running by a previous app launch.
  ///
  /// Returns true when a session was restored. Anything that goes wrong
  /// clears the stored session rather than leaving a phantom in the UI.
  ///
  /// The receiver is asked what it is playing *before* anything connects to
  /// it. `ChromecastSession.connect` sends `LAUNCH CC1AD845`, which evicts
  /// whatever app the receiver is running — so a restore that connected first
  /// and checked afterwards would stop the user's TV every time they opened
  /// Mydia within the 12 hour window. When the receiver's state cannot be
  /// determined without launching (see
  /// `DartCastBackend.probeReceiverContentUrl`), the stored session is
  /// discarded: not restoring is a much smaller failure than hijacking.
  Future<bool> restoreSession() async {
    final stored = await _store.load();
    if (stored == null) return false;

    if (stored.isExpired(_clock())) {
      await _store.clear();
      return false;
    }

    if (!await _receiverStillPlaying(stored)) {
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

    // The progress pump reads a CastLaunchRequest, not a PersistedCastSession
    // — reconstruct an equivalent one from the fields the persisted record
    // carries, so a restored session keeps syncing progress and marks
    // itself stale like a freshly started one does.
    final request = CastLaunchRequest(
      fileId: stored.fileId,
      mediaId: stored.mediaId,
      mediaType: stored.mediaType,
      title: stored.title,
      startPosition: stored.position,
      duration: stored.duration,
    );

    // The bridge branch below reloads through `_loadOnRoute`, which sets this
    // itself; the direct branch adopts a receiver that is already playing and
    // never loads, so it has to be recorded here. Either way a later seek
    // restart carries exactly what the restore had — no subtitles or artwork,
    // because a record that survived an app restart never had them.
    _lastRequest = request;

    _listenToBackend(request);

    if (stored.routeKind == CastRouteKind.localBridge) {
      // The byte source died with the app: the proxy is gone, its port and
      // path token are new, and any HLS session id in the old URL is stale.
      // Re-resolve and reload at the stored position — a visible blip, which
      // the design accepts as the cost of the bridge path.
      if (!await _reloadBridgeSession(stored, request)) {
        await _store.clear();
        return false;
      }
      return true;
    }

    _publish(CastSession(
      device: stored.device,
      playbackState: CastPlaybackState.buffering,
      mediaInfo: CastMediaInfo(
        title: stored.title,
        duration: stored.duration,
        position: stored.position,
      ),
    ));

    return true;
  }

  Future<bool> _receiverStillPlaying(PersistedCastSession stored) async {
    String? playing;
    try {
      playing = await _backend.probeReceiverContentUrl(stored.device);
    } catch (e) {
      debugPrint('[CastSessionManager] Receiver probe failed: $e');
      return false;
    }

    if (playing == null) {
      debugPrint(
        '[CastSessionManager] Cannot tell what the receiver is playing; '
        'discarding the stored session rather than taking it over',
      );
      return false;
    }

    if (stored.mediaUrl.isEmpty || playing != stored.mediaUrl) {
      debugPrint(
        '[CastSessionManager] Receiver is playing something else; '
        'discarding the stored session',
      );
      return false;
    }

    return true;
  }

  Future<bool> _reloadBridgeSession(
    PersistedCastSession stored,
    CastLaunchRequest request,
  ) async {
    final resolver = _resolverFactory();
    final startedHlsSessions = <String>[];

    try {
      final route = await _resolveRoute(
        resolver,
        request,
        stored.device,
        startedHlsSessions,
        forceBridge: true,
      );
      if (route == null) {
        await _abandonStart(false, startedHlsSessions);
        return false;
      }

      await _loadOnRoute(resolver, route, stored.device, request);
      await _adoptHlsSession(route.hlsSessionId, startedHlsSessions);
      return true;
    } catch (e) {
      debugPrint('[CastSessionManager] Bridge restore failed: $e');
      _cancelSubscriptions();
      await _abandonStart(false, startedHlsSessions);
      try {
        await _backend.disconnect();
      } catch (_) {
        // Best effort: the restore has already failed.
      }
      return false;
    }
  }

  void _publish(CastSession? session) {
    _current = session;
    if (!_sessions.isClosed) _sessions.add(session);
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

  /// Release everything this manager owns.
  ///
  /// Disposal has to be a real teardown, not just a stream close: a manager
  /// dropped with a live session used to leave the backend connected and the
  /// LAN proxy exposed with nothing left to turn either off.
  void dispose() {
    _cancelSubscriptions();

    final hadSession = _current != null;
    final hlsSessionId = _activeHlsSessionId;
    _activeHlsSessionId = null;
    _current = null;

    unawaited(_releaseResources(hadSession, hlsSessionId));

    _sessions.close();
  }

  Future<void> _releaseResources(bool hadSession, String? hlsSessionId) async {
    if (hadSession) {
      try {
        await _backend.disconnect();
      } catch (e) {
        debugPrint(
            '[CastSessionManager] Ignoring disconnect error on dispose: $e');
      }
    }

    if (hlsSessionId != null) await _streamingSessions.end(hlsSessionId);

    await _disableLanQuietly();
  }
}
