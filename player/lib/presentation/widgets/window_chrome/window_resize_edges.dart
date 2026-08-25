import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/window/window_controller.dart';

/// Eight invisible resize zones around the window border.
///
/// An undecorated GTK window has no invisible resize frame of its own, so
/// without these a mouse-only user cannot resize the window at all. The zones
/// sit INSIDE the window, which costs [thickness] logical pixels of hit
/// testing along each edge; [child] is still laid out at full size beneath
/// them, so nothing reflows.
///
/// Corners are stacked after the sides so they win the hit test where they
/// overlap, which is what makes a diagonal drag from a corner resize both
/// axes.
class WindowResizeEdges extends StatelessWidget {
  const WindowResizeEdges({
    super.key,
    required this.controller,
    required this.child,
  });

  final WindowController controller;
  final Widget child;

  /// How far in from each edge the resize zones reach, in logical pixels.
  static const double thickness = 8;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: child),

        // Sides.
        _zone(
            top: 0, left: 0, right: 0, height: thickness, edge: WindowEdge.top),
        _zone(
          bottom: 0,
          left: 0,
          right: 0,
          height: thickness,
          edge: WindowEdge.bottom,
        ),
        _zone(
            top: 0,
            bottom: 0,
            left: 0,
            width: thickness,
            edge: WindowEdge.left),
        _zone(
          top: 0,
          bottom: 0,
          right: 0,
          width: thickness,
          edge: WindowEdge.right,
        ),

        // Corners last, so they win where they overlap a side.
        _zone(
          top: 0,
          left: 0,
          width: thickness,
          height: thickness,
          edge: WindowEdge.topLeft,
        ),
        _zone(
          top: 0,
          right: 0,
          width: thickness,
          height: thickness,
          edge: WindowEdge.topRight,
        ),
        _zone(
          bottom: 0,
          left: 0,
          width: thickness,
          height: thickness,
          edge: WindowEdge.bottomLeft,
        ),
        _zone(
          bottom: 0,
          right: 0,
          width: thickness,
          height: thickness,
          edge: WindowEdge.bottomRight,
        ),
      ],
    );
  }

  Widget _zone({
    required WindowEdge edge,
    double? top,
    double? bottom,
    double? left,
    double? right,
    double? width,
    double? height,
  }) {
    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      width: width,
      height: height,
      child: MouseRegion(
        cursor: _cursorFor(edge),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => controller.startResizing(edge).catchError(
                (Object e) =>
                    debugPrint('[WindowResizeEdges] ${edge.name} failed: $e'),
              ),
        ),
      ),
    );
  }

  static SystemMouseCursor _cursorFor(WindowEdge edge) => switch (edge) {
        WindowEdge.top || WindowEdge.bottom => SystemMouseCursors.resizeUpDown,
        WindowEdge.left ||
        WindowEdge.right =>
          SystemMouseCursors.resizeLeftRight,
        WindowEdge.topLeft ||
        WindowEdge.bottomRight =>
          SystemMouseCursors.resizeUpLeftDownRight,
        WindowEdge.topRight ||
        WindowEdge.bottomLeft =>
          SystemMouseCursors.resizeUpRightDownLeft,
      };
}
