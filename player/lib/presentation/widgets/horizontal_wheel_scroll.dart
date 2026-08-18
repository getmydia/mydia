import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// One wheel tick's animation. GTK delivers coarse discrete deltas on Linux,
/// so each tick animates; jumping on every tick reads as teleporting.
const _glideDuration = Duration(milliseconds: 150);
const _glideCurve = Curves.easeOutCubic;

/// Makes a horizontal scrollable respond to a vertical mouse wheel.
///
/// Flutter maps a wheel event onto the scrollable's own axis, so `scrollDelta.dy`
/// over a horizontal `ListView` resolves to nothing, the rail declines the
/// event, and it falls through to the page. That is why a rail cannot be
/// scrolled with a plain mouse. This wrapper claims the event instead.
///
/// It claims it only while the rail can actually use it, so vertical page
/// scrolling still works over a rail that has nowhere left to go.
class HorizontalWheelScroll extends StatefulWidget {
  /// The scrollable's controller. Pass one when the call site already owns it,
  /// as the rails do for their edge fades. When null this widget creates and
  /// disposes its own, which keeps a call site from needing a `State` class
  /// solely to hold a controller.
  final ScrollController? controller;

  /// Builds the scrollable. The controller handed back is either [controller]
  /// or the internally owned one, and must be attached to the scrollable this
  /// returns.
  final Widget Function(BuildContext context, ScrollController controller)
      builder;

  const HorizontalWheelScroll({
    super.key,
    this.controller,
    required this.builder,
  });

  @override
  State<HorizontalWheelScroll> createState() => _HorizontalWheelScrollState();
}

class _HorizontalWheelScrollState extends State<HorizontalWheelScroll> {
  ScrollController? _ownedController;

  /// Where the in-flight glide is heading. Ticks accumulate onto this rather
  /// than onto the live offset, so a burst compounds into one motion instead
  /// of each tick restarting from wherever the animation happens to be.
  double? _target;

  /// The page scroller this rail sits inside, resolved once per dependency
  /// change. `_ScrollableScope` only notifies when the position object itself
  /// is replaced, so this dependency costs nothing per frame.
  ScrollableState? _verticalAncestor;

  ScrollController get _controller => widget.controller ?? _ownedController!;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _ownedController = ScrollController();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _verticalAncestor = Scrollable.maybeOf(context, axis: Axis.vertical);
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    // Trackpads arrive as pan-zoom events and already scroll both axes.
    if (event is! PointerScrollEvent) return;
    // A tilt or horizontal wheel already lands on the rail's own axis.
    if (event.scrollDelta.dy == 0) return;

    final controller = _controller;
    if (!controller.hasClients) return;

    final position = controller.position;
    // A rail that fits on screen has no business eating the page's wheel.
    if (position.maxScrollExtent <= 0) return;
    // Mirrors Scrollable's own guard, so a NeverScrollableScrollPhysics rail
    // stays inert instead of being scrolled from here.
    if (!position.physics.shouldAcceptUserOffset(position)) return;

    // A page scroll already in flight keeps the wheel until it settles, so a
    // flick down the home screen is not snagged by a rail it passes over. It
    // also covers the mirror case: once a rail hands off at its end, the page
    // holds the wheel rather than bouncing back.
    if (_verticalAncestor?.position.isScrollingNotifier.value ?? false) return;

    // `pixels` is direction-normalised, so `dy` maps onto it unsigned in both
    // LTR and RTL: down always means further through the list.
    final base = _target ?? position.pixels;
    final next = clampDouble(
      base + event.scrollDelta.dy,
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    // Already at that end. Declining, rather than registering a no-op, is what
    // lets the page take the event.
    if (next == base) return;

    GestureBinding.instance.pointerSignalResolver
        .register(event, (_) => _glideTo(next));
  }

  void _glideTo(double next) {
    _target = next;
    _controller
        .animateTo(next, duration: _glideDuration, curve: _glideCurve)
        .whenComplete(() {
      // Completes on interruption as well as on completion, so a drag that
      // cuts a glide short re-bases the next tick off the real offset. The
      // guard stops a stale completion from clearing a newer target.
      if (mounted && _target == next) _target = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: widget.builder(context, _controller),
    );
  }
}
