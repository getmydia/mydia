import 'package:flutter/material.dart';

import '../../core/player/input_capabilities.dart';

/// Scrolls its child to the middle of every enclosing scrollable when it
/// takes focus.
///
/// Flutter's traversal policy already calls `Scrollable.ensureVisible` with
/// the default alignment, which parks a newly focused card flush against the
/// edge it entered from. That is disorienting on a television, where the
/// viewer is reading the rail rather than pointing at it, and it also leaves
/// no built item beyond the edge for the next move to reach.
///
/// `ensureVisible` walks every scrollable ancestor, not just the rail, and
/// that is deliberate: a rail sitting in a vertically scrolling page brings
/// its row toward the middle of the page as focus enters it, which is how a
/// television is expected to behave. Centring the rail alone would leave the
/// row parked wherever traversal put it vertically, which is the same
/// disorientation this widget exists to fix, on the other axis.
///
/// Shared by every horizontal rail (`ContentRail`, `HorizontalRail`) so the
/// behaviour lives in one place instead of three copies.
class RailFocusScroller extends StatefulWidget {
  final Widget child;

  const RailFocusScroller({super.key, required this.child});

  @override
  State<RailFocusScroller> createState() => _RailFocusScrollerState();
}

class _RailFocusScrollerState extends State<RailFocusScroller> {
  void _handleFocusChange(bool hasFocus) {
    if (!hasFocus || !mounted) return;
    // Deferred: the focus notification arrives during a build, and
    // `ensureVisible` schedules a scroll, which cannot run in that phase.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!InputCapabilities.directionalPrimary) return widget.child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _handleFocusChange,
      child: widget.child,
    );
  }
}
