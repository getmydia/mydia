import 'package:flutter/widgets.dart';

/// The logical canvas a television is presented with.
///
/// A television reports a large physical size at a low logical density, so the
/// canvas Flutter lays out on is much smaller than the panel. The reported
/// Chromecast with Google TV is 1920x1080 at density 320, i.e. a 960x540 logical
/// canvas at devicePixelRatio 2.0 — the ordinary Android TV canvas, and not a
/// bug in itself.
///
/// 960x540 is small enough that the app's own desktop tier is a poor fit for it:
/// the permanent sidebar alone takes 260 of those 960 logical pixels, and every
/// fixed-size label, icon and pad is proportionally twice the size of the same
/// element on a 1920-wide desktop window. Presenting a larger canvas to the
/// widget tree — this app's equivalent of a television UI scaling down its
/// density — is what makes the layout match the panel.
///
/// The scale is not a layout decision: no breakpoint, tier or structure is
/// computed here. It only decides how many logical pixels the tree is laid out
/// across.
abstract class TvCanvasScale {
  /// Canvas width a television is targeted at, in logical pixels.
  static const double targetWidth = 1280;

  /// Canvas height a television is targeted at, in logical pixels.
  static const double targetHeight = 720;

  /// The factor to shrink the physical canvas by, so that the tree is laid out
  /// across at least [targetWidth] x [targetHeight].
  ///
  /// Returns 1.0 — meaning "do nothing" — off the directional tier, and for any
  /// canvas already at or above the target. Scaling up is deliberately
  /// excluded: a telephone browser must not be magnified, and this method has
  /// no caller that wants that.
  ///
  /// The limiting axis wins. A canvas that is wider than 16:9 but shorter than
  /// 720 logical pixels is constrained by its height, and using the width
  /// instead would overflow the canvas vertically.
  static double computeScale({
    required Size logicalSize,
    required bool directionalPrimary,
  }) {
    // A zero-area canvas is a transient state (a window mid-resize, a test
    // viewport) and a factor of 0.0 would be divided into by the caller,
    // producing a NaN-sized box. Reporting "no scaling" keeps the caller's
    // arithmetic total.
    if (logicalSize.width <= 0 || logicalSize.height <= 0) return 1.0;

    if (!directionalPrimary) return 1.0;

    final byWidth = logicalSize.width / targetWidth;
    final byHeight = logicalSize.height / targetHeight;
    final scale = byWidth < byHeight ? byWidth : byHeight;

    return scale < 1.0 ? scale : 1.0;
  }
}
