import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'toast_models.dart';

/// The window edge an obstruction occupies.
enum ToastEdge { left, bottom }

/// One obstruction's footprint, in the toast layer's coordinates.
@immutable
class ToastClaim {
  const ToastClaim(this.edge, this.rect);

  final ToastEdge edge;
  final Rect rect;

  @override
  bool operator ==(Object other) =>
      other is ToastClaim && other.edge == edge && other.rect == rect;

  @override
  int get hashCode => Object.hash(edge, rect);
}

/// State behind `ToastLayer`: the toast on screen, its timer, and the
/// obstructions the pill has to clear.
///
/// A plain [ChangeNotifier], not a Riverpod provider. Obstructions register
/// and retract from widget lifecycles, including `dispose`, which is exactly
/// where `player/docs/riverpod.md` documents Riverpod refusing writes.
///
/// The countdown is a [Timer], not an animation: an animation would keep
/// scheduling frames, and every `pumpAndSettle` in the suite would then run a
/// visible toast all the way to dismissal. `SnackBar` does the same.
class ToastController extends ChangeNotifier {
  ToastEntry? _current;
  Timer? _timer;
  int _nextId = 0;
  bool _disposed = false;
  final Map<Object, ToastClaim> _claims = {};

  /// Mirrors `MediaQuery.accessibleNavigationOf` at the layer. When true, a
  /// toast with an action waits to be dismissed instead of timing out, since
  /// a screen-reader user may not reach its button in time.
  bool accessibleNavigation = false;

  /// The layer's own render box, set by `ToastLayer`. Obstructions measure
  /// themselves against it.
  RenderBox? Function()? layerBox;

  ToastEntry? get current => _current;

  ToastEntry show(
    String message, {
    ToastKind kind = ToastKind.info,
    IconData? icon,
    ToastAction? action,
    Duration? duration,
  }) {
    final entry = ToastEntry(
      id: _nextId++,
      message: message,
      kind: kind,
      icon: kind == ToastKind.info ? icon : null,
      action: action,
      duration: duration ??
          ToastMetrics.defaultDuration(kind, hasAction: action != null),
    );
    if (_disposed) return entry;
    _current = entry;
    _startTimer(entry);
    notifyListeners();
    return entry;
  }

  /// Closes the toast shown as [id]. A no-op once another toast replaced it,
  /// it timed out, or it was dismissed.
  void close(int id) {
    if (_disposed || _current?.id != id) return;
    _cancelTimer();
    _current = null;
    notifyListeners();
  }

  /// Stops [id]'s countdown while the pointer rests on it.
  void pause(int id) {
    if (_current?.id != id) return;
    _cancelTimer();
  }

  /// Restarts [id]'s countdown at its full duration.
  void resume(int id) {
    final entry = _current;
    if (_disposed || entry == null || entry.id != id) return;
    _startTimer(entry);
  }

  void _startTimer(ToastEntry entry) {
    _cancelTimer();
    if (entry.action != null && accessibleNavigation) return;
    _timer = Timer(entry.duration, () => close(entry.id));
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void setClaim(Object token, ToastClaim claim) {
    if (_disposed || _claims[token] == claim) return;
    _claims[token] = claim;
    notifyListeners();
  }

  void removeClaim(Object token) {
    if (_disposed || _claims.remove(token) == null) return;
    notifyListeners();
  }

  /// How far in from the left, and up from the bottom, of a [layerSize]
  /// layer the pill has to stay.
  EdgeInsets insetsFor(Size layerSize) {
    var left = 0.0;
    var bottom = 0.0;
    for (final claim in _claims.values) {
      switch (claim.edge) {
        case ToastEdge.left:
          left = math.max(left, claim.rect.right);
        case ToastEdge.bottom:
          bottom = math.max(bottom, layerSize.height - claim.rect.top);
      }
    }
    return EdgeInsets.only(
      left: math.min(left, layerSize.width),
      bottom: math.min(bottom, layerSize.height),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelTimer();
    super.dispose();
  }
}
