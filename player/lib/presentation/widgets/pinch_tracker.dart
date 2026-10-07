import 'dart:ui' show Offset;

import '../../core/player/video_scaling.dart';

/// Turns raw pointer events into a Fit/Fill decision.
///
/// Fed from a `Listener`, so it never enters the gesture arena (see
/// `GestureControls.onPinch`). Tracks the first two fingers down and compares
/// their distance when one lifts with the distance when the second landed.
/// Spreading past [fillRatio] asks for Fill, pinching under [fitRatio] asks
/// for Fit, and anything between is a wobble that asks for nothing. No live
/// zoom: the result arrives once, on lift.
class PinchTracker {
  static const double fillRatio = 1.15;
  static const double fitRatio = 0.87;

  final Map<int, Offset> _positions = {};
  int? _first;
  int? _second;
  double? _startDistance;

  /// True from the moment the second tracked finger lands until the pinch
  /// ends, by a lift or a cancel. `GestureControls` stands its vertical-drag
  /// volume and brightness handling down while this holds.
  bool get pinching => _startDistance != null;

  void down(int pointer, Offset position) {
    _positions[pointer] = position;
    if (_first == null) {
      _first = pointer;
    } else if (_second == null) {
      _second = pointer;
      _startDistance = _distance();
    }
  }

  void move(int pointer, Offset position) {
    if (_positions.containsKey(pointer)) _positions[pointer] = position;
  }

  /// The decision when the lift ends a two-finger pinch, otherwise null.
  VideoScaling? up(int pointer) {
    VideoScaling? result;
    final start = _startDistance;
    if (start != null && start > 0 && _tracked(pointer)) {
      final ratio = _distance() / start;
      if (ratio > fillRatio) result = VideoScaling.fill;
      if (ratio < fitRatio) result = VideoScaling.fit;
      // One report per pinch: the other finger lifting next must not
      // report again.
      _startDistance = null;
    }
    _forget(pointer);
    return result;
  }

  void cancel(int pointer) {
    if (_tracked(pointer)) _startDistance = null;
    _forget(pointer);
  }

  bool _tracked(int pointer) => pointer == _first || pointer == _second;

  double _distance() => (_positions[_first]! - _positions[_second]!).distance;

  void _forget(int pointer) {
    _positions.remove(pointer);
    if (pointer == _first) _first = null;
    if (pointer == _second) _second = null;
    if (_first == null && _second == null) _startDistance = null;
  }
}
