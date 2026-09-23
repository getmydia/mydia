import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Heights the cast bar and the dock need from each other.
///
/// `CastBarLayer` sits above the router and `AppShell` below it, so the
/// dock's height has to travel up to the bar and the bar's height back down
/// to the screens' `DockInsets`. `CastBarLayer` owns both values and
/// provides them here; the dock and the bar report into [onDock] and
/// [onCastBar].
class DockExtents extends InheritedWidget {
  const DockExtents({
    super.key,
    required this.dock,
    required this.castBar,
    required this.onDock,
    required this.onCastBar,
    required super.child,
  });

  /// Space between the bar and the dock, and between the bar and content.
  static const double gap = 8;

  final double dock;
  final double castBar;
  final ValueChanged<double> onDock;
  final ValueChanged<double> onCastBar;

  /// Rebuilds the caller when a height changes.
  static DockExtents? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DockExtents>();

  /// For reporters, which only need the callbacks and must not rebuild on
  /// the values they themselves change.
  static DockExtents? reporterOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DockExtents>();

  @override
  bool updateShouldNotify(DockExtents old) =>
      old.dock != dock || old.castBar != castBar;
}

/// Reports [child]'s laid-out height after each frame it changes, and 0
/// when it goes away or [active] turns false.
class ReportedHeight extends StatefulWidget {
  const ReportedHeight({
    super.key,
    required this.onHeight,
    this.active = true,
    required this.child,
  });

  final ValueChanged<double>? onHeight;
  final bool active;
  final Widget child;

  @override
  State<ReportedHeight> createState() => _ReportedHeightState();
}

class _ReportedHeightState extends State<ReportedHeight> {
  /// Last height layout measured, whether or not it was reported.
  double _measured = 0;

  /// Last value actually sent to [ReportedHeight.onHeight].
  double? _last;

  void _onLayout(double height) {
    _measured = height;
    _report();
  }

  void _report() {
    final value = widget.active ? _measured : 0.0;
    if (value == _last) return;
    _last = value;
    final onHeight = widget.onHeight;
    if (onHeight == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) => onHeight(value));
  }

  @override
  void didUpdateWidget(ReportedHeight old) {
    super.didUpdateWidget(old);
    // Layout does not necessarily re-run when only `active` flips (the
    // shell's route becoming current again), so report from here too.
    if (old.active != widget.active) _report();
  }

  @override
  void dispose() {
    final onHeight = widget.onHeight;
    if (onHeight != null && (_last ?? 0) != 0) {
      SchedulerBinding.instance.addPostFrameCallback((_) => onHeight(0));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _SizeProbe(onHeight: _onLayout, child: widget.child);
}

class _SizeProbe extends SingleChildRenderObjectWidget {
  const _SizeProbe({required this.onHeight, super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSizeProbe(onHeight);

  @override
  void updateRenderObject(
          BuildContext context, _RenderSizeProbe renderObject) =>
      renderObject.onHeight = onHeight;
}

class _RenderSizeProbe extends RenderProxyBox {
  _RenderSizeProbe(this.onHeight);

  ValueChanged<double> onHeight;

  @override
  void performLayout() {
    super.performLayout();
    onHeight(size.height);
  }
}
