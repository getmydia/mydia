import 'dart:async';

import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/domain/models/cast_device.dart';

/// Networkless [CastBackend] for tests. Emission is driver-controlled so tests
/// can script exact sequences instead of waiting on timers.
class FakeCastBackend implements CastBackend {
  final _devices = StreamController<List<CastDevice>>.broadcast();
  final _states = StreamController<CastPlaybackState>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _failures = StreamController<CastFailureKind>.broadcast();

  final List<CastMediaRequest> loadedRequests = [];
  final List<Duration> seeks = [];

  /// Every `connect` call, so tests can prove an open connection is reused
  /// rather than torn down and rebuilt.
  final List<CastDevice> connectAttempts = [];

  CastDevice? _connected;
  final List<CastFailureKind> _queuedLoadFailures = [];
  CastFailureKind? _persistentLoadFailure;
  CastFailureKind? _pendingConnectFailure;
  bool discoveryStarted = false;
  bool discoveryStopped = false;

  /// Every `selectSubtitle` call in order, including the nulls.
  ///
  /// A list rather than the last value: loading with subtitles off issues an
  /// explicit disable right after LOAD, and a test proving that has to see
  /// the call happened at all, not just what the final state settled on.
  final List<CastSubtitleTrack?> subtitleSelections = [];

  CastSubtitleTrack? get selectedSubtitle =>
      subtitleSelections.isEmpty ? null : subtitleSelections.last;

  /// Held open by [holdNextConnect] until [releaseConnect] completes it, so a
  /// test can observe state (a cancel, a second `connectTo`) while `connect`
  /// is still in flight — mirroring `DartCastBackend.connect`, whose await on
  /// the real transport is exactly the window a cancel or a double-pick races
  /// against.
  ///
  /// Left in place (not nulled) once a `connect` call starts waiting on it:
  /// [releaseConnect] has to be able to reach the same [Completer] a later
  /// call, so the field itself can't be the "has this already been claimed"
  /// flag — [_connectGateClaimed] is.
  Completer<void>? _connectGate;
  bool _connectGateClaimed = false;

  /// How many times [disconnect] has actually been called, so a test can
  /// prove a cancelled/superseded connect tore its connection down rather
  /// than merely being ignored.
  int disconnectCallCount = 0;

  /// Makes the *next* [connect] call suspend until [releaseConnect] is
  /// called, instead of resolving immediately. Only that one call waits —
  /// any later `connect` (e.g. a second, winning `connectTo`) proceeds
  /// normally even before [releaseConnect] runs.
  void holdNextConnect() {
    _connectGate = Completer<void>();
    _connectGateClaimed = false;
  }

  /// Lets the [connect] call gated by [holdNextConnect] proceed.
  void releaseConnect() {
    _connectGate?.complete();
  }

  /// What `probeReceiverContentUrl` reports. Null — the default, and what the
  /// real `DartCastBackend` always answers — means "cannot tell".
  String? receiverContentUrl;

  /// Devices the receiver was probed for, so tests can prove the probe ran
  /// before anything connected.
  final List<CastDevice> probedDevices = [];

  void emitDevices(List<CastDevice> devices) => _devices.add(devices);
  void emitState(CastPlaybackState state) => _states.add(state);
  void emitPosition(Duration position) => _positions.add(position);
  void emitDuration(Duration duration) => _durations.add(duration);
  void emitFailure(CastFailureKind kind) => _failures.add(kind);

  /// Fail only the next [times] `loadMedia` call(s), consumed in order, so a
  /// later attempt can succeed. Calling this more than once (or with
  /// `times > 1`) queues multiple failures — needed to script a
  /// `CastSessionManager` escalation that fails more than once before
  /// succeeding (e.g. direct -> bridge -> transcode).
  void failNextLoad(CastFailureKind kind, {int times = 1}) {
    for (var i = 0; i < times; i++) {
      _queuedLoadFailures.add(kind);
    }
  }

  /// Fail every `loadMedia` call, so retry exhaustion can be tested.
  void failAllLoads(CastFailureKind kind) => _persistentLoadFailure = kind;

  void failNextConnect(CastFailureKind kind) => _pendingConnectFailure = kind;

  @override
  Stream<List<CastDevice>> startDiscovery({
    required CastCapabilities capabilities,
    Duration timeout = const Duration(seconds: 10),
  }) {
    discoveryStarted = true;
    return _devices.stream;
  }

  @override
  void stopDiscovery() => discoveryStopped = true;

  @override
  Future<void> connect(CastDevice device) async {
    final failure = _pendingConnectFailure;
    if (failure != null) {
      _pendingConnectFailure = null;
      throw CastBackendException('fake connect failure', failure);
    }

    // Claimed before awaiting so a later `connect` call sees the gate is
    // already spoken for and proceeds without waiting — only the call that
    // arrives while `holdNextConnect` is armed actually blocks.
    final gate = _connectGate;
    if (gate != null && !_connectGateClaimed) {
      _connectGateClaimed = true;
      await gate.future;
    }

    connectAttempts.add(device);
    _connected = device;
  }

  @override
  Future<String?> probeReceiverContentUrl(CastDevice device) async {
    probedDevices.add(device);
    return receiverContentUrl;
  }

  @override
  Future<void> disconnect() async {
    disconnectCallCount++;
    _connected = null;
  }

  @override
  Future<void> loadMedia(CastMediaRequest request) async {
    final persistent = _persistentLoadFailure;
    if (persistent != null) {
      throw CastBackendException('fake persistent load failure', persistent);
    }

    if (_queuedLoadFailures.isNotEmpty) {
      final failure = _queuedLoadFailures.removeAt(0);
      throw CastBackendException('fake load failure', failure);
    }
    loadedRequests.add(request);
  }

  @override
  Future<void> play() async => _states.add(CastPlaybackState.playing);

  @override
  Future<void> pause() async => _states.add(CastPlaybackState.paused);

  @override
  Future<void> stop() async => _states.add(CastPlaybackState.idle);

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> selectSubtitle(CastSubtitleTrack? track) async =>
      subtitleSelections.add(track);

  @override
  Stream<CastPlaybackState> get stateStream => _states.stream;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Stream<Duration> get durationStream => _durations.stream;

  @override
  Stream<CastFailureKind> get failureStream => _failures.stream;

  @override
  CastDevice? get connectedDevice => _connected;

  @override
  Future<void> dispose() async {
    await _devices.close();
    await _states.close();
    await _positions.close();
    await _durations.close();
    await _failures.close();
  }
}
