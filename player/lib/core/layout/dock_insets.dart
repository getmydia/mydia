import 'package:flutter/material.dart';

import 'breakpoints.dart';

/// Bottom clearance for content that scrolls under the floating mobile dock.
///
/// `AppShell`'s mobile branch uses `Scaffold(extendBody: true)`, which makes
/// body content flow under the dock on purpose so the frosted pill reads as
/// real glass over the ambient backdrop. Flutter compensates by rewriting the
/// body's `MediaQuery.padding.bottom` to the dock's measured height (see
/// `_BodyBuilder` in material/scaffold.dart, which takes
/// `max(metrics.padding.bottom, bodyConstraints.bottomWidgetsHeight)`), with
/// the system safe-area inset already folded in because `BottomNav` wraps
/// itself in a `SafeArea`.
///
/// That value survives `AppShell.contentGutter` (which insets top only) and
/// each screen's own nested `Scaffold` (which has no `bottomNavigationBar`, so
/// it passes the padding through untouched). Reading it here is therefore
/// exact by construction, and self-correcting if the dock is ever restyled.
///
/// Measured: the dock is 83.0 tall with no system inset and 117.0 with a 34px
/// home indicator. The literal `100.0` this replaced was short on every
/// home-indicator phone.
abstract final class DockInsets {
  /// Breathing room between the last item and the floating dock.
  static const double dockGap = 16;

  /// Bottom breathing room on desktop, which has no dock because the sidebar
  /// is on the left. Preserves the pre-existing spacing exactly.
  static const double desktopGap = 32;

  /// Bottom padding a scrollable must reserve for its last item to clear the
  /// dock.
  ///
  /// Branches on [Breakpoints.isDesktop] rather than on whether the inset is
  /// non-zero, for two reasons. The arms encode different intents: clearing a
  /// floating dock versus leaving window-edge breathing room. And it is the
  /// same predicate `AppShell` uses to pick its own desktop or mobile branch,
  /// read off the window-sized ambient `MediaQuery`, so a screen can never
  /// disagree with the shell about which layout it is in.
  static double bottomOf(BuildContext context) => Breakpoints.isDesktop(context)
      ? desktopGap
      : MediaQuery.paddingOf(context).bottom + dockGap;
}

/// A box-shaped gap reserving [DockInsets.bottomOf].
///
/// Use at the tail of a `Column` or `SingleChildScrollView`. The gap must sit
/// INSIDE the scrollable, never as a `SafeArea` wrapped around it: wrapping
/// would shrink the viewport so it ends above the dock, leaving nothing
/// visible under the glass and losing the blur the design depends on.
class DockGap extends StatelessWidget {
  const DockGap({super.key});

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: DockInsets.bottomOf(context));
}

/// The sliver form of [DockGap]. Always the LAST sliver in a
/// `CustomScrollView`.
///
/// `CustomScrollView` is not a `BoxScrollView`, so unlike `ListView` and
/// `GridView` it never auto-pads from `MediaQuery` even when no explicit
/// padding is given. A sliver list gets nothing unless someone writes it,
/// which is why the worst-reserved screens were all sliver-based.
class SliverDockGap extends StatelessWidget {
  const SliverDockGap({super.key});

  @override
  Widget build(BuildContext context) =>
      const SliverToBoxAdapter(child: DockGap());
}
