import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/player/platform_features.dart';
import '../../../core/theme/depth_tokens.dart';
import '../glass_surface.dart';

/// Responsive sizing for the playback panel.
///
/// The panel is a compact, centered, floating object — not an edge-to-edge
/// chrome strip. It sits above the bottom edge so it reads as deliberate.
@immutable
class PanelMetrics {
  /// Maximum panel width in logical pixels.
  final double maxWidth;

  /// Distance from the bottom of the viewport.
  final double bottomOffset;

  /// Whether to show the volume cluster. Phones have hardware volume buttons,
  /// so the cluster is dropped there to buy space.
  final bool showVolume;

  /// Whether controls should use enlarged touch hit areas.
  final bool touchTargets;

  /// Whether the in-bar transport collapses to play/pause only, dropping ±10s
  /// and episode navigation.
  ///
  /// Split out of [touchTargets], which used to drive both this and the
  /// enlarged seek hit area. They answer different questions: this one is
  /// about horizontal room, [touchTargets] is about finger size. Keeping them
  /// fused meant that making [touchTargets] follow input capability would have
  /// silently taken episode navigation away from a landscape phone browser,
  /// which sits around 800px and clears this breakpoint comfortably.
  final bool compactTransport;

  /// Whether `SecondaryCluster`'s quality button renders.
  ///
  /// True at every tier. It was previously true only on desktop, for two
  /// reasons that no longer hold. The first was that a non-null
  /// `onQualityTap` was a *web* signal, because `player_screen.dart` gated
  /// the callback on `PlatformFeatures.isWeb`; that gate is gone and the
  /// control is wired on every platform. The second was budget: a 4th 40px
  /// button raised `SecondaryCluster`'s floor from 120 to 160px each side,
  /// which genuinely could not be closed at the tablet or mobile tiers by
  /// any padding or width-factor lever.
  ///
  /// Compaction closed it structurally rather than by lever. The transport
  /// cluster dropped from 256px to 192px, secondary buttons from 40 to 32,
  /// and padding from 20/12 to 12/8, so the four-button floor is now 128px
  /// on mobile against 142px available at 360px wide. See
  /// `chrome_panel_overflow_test.dart` for the full per-width budget.
  ///
  /// This field is kept rather than deleted because it stays a real
  /// per-tier lever: if a 5th control is ever added, this is where the tier
  /// that cannot afford it says so.
  final bool showQuality;

  /// Whether `SecondaryCluster`'s always-on-top button renders.
  ///
  /// Unlike [showQuality], this is not true at every tier. Always-on-top is
  /// desktop-only regardless of this field — `PlaybackChrome` also gates it
  /// on `PlatformFeatures.isDesktop` — but a narrowed desktop window can
  /// still land in the tablet or mobile width tiers below, and a 5th
  /// `SecondaryCluster` button reopens the exact overflow budget
  /// [showQuality]'s dartdoc warned about. This field is `false` at both of
  /// those tiers, not just mobile: the tablet tier was measured too, and its
  /// tightest width came up short (see that branch's own inline comment
  /// below for the figure). See `chrome_panel_overflow_test.dart`'s
  /// five-button group for the measured budget this field is tuned against.
  final bool showAlwaysOnTop;

  /// Horizontal padding on both sides of the panel. Previously a single
  /// global constant on [ChromePanel] itself; now tier-dependent, so it
  /// lives here alongside the other per-tier values.
  ///
  /// 8px on the mobile and tablet tiers, 12px on desktop. This is a real
  /// overflow-budget lever, not a cosmetic tweak — see
  /// `chrome_panel_overflow_test.dart` for the full per-width budget.
  final double horizontalPadding;

  /// Bottom inset for a corner overlay — `SkipSegmentButton` and
  /// `UpNextPrompt` — measured so the overlay always clears the panel.
  ///
  /// Both widgets previously hardcoded 120 at every tier, and
  /// `SkipSegmentButton` documented its value as "Matches `UpNextOverlay`":
  /// the widget that follows the design system took its geometry from the one
  /// that did not. One value, read by both, guarded by
  /// `chrome_corner_inset_test.dart`.
  ///
  /// This is [bottomOffset] plus the panel's rendered height plus a 12px gap,
  /// so it tracks the panel automatically when a tier's offset changes.
  final double cornerInsetBottom;

  /// Horizontal gap between `SecondaryCluster`'s buttons, supplied per tier.
  ///
  /// Desktop and tablet can afford real separation once the transport
  /// cluster is compacted; mobile runs at the 0px floor, which is what makes
  /// four discrete 32px buttons fit at 360px at all.
  final double secondaryGap;

  const PanelMetrics({
    required this.maxWidth,
    required this.bottomOffset,
    required this.showVolume,
    required this.touchTargets,
    required this.compactTransport,
    required this.showQuality,
    required this.showAlwaysOnTop,
    required this.secondaryGap,
    required this.horizontalPadding,
    required this.cornerInsetBottom,
  });

  /// Right inset for a corner overlay. Constant across tiers: unlike the
  /// vertical inset, nothing sits to the right of these widgets.
  static const double cornerInsetRight = 24.0;

  /// The panel's rendered height at every tier: a 44px control row, the
  /// scrubber row, [ChromePanel.rowGap] between them, and
  /// [ChromePanel.verticalPadding] above and below.
  static const double _panelHeight =
      44 + ChromePanel.rowGap + 20 + (ChromePanel.verticalPadding * 2);

  /// Gap between the panel's top edge and a corner overlay's bottom edge.
  static const double _cornerGap = 12.0;

  static double _cornerInset(double bottomOffset) =>
      bottomOffset + _panelHeight + _cornerGap;

  /// Resolve metrics for a viewport [width] and the viewer's input type,
  /// using the breakpoints in `core/layout/breakpoints.dart`
  /// (mobile < 600, tablet 600-899, desktop >= 900).
  ///
  /// [touchPrimary] governs finger-sized affordances only; [width] governs how
  /// much fits. See [compactTransport] for why these are separate.
  factory PanelMetrics.resolve({
    required double width,
    required bool touchPrimary,
  }) {
    final compactTransport = width < Breakpoints.mobile;

    // Finger size, not window size. A landscape phone is around 800px and
    // would otherwise take the tablet tier's 32px scrubber.
    final touchTargets = touchPrimary || width < Breakpoints.mobile;

    if (width >= Breakpoints.tablet) {
      return PanelMetrics(
        maxWidth: math.min(720.0, width * 0.70),
        bottomOffset: 48,
        cornerInsetBottom: _cornerInset(48),
        showVolume: true,
        touchTargets: touchTargets,
        compactTransport: compactTransport,
        showQuality: true,
        showAlwaysOnTop: true,
        secondaryGap: 8,
        horizontalPadding: 12,
      );
    }
    if (width >= Breakpoints.mobile) {
      return PanelMetrics(
        maxWidth: math.min(640.0, width * 0.90),
        bottomOffset: 32,
        cornerInsetBottom: _cornerInset(32),
        showVolume: true,
        touchTargets: touchTargets,
        compactTransport: compactTransport,
        showQuality: true,
        // false, not true: measured against `chrome_panel_overflow_test.dart`
        // (per `showAlwaysOnTop`'s dartdoc), the tablet tier's tightest width
        // (600px) overflows `SecondaryCluster`'s row by 18px with a 5th
        // button. The desktop branch above affords it (looser padding and
        // gap); this tier does not.
        showAlwaysOnTop: false,
        secondaryGap: 6,
        horizontalPadding: 8,
      );
    }
    return PanelMetrics(
      // Clamp: below a 20px-wide viewport this would otherwise go negative,
      // which trips BoxConstraints' normalization assert downstream.
      maxWidth: math.max(0.0, width - 20),
      bottomOffset: 24,
      cornerInsetBottom: _cornerInset(24),
      showVolume: false,
      touchTargets: touchTargets,
      compactTransport: compactTransport,
      showQuality: true,
      showAlwaysOnTop: false,
      secondaryGap: 0,
      horizontalPadding: 8,
    );
  }

  /// Fine-pointer shorthand for [resolve], for the many assertions that are
  /// about width alone.
  ///
  /// Annotated so production code cannot quietly take the fine-pointer default
  /// on a touch device: `playback_chrome.dart` passes the real
  /// `InputCapabilities.touchPrimary` through [resolve] instead.
  @visibleForTesting
  factory PanelMetrics.forWidth(double width) =>
      PanelMetrics.resolve(width: width, touchPrimary: false);
}

/// The playback control panel.
///
/// Two rows: controls on top, scrubber below. Slot-based so it can be tested
/// without a media_kit [Player].
class ChromePanel extends StatelessWidget {
  /// Center group of row 1.
  final Widget transport;

  /// Row 2.
  final Widget scrubber;

  /// Left group of row 1. Omitted on mobile.
  ///
  /// Pass this **unconditionally** (e.g. always `VolumeCluster(player: ...)`)
  /// rather than gating construction on [PanelMetrics.showVolume] yourself.
  /// [ChromePanel] does that gating internally with a [Visibility] that keeps
  /// the widget mounted (`maintainState: true`) even while hidden, so its
  /// `State` survives a breakpoint crossing — e.g. resizing a desktop window
  /// or rotating a tablet past 600px. If the caller instead constructs (or
  /// tears down) the widget itself based on [PanelMetrics.showVolume], a
  /// stateful volume control loses whatever it was tracking (such as the
  /// pre-mute volume) every time the breakpoint is crossed, because it gets a
  /// fresh `State` on every remount. Pass `null` only when there is truly no
  /// volume control to show (e.g. a host with no player to bind to).
  final Widget? volume;

  /// Right group of row 1.
  final Widget? secondary;

  final PanelMetrics metrics;

  /// Forced glass tier. Defaults to [PlatformFeatures.playerGlassTier]; pass
  /// explicitly in tests/goldens so images do not vary by host platform.
  final PlayerGlassTier? tier;

  const ChromePanel({
    super.key,
    required this.transport,
    required this.scrubber,
    required this.metrics,
    this.volume,
    this.secondary,
    this.tier,
  });

  /// Vertical gap between the controls row and the scrubber row.
  static const double rowGap = 10.0;

  /// Vertical padding above row 1 and below row 2. Public so tests (e.g.
  /// `glass_legibility_test`) can derive real panel-geometry fractions
  /// instead of hand-rounded literals.
  static const double verticalPadding = 10.0;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: metrics.maxWidth),
      child: GlassSurface.playerChrome(
        tier: tier,
        borderRadius: const BorderRadius.all(
          Radius.circular(DepthTokens.radiusPlayerPanel),
        ),
        child: Padding(
          // Horizontal padding is now tier-dependent (see
          // `PanelMetrics.horizontalPadding`'s dartdoc); it used to be a
          // single global constant here.
          padding: EdgeInsets.symmetric(
            horizontal: metrics.horizontalPadding,
            vertical: verticalPadding,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  // Left and right groups are given equal flex — always,
                  // regardless of `metrics.showVolume` — so the transport
                  // stays *exactly* optically centered: two equal-flex
                  // `Expanded`s are, by construction, always the same width,
                  // so `transport`'s own center always lands on the panel's
                  // center, whether or not the left side has real content.
                  //
                  // An earlier version special-cased `!metrics.showVolume` to
                  // `flex: 0` (inflexible, sized to its offstage — zero-width
                  // — content) to stop the empty slot "wasting" half the
                  // leftover width on nothing. That fixed one real overflow
                  // (`SecondaryCluster` squeezed into the other, smaller
                  // half) by introducing a worse one: giving `secondary` the
                  // *entire* remainder pins it hard against `transport`,
                  // dragging the whole transport group off-center by however
                  // much of the leftover width `secondary` doesn't use — up
                  // to ~187.5px at some mobile widths, a real, measured
                  // regression, not a rounding error. Equal-flex `Expanded` on
                  // both sides never does that: at worst, `secondary`
                  // overflows its own (equal) slot and throws, which is a
                  // loud, honest failure instead of a silent, ever-growing
                  // miscentering.
                  //
                  // What actually fixes the mobile-width overflow is
                  // upstream: `PlaybackChrome` now passes a `compact`
                  // (play/pause-only, 48px) `transport` below the mobile
                  // breakpoint instead of the full 152px cluster, which is
                  // enough headroom for this equal-flex split to hold. See
                  // `chrome_panel_overflow_test.dart` for exactly which
                  // widths that does and does not close.
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _volumeSlot(),
                    ),
                  ),
                  transport,
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: secondary ?? const SizedBox.shrink(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: rowGap),
              scrubber,
            ],
          ),
        ),
      ),
    );
  }

  /// Renders [volume], keeping it mounted across a [PanelMetrics.showVolume]
  /// flip (see the [volume] dartdoc) instead of adding/removing it from the
  /// tree. `maintainSize: false` means it still takes zero space when hidden,
  /// matching the prior (unmounted) layout exactly.
  ///
  /// `maintainAnimation: false` (the default) is deliberate, not an
  /// oversight: it still preserves `State` — the whole point of this
  /// [Visibility] — by adding only a disabled `TickerMode` around the hidden
  /// child, so `VolumeCluster`'s `_lastVolume` still survives. Setting it to
  /// `true` would additionally keep the hidden widget's tickers/animations
  /// running while offstage, which is wasted work with nothing to show for
  /// it.
  Widget _volumeSlot() {
    final child = volume;
    if (child == null) return const SizedBox.shrink();
    return Visibility(
      visible: metrics.showVolume,
      maintainState: true,
      child: child,
    );
  }
}
