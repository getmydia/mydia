import 'package:flutter/widgets.dart';

import 'breakpoints.dart';

/// The geometry of one horizontal poster rail, resolved for the current
/// screen width.
///
/// `ContentRail` and the `ShimmerRail` that stands in for it while data loads
/// both read this, so a change to rail geometry cannot land in one and miss
/// the other. The two carried independent copies of these numbers until
/// 2026-09-01 and every one of them had drifted: the skeleton drew 120px cards
/// against the rail's 130 to 160, with its own spacing, padding, rail height
/// and corner radius. `test/test_utils/rail_parity.dart` is the trip-wire.
///
/// Tier thresholds are not repeated here. Every dimension delegates to
/// [Breakpoints], which stays the single place a breakpoint is written down.
@immutable
class RailMetrics {
  const RailMetrics({
    required this.cardSize,
    required this.cardSpacing,
    required this.horizontalPadding,
    required this.railHeight,
    required this.headerTopPadding,
    required this.headerBottomPadding,
    required this.headerBottomCollapsed,
  });

  /// Resolves the metrics for [context]'s current width.
  factory RailMetrics.of(BuildContext context) {
    // Two thresholds, deliberately read separately. `Breakpoints.isDesktop` is
    // true from 900 (`Breakpoints.tablet`), while `Breakpoints.desktop` is
    // 1200. Card size, spacing, side padding and rail height switch at both;
    // the header paddings, which were written in terms of `isDesktop`, switch
    // only at 900. Collapsing these into one branch is the mistake this
    // comment exists to prevent.
    final isDesktop = Breakpoints.isDesktop(context);

    return RailMetrics(
      cardSize: Breakpoints.getCardSize(context),
      cardSpacing: Breakpoints.getCardSpacing(context),
      horizontalPadding: Breakpoints.getHorizontalPadding(context),
      railHeight: Breakpoints.getRailHeight(context),
      headerTopPadding: isDesktop ? 32 : 24,
      headerBottomPadding: isDesktop ? 20 : 16,
      headerBottomCollapsed: isDesktop ? 10 : 8,
    );
  }

  /// Poster dimensions for one card.
  final CardSize cardSize;

  /// Gap between two adjacent cards.
  final double cardSpacing;

  /// Space to the left of the first card and to the right of the last.
  final double horizontalPadding;

  /// Height of the strip the cards scroll in. Exceeds [cardSize]'s height by
  /// enough to hold a card's title and subtitle beneath its poster.
  final double railHeight;

  /// Space above a rail's title. This is also what separates one rail from the
  /// rail above it: rails carry no inter-rail spacer, and neither does the
  /// skeleton.
  final double headerTopPadding;

  /// Space below the title of an open rail.
  final double headerBottomPadding;

  /// Space below the title of a collapsed rail, where the title sits directly
  /// above whatever follows rather than above a strip of posters.
  ///
  /// Rail-only; the skeleton never collapses. It lives here because it and
  /// [headerBottomPadding] are two halves of one decision, and separating them
  /// is how the next divergence starts.
  final double headerBottomCollapsed;

  /// Gap between a card's poster and its title. Mirrors `MediaCard`.
  static const double labelGap = 10;

  /// Gap between a card's title and its subtitle. Mirrors `MediaCard`.
  static const double subtitleGap = 4;
}
