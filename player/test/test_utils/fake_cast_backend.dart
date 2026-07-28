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

  CastDevice? _connected;
  CastFailureKind? _pendingLoadFailure;
  CastFailureKind? _persistentLoadFailure;
  CastFailureKind? _pendingConnectFailure;
  bool discoveryStarted = false;
  bool discoveryStopped = false;
  CastSubtitleTrack? selectedSubtitle;

  void emitDevices(List<CastDevice> devices) => _devices.add(devices);
  void emitState(CastPlaybackState state) => _states.add(state);
  void emitPosition(Duration position) => _positions.add(position);
  void emitDuration(Duration duration) => _durations.add(duration);
  void emitFailure(CastFailureKind kind) => _failures.add(kind);

  /// Fail only the next `loadMedia` call, so a retry can succeed.
  void failNextLoad(CastFailureKind kind) => _pendingLoadFailure = kind;

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
    _connected = device;
  }

  @override
  Future<void> disconnect() async => _connected = null;

  @override
  Future<void> loadMedia(CastMediaRequest request) async {
    final persistent = _persistentLoadFailure;
    if (persistent != null) {
      throw CastBackendException('fake persistent load failure', persistent);
    }

    final failure = _pendingLoadFailure;
    if (failure != null) {
      _pendingLoadFailure = null;
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
      selectedSubtitle = track;

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
