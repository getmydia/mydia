import 'dart:async';

import '../../domain/models/cast_device.dart';
import '../../native/lib.dart';
import '../remote/remote_roster.dart';
import 'cast_backend.dart';
import 'cast_capabilities.dart';

/// The controller-facing name this app hands a Mydia target on `Hello`.
const _controllerName = 'Mydia Player';

/// The remote-control protocol version this build speaks.
const _protocolVersion = 1;

/// How the poll timer refreshes state while the remote UI is on screen.
const _visiblePollInterval = Duration(seconds: 1);

/// How the poll timer refreshes state while the remote UI is not on screen —
/// coarse, since nothing is watching a scrubber move.
const _backgroundPollInterval = Duration(seconds: 5);

/// How often the locally interpolated position is republished between real
/// polls, so a visible scrubber does not visibly step once a second.
const _interpolationInterval = Duration(milliseconds: 500);

/// Where a [MydiaCastBackend] command actually goes.
///
/// Kept behind an interface — rather than dialing [P2PHost] directly from
/// [MydiaCastBackend] — so every unit test can script a target's answers
/// instead of standing up a real iroh node.
abstract class MydiaControlTransport {
  Future<FlutterRemoteControlResponse> send(
    String nodeId,
    FlutterRemoteControlRequest request,
  );
}

/// The production transport: wraps [P2PHost.sendRemoteControlRequest].
class P2pControlTransport implements MydiaControlTransport {
  final P2PHost host;

  const P2pControlTransport(this.host);

  @override
  Future<FlutterRemoteControlResponse> send(
    String nodeId,
    FlutterRemoteControlRequest request,
  ) =>
      host.sendRemoteControlRequest(peer: nodeId, req: request);
}

/// A [CastBackend] over Mydia's own remote-control protocol, rather than
/// Chromecast or DLNA.
///
/// A Mydia target is another instance of this same app, reached over the
/// p2p transport instead of the LAN. It resolves its own content from a
/// [MydiaContentRef] — see [loadMedia] — and it is the only backend that
/// reports real [CastCapabilityFlags], because it is the only one whose
/// receiver is a peer that can describe itself.
class MydiaCastBackend implements CastBackend {
  final RemoteRoster roster;
  final MydiaControlTransport transport;
  final String selfNodeId;

  /// Budget covering dial, `Hello` and `GetState` together for one
  /// discovery candidate. Three seconds is generous for a p2p round trip
  /// and short enough that one dead target does not stall the whole sweep
  /// (candidates are probed in parallel, so this bounds the slowest one).
  final Duration probeBudget;

  final DateTime Function() _now;

  MydiaCastBackend({
    required this.roster,
    required this.transport,
    required this.selfNodeId,
    this.probeBudget = const Duration(seconds: 3),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final _states = StreamController<CastPlaybackState>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _failures = StreamController<CastFailureKind>.broadcast();
  final _volumes = StreamController<double>.broadcast();

  CastDevice? _connected;
  String? _connectedNodeId;

  /// Whether `Hello` has ever succeeded against the currently connected
  /// node. Distinguishes a target that was never reachable
  /// ([CastFailureKind.unreachable]) from one that dropped mid-session
  /// ([CastFailureKind.connectionLost]).
  bool _everConnected = false;

  CastCapabilityFlags _capabilities = const CastCapabilityFlags();

  BigInt? _lastSequence;
  FlutterPlaybackSnapshot? _lastSnapshot;
  DateTime? _lastSnapshotAt;

  Timer? _pollTimer;
  Timer? _positionTicker;

  bool _remoteUiVisible = true;

  /// Whether the remote-control screen is currently on screen. Not part of
  /// [CastBackend] — nothing outside this backend needs it — but settable so
  /// a future caller (the remote UI itself, or ambient background handling)
  /// can trade poll frequency for battery without tearing the session down.
  bool get remoteUiVisible => _remoteUiVisible;

  set remoteUiVisible(bool value) {
    if (_remoteUiVisible == value) return;
    _remoteUiVisible = value;
    if (_connectedNodeId != null) _startPolling();
  }

  @override
  Stream<List<CastDevice>> startDiscovery({
    required CastCapabilities capabilities,
    Duration timeout = const Duration(seconds: 10),
  }) {
    // `capabilities` gates Chromecast/DLNA on platform entitlements; Mydia
    // targets are reached over the already-connected p2p host, so nothing
    // here needs gating on it.
    return Stream.fromFuture(_discover());
  }

  Future<List<CastDevice>> _discover() async {
    final entries = await roster.entries();
    final candidates = entries.where((e) => e.nodeId != selfNodeId);

    final probed = await Future.wait(candidates.map(_probe));
    return probed.whereType<CastDevice>().toList(growable: false);
  }

  /// Dials one candidate, sends `Hello`, and — best-effort — `GetState`, all
  /// under [probeBudget]. A target that answers `Hello` but not `GetState`
  /// is still offered, just without a "now playing" label.
  Future<CastDevice?> _probe(RemoteDeviceEntry entry) async {
    try {
      return await _probeSequence(entry).timeout(probeBudget);
    } catch (_) {
      // Unreachable, timed out, or the response could not be decoded (an
      // old build cannot decode the new outer variant at all). Every one of
      // those means the device simply is not offered.
      return null;
    }
  }

  Future<CastDevice?> _probeSequence(RemoteDeviceEntry entry) async {
    final hello = await transport.send(
      entry.nodeId,
      const FlutterRemoteControlRequest.hello(
        controllerName: _controllerName,
        protocolVersion: _protocolVersion,
      ),
    );

    if (hello is! FlutterRemoteControlResponse_Welcome) return null;

    var metadata = {'nodeId': entry.nodeId};

    try {
      final state = await transport.send(
        entry.nodeId,
        const FlutterRemoteControlRequest.getState(),
      );
      if (state is FlutterRemoteControlResponse_State &&
          state.field0.state == FlutterPlaybackState.playing) {
        metadata = {...metadata, 'nowPlayingTitle': state.field0.title};
      }
    } catch (_) {
      // Hello worked, so the target is genuinely reachable and stays listed
      // (see `_probe`'s dartdoc) — but GetState failing here means we
      // actually don't know what it's doing, which is a different claim
      // than "confirmed idle". Flagged in metadata so the picker's copy
      // ("Nothing playing" vs "Status unavailable") can tell the two apart.
      metadata = {...metadata, 'statusUnavailable': 'true'};
    }

    return CastDevice(
      id: entry.nodeId,
      name: hello.targetName,
      protocol: CastProtocolKind.mydia,
      metadata: metadata,
    );
  }

  @override
  void stopDiscovery() {
    // Each sweep is a single bounded Future (see `_discover`), not a
    // subscription that can outlive its caller, so there is nothing to
    // cancel here.
  }

  @override
  Future<void> connect(CastDevice device) async {
    final nodeId = device.metadata['nodeId'] ?? device.id;
    _connectedNodeId = nodeId;
    _connected = device;
    _everConnected = false;
    _lastSequence = null;
    _lastSnapshot = null;
    _lastSnapshotAt = null;

    final response = await _send(const FlutterRemoteControlRequest.hello(
      controllerName: _controllerName,
      protocolVersion: _protocolVersion,
    ));
    _everConnected = true;
    _handleResponse(response);
    _startPolling();
  }

  @override
  Future<void> disconnect() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _positionTicker?.cancel();
    _positionTicker = null;
    _connectedNodeId = null;
    _connected = null;
    _everConnected = false;
    _capabilities = const CastCapabilityFlags();
    _lastSequence = null;
    _lastSnapshot = null;
    _lastSnapshotAt = null;
  }

  @override
  Future<String?> probeReceiverContentUrl(CastDevice device) async {
    // Unlike Chromecast, probing here never evicts anything: there is no
    // `LAUNCH` a Mydia target has to run to answer `GetState`, so the "do
    // not touch this receiver" caveat this method carries on `CastBackend`
    // does not apply.
    final nodeId = device.metadata['nodeId'] ?? device.id;
    try {
      final response = await transport
          .send(nodeId, const FlutterRemoteControlRequest.getState())
          .timeout(probeBudget);
      if (response is! FlutterRemoteControlResponse_State) return null;

      final mediaItemId = response.field0.mediaItemId;
      if (mediaItemId == null) return null;

      final episodeId = response.field0.episodeId;
      return episodeId == null ? mediaItemId : '$mediaItemId:$episodeId';
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> loadMedia(CastMediaRequest request) async {
    final ref = request.contentRef;
    if (ref == null) {
      throw const CastBackendException(
        'A Mydia target resolves its own stream and needs a content '
        'reference, not a URL.',
        CastFailureKind.mediaLoadFailed,
      );
    }

    await _sendCommand(FlutterRemoteControlRequest.loadContent(
      FlutterLoadContentRequest(
        mediaItemId: ref.mediaItemId,
        episodeId: ref.episodeId,
        positionMs: BigInt.from(request.startPosition?.inMilliseconds ?? 0),
        audioTrack: ref.audioTrack,
        subtitleTrack: ref.subtitleTrack,
        autoplay: true,
      ),
    ));
  }

  @override
  Future<void> play() => _sendCommand(const FlutterRemoteControlRequest.play());

  @override
  Future<void> pause() =>
      _sendCommand(const FlutterRemoteControlRequest.pause());

  @override
  Future<void> stop() => _sendCommand(const FlutterRemoteControlRequest.stop());

  @override
  Future<void> seek(Duration position) => _sendCommand(
        FlutterRemoteControlRequest.seek(
          positionMs: BigInt.from(position.inMilliseconds),
        ),
      );

  @override
  Future<void> selectSubtitle(CastSubtitleTrack? track) => _sendCommand(
        FlutterRemoteControlRequest.selectSubtitleTrack(id: track?.trackId),
      );

  @override
  Future<void> setVolume(double level) => _sendCommand(
        FlutterRemoteControlRequest.setVolume(level: level),
      );

  @override
  Future<void> setMuted(bool muted) => _sendCommand(
        FlutterRemoteControlRequest.setMute(muted: muted),
      );

  @override
  Stream<CastPlaybackState> get stateStream => _states.stream;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Stream<Duration> get durationStream => _durations.stream;

  @override
  Stream<CastFailureKind> get failureStream => _failures.stream;

  @override
  Stream<double> get volumeStream => _volumes.stream;

  @override
  CastDevice? get connectedDevice => _connected;

  @override
  CastCapabilityFlags get capabilities => _capabilities;

  @override
  Future<void> dispose() async {
    _pollTimer?.cancel();
    _positionTicker?.cancel();
    await _states.close();
    await _positions.close();
    await _durations.close();
    await _failures.close();
    await _volumes.close();
  }

  /// Sends one command, maps its answer, then — unless the target refused
  /// outright — re-reads state immediately so the UI does not wait for the
  /// next poll tick to reflect a command it just issued.
  Future<void> _sendCommand(FlutterRemoteControlRequest request) async {
    final FlutterRemoteControlResponse response;
    try {
      response = await _send(request);
    } catch (_) {
      // `_send` already reported this on `failureStream`.
      return;
    }

    _handleResponse(response);
    if (response is! FlutterRemoteControlResponse_NotAuthorized) {
      await _pollOnce();
    }
  }

  Future<FlutterRemoteControlResponse> _send(
    FlutterRemoteControlRequest request,
  ) async {
    final nodeId = _connectedNodeId;
    if (nodeId == null) {
      throw const CastBackendException(
        'Not connected to a Mydia target.',
        CastFailureKind.connectionLost,
      );
    }

    try {
      return await transport.send(nodeId, request);
    } catch (error) {
      // A thrown transport error before the first successful `Hello` means
      // the target was never reachable; after one, it means the session
      // just dropped. `_sendCommand` swallows this for ordinary commands
      // (the classification above already reached `failureStream`), but
      // `connect()` calls `_send` directly, so this still needs to be a
      // `CastBackendException` rather than a raw transport error leaking
      // out — that is what lets a caller's `on CastBackendException catch`
      // (see `DartCastBackend.connect` for the equivalent) tell this apart
      // from an unrelated bug.
      final kind = _everConnected
          ? CastFailureKind.connectionLost
          : CastFailureKind.unreachable;
      _failures.add(kind);
      throw CastBackendException(
          'Could not reach the Mydia target: $error', kind);
    }
  }

  void _handleResponse(FlutterRemoteControlResponse response) {
    switch (response) {
      case FlutterRemoteControlResponse_Welcome(:final capabilities):
        _capabilities = CastCapabilityFlags(
          volume: capabilities.volume,
          trackSelection: capabilities.trackSelection,
          nextPrevious: capabilities.nextPrevious,
        );
      case FlutterRemoteControlResponse_State(:final field0):
        _applySnapshot(field0);
      case FlutterRemoteControlResponse_NotAuthorized():
        // A revoked pairing. Not fixed by retrying or re-reading state, so
        // `_sendCommand` skips the usual follow-up poll for this one.
        _failures.add(CastFailureKind.notAuthorized);
      case FlutterRemoteControlResponse_NotPlaying():
        // Reachable, but nothing is mounted to command. This is a state to
        // re-sync from, not a hard failure — the caller still follows up
        // with a `GetState` poll (see `_sendCommand`), which is what turns
        // this into an idle UI rather than a dead end.
        _failures.add(CastFailureKind.notPlaying);
      case FlutterRemoteControlResponse_Accepted():
        break;
      case FlutterRemoteControlResponse_Unsupported():
        break;
      case FlutterRemoteControlResponse_Error():
        _failures.add(CastFailureKind.unknown);
    }
  }

  Future<void> _pollOnce() async {
    if (_connectedNodeId == null) return;
    try {
      final response =
          await _send(const FlutterRemoteControlRequest.getState());
      _handleResponse(response);
    } catch (_) {
      // A dead transport already reported connectionLost via `_send`; a
      // background poll has nothing further useful to do with the error.
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _positionTicker?.cancel();

    _pollTimer = Timer.periodic(
      _remoteUiVisible ? _visiblePollInterval : _backgroundPollInterval,
      (_) => unawaited(_pollOnce()),
    );

    // Only bother interpolating between real polls while something is
    // actually showing a scrubber; the background cadence above is already
    // coarse on purpose.
    if (_remoteUiVisible) {
      _positionTicker = Timer.periodic(_interpolationInterval, (_) {
        final snapshot = _lastSnapshot;
        final at = _lastSnapshotAt;
        if (snapshot == null || at == null) return;
        _positions.add(_positionAt(snapshot, at));
      });
    }
  }

  void _applySnapshot(FlutterPlaybackSnapshot snapshot) {
    final lastSequence = _lastSequence;
    if (lastSequence != null && snapshot.sequence <= lastSequence) {
      // Stale or duplicate: another controller's poll (or our own retried
      // one) already rendered something newer. Keeping the newer one is
      // what stops two controllers from fighting over the displayed state.
      return;
    }

    final at = _now();
    _lastSequence = snapshot.sequence;
    _lastSnapshot = snapshot;
    _lastSnapshotAt = at;

    _states.add(_toCastPlaybackState(snapshot.state));
    _durations.add(Duration(milliseconds: snapshot.durationMs.toInt()));
    _positions.add(_positionAt(snapshot, at));
    final volume = snapshot.volume;
    if (volume != null) _volumes.add(volume);
  }

  /// The position to show right now: the snapshot's own position, projected
  /// forward by however much wall clock has passed since it was captured —
  /// but only while the target was actually playing. A paused or buffering
  /// snapshot never advances just because time passed.
  Duration _positionAt(FlutterPlaybackSnapshot snapshot, DateTime capturedAt) {
    final base = Duration(milliseconds: snapshot.positionMs.toInt());
    if (snapshot.state != FlutterPlaybackState.playing) return base;

    final elapsed = _now().difference(capturedAt);
    final projected = base + (elapsed.isNegative ? Duration.zero : elapsed);

    final duration = Duration(milliseconds: snapshot.durationMs.toInt());
    if (duration > Duration.zero && projected > duration) return duration;
    return projected;
  }

  CastPlaybackState _toCastPlaybackState(FlutterPlaybackState state) {
    switch (state) {
      case FlutterPlaybackState.idle:
        return CastPlaybackState.idle;
      case FlutterPlaybackState.loading:
      case FlutterPlaybackState.buffering:
        return CastPlaybackState.buffering;
      case FlutterPlaybackState.playing:
        return CastPlaybackState.playing;
      case FlutterPlaybackState.paused:
        return CastPlaybackState.paused;
      case FlutterPlaybackState.ended:
      case FlutterPlaybackState.error:
        return CastPlaybackState.idle;
    }
  }
}
