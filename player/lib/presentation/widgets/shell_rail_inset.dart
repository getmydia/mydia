import 'package:flutter/widgets.dart';

/// How far the floating rail reaches into the shell's content area, published
/// by `AppShell.railLayers`.
///
/// The shell's navigator spans the whole window, under the rail, and does not
/// pad its pages: go_router wraps them in an Overlay that clips at its own
/// bounds, so a column padded by the shell could never paint under the rail.
/// Each page insets itself instead, inside its own route, so every page keeps
/// its own geometry while another opens over it and nothing slides.
///
/// - Most pages are wrapped in [ShellPageInset] once, centrally
///   (`core/router/shell_pages.dart`).
/// - A page that paints under the rail (Home's hero, the detail pages) opts
///   out of that wrapper, paints its art and ground full width and insets its
///   text and controls with [ShellRailInset.of], [ShellPageInset] and
///   [SliverRailInset].
///
/// Zero where there is no rail (the phone layout) and outside the shell, so
/// such a page is unchanged there.
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

/// Insets [child] by the rail's footprint.
class ShellPageInset extends StatelessWidget {
  const ShellPageInset({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(left: ShellRailInset.of(context)),
        child: child,
      );
}

/// Insets a [sliver] by the rail's footprint.
class SliverRailInset extends StatelessWidget {
  const SliverRailInset({super.key, required this.sliver});

  final Widget sliver;

  @override
  Widget build(BuildContext context) => SliverPadding(
        padding: EdgeInsets.only(left: ShellRailInset.of(context)),
        sliver: sliver,
      );
}

/// Wraps each of [slivers] in a [SliverRailInset].
List<Widget> railInsetSlivers(List<Widget> slivers) =>
    [for (final s in slivers) SliverRailInset(sliver: s)];
