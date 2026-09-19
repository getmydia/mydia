import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'toast_controller.dart';
import 'toaster.dart';

export 'toast_controller.dart' show ToastEdge;

/// Marks [child] as something toasts must not cover.
///
/// Wrap the desktop sidebar ([ToastEdge.left]) and anything pinned to the
/// bottom of the window ([ToastEdge.bottom]). The `ToastLayer` above keeps
/// the pill right of the widest left claim and above the tallest bottom one.
/// Nothing hardcodes the sidebar's 260 or the dock's 83: a restyled
/// obstruction moves the toast with no further edits.
///
/// A claim counts only while [active] is true and this subtree is on screen.
/// The second condition reads `TickerMode`: the Navigator's `Overlay`
/// disables tickers for routes covered by an opaque route, so the shell's
/// sidebar stops counting under a full-screen detail page or the player, and
/// keeps counting under a dialog, which is not opaque.
///
/// Inert without a `ToastLayer` ancestor, so wrapped widgets still pump in
/// isolated tests.
class ToastObstruction extends StatefulWidget {
  const ToastObstruction({
    super.key,
    required this.edge,
    this.active = true,
    required this.child,
  });

  final ToastEdge edge;

  /// Withdraws the claim without unmounting [child], for obstructions that
  /// hide while staying mounted (the playback chrome fades out behind an
  /// `IgnorePointer`).
  final bool active;

  final Widget child;

  @override
  State<ToastObstruction> createState() => _ToastObstructionState();
}

class _ToastObstructionState extends State<ToastObstruction> {
  ToastController? _controller;
  bool _onScreen = true;
  Rect? _rect;
  bool _syncScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = Toaster.maybeControllerOf(context);
    if (!identical(controller, _controller)) {
      _retractFrom(_controller);
      _controller = controller;
    }
    _onScreen = TickerMode.valuesOf(context).enabled;
    _scheduleSync();
  }

  @override
  void didUpdateWidget(ToastObstruction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active || oldWidget.edge != widget.edge) {
      _scheduleSync();
    }
  }

  @override
  void dispose() {
    _retractFrom(_controller);
    super.dispose();
  }

  void _handlePainted(Rect rect) {
    if (rect == _rect) return;
    _rect = rect;
    _scheduleSync();
  }

  /// Writes are deferred to after the frame. This runs from paint, from
  /// `didChangeDependencies` and from `didUpdateWidget`, and notifying the
  /// layer from any of those would mark it dirty while the tree is locked.
  void _scheduleSync() {
    if (_syncScheduled || _controller == null) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      final controller = _controller;
      if (!mounted || controller == null) return;
      final rect = _rect;
      if (widget.active && _onScreen && rect != null && !rect.isEmpty) {
        controller.setClaim(this, ToastClaim(widget.edge, rect));
      } else {
        controller.removeClaim(this);
      }
    });
  }

  /// Claims are keyed by this State, so a disposing obstruction can only
  /// remove its own claim, never a newer one registered by its replacement.
  void _retractFrom(ToastController? controller) {
    if (controller == null) return;
    WidgetsBinding.instance
        .addPostFrameCallback((_) => controller.removeClaim(this));
  }

  @override
  Widget build(BuildContext context) => _PaintedRectReporter(
        layerBox: () => _controller?.layerBox?.call(),
        onPainted: _handlePainted,
        child: widget.child,
      );
}

class _PaintedRectReporter extends SingleChildRenderObjectWidget {
  const _PaintedRectReporter({
    required this.layerBox,
    required this.onPainted,
    super.child,
  });

  final RenderBox? Function() layerBox;
  final ValueChanged<Rect> onPainted;

  @override
  _RenderPaintedRectReporter createRenderObject(BuildContext context) =>
      _RenderPaintedRectReporter(layerBox, onPainted);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPaintedRectReporter renderObject,
  ) {
    renderObject
      ..layerBox = layerBox
      ..onPainted = onPainted;
  }
}

/// Reports this box's rect, in the toast layer's coordinates, each time it
/// paints. Paint rather than layout: a parent can move this box without
/// laying it out again (a slide transform), but moving it repaints it.
class _RenderPaintedRectReporter extends RenderProxyBox {
  _RenderPaintedRectReporter(this.layerBox, this.onPainted);

  RenderBox? Function() layerBox;
  ValueChanged<Rect> onPainted;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final layer = layerBox();
    if (layer == null || !layer.attached || !layer.hasSize) return;
    onPainted(localToGlobal(Offset.zero, ancestor: layer) & size);
  }
}
