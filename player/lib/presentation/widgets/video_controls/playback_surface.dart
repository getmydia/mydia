import 'package:flutter/material.dart';

/// The bare video background beneath the playback chrome.
///
/// Owns every pointer semantic for the region that is *not* a control: tap to
/// toggle chrome, double-click to toggle fullscreen, and press-and-move to
/// drag the OS window. Consolidating them here is the point. Before this
/// widget, three separate gesture layers competed over the same region and
/// the outermost one (desktop double-click-to-fullscreen in
/// `player_screen.dart`) lost every arena to the innermost one and never
/// fired.
///
/// **Why the drag lives in a `Listener` and not `GestureDetector.onPanStart`.**
/// For a mouse, Flutter's drag recognizers accept after
/// `kPrecisePointerHitSlop`, which is 1 logical pixel and is not configurable
/// for precise pointers through `DeviceGestureSettings`. A pan recognizer here
/// would win the arena and cancel the click after a single pixel of hand
/// tremor. A `Listener` does not enter the gesture arena at all, so it can
/// watch the pointer without ever stealing a tap.
class PlaybackSurface extends StatefulWidget {
  /// Toggles chrome visibility. Suppressed when the gesture became a drag.
  final VoidCallback onTap;

  /// Toggles fullscreen. Null off native desktop.
  ///
  /// Passing null is load-bearing, not merely tidy: registering a double-tap
  /// handler makes Flutter defer [onTap] by `kDoubleTapTimeout`, so platforms
  /// with no double-click must not register one.
  final VoidCallback? onDoubleTap;

  /// Hands the gesture to the OS as a window drag. Null when there is no
  /// window to move (web, mobile) or it cannot be moved (fullscreen). When
  /// null, no drag distance is tracked at all and taps behave exactly as they
  /// would without this widget.
  final VoidCallback? onWindowDrag;

  const PlaybackSurface({
    super.key,
    required this.onTap,
    this.onDoubleTap,
    this.onWindowDrag,
  });

  /// Movement past this many logical pixels, while the pointer is held,
  /// promotes the gesture from a click to a window drag.
  ///
  /// Deliberately well above `kPrecisePointerHitSlop` (1.0) so a click is
  /// clearly distinct from a drag. Note this leaves 1px to 8px accepted as
  /// neither: Flutter has already rejected the tap by then. That dead zone is
  /// pre-existing behaviour, not something this threshold introduces.
  static const double dragSlop = 8.0;

  @override
  State<PlaybackSurface> createState() => _PlaybackSurfaceState();
}

class _PlaybackSurfaceState extends State<PlaybackSurface> {
  Offset? _downPosition;

  /// Set once the held pointer travels past [PlaybackSurface.dragSlop]. Read
  /// by [_handleTap] to suppress the toggle.
  ///
  /// Never cleared on pointer up. `GestureBinding` routes the up event to
  /// this `Listener` *before* it sweeps the gesture arena, so `onTap` always
  /// runs after `onPointerUp`, and clearing there would defeat the whole
  /// mechanism. It is cleared on the next pointer down instead, which also
  /// covers the case where the OS takes the pointer for a window drag and
  /// Flutter never sees a matching up event at all.
  bool _draggedThisGesture = false;

  void _onPointerDown(PointerDownEvent event) {
    _downPosition = event.position;
    _draggedThisGesture = false;
  }

  void _onPointerMove(PointerMoveEvent event) {
    final startDrag = widget.onWindowDrag;
    final down = _downPosition;
    if (startDrag == null || down == null || _draggedThisGesture) return;
    if ((event.position - down).distance < PlaybackSurface.dragSlop) return;

    _draggedThisGesture = true;
    startDrag();
  }

  void _onPointerFinished(PointerEvent event) => _downPosition = null;

  void _handleTap() {
    if (_draggedThisGesture) {
      _draggedThisGesture = false;
      return;
    }
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerFinished,
      onPointerCancel: _onPointerFinished,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        onDoubleTap: widget.onDoubleTap,
        child: const SizedBox.expand(),
      ),
    );
  }
}
