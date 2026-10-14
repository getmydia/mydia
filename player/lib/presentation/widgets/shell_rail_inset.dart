import 'package:flutter/widgets.dart';

/// How far the floating rail reaches into the shell's content area, published
/// by `AppShell.railLayers`.
///
/// Most pages never read it: the shell pads their column by this amount, for
/// every page, so a page never moves when another opens over it. A page whose
/// artwork runs under the rail (Home's hero, the detail pages) reaches left by
/// this much itself, with [ShellRailInset.of] and [RailBleed]. Zero where
/// there is no rail (the phone layout) and outside the shell, so such a page
/// is unchanged there.
class ShellRailInset extends InheritedWidget {
  const ShellRailInset({super.key, required this.left, required super.child});

  /// The leading inset: the rail's footprint plus its gap, plus any safe area.
  /// Animates with the rail when it is pinned or unpinned.
  final double left;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellRailInset>()?.left ?? 0;

  @override
  bool updateShouldNotify(ShellRailInset old) => old.left != left;
}

/// Lets [child] paint up to [ShellRailInset] to the left of its own box, so
/// art in a page the shell has already inset (Home) can run under the rail.
///
/// The top, right and bottom edges still clip as before. Pair it with a
/// scrollable whose own `clipBehavior` is `Clip.none`, since the scrollable's
/// viewport would otherwise clip at the column's edge first.
class RailBleed extends StatelessWidget {
  const RailBleed({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
        clipper: _RailBleedClipper(ShellRailInset.of(context)),
        child: child,
      );
}

class _RailBleedClipper extends CustomClipper<Rect> {
  const _RailBleedClipper(this.inset);

  final double inset;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(-inset, 0, size.width, size.height);

  @override
  bool shouldReclip(_RailBleedClipper old) => old.inset != inset;
}
