import 'dart:async';

import '../../domain/models/cast_device.dart';
import '../../native/lib.dart';

/// Bound on how many Mydia peers this app holds an open, polled connection
/// to at once. A large roster could easily have more than this playing
/// something at once, but ambient awareness only needs "enough to be
/// useful" — three is generous for "the number of rooms with a screen in
/// them".
///
/// This bounds the *recurring* poll cost, not [sweep]'s one-shot roster fan
/// out: [sweep] still dials every rostered device once, same as
/// `MydiaCastBackend._discover`. It is [AmbientTargets._refreshHeld] — the
/// thing that repeats every [_pollInterval] for as long as something is
/// held — that this cap actually keeps flat regardless of roster size, by
/// dialing only the held IDs instead of re-running the whole sweep.
const _maxHeldTargets = 3;

/// How often a held connection's snapshot is refreshed. Matches
/// `MydiaCastBackend`'s own background poll cadence
/// (`_backgroundPollInterval` in `mydia_cast_backend.dart`) — ambient
/// awareness is background-grade by definition; nothing reading it here is
/// ever the foregrounded remote-control screen.
const _pollInterval = Duration(seconds: 5);

/// Answers one node's current playback snapshot, or `null` if it is idle,
/// unreachable, or timed out.
///
/// Unreachable, genuinely idle, and timed-out all fold into `null` —
/// [AmbientTargets] only ever needs to tell "hold this" from "don't", not
/// why a given device didn't qualify.
///
/// Deliberately per-node rather than bulk. [AmbientTargets] fans this out
/// itself in two different shapes with two different cost profiles: once
/// over the *whole roster* in [AmbientTargets.sweep], and separately over
/// only the *held* IDs (at most [_maxHeldTargets]) on every 5-second
/// refresh. Giving [AmbientTargets] a per-node primitive instead of a bulk
/// one is what lets the refresh's cost be bounded by the cap instead of by
/// roster size. It also mirrors production shape one file over:
/// `MydiaCastBackend`'s own poll timer re-dials only the single connected
/// node (`_pollOnce`/`_send` against `_connectedNodeId`), never re-runs
/// `_discover()`.
typedef AmbientNodeProbe = Future<FlutterPlaybackSnapshot?> Function(
  String nodeId,
);

/// Lists the roster's node IDs to sweep. Mirrors `RemoteRoster.entries()`
/// mapped down to bare IDs — kept abstract, like [AmbientNodeProbe], so a
/// test can script a roster directly instead of standing up a real
/// `RemoteRoster`.
typedef AmbientRosterSource = Future<List<String>> Function();

/// One peer this app is holding an ambient connection to, because it is
/// already playing something nobody here started.
class AmbientTarget {
  /// The peer. Only the node ID comes from the probe — an [AmbientNodeProbe]
  /// answers with a snapshot and nothing else, so [CastDevice.name] here is
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
/// [onBackground] drops every held connection outright; recovery is the
/// next [sweep] — expected to be fired by the caller on the next foreground
/// transition — not a reconnect loop run from in here.
///
/// That much is deliberately dumb, but the backgrounded state itself is
/// authoritative here, not merely advisory: [sweep] is a no-op for as long
/// as [onBackground] was the last transition heard, until [onForeground]
/// says otherwise. This is what [AmbientLifecycleBinding]
/// (`ambient_lifecycle.dart`) relies on to make its own foreground-recovery
/// [sweep] call the *only* [sweep] that can repopulate [_held] while
/// backgrounded — `ambientPlayingProvider`'s (`cast_providers.dart`) own
/// 30-second resweep timer keeps calling plain `sweep()` for as long as
/// `CastMiniController` holds a listener, which is permanently, background
/// included, and without this guard that timer alone was enough to undo
/// [onBackground] within half a minute: it repopulated [_held] and
/// restarted the 5-second poll, defeating the entire point of dropping
/// connections on background in the first place (unbounded p2p connection
/// and polling cost behind a backgrounded window — exactly what the cap on
/// held targets exists to prevent).
class AmbientTargets {
  final AmbientRosterSource rosterSource;
  final AmbientNodeProbe probe;

  AmbientTargets({required this.rosterSource, required this.probe});

  List<AmbientTarget> _held = const [];
  final _updates = StreamController<List<AmbientTarget>>.broadcast();
  Timer? _pollTimer;

  /// Set by [onBackground], cleared by [onForeground]. While `true`,
  /// [sweep] returns immediately without touching [rosterSource] or
  /// [probe] at all — not just discarding the result — so a backgrounded
  /// app pays no roster-wide dial cost no matter how often some other
  /// timer calls [sweep].
  bool _backgrounded = false;

  /// The currently held targets, replayed to every new listener before any
  /// later update. Without the replay, `await playing.first` right after
  /// [sweep] would hang past that sweep's own result: nothing was listening
  /// on the broadcast stream while [sweep] ran, so a plain `.add` would have
  /// been dropped with no subscriber to deliver it to.
  ///
  /// This getter is `async*`, which makes every read a fresh
  /// single-subscription `Stream` — listening to the *same* returned
  /// `Stream` object twice throws `StateError`. Read `.playing` again for
  /// each new subscriber (e.g. hand it straight to a `StreamBuilder`
  /// rather than storing it in a field); never cache the `Stream` reference
  /// and share it across listeners.
  Stream<List<AmbientTarget>> get playing async* {
    yield _held;
    yield* _updates.stream;
  }

  /// Probes every rostered device once, in parallel, and holds a connection
  /// to whichever ones answered playing — capped at [_maxHeldTargets],
  /// taking the first three in roster order — then starts polling those.
  ///
  /// This is the expensive operation: it dials the whole roster, the same
  /// shape as `MydiaCastBackend._discover`. The cap does not make *this*
  /// cheaper; see [_refreshHeld] for the operation it actually bounds.
  ///
  /// A no-op while [_backgrounded] — see the class doc for why that has to
  /// be true regardless of which caller's timer is the one dialing this.
  Future<void> sweep() async {
    if (_backgrounded) return;
    final ids = await rosterSource();
    // A background transition can land while the roster fetch above was in
    // flight. Checking only at entry (the guard two lines up) is not
    // enough — `AmbientLifecycleBinding._sweep` only compensates for its
    // own call, and `ambientPlayingProvider`'s 30-second resweep timer
    // keeps calling this regardless of foreground state (see the class
    // doc), so a sweep already past its first await has to re-check itself
    // rather than assume nothing changed underneath it.
    if (_backgrounded) return;
    final probed = await Future.wait(ids.map((id) async {
      final snapshot = await probe(id);
      return MapEntry(id, snapshot);
    }));
    // Same reasoning, after the second await: a background transition that
    // arrived while the probe fan-out was in flight must win. Publishing
    // here would repopulate `_held` and restart the poll timer behind a
    // backgrounded app — exactly the state this guard exists to prevent.
    if (_backgrounded) return;
    _setHeld(_takePlaying(Map.fromEntries(probed)));
    _restartPolling();
  }

  /// Drops every held connection immediately and marks [sweep] inert until
  /// [onForeground] says otherwise. Does not itself reconnect — see the
  /// class doc; the next [sweep] *after* [onForeground] is what recovers.
  void onBackground() {
    _backgrounded = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    _setHeld(const []);
  }

  /// Re-arms [sweep], undoing [onBackground]. Called by
  /// [AmbientLifecycleBinding] immediately before the [sweep] it fires on a
  /// genuine `resumed` transition — that ordering is what lets *that*
  /// specific call through while every other caller's [sweep] keeps
  /// no-oping for as long as [onBackground] was the last transition heard.
  void onForeground() {
    _backgrounded = false;
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
    // Guards against `sweep()` being called after `dispose()`: without the
    // `isClosed` check, this would start a fresh, uncancellable
    // `Timer.periodic` — `_setHeld`'s own `isClosed` guard only silences
    // the emit, it does not stop the timer from existing.
    _pollTimer = (_held.isEmpty || _updates.isClosed)
        ? null
        : Timer.periodic(_pollInterval, (_) => unawaited(_refreshHeld()));
  }

  /// Refreshes the snapshot for each currently held target — genuinely
  /// bounded to at most [_maxHeldTargets] calls to [probe] per tick, never
  /// the whole roster, because it probes only the IDs already in [_held]
  /// instead of re-running [sweep]'s roster-wide fan-out.
  ///
  /// Membership is only ever decided by [sweep]: this drops a target that
  /// stops reporting playing, but never promotes a newly-playing one into
  /// the held set. **That is a deliberate product decision, not an
  /// oversight**: promoting here would make this poll timer a second,
  /// undeclared discovery path running behind [sweep]'s back. The
  /// consequence is a staleness window — a device that starts playing while
  /// the user is looking at the ambient banner stays invisible until the
  /// next [sweep] — and it is whoever drives [sweep]'s cadence (not this
  /// class) that decides how wide that window gets.
  Future<void> _refreshHeld() async {
    if (_held.isEmpty) return;
    final probed = await Future.wait(_held.map((target) async {
      final snapshot = await probe(target.device.id);
      return MapEntry(target, snapshot);
    }));
    final refreshed = <AmbientTarget>[
      for (final entry in probed)
        if (entry.value != null)
          AmbientTarget(device: entry.key.device, snapshot: entry.value!),
    ];
    _setHeld(refreshed);
    if (_held.isEmpty) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }
}
