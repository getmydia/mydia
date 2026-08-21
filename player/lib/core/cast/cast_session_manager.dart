import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/models/cast_device.dart';
import '../../native/lib.dart';
import '../player/progress_service.dart';
import '../player/stream_timeline.dart';
import 'cast_backend.dart';
import 'cast_capabilities.dart';
import 'cast_route_resolver.dart';
import 'cast_seek_restart.dart';
import 'cast_session_store.dart';
import 'cast_streaming_session_service.dart';
import 'mydia_cast_backend.dart';

/// The track list to hand to LOAD, with [selectedTrackId] first.
///
/// dart_cast activates `subtitles.first` unconditionally at LOAD
/// (`cast_media_channel.dart:135`) and exposes no way to offer tracks without
/// activating one. Ordering is therefore the only lever for *which* track
/// comes up, and an explicit `selectSubtitle(null)` right after LOAD is the
/// only lever for none. Both are workarounds for that library behaviour, not
/// design.
///
/// An id that matches nothing leaves the order alone rather than guessing.
List<CastSubtitleTrack> orderSubtitlesForLoad(
  List<CastSubtitleTrack> tracks,
  String? selectedTrackId,
) {
  if (selectedTrackId == null) return tracks;

  final index = tracks.indexWhere((t) => t.trackId == selectedTrackId);
  if (index <= 0) return tracks;

  return [tracks[index], ...tracks]..removeAt(index + 1);
}

/// Whether picking [device] should *adopt* whatever is already on it,
/// rather than connect media-less and wait for a `LoadContent`.
///
/// The signal is `metadata['nowPlayingTitle']`: `MydiaCastBackend`'s
/// discovery probe (`_probeSequence`) sets it when a `GetState` call made
/// *during discovery* both succeeded and reported the target playing *or*
/// paused. Paused counts deliberately, not just playing: the whole point of
/// this fork is that one player must not stomp what another is doing, and a
/// paused-but-resumable session is exactly the kind of thing worth not
/// stomping — treating it as idle would let picking that device silently
/// restart it. Everything else reads as false here — a non-Mydia device, a
/// Mydia device the probe found genuinely idle, and one whose `GetState`
/// failed during that same probe (`metadata['statusUnavailable']`, a target
/// that answered `Hello` but not `GetState`) — and falls back to the
/// existing media-less connect. Not knowing what a target is doing must
/// never be read as "it has something loaded".
bool isPlayingMydiaTarget(CastDevice device) =>
    device.protocol == CastProtocolKind.mydia &&
    device.metadata['nowPlayingTitle'] != null;

/// Reaches through [backend]'s snapshot bridge — see [MydiaSnapshotSource]'s
/// dartdoc for why this exists instead of a richer [CastBackend] — or null
/// when it doesn't have one: a Chromecast/DLNA backend, or a Mydia one with
/// nothing polled yet.
///
/// Paired with an explicit cast rather than a bare `is` check because Dart
/// only promotes a variable's static type on a *narrowing* check — [backend]
/// is declared [CastBackend], which shares no subtype relationship with
/// [MydiaSnapshotSource], so `backend is MydiaSnapshotSource` alone leaves
/// `backend.lastSnapshot` a compile error even in the branch that just
/// proved it true.
FlutterPlaybackSnapshot? _snapshotFrom(CastBackend backend) =>
    backend is MydiaSnapshotSource
        ? (backend as MydiaSnapshotSource).lastSnapshot
        : null;

/// Chooses which backend owns a device's protocol, and fans discovery out
/// across every backend registered.
///
/// Extracted out of [CastSessionManager] itself rather than left as a
/// conditional at each call site: once Mydia needed its own backend,
/// dispatch by protocol touched connect, discovery, and every command entry
/// point, which is exactly the "edits scattered across the file" a single
/// `if (protocol == mydia)` per call site would have produced. One named
/// unit reads better and cannot drift between call sites.
///
/// Chromecast and DLNA are not two entries here: one `DartCastBackend`
/// already discovers and drives both through a single `dart_cast` service,
/// gating itself on [CastCapabilities] internally. Only Mydia gets a
/// distinct backend.
class CastBackendRegistry {
  final CastBackend primary;
  final CastBackend? mydia;

  const CastBackendRegistry({required this.primary, this.mydia});

  /// The backend that owns [protocol].
  ///
  /// Falls back to [primary] for a protocol this build has no distinct
  /// backend for, rather than throwing — today that only matters when
  /// [mydia] itself is unconfigured (P2P not ready yet; see
  /// `mydiaCastBackendProvider`). A Mydia device then simply cannot be
  /// reached, which the connect attempt reports as an ordinary failure
  /// instead of a crash.
  CastBackend forProtocol(CastProtocolKind protocol) {
    return switch (protocol) {
      CastProtocolKind.mydia => mydia ?? primary,
      CastProtocolKind.chromecast || CastProtocolKind.dlna => primary,
    };
  }

  /// Every distinct backend, for fan-out operations like discovery.
  List<CastBackend> get all => [primary, if (mydia != null) mydia!];
}

/// Merges every backend's discovery stream into one combined device list,
/// republishing the full list whenever any single backend's own view
/// changes.
///
/// Each backend already reports only the devices it owns — the Chromecast/
/// DLNA backend gates itself on [capabilities], Mydia ignores it and always
/// sweeps — so this never needs to know which protocol a device came from;
/// it just keeps one slot of "the latest list from backend N" per backend
/// and concatenates them.
Stream<List<CastDevice>> mergeCastDiscovery(
  List<CastBackend> backends, {
  required CastCapabilities capabilities,
  Duration timeout = const Duration(seconds: 10),
}) {
  if (backends.isEmpty) return Stream.value(const []);
  if (backends.length == 1) {
    return backends.single
        .startDiscovery(capabilities: capabilities, timeout: timeout);
  }

  final latest = List<List<CastDevice>>.filled(backends.length, const []);
  final subs = <StreamSubscription<List<CastDevice>>>[];
  late final StreamController<List<CastDevice>> controller;

  // Coalesced onto the microtask queue rather than published straight from
  // each backend's own listener: two backends that both answer "eagerly"
  // (a discovery sweep that resolves instantly, as every test double here
  // does) fire their updates back to back within the same microtask drain.
  // Publishing on the first of those and only *then* letting the second
  // land would make a `.first`-style read of this stream see just one
  // backend's devices — a real, order-dependent bug this coalescing closes.
  // Two backends that answer minutes apart, which is the normal case for a
  // live discovery sweep, are unaffected: each gets its own flush once the
  // scheduled one has already run, so a fast backend's devices still show
  // up without waiting on a slow (or silent) one.
  var flushScheduled = false;
  void scheduleFlush() {
    if (flushScheduled) return;
    flushScheduled = true;
    scheduleMicrotask(() {
      flushScheduled = false;
      if (controller.isClosed) return;
      controller.add(latest.expand((d) => d).toList(growable: false));
    });
  }

  controller = StreamController<List<CastDevice>>(
    onCancel: () {
      for (final sub in subs) {
        unawaited(sub.cancel());
      }
    },
  );

  for (var i = 0; i < backends.length; i++) {
    final index = i;
    subs.add(backends[i]
        .startDiscovery(capabilities: capabilities, timeout: timeout)
        .listen((devices) {
      latest[index] = devices;
      scheduleFlush();
    }, onError: controller.addError));
  }

  return controller.stream;
}

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

  /// The track the viewer wants showing, by Mydia's own track id.
  ///
  /// Null means off, which is what local playback does when streaming, so it
  /// is what a cast defaults to.
  final String? selectedSubtitleTrackId;

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
    this.selectedSubtitleTrackId,
  });

  /// The same request, resumed from somewhere else, or with a new subtitle
  /// choice.
  ///
  /// [startPosition] and [selectedSubtitleTrackId] are the only fields that
  /// can be replaced. Everything else is carried across verbatim, which is
  /// the whole point: a seek restart rebuilds the cast from this, and
  /// anything dropped here disappears from the receiver for the rest of the
  /// session.
  ///
  /// [selectedSubtitleTrackId] can't just be `String?`, because passing null
  /// would then be ambiguous between "leave unchanged" and "turn subtitles
  /// off" — [clearSelectedSubtitle] is what [selectSubtitle] uses to say the
  /// latter.
  CastLaunchRequest copyWith({
    Duration? startPosition,
    String? selectedSubtitleTrackId,
    bool clearSelectedSubtitle = false,
  }) =>
      CastLaunchRequest(
        fileId: fileId,
        mediaId: mediaId,
        mediaType: mediaType,
        title: title,
        subtitleLabel: subtitleLabel,
        imageUrl: imageUrl,
        startPosition: startPosition ?? this.startPosition,
        subtitles: subtitles,
        duration: duration,
        selectedSubtitleTrackId: clearSelectedSubtitle
            ? null
            : (selectedSubtitleTrackId ?? this.selectedSubtitleTrackId),
      );
}

/// What [CastSessionManager.pullToLocal] hands back for a caller to resume
/// playback locally with — the mirror of what a [CastLaunchRequest] carries
/// *out* to a receiver, but read back from a Mydia target's own snapshot
/// rather than assembled from what this app chose to load.
///
/// [mediaItemId] is null when the target had nothing usable to report (see
/// [CastSessionManager.pullToLocal]'s dartdoc) — a caller with nothing to
/// open should treat that as "there was nothing to pull", not open an item
/// with no id.
class PulledSession {
  final String? mediaItemId;
  final String? episodeId;
  final Duration position;
  final String? selectedAudioTrackId;
  final String? selectedSubtitleTrackId;

  const PulledSession({
    required this.mediaItemId,
    required this.episodeId,
    required this.position,
    required this.selectedAudioTrackId,
    required this.selectedSubtitleTrackId,
  });
}

/// Owns the active cast session: routing, playback, progress and persistence.
class CastSessionManager {
  final CastBackendRegistry _registry;
  final CastCapabilities _capabilities;

  /// The backend behind whatever [_current] session is (or, before any
  /// connect, the primary/default one).
  ///
  /// Mutable rather than the single object it used to be: it is reassigned
  /// to `_registry.forProtocol(device.protocol)` at every entry point that
  /// establishes a new connection ([startCast], [connectTo],
  /// [restoreSession]), and only once that call has confirmed it actually
  /// owns the session — never from inside a race with another such call. See
  /// those methods for why the commit point matters: a naive reassignment as
  /// soon as the protocol is known would let a second, concurrent connect to
  /// a *different* protocol repoint this field out from under the first
  /// call's own post-await cleanup, which reads `_backend` expecting it to
  /// still be the one it just connected.
  CastBackend _backend;

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

  /// The tracks offered to the receiver for whatever is currently loaded.
  List<CastSubtitleTrack> _subtitles = const [];

  /// The track currently showing on the receiver, or null when off.
  CastSubtitleTrack? _selectedSubtitle;

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

  /// Bumped at the start of every [connectTo] and [startCast], and by
  /// [stopCast].
  ///
  /// `connectTo` awaits `_backend.connect(device)` with nothing else guarding
  /// against a second call landing while the first is still in flight — the
  /// cast button stays tappable while connecting, and a cancel
  /// (`cast-bar-connecting-cancel`) is `stopCast`, not something that can
  /// reach into a suspended `connectTo` and unwind it. Capturing this value at
  /// entry and re-checking it after the await is what lets a superseded call
  /// notice: if the generation has moved on — the user cancelled, or picked a
  /// second device before the first connect resolved — the connection this
  /// call just established is unwanted, so it is torn down instead of
  /// published. Without this, cancelling mid-connect was a no-op (there was
  /// no session yet for `stopCast`'s `disconnect()` to act on) and the
  /// connect would resurrect the bar up to 15s later; a double-pick left
  /// whichever connect resolved last in control with no way to stop it.
  ///
  /// `startCast` captures its own generation the same way and re-checks it in
  /// its failure-rollback catch block, for the same reason: `_loadWithRetries`
  /// awaits across a network round trip with nothing else guarding against a
  /// `connectTo` (to a different device, possibly a different protocol) both
  /// starting and finishing while this call is still failing to load. Without
  /// the check, that failure's cleanup — `_cancelSubscriptions()` and
  /// `_publish(null)` — would clobber the newer, already-published, unrelated
  /// session the winning `connectTo` just installed, exactly the "phantom
  /// disconnected while still connected" bug this field exists to prevent on
  /// `connectTo`'s own path.
  int _connectGeneration = 0;

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
    CastBackend? mydiaBackend,
    required CastSessionStore store,
    required ProgressService progressService,
    required CastRouteResolver Function() resolverFactory,
    required CastStreamingSessionService streamingSessions,
    required Future<void> Function(bool enabled) setLanAccess,
    DateTime Function()? clock,
    CastCapabilities? capabilities,
  })  : _registry = CastBackendRegistry(primary: backend, mydia: mydiaBackend),
        _backend = backend,
        _store = store,
        _progressService = progressService,
        _resolverFactory = resolverFactory,
        _streamingSessions = streamingSessions,
        _setLanAccess = setLanAccess,
        _clock = clock ?? DateTime.now,
        _capabilities = capabilities ?? const CastCapabilities.full();

  Stream<CastSession?> get sessionStream => _sessions.stream;
  CastSession? get currentSession => _current;

  /// Devices from every registered backend, merged into one list.
  ///
  /// A fresh sweep on every read, matching how `CastBackend.startDiscovery`
  /// itself behaves — this is a thin fan-out over the same per-backend
  /// sweeps `castDiscoveryProvider` starts for the picker, not a cache.
  Stream<List<CastDevice>> get discoveredDevices =>
      mergeCastDiscovery(_registry.all, capabilities: _capabilities);

  /// The item the active (or last) session is playing, for a UI that needs to
  /// re-cast it — a stale session's "Reconnect" must target the media that
  /// session was playing, not whatever screen happens to be open.
  PersistedCastSession? get persistedSession => _persisted;

  Future<void> startCast({
    required CastDevice device,
    required CastLaunchRequest request,
  }) async {
    // Invalidates any `connectTo` still awaiting `_backend.connect` — see
    // `_connectGeneration`'s dartdoc. Must happen before anything else here,
    // the same way `stopCast` bumps it first: a user can pick a device via
    // `connectTo` and, before that connect resolves (up to 15s), immediately
    // start playing something, landing here while the picker's `connectTo`
    // is still in flight. Without this, that in-flight `connectTo` would
    // resolve later, see itself *not* superseded, and publish a media-less
    // idle session over the one this call is about to load — and
    // `_listenForConnectionLoss`'s subscription setup would then tear down
    // the progress/state subscriptions this call installs via
    // `_listenToBackend`. Captured into a local (see `_connectGeneration`'s
    // dartdoc): this call's own failure-rollback catch block below re-checks
    // it before touching any shared state, the same way `connectTo`'s does.
    final generation = ++_connectGeneration;

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

    // Resolved from `device.protocol`, not read off `_backend`: a concurrent
    // call for a different protocol could have repointed that field between
    // here and whenever this call last touched it. Everything below uses
    // this local until the connection is confirmed to belong to this call,
    // at which point it is committed to `_backend` for the rest of the
    // session (see that field's dartdoc).
    final backend = _registry.forProtocol(device.protocol);

    // Reuse an open connection instead of rebuilding it. `connectTo` may
    // already own this receiver because the user chose it while browsing, and
    // `backend.connect` sends LAUNCH again — evicting and relaunching the
    // receiver app for no reason, which the user sees as a flicker on the TV
    // and a slower start.
    //
    // The `connected` check matters as much as the device check: after a drop,
    // `connectedDevice` still names the device (nothing called disconnect), so
    // matching on the id alone would load onto a dead socket.
    final reusable = backend.connectedDevice?.id == device.id &&
        _current?.connectionState == CastConnectionState.connected;

    if (!reusable) {
      try {
        await backend.connect(device);
      } catch (e) {
        await _abandonStart(lanEnabledBeforeCall, startedHlsSessions);
        rethrow;
      }
    }

    if (generation != _connectGeneration) {
      // Superseded (by a second `startCast`, a `connectTo`, or `stopCast`)
      // while `backend.connect()` above — or the `reusable` check itself —
      // was resolving. `connectTo`'s own catch block already guards this
      // moment for the *failure* path; this is the same race on the success
      // path, which until now ran `_backend = backend; _listenToBackend(...)`
      // unconditionally just below. A winner may already have its own
      // backend and listeners live, and repointing `_backend` here would
      // silently kill that winner's `connectionLost`/`notAuthorized`
      // reporting for the rest of the session — permanently, since nothing
      // re-arms it short of another connectTo/startCast/stopCast.
      //
      // Same device-match and newer-ownership care as `connectTo`'s stale
      // branch: `backend.disconnect()` targets whatever this backend
      // currently holds, with no device argument to aim it, so it must not
      // run when a newer call already owns this same backend/device.
      final newerOwnsThisDevice = _current?.device.id == device.id;
      if (backend.connectedDevice?.id == device.id && !newerOwnsThisDevice) {
        await backend.disconnect();
      }
      await _abandonStart(lanEnabledBeforeCall, startedHlsSessions);
      return;
    }

    _backend = backend;
    _listenToBackend(request);

    final CastRoute loaded;
    try {
      loaded = await _loadWithRetries(
        resolver,
        backend,
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
      //
      // `_cancelSubscriptions()` and `_publish(null)` below only run when
      // nothing has superseded this call while `_loadWithRetries` awaited
      // above — the same `generation == _connectGeneration` ownership check
      // `connectTo`'s own catch block uses. A concurrent `connectTo` (to a
      // different device, possibly a different protocol) may already have
      // published its own session and installed its own listeners by now,
      // and this call's failure must not tear those down or null out that
      // unrelated, newer session. `backend.disconnect()` just below is
      // unconditional regardless: it always targets *this call's own*
      // resolved backend local from `:415`, never whatever `_backend`
      // currently points at, so it can never reach a backend this call did
      // not itself connect (or reuse).
      if (generation == _connectGeneration) _cancelSubscriptions();
      try {
        await backend.disconnect();
      } catch (e) {
        debugPrint(
            '[CastSessionManager] Ignoring disconnect error during rollback: $e');
      }
      await _abandonStart(lanEnabledBeforeCall, startedHlsSessions);
      // The backend has just been disconnected, so leaving a session
      // published — as `connectTo` may have done before this call, or a
      // prior `startCast` on this same device — would claim a connection
      // that no longer exists. That is exactly the stale "connected" state
      // this project exists to eliminate, so clear it unconditionally here,
      // not only when the connection was reused — but, as above, only when
      // this call still owns whatever is currently published.
      if (generation == _connectGeneration) _publish(null);
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

  /// Moves whatever is playing to [device], keeping the live request.
  ///
  /// [_lastRequest] is the only thing that carries subtitle tracks, artwork
  /// and the subtitle label; `PersistedCastSession` deliberately carries only
  /// what a cold restore can act on. Rebuilding a request from the persisted
  /// record, which is what the cast picker used to do, silently dropped all
  /// three for the rest of the session.
  Future<void> retargetTo(CastDevice device) async {
    final request = _lastRequest;
    if (request == null) {
      throw StateError('retargetTo called with no live request');
    }

    final position = _current?.mediaInfo?.position ?? request.startPosition;
    await startCast(
        device: device, request: request.copyWith(startPosition: position));
  }

  /// Whether [retargetTo] has a request to move.
  bool get canRetarget => _lastRequest != null;

  /// Pulls whatever is on the connected Mydia target back onto this device:
  /// pauses and stops the target, ends this manager's own session, and
  /// hands back what the target was actually at so a caller can resume
  /// locally at the same spot.
  ///
  /// The target's exact position is read from its captured
  /// [FlutterPlaybackSnapshot] — via [MydiaSnapshotSource], the same seam
  /// [_applyAdoptedSnapshotExtras] uses — never from [CastBackend
  /// .positionStream], whose interpolation exists purely to keep a scrubber
  /// moving between real polls (see `MydiaCastBackend._positionTicker`), and
  /// never from server-reported progress, which [_syncProgress] throttles to
  /// once every 10 seconds. Either would routinely be seconds off, which
  /// matters here: this is the one number a caller cannot re-derive once the
  /// target has been told to stand down.
  ///
  /// Reads before it sends anything, deliberately: [_backend.pause] runs
  /// first below, and the target's own follow-up `GetState` poll (or the
  /// `disconnect` [stopCast] issues right after) can freely overwrite or
  /// clear the cached snapshot once the target has actually been told to
  /// pause or stop. Capturing [PulledSession] after either call risks
  /// reading a position that is no longer the one the viewer was actually
  /// watching from — or, once disconnected, no snapshot at all.
  ///
  /// Returns null, touching nothing, when [_backend] is not
  /// [MydiaSnapshotSource] (a Chromecast or DLNA target — there is no
  /// symmetric "pull" for either, since neither runs this app) or when
  /// nothing has been polled from it yet.
  Future<PulledSession?> pullToLocal() async {
    final snapshot = _snapshotFrom(_backend);
    if (snapshot == null) return null;

    final pulled = PulledSession(
      mediaItemId: snapshot.mediaItemId,
      episodeId: snapshot.episodeId,
      position: Duration(milliseconds: snapshot.positionMs.toInt()),
      selectedAudioTrackId: snapshot.selectedAudio,
      selectedSubtitleTrackId: snapshot.selectedSubtitle,
    );

    try {
      await _backend.pause();
    } catch (e) {
      // Best-effort: a target that will not even answer `pause` is not one
      // `stop` (via `stopCast` below) is likely to fare better with either,
      // and the position that matters has already been captured above.
      debugPrint('[CastSessionManager] Ignoring pause error during pull: $e');
    }

    await stopCast();

    return pulled;
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
    final generation = ++_connectGeneration;

    // Resolved locally rather than read off `_backend`: this call's own
    // cleanup below re-reads whichever backend it itself connected, even if
    // a concurrent call for a different protocol commits a different one to
    // `_backend` in the meantime. See that field's dartdoc.
    final backend = _registry.forProtocol(device.protocol);

    _publish(CastSession(
      device: device,
      playbackState: CastPlaybackState.idle,
      connectionState: CastConnectionState.connecting,
    ));

    try {
      await backend.connect(device);
    } catch (e) {
      // Only touch shared state if nothing superseded this call while it was
      // awaiting: a stale failure racing behind a newer, already-published
      // connectTo must not cancel that one's subscriptions or clobber its
      // session with null.
      if (generation == _connectGeneration) {
        _cancelSubscriptions();
        _publish(null);
      }
      rethrow;
    }

    if (generation != _connectGeneration) {
      // Cancelled (`stopCast`) or superseded by a second `connectTo` (or a
      // `startCast`) while this one was in flight. The backend has just
      // connected on our behalf regardless — undo that rather than publish a
      // session nobody asked for anymore.
      //
      // Two independent checks guard the actual `disconnect()`:
      //
      // - Device match: `backend.disconnect()` closes whatever that backend
      //   currently holds, with no device argument to target. If a second
      //   `connectTo` resolved first and is already connected to a
      //   *different* device on this SAME backend, an unconditional
      //   disconnect here would tear down that newer, wanted connection
      //   instead of this stale one. (A second call for a *different*
      //   protocol cannot collide here at all — it resolved its own,
      //   different `backend` local above.)
      //
      // - Not newer-owned: matching on device id alone is not enough,
      //   because `startCast` can supersede this call and then connect to
      //   *this same* device to load media on it — `_current` is that
      //   newer session at this point, not this call's. Disconnecting here
      //   would kill the very socket `startCast` just adopted and is
      //   actively using, leaving a published session with real media over
      //   a closed connection: the exact phantom-connected failure mode
      //   this whole generation guard exists to eliminate. `stopCast`
      //   publishes null before bumping past this call, so it never counts
      //   as an owner and the disconnect it demands still happens.
      final newerOwnsThisDevice = _current?.device.id == device.id;
      if (backend.connectedDevice?.id == device.id && !newerOwnsThisDevice) {
        await backend.disconnect();
      }
      return;
    }

    // This call won: commit its backend as the one behind the session about
    // to be published, so every command with no device of its own to name
    // (`play`, `pause`, `seek`, ...) reaches the right receiver.
    _backend = backend;

    if (isPlayingMydiaTarget(device)) {
      // Adopted: something is already on this receiver that nobody here
      // chose. See `_listenToBackendForAdoption`'s dartdoc for why this
      // needs its own subscription setup rather than reusing
      // `_listenForConnectionLoss` (no media, so nothing to track) or
      // `_listenToBackend` (assumes this app is the one that loaded it) —
      // including how it backfills artwork and subtitle tracks from the
      // target's own snapshot via `MydiaSnapshotSource`, which the generic
      // `CastBackend` streams this manager otherwise reads from carry no
      // channel for at all.
      _listenToBackendForAdoption();

      _publish(CastSession(
        device: device,
        // Not `idle`: something genuinely is loaded, we just don't yet know
        // its playback state — the first `stateStream` event resolves this,
        // same as a freshly loaded session sits at `buffering` until the
        // receiver reports otherwise.
        playbackState: CastPlaybackState.buffering,
        connectionState: CastConnectionState.connected,
        mediaInfo: CastMediaInfo(
          // The only field the discovery probe actually carries (see
          // `isPlayingMydiaTarget`'s dartdoc) — guaranteed non-null here.
          // Duration and position start at zero and are corrected by the
          // first real `durationStream`/`positionStream` events, exactly
          // like a freshly loaded session's placeholder is corrected by the
          // receiver's own numbers.
          title: device.metadata['nowPlayingTitle']!,
          duration: Duration.zero,
          position: Duration.zero,
        ),
      ));
    } else {
      _listenForConnectionLoss();

      _publish(CastSession(
        device: device,
        playbackState: CastPlaybackState.idle,
        connectionState: CastConnectionState.connected,
      ));
    }
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
      // `notAuthorized` is a Mydia target revoking this app mid-session — a
      // trust boundary, and actionable ("pair with it again") — so it gets
      // the same treatment as a dropped connection. `notPlaying` stays
      // quiet on purpose: it is a benign state Mydia's own backend already
      // re-syncs from (see its `_sendCommand`), not a failure the UI needs
      // to react to. Everything else here is unreachable for the backends
      // this manager drives today (see `CastFailureKind`'s dartdoc on each
      // member for why), so it stays filtered out rather than silently
      // handled the same way.
      if (failure != CastFailureKind.connectionLost &&
          failure != CastFailureKind.notAuthorized) {
        return;
      }

      final current = _current;
      if (current == null) return;

      debugPrint('[CastSessionManager] Receiver lost while idle');
      _publish(current.copyWith(connectionState: CastConnectionState.lost));
    });
  }

  /// Subscription setup for a session this app *adopted* — connected to and
  /// found already playing — rather than one it loaded itself.
  ///
  /// Differs from [_listenToBackend] in every way that assumption matters:
  ///
  /// - Never calls [_syncProgress]. Progress reporting stays with whoever is
  ///   playing: the target is the one writing `updateMovieProgress`/
  ///   `updateEpisodeProgress` for this item already, and a second writer
  ///   here would race it for continue-watching.
  /// - Resets [_timeline] to [StreamTimeline.zero] instead of carrying
  ///   forward whatever offset a *previous*, unrelated session on this same
  ///   manager left behind. A stale offset here would mistranslate a later
  ///   [seek] on a session this manager never itself routed — the receiver's
  ///   position already *is* the real position.
  /// - Clears every field that answers "what did I load" —
  ///   [_persisted], [_lastRequest], [_subtitles], [_selectedSubtitle] — for
  ///   the same reason: this session's item was never chosen through this
  ///   manager, so a value left over from an earlier, different session must
  ///   not be read as this one's.
  /// - Leaves [_lastDuration] at [Duration.zero] rather than tracking the
  ///   receiver's real duration the way [_listenToBackend] does. That field
  ///   exists only to gate [_syncProgress] (see its own `<=` guard), which
  ///   this method never calls — keeping it at zero means an adopted session
  ///   stays inert to progress sync even if something were ever wired up to
  ///   call it by mistake, rather than merely happening not to be called
  ///   today.
  /// - Also backfills artwork and subtitle tracks from [_backend]'s captured
  ///   [FlutterPlaybackSnapshot] (see [_applyAdoptedSnapshotExtras]), which
  ///   [_listenToBackend] never needs to: a session this manager loaded
  ///   itself already got both from the [CastLaunchRequest] at
  ///   [_loadOnRoute] time.
  ///
  /// [_updateMediaInfo] still does the actual publishing — the same helper
  /// [_listenToBackend] uses — since both cases are "republish [_current]'s
  /// `mediaInfo` with a new position/duration applied" and nothing about
  /// that step differs for an adopted session.
  void _listenToBackendForAdoption() {
    _cancelSubscriptions();

    _persisted = null;
    _lastRequest = null;
    _lastDuration = Duration.zero;
    _lastProgressSync = null;
    _subtitles = const [];
    _selectedSubtitle = null;
    _useTimeline(StreamTimeline.zero);

    _durationSub = _backend.durationStream.listen((duration) {
      // Same "receiver says -1 for unknown" guard `_listenToBackend` uses.
      if (duration <= Duration.zero) return;
      _updateMediaInfo(duration: duration);
      _applyAdoptedSnapshotExtras();
    });

    _positionSub = _backend.positionStream.listen((position) {
      // No `_timeline` translation: an adopted session was never routed
      // through this manager, so the receiver's own position already is the
      // real one.
      _updateMediaInfo(position: position);
    });

    _stateSub = _backend.stateStream.listen((state) {
      final current = _current;
      if (current == null) return;
      _publish(current.copyWith(playbackState: state));
    });

    _failureSub = _backend.failureStream.listen((failure) {
      if (failure != CastFailureKind.connectionLost &&
          failure != CastFailureKind.notAuthorized) {
        return;
      }

      final current = _current;
      if (current == null) return;

      debugPrint(
          '[CastSessionManager] Adopted receiver lost; marking session stale');
      _publish(current.copyWith(
        connectionState: CastConnectionState.lost,
        playbackState: CastPlaybackState.idle,
      ));
    });
  }

  /// Fills in what an adopted session's generic streams cannot carry —
  /// artwork and subtitle tracks — from [_backend]'s own captured snapshot.
  ///
  /// A no-op for anything that is not [MydiaSnapshotSource] (Chromecast,
  /// DLNA, or a Mydia backend that has not polled yet) — exactly the
  /// backends [isPlayingMydiaTarget] can never have flagged this session
  /// adoptable from in the first place, so this only ever does real work on
  /// the path that actually reaches it.
  ///
  /// `url` on the rebuilt [CastSubtitleTrack]s is always empty: a Mydia
  /// target is selected by [CastSubtitleTrack.trackId] alone
  /// (`MydiaCastBackend.selectSubtitle` sends only `track?.trackId`), so
  /// there is no receiver URL to reconstruct and none is needed.
  void _applyAdoptedSnapshotExtras() {
    final snapshot = _snapshotFrom(_backend);
    final current = _current;
    if (snapshot == null || current == null) return;

    _subtitles = [
      for (final track in snapshot.subtitleTracks)
        CastSubtitleTrack(
          trackId: track.id,
          url: '',
          label: track.label,
          language: track.language ?? '',
        ),
    ];
    _selectedSubtitle = _subtitles
        .where((t) => t.trackId == snapshot.selectedSubtitle)
        .firstOrNull;

    _publish(current.copyWith(
      mediaInfo: current.mediaInfo?.copyWith(imageUrl: snapshot.imageUrl),
      subtitles: _subtitles,
      selectedSubtitle: _selectedSubtitle,
      clearSelectedSubtitle: _selectedSubtitle == null,
    ));
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
      subtitles: request.subtitles,
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
  ///
  /// [backend] is this call's own resolved backend local (see `startCast`'s
  /// `:415`) threaded all the way down to [_loadOnRoute], never read off the
  /// shared `_backend` field — a concurrent connect to a different device
  /// could repoint that field before any of the awaits below settle.
  Future<CastRoute> _loadWithRetries(
    CastRouteResolver resolver,
    CastBackend backend,
    CastRoute route,
    CastDevice device,
    CastLaunchRequest request,
    List<String> startedHlsSessions,
  ) async {
    try {
      await _loadOnRoute(resolver, route, device, request, backend);
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
        await _loadOnRoute(resolver, secondRoute, device, request, backend);
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
        await _loadOnRoute(resolver, transcodeRoute, device, request, backend);
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
      // A block on our own side. No alternate media route reaches a receiver
      // the OS will not let us open a socket to.
      case CastFailureKind.localNetworkDenied:
      // Both are Mydia-target-specific and neither is a media-route problem:
      // a revoked pairing or an unmounted player is not fixed by retrying
      // with a different URL or encoding.
      case CastFailureKind.notAuthorized:
      case CastFailureKind.notPlaying:
      case CastFailureKind.unknown:
        return null;
    }
  }

  /// [backend] is the caller's own resolved backend — from `startCast`'s
  /// `:415` local, `_reloadBridgeSession`'s parameter, or (transitively)
  /// `restoreSession`'s local — used here instead of the shared `_backend`
  /// field for the same reason `_receiverStillPlaying` already takes one: a
  /// concurrent connect elsewhere in the manager can repoint `_backend`
  /// between when the caller started and when this method's own awaits
  /// settle, and a load must land on the connection it actually resolved a
  /// route for, not whatever the field currently names.
  Future<void> _loadOnRoute(
    CastRouteResolver resolver,
    CastRoute route,
    CastDevice device,
    CastLaunchRequest request,
    CastBackend backend,
  ) async {
    // The route already rewrote every track to a URL its receiver can fetch,
    // and dropped them entirely when it cannot serve any. Reading them from
    // here rather than from `request` is what gives every entry point
    // subtitles: they all resolve a route, and only one of them ever passed
    // tracks of its own.
    //
    // Reordered with the viewer's choice first: see `orderSubtitlesForLoad`'s
    // dartdoc for why this — and the disable call below — are workarounds for
    // a dart_cast limitation, not design.
    final subtitles =
        orderSubtitlesForLoad(route.subtitles, request.selectedSubtitleTrackId);

    _useTimeline(StreamTimeline(
      startOffset: route.startOffset,
      totalDuration: request.duration,
    ));

    await backend.loadMedia(CastMediaRequest(
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

    _subtitles = subtitles;
    _selectedSubtitle = subtitles
        .where((t) => t.trackId == request.selectedSubtitleTrackId)
        .firstOrNull;

    // dart_cast activated subtitles.first at LOAD. Nothing *resolved* to a
    // choice — either nothing was requested, or the requested id doesn't
    // match any track actually offered (e.g. it named a track this route
    // dropped for being undeliverable) — so turn them back off. Checking
    // `_selectedSubtitle` rather than `request.selectedSubtitleTrackId`
    // directly is what covers the mismatch case: leaving dart_cast's forced
    // first track active while the UI (`CastSession.selectedSubtitle`) says
    // off would show the viewer a subtitle they were told is disabled.
    if (subtitles.isNotEmpty && _selectedSubtitle == null) {
      await backend.selectSubtitle(null);
    }

    // What to carry forward as "the chosen id". When tracks were actually
    // offered and the requested one matched none of them, the id is bogus —
    // `_selectedSubtitle` is null and the receiver was just told subtitles
    // are off above, so persisting the unmatched id would leave the store
    // claiming a selection that never took effect. But an empty `subtitles`
    // list does *not* mean the same thing: `restoreSession`'s bridge reload
    // and `reconnectStoredSession` rebuild a request with no track list at
    // all (a `PersistedCastSession` never carries one), and that structural
    // gap must not be read as "the id didn't match" and scrub a real,
    // previously-resolved choice.
    final resolvedSubtitleId = subtitles.isEmpty
        ? request.selectedSubtitleTrackId
        : _selectedSubtitle?.trackId;

    _lastRequest = request.copyWith(
      selectedSubtitleTrackId: resolvedSubtitleId,
      clearSelectedSubtitle: resolvedSubtitleId == null,
    );

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
      selectedSubtitleTrackId: resolvedSubtitleId,
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
      subtitles: _subtitles,
      selectedSubtitle: _selectedSubtitle,
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
    //
    // `notAuthorized` gets the same treatment: a Mydia target that revokes
    // this app mid-session is just as unable to take further commands as
    // one that dropped off the network, and without this a controller would
    // keep showing live transport controls for a target refusing every one
    // of them. `notPlaying` is deliberately left out — Mydia's own backend
    // treats it as a benign state to re-sync from, not a failure, and
    // routing it here would raise an alarming "lost" bar for a non-event.
    _failureSub = _backend.failureStream.listen((failure) {
      if (failure != CastFailureKind.connectionLost &&
          failure != CastFailureKind.notAuthorized) {
        return;
      }

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

  /// Turns subtitles on, off, or switches track on the live receiver.
  ///
  /// [track] must be an instance from the current session's list: dart_cast
  /// keys its internal Chromecast track ids by URL, and a re-derived URL that
  /// differs by so much as a token falls back to activating trackId=1 with
  /// only a log warning.
  Future<void> selectSubtitle(CastSubtitleTrack? track) async {
    await _backend.selectSubtitle(track);

    _selectedSubtitle = track;
    _lastRequest = _lastRequest?.copyWith(
      selectedSubtitleTrackId: track?.trackId,
      clearSelectedSubtitle: track == null,
    );

    // Keeps a cold restore in sync with whatever the viewer picked mid
    // session — without this, only a seek restart (which rebuilds from
    // `_lastRequest`, not the store) would remember the choice.
    final persisted = _persisted;
    if (persisted != null) {
      _persisted = persisted.copyWith(
        selectedSubtitleTrackId: track?.trackId,
        clearSelectedSubtitle: track == null,
      );
      await _store.save(_persisted!);
    }

    _republishWithSubtitles();
  }

  /// Re-emits [_current] with [_subtitles]/[_selectedSubtitle] applied.
  ///
  /// Goes through `CastSession.copyWith` — including its
  /// `clearSelectedSubtitle` flag for the "turn off" case a plain
  /// `selectedSubtitle: null` argument can't express — rather than
  /// hand-building a new `CastSession`, so every other field on the current
  /// session (device, mediaInfo, playbackState, connectionState) is carried
  /// forward automatically. Hand-building here would mean any field added to
  /// `CastSession` later has to be remembered in two places — the
  /// constructor and this method — or it silently regresses exactly like the
  /// bug this pair of fields was added to fix.
  void _republishWithSubtitles() {
    final current = _current;
    if (current == null) return;

    _publish(current.copyWith(
      subtitles: _subtitles,
      selectedSubtitle: _selectedSubtitle,
      clearSelectedSubtitle: _selectedSubtitle == null,
    ));
  }

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
        // Carried across for the same reason `restoreSession` carries it:
        // this always reaches `_loadOnRoute` (unlike `restoreSession`'s
        // direct-route branch, which adopts a receiver without reloading),
        // and `_loadOnRoute` re-saves `_persisted` from this request. Leaving
        // it out would silently overwrite the store's real choice with null
        // on every stale-session reconnect.
        selectedSubtitleTrackId: stored.selectedSubtitleTrackId,
      ),
    );
  }

  Future<void> stopCast() async {
    // Invalidates any `connectTo` still awaiting `_backend.connect` — see
    // `_connectGeneration`'s dartdoc. Must happen before anything else here:
    // the whole point is that the in-flight call's own generation check,
    // running after this returns, sees a mismatch.
    _connectGeneration++;

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
    _subtitles = const [];
    _selectedSubtitle = null;
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

    final backend = _registry.forProtocol(stored.device.protocol);

    if (!await _receiverStillPlaying(stored, backend)) {
      await _store.clear();
      return false;
    }

    try {
      await backend.connect(stored.device);
    } catch (e) {
      debugPrint('[CastSessionManager] Reconnect failed: $e');
      await _store.clear();
      return false;
    }

    _backend = backend;
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
      selectedSubtitleTrackId: stored.selectedSubtitleTrackId,
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
      if (!await _reloadBridgeSession(stored, request, backend)) {
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

  Future<bool> _receiverStillPlaying(
    PersistedCastSession stored,
    CastBackend backend,
  ) async {
    String? playing;
    try {
      playing = await backend.probeReceiverContentUrl(stored.device);
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

  /// [backend] is `restoreSession`'s own resolved local, threaded through
  /// rather than read off the shared `_backend` field: `restoreSession` runs
  /// `unawaited` from app startup while the UI is already interactive (see
  /// `app.dart`'s `_restoreCastSession`), so a user tapping cast during that
  /// window is an ordinary concurrent connect, not a hypothetical — and the
  /// catch block's `disconnect()` below must tear down only the backend this
  /// restore itself connected, never a newer, user-chosen one that raced
  /// ahead and committed to `_backend` in the meantime.
  Future<bool> _reloadBridgeSession(
    PersistedCastSession stored,
    CastLaunchRequest request,
    CastBackend backend,
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

      await _loadOnRoute(resolver, route, stored.device, request, backend);
      await _adoptHlsSession(route.hlsSessionId, startedHlsSessions);
      return true;
    } catch (e) {
      debugPrint('[CastSessionManager] Bridge restore failed: $e');
      _cancelSubscriptions();
      await _abandonStart(false, startedHlsSessions);
      try {
        await backend.disconnect();
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
