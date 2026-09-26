import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Extents the cast bar, the dock and the desktop sidebar need from each
/// other, plus whether the mobile nav drawer is open.
///
/// `CastBarLayer` sits above the router and `AppShell` below it, so the
/// dock's height and the sidebar's width have to travel up to the bar, and
/// the bar's height back down to the screens' `DockInsets`. `CastBarLayer`
/// owns all three values and provides them here; the dock, the sidebar and
/// the bar report into [onDock], [onSidebar] and [onCastBar]. The shell
/// reports its drawer through [ReportedDrawer] into [onDrawer], because the
/// bar paints above `Scaffold.drawer` and has to get out of its way.
class DockExtents extends InheritedWidget {
  const DockExtents({
    super.key,
    required this.dock,
    required this.castBar,
    required this.sidebar,
    required this.drawerOpen,
    required this.onDock,
    required this.onCastBar,
    required this.onSidebar,
    required this.onDrawer,
    required super.child,
  });

  /// Space between the bar and the dock, and between the bar and content.
  static const double gap = 8;

  final double dock;
  final double castBar;

  /// The desktop sidebar's width while it is on screen and its route is
  /// current; 0 otherwise.
  final double sidebar;

  /// Whether the mobile nav drawer is open.
  final bool drawerOpen;
  final ValueChanged<double> onDock;
  final ValueChanged<double> onCastBar;
  final ValueChanged<double> onSidebar;
  final ValueChanged<bool> onDrawer;

  /// Rebuilds the caller when a height changes.
  static DockExtents? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DockExtents>();

  /// For reporters, which only need the callbacks and must not rebuild on
  /// the values they themselves change.
  static DockExtents? reporterOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DockExtents>();

  @override
  bool updateShouldNotify(DockExtents old) =>
      old.dock != dock ||
      old.castBar != castBar ||
      old.sidebar != sidebar ||
      old.drawerOpen != drawerOpen;
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
  /// Last size layout measured, whether or not it was reported. Kept whole
  /// rather than as the selected dimension so an [ReportedExtent.axis]
  /// change can be answered without waiting for another layout.
  Size? _measuredSize;

  /// Last value actually sent to [ReportedExtent.onExtent].
  double? _last;

  /// The dimension currently selected out of [_measuredSize].
  double get _measured => switch (widget.axis) {
        Axis.vertical => _measuredSize?.height ?? 0,
        Axis.horizontal => _measuredSize?.width ?? 0,
      };

  void _onLayout(Size size) {
    _measuredSize = size;
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
    // shell's route becoming current again) or when `axis` switches to the
    // other dimension of an unchanged size, so report from here too.
    if (old.active != widget.active || old.axis != widget.axis) _report();
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

/// Reports whether the mobile nav drawer is [open] to [DockExtents.onDrawer],
/// and reports it closed when this widget goes away, so a shell torn down
/// with its drawer open cannot leave the cast bar hidden.
class ReportedDrawer extends StatefulWidget {
  const ReportedDrawer({super.key, required this.open, required this.child});

  final bool open;
  final Widget child;

  @override
  State<ReportedDrawer> createState() => _ReportedDrawerState();
}

class _ReportedDrawerState extends State<ReportedDrawer> {
  /// Cached because `dispose` cannot look up inherited widgets.
  ValueChanged<bool>? _onDrawer;

  /// Last value reported; the layer starts out assuming closed.
  bool _last = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _onDrawer = DockExtents.reporterOf(context)?.onDrawer;
    _report(widget.open);
  }

  @override
  void didUpdateWidget(ReportedDrawer old) {
    super.didUpdateWidget(old);
    if (old.open != widget.open) _report(widget.open);
  }

  @override
  void dispose() {
    _report(false);
    super.dispose();
  }

  // Deferred like ReportedExtent's reports: the receiver calls setState,
  // which must not happen while this subtree is building.
  void _report(bool open) {
    if (open == _last) return;
    _last = open;
    final onDrawer = _onDrawer;
    if (onDrawer == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) => onDrawer(open));
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
