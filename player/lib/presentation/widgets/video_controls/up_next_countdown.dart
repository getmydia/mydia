import 'dart:async';

import 'package:flutter/foundation.dart';

/// How long the prompt waits before playing the next episode.
///
/// The same value for an episode crossing and a season crossing: a longer
/// countdown for the bigger jump was considered and dropped, because two
/// durations means two things for the ring to mean.
const kUpNextCountdown = Duration(seconds: 10);

/// Why the countdown is currently held.
///
/// A set rather than a bool, so two independent reasons cannot clobber each
/// other: a viewer who pauses playback *and* hovers the prompt must still be
/// held after the pointer leaves.
enum UpNextHold {
  /// The pointer is over the prompt, it holds focus, or it is expanded.
  engaged,

  /// Playback itself is paused.
  paused,
}

/// The auto-play countdown.
///
/// Owns the timer, the holds, and the race guard, so `player_screen` does not
/// have to and so all three can be tested with `fakeAsync` and an injected
/// clock rather than against the wall clock.
///
/// Exposes [fraction] rather than a raw second count plus a total. The ring
/// that renders it therefore never learns the duration, which is what removes
/// the old `value: seconds / 10` hardcode structurally instead of merely
/// correcting the divisor.
class UpNextCountdown extends ChangeNotifier {
  UpNextCountdown({
    this.total = kUpNextCountdown,
    required this.onElapsed,
    this.raceGuard = const Duration(seconds: 1),
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        _remaining = total;

  final Duration total;

  /// Called at most once, when the countdown has drained and the race guard
  /// allows it.
  final VoidCallback onElapsed;

  /// Auto-play never fires within this long of the last [noteInput].
  ///
  /// This is what makes "I was reaching for Dismiss and it went anyway"
  /// impossible rather than merely unlikely: engaging at all pushes the fire
  /// out, so the viewer cannot lose the race.
  final Duration raceGuard;

  final DateTime Function() _clock;
  final Set<UpNextHold> _holds = <UpNextHold>{};

  Timer? _ticker;
  Duration _remaining;
  DateTime? _lastInput;
  bool _finished = false;

  Duration get remaining => _remaining;

  /// Remaining share of [total], 1.0 down to 0.0.
  double get fraction {
    final totalMs = total.inMilliseconds;
    if (totalMs <= 0) return 0;
    return _remaining.inMilliseconds / totalMs;
  }

  bool get isHeld => _holds.isNotEmpty;

  void start() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void hold(UpNextHold reason) {
    if (_holds.add(reason)) notifyListeners();
  }

  void release(UpNextHold reason) {
    if (!_holds.remove(reason)) return;
    notifyListeners();
    if (_remaining <= Duration.zero) _maybeElapse();
  }

  /// Records that the viewer did something. Resets the [raceGuard] window.
  void noteInput() => _lastInput = _clock();

  /// Stops the countdown permanently. Synchronous on purpose: `PlaybackChrome`
  /// was bitten by deriving state from an `AnimationController` status that
  /// lagged a frame, which is why its `_visible` is a plain field. A dismiss
  /// that only takes effect next frame can lose to a fire scheduled this one.
  void cancel() {
    _finished = true;
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    super.dispose();
  }

  void _tick() {
    if (_finished || isHeld) return;
    if (_remaining > Duration.zero) {
      _remaining -= const Duration(seconds: 1);
      if (_remaining < Duration.zero) _remaining = Duration.zero;
      notifyListeners();
    }
    if (_remaining <= Duration.zero) _maybeElapse();
  }

  void _maybeElapse() {
    if (_finished || isHeld) return;
    final last = _lastInput;
    if (last != null && _clock().difference(last) <= raceGuard) {
      // Inside the guard. Leave the ticker running; the next tick retries.
      return;
    }
    _finished = true;
    _ticker?.cancel();
    _ticker = null;
    onElapsed();
  }
}
