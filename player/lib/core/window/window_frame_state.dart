import 'package:flutter/foundation.dart';

/// What GTK says about the Linux window's frame: whether it is maximized,
/// snapped (tiled) or fullscreen, or drawn without a compositor.
///
/// GTK squares its frame and drops the shadow in each of the first three
/// states, and again, without a compositor, whenever `solidFrame` is set
/// (GTK's `.solid-csd`, which has no shadow to draw regardless of window
/// state). `DesktopWindowChrome` squares the Flutter clip to match.
/// `window_manager` cannot supply this: it has no notion of tiled, which is
/// how GNOME reports a half-screen snap, or of compositing. Read over
/// `kWindowFrameChannelName` by `WindowFrameStateSource`.
///
/// Platform-free, like `window_maximized.dart`, so widgets can take it
/// without a conditional import.
@immutable
class WindowFrameState {
  const WindowFrameState({
    this.maximized = false,
    this.tiled = false,
    this.fullscreen = false,
    this.solidFrame = false,
  });

  /// Every flag clear: a free-floating window with rounded corners.
  static const WindowFrameState floating = WindowFrameState();

  /// Parses the `{maximized, tiled, fullscreen, solidFrame}` map the GTK
  /// runner sends.
  ///
  /// Anything malformed reads as [floating] rather than throwing: this runs
  /// on a platform message during startup, and the worst a wrong state costs
  /// is a few corner pixels.
  factory WindowFrameState.fromChannel(Object? raw) {
    if (raw is! Map) return floating;
    bool flag(String key) => raw[key] == true;
    return WindowFrameState(
      maximized: flag('maximized'),
      tiled: flag('tiled'),
      fullscreen: flag('fullscreen'),
      solidFrame: flag('solidFrame'),
    );
  }

  final bool maximized;
  final bool tiled;
  final bool fullscreen;

  /// GTK is drawing its compositor-less `.solid-csd` frame: square, no
  /// shadow, no transparency.
  final bool solidFrame;

  bool get isFloating => !maximized && !tiled && !fullscreen;

  @override
  bool operator ==(Object other) =>
      other is WindowFrameState &&
      other.maximized == maximized &&
      other.tiled == tiled &&
      other.fullscreen == fullscreen &&
      other.solidFrame == solidFrame;

  @override
  int get hashCode => Object.hash(maximized, tiled, fullscreen, solidFrame);

  @override
  String toString() => 'WindowFrameState(maximized: $maximized, '
      'tiled: $tiled, fullscreen: $fullscreen, solidFrame: $solidFrame)';
}
