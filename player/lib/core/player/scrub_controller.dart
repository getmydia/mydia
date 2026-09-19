import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Which way a D-pad press moves the scrub cursor.
enum ScrubDirection { backward, forward }

/// Cursor state for scrubbing with a remote's D-pad.
///
/// A pointer scrub is one gesture: press, drag, release, seek. A remote has
/// only discrete presses and key repeat, so the cursor has to live somewhere
/// between presses, and this is where. Playback continues while the cursor
/// moves, and exactly one seek is made per scrub, on [commit], because on an
/// HLS transcode every seek can cost a rebuffer.
///
/// Free of media_kit and widgets so the timing rules can be tested with
/// `fake_async`. Positions arrive through `position` and `duration`, which
/// the player screen maps through its `StreamTimeline`, and the clock is
/// injectable through `elapsed`.
class ScrubController extends ChangeNotifier {
  ScrubController({
    required Duration Function() position,
    required Duration Function() duration,
    required Future<void> Function(Duration target) onCommit,
    Duration Function()? elapsed,
  })  : _position = position,
        _duration = duration,
        _onCommit = onCommit,
        _elapsed = elapsed ?? _stopwatch();

  /// How far one press moves the cursor.
  static const Duration tapStep = Duration(seconds: 10);

  /// How long the cursor may sit still before the scrub commits itself.
  static const Duration idleCommit = Duration(milliseconds: 1500);

  /// How close playback must get to a committed target to count as there.
  static const Duration settleTolerance = Duration(seconds: 3);

  /// The longest the cursor waits for playback to reach a committed target.
  static const Duration settleTimeout = Duration(seconds: 10);

  /// How often a settling cursor checks whether playback has arrived.
  static const Duration settlePoll = Duration(milliseconds: 250);

  /// Hold time at which a held key moves to [mediumSpeed].
  static const Duration mediumHold = Duration(milliseconds: 1500);

  /// Hold time at which a held key moves to the fast tier.
  static const Duration fastHold = Duration(seconds: 3);

  /// 30 s of media per second held, in media ms per wall-clock ms.
  static const double slowSpeed = 30;

  /// 2 min of media per second held, in media ms per wall-clock ms.
  static const double mediumSpeed = 120;

  /// How fast a held key moves the cursor, in media milliseconds per
  /// wall-clock millisecond, once the key has been down for [held].
  ///
  /// Chosen by hold time rather than by counting repeat events, so the feel
  /// does not depend on the device's key repeat rate.
  static double speedFor(Duration held, Duration runtime) {
    if (held < mediumHold) return slowSpeed;
    if (held < fastHold) return mediumSpeed;
    // A tenth of the runtime per second, never slower than the medium tier.
    return math.max(mediumSpeed, runtime.inMilliseconds / 10000);
  }

  static Duration Function() _stopwatch() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  final Duration Function() _position;
  final Duration Function() _duration;
  final Future<void> Function(Duration target) _onCommit;
  final Duration Function() _elapsed;

  Duration? _origin;
  Duration? _cursor;
  Duration? _settlingTarget;
  Duration _holdStartedAt = Duration.zero;
  Duration _lastStepAt = Duration.zero;
  Duration _settleStartedAt = Duration.zero;
  Timer? _idleTimer;
  Timer? _settleTimer;

  /// Whether a scrub is in progress: the cursor is moving and nothing has
  /// been sought yet.
  bool get active => _cursor != null;

  /// Where the scrub started. Null when no scrub is active.
  Duration? get origin => _origin;

  /// Where the scrub would seek to now. Null when no scrub is active.
  Duration? get cursor => _cursor;

  /// Where the bar should draw the scrub cursor: the live cursor while
  /// scrubbing, then the committed target until playback reaches it.
  Duration? get displayPosition => _cursor ?? _settlingTarget;

  /// [displayPosition] as a 0..1 fraction of the runtime, or null when there
  /// is nothing to draw or the runtime is unknown.
  double? get displayFraction {
    final shown = displayPosition;
    final total = _duration();
    if (shown == null || total <= Duration.zero) return null;
    return (shown.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
  }

  /// Moves the cursor one press or one repeat in [direction], starting a
  /// scrub if none is active.
  ///
  /// Returns false, and changes nothing, when the runtime is unknown: a
  /// cursor has nothing to be a fraction of, and the caller falls back to a
  /// plain skip.
  bool step(ScrubDirection direction, {required bool isRepeat}) {
    final total = _duration();
    if (total <= Duration.zero) return false;

    final now = _elapsed();
    final continuing = active;
    if (!continuing) {
      // A scrub started while a commit is still settling continues from that
      // target: during a stream restart the playing position is stale.
      _origin = _clamp(_settlingTarget ?? _position(), total);
      _cursor = _origin;
      _stopSettling();
    }

    final Duration distance;
    if (isRepeat && continuing) {
      final wall = now - _lastStepAt;
      final speed = speedFor(now - _holdStartedAt, total);
      distance = Duration(milliseconds: (wall.inMilliseconds * speed).round());
    } else {
      _holdStartedAt = now;
      distance = tapStep;
    }
    _lastStepAt = now;

    final signed = direction == ScrubDirection.forward ? distance : -distance;
    _cursor = _clamp(_cursor! + signed, total);
    _idleTimer?.cancel();
    _idleTimer = Timer(idleCommit, () => unawaited(commit()));
    notifyListeners();
    return true;
  }

  /// Seeks to the cursor and ends the scrub. A no-op when none is active.
  Future<void> commit() async {
    final target = _cursor;
    if (target == null) return;

    _idleTimer?.cancel();
    _idleTimer = null;
    _cursor = null;
    _origin = null;
    _startSettling(target);
    notifyListeners();
    try {
      await _onCommit(target);
    } catch (e) {
      // Reached from a timer as often as from a key press, where nothing
      // would catch it. The settling timeout still releases the cursor.
      debugPrint('[ScrubController] Commit to $target failed: $e');
    }
  }

  /// Ends an active scrub without seeking. A settling target is left alone:
  /// it belongs to a seek that has already been made.
  void cancel() {
    if (!active) return;
    _idleTimer?.cancel();
    _idleTimer = null;
    _cursor = null;
    _origin = null;
    notifyListeners();
  }

  /// Clears everything, including a settling target, for when the player the
  /// positions describe is going away.
  void reset() {
    final hadState = active || _settlingTarget != null;
    _idleTimer?.cancel();
    _idleTimer = null;
    _cursor = null;
    _origin = null;
    _stopSettling();
    if (hadState) notifyListeners();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _settleTimer?.cancel();
    _cursor = null;
    _origin = null;
    _settlingTarget = null;
    super.dispose();
  }

  void _startSettling(Duration target) {
    _settleTimer?.cancel();
    _settlingTarget = target;
    _settleStartedAt = _elapsed();
    _settleTimer = Timer.periodic(settlePoll, (_) => _checkSettled());
  }

  void _stopSettling() {
    _settleTimer?.cancel();
    _settleTimer = null;
    _settlingTarget = null;
  }

  void _checkSettled() {
    final target = _settlingTarget;
    if (target == null) return;
    final arrived = (_position() - target).abs() <= settleTolerance;
    final expired = _elapsed() - _settleStartedAt >= settleTimeout;
    if (!arrived && !expired) return;
    _stopSettling();
    notifyListeners();
  }

  static Duration _clamp(Duration value, Duration total) {
    if (value < Duration.zero) return Duration.zero;
    if (value > total) return total;
    return value;
  }
}
