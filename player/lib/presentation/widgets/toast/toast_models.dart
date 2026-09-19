import 'package:flutter/widgets.dart';

/// What a toast reports. Picks the leading glyph and the default duration;
/// the pill itself is the same neutral glass for every kind.
enum ToastKind { info, success, error, progress }

/// The one optional button a toast can carry.
@immutable
class ToastAction {
  const ToastAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;
}

/// A single `show` call. [id] is unique per call, which is how a
/// `ToastHandle` tells whether its toast is still the one on screen.
@immutable
class ToastEntry {
  const ToastEntry({
    required this.id,
    required this.message,
    required this.kind,
    required this.duration,
    this.icon,
    this.action,
  });

  final int id;
  final String message;
  final ToastKind kind;
  final Duration duration;

  /// Only honoured for [ToastKind.info]; the other kinds own their glyph so
  /// severity is never restyled per call site.
  final IconData? icon;

  final ToastAction? action;
}

/// Geometry and timing for the toast pill and the layer that places it.
abstract final class ToastMetrics {
  /// Widest a pill gets on a large window.
  static const double maxWidth = 420;

  /// Corner radius. A single-line pill is about 44 tall, so this reads as a
  /// full stadium. The mobile dock's pill uses the same 22.
  static const double radius = 22;

  /// Clearance from the sides of the area the pill centres in.
  static const double gutter = 16;

  /// Space between the pill and the tallest bottom obstruction.
  static const double obstructionGap = 16;

  /// Space between the pill and the bottom safe area when nothing obstructs.
  static const double restingGap = 24;

  /// How far the pill rises on entry and sinks on exit.
  static const double rise = 8;

  static const int maxLines = 3;

  static const Duration shortDuration = Duration(seconds: 3);
  static const Duration errorDuration = Duration(seconds: 5);
  static const Duration actionDuration = Duration(seconds: 8);

  /// A progress toast is closed by its caller; this only catches a caller
  /// that never does.
  static const Duration progressTimeout = Duration(seconds: 30);

  static Duration defaultDuration(ToastKind kind, {required bool hasAction}) {
    if (kind == ToastKind.progress) return progressTimeout;
    if (hasAction) return actionDuration;
    if (kind == ToastKind.error) return errorDuration;
    return shortDuration;
  }
}
