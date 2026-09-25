import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Extents the cast bar, the dock and the desktop sidebar need from each
/// other.
///
/// `CastBarLayer` sits above the router and `AppShell` below it, so the
/// dock's height and the sidebar's width have to travel up to the bar, and
/// the bar's height back down to the screens' `DockInsets`. `CastBarLayer`
/// owns all three values and provides them here; the dock, the sidebar and
/// the bar report into [onDock], [onSidebar] and [onCastBar].
class DockExtents extends InheritedWidget {
  const DockExtents({
    super.key,
    required this.dock,
    required this.castBar,
    required this.sidebar,
    required this.onDock,
    required this.onCastBar,
    required this.onSidebar,
    required super.child,
  });

  /// Space between the bar and the dock, and between the bar and content.
  static const double gap = 8;

  final double dock;
  final double castBar;

  /// The desktop sidebar's width while it is on screen and its route is
  /// current; 0 otherwise.
  final double sidebar;
  final ValueChanged<double> onDock;
  final ValueChanged<double> onCastBar;
  final ValueChanged<double> onSidebar;

  /// Rebuilds the caller when a height changes.
  static DockExtents? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DockExtents>();

  /// For reporters, which only need the callbacks and must not rebuild on
  /// the values they themselves change.
  static DockExtents? reporterOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DockExtents>();

  @override
  bool updateShouldNotify(DockExtents old) =>
      old.dock != dock || old.castBar != castBar || old.sidebar != sidebar;
}

/// Reports [child]'s laid-out extent along [axis] (its height by default)
/// after each frame it changes, and 0 when it goes away or [active] turns
/// false.
class ReportedExtent extends StatefulWidget {
  const ReportedExtent({
    super.key,
    required this.onExtent,
    this.axis = Axis.vertical,
    this.active = true,
    required this.child,
  });

  final ValueChanged<double>? onExtent;
  final Axis axis;
  final bool active;
  final Widget child;

  @override
  State<ReportedExtent> createState() => _ReportedExtentState();
}

class _ReportedExtentState extends State<ReportedExtent> {
  /// Last extent layout measured, whether or not it was reported.
  double _measured = 0;

  /// Last value actually sent to [ReportedExtent.onExtent].
  double? _last;

  void _onLayout(Size size) {
    _measured = widget.axis == Axis.vertical ? size.height : size.width;
    _report();
  }

  void _report() {
    final value = widget.active ? _measured : 0.0;
    if (value == _last) return;
    _last = value;
    final onExtent = widget.onExtent;
    if (onExtent == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) => onExtent(value));
  }

  @override
  void didUpdateWidget(ReportedExtent old) {
    super.didUpdateWidget(old);
    // Layout does not necessarily re-run when only `active` flips (the
    // shell's route becoming current again), so report from here too.
    if (old.active != widget.active) _report();
  }

  @override
  void dispose() {
    final onExtent = widget.onExtent;
    if (onExtent != null && (_last ?? 0) != 0) {
      SchedulerBinding.instance.addPostFrameCallback((_) => onExtent(0));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _SizeProbe(onSize: _onLayout, child: widget.child);
}

class _SizeProbe extends SingleChildRenderObjectWidget {
  const _SizeProbe({required this.onSize, super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSizeProbe(onSize);

  @override
  void updateRenderObject(
          BuildContext context, _RenderSizeProbe renderObject) =>
      renderObject.onSize = onSize;
}

class _RenderSizeProbe extends RenderProxyBox {
  _RenderSizeProbe(this.onSize);

  ValueChanged<Size> onSize;

  @override
  void performLayout() {
    super.performLayout();
    onSize(size);
  }
}
