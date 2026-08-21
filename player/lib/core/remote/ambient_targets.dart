import 'dart:async';

import '../../domain/models/cast_device.dart';
import '../../native/lib.dart';

/// Bound on how many Mydia peers this app holds an open, polled connection
/// to at once. A large roster could easily have more than this playing
/// something at once, but ambient awareness only needs "enough to be
/// useful" — three is generous for "the number of rooms with a screen in
/// them" while keeping the poll cost flat regardless of roster size.
const _maxHeldTargets = 3;

/// How often a held connection's snapshot is refreshed. Matches
/// `MydiaCastBackend`'s own background poll cadence
/// (`_backgroundPollInterval` in `mydia_cast_backend.dart`) — ambient
/// awareness is background-grade by definition; nothing reading it here is
/// ever the foregrounded remote-control screen.
const _pollInterval = Duration(seconds: 5);

/// Sweeps every device on the roster and reports each one's current
/// playback snapshot, or `null` for a device that is not playing.
///
/// Unreachable, genuinely idle, and timed-out all fold into `null` —
/// [AmbientTargets] only ever needs to tell "hold this" from "don't", not
/// why a given device didn't qualify.
///
/// Bulk (no node ID in, the whole roster's answers out) rather than
/// per-node, and deliberately so: the real implementation already has to
/// fan out across the whole roster in parallel to answer this at all — the
/// same shape as `MydiaCastBackend._discover` — so that fan-out belongs
/// behind one call rather than being redone inside [AmbientTargets]. It is
/// also what lets [AmbientTargets] work from nothing but this one
/// function: no `RemoteRoster`, no `MydiaControlTransport`, no iroh node,
/// so a test can script it directly instead of standing up either.
typedef AmbientProbe = Future<Map<String, FlutterPlaybackSnapshot?>> Function();

/// One peer this app is holding an ambient connection to, because it is
/// already playing something nobody here started.
class AmbientTarget {
  /// The peer. Only [CastDevice.id] comes from the sweep — an [AmbientProbe]
  /// result carries a node ID and nothing else, so [CastDevice.name] here is
  /// just that same ID standing in for one. A caller that wants "Living
  /// Room" rather than a bare node ID has to resolve it itself, e.g.
  /// against the roster or the picker's already-discovered device list.
  final CastDevice device;

  final FlutterPlaybackSnapshot snapshot;

  const AmbientTarget({required this.device, required this.snapshot});
}

/// Ambient awareness of what *other* paired players are already doing.
///
/// A discovery sweep (`MydiaCastBackend.startDiscovery`) answers "what can
/// I connect to"; this answers "what is already playing, right now, that I
/// never started" — the difference that lets a controller show "Playing on
/// Living Room" without the user opening a picker first.
///
/// Deliberately dumb about backgrounding: [onBackground] just drops every
/// held connection outright. Recovery is the next [sweep] — expected to be
/// fired by the caller on the next foreground transition — not a reconnect
/// loop run from in here.
class AmbientTargets {
  final AmbientProbe probe;

  AmbientTargets({required this.probe});

  List<AmbientTarget> _held = const [];
  final _updates = StreamController<List<AmbientTarget>>.broadcast();
  Timer? _pollTimer;

  /// The currently held targets, replayed to every new listener before any
  /// later update. Without the replay, `await playing.first` right after
  /// [sweep] would hang past that sweep's own result: nothing was listening
  /// on the broadcast stream while [sweep] ran, so a plain `.add` would have
  /// been dropped with no subscriber to deliver it to.
  Stream<List<AmbientTarget>> get playing async* {
    yield _held;
    yield* _updates.stream;
  }

  /// Probes the whole roster once, holds a connection to whichever targets
  /// answered playing — capped at three, taking the first three the probe
  /// result reports in iteration order (roster order, for the production
  /// probe) — and starts polling those.
  Future<void> sweep() async {
    final results = await probe();
    _setHeld(_takePlaying(results));
    _restartPolling();
  }

  /// Drops every held connection immediately. Does not itself reconnect —
  /// see the class doc; the next [sweep] is what recovers.
  void onBackground() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _setHeld(const []);
  }

  Future<void> dispose() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    await _updates.close();
  }

  List<AmbientTarget> _takePlaying(
    Map<String, FlutterPlaybackSnapshot?> results,
  ) {
    final held = <AmbientTarget>[];
    for (final entry in results.entries) {
      if (held.length >= _maxHeldTargets) break;
      final snapshot = entry.value;
      if (snapshot == null) continue;
      held.add(AmbientTarget(
        device: CastDevice(
          id: entry.key,
          name: entry.key,
          protocol: CastProtocolKind.mydia,
        ),
        snapshot: snapshot,
      ));
    }
    return held;
  }

  void _setHeld(List<AmbientTarget> held) {
    _held = List.unmodifiable(held);
    if (!_updates.isClosed) _updates.add(_held);
  }

  void _restartPolling() {
    _pollTimer?.cancel();
    _pollTimer = _held.isEmpty
        ? null
        : Timer.periodic(_pollInterval, (_) => unawaited(_refreshHeld()));
  }

  /// Refreshes the snapshot for each currently held target from a fresh
  /// probe. Membership is only ever decided by [sweep]: this drops a target
  /// that stops reporting playing, but never promotes a newly-playing one
  /// into the held set, since that would make the poll timer a second,
  /// undeclared discovery path running behind [sweep]'s back.
  Future<void> _refreshHeld() async {
    if (_held.isEmpty) return;
    final results = await probe();
    final refreshed = <AmbientTarget>[];
    for (final target in _held) {
      final snapshot = results[target.device.id];
      if (snapshot == null) continue;
      refreshed.add(AmbientTarget(device: target.device, snapshot: snapshot));
    }
    _setHeld(refreshed);
    if (_held.isEmpty) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }
}
