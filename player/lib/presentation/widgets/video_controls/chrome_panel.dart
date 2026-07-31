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

  /// Whether `SecondaryCluster`'s web-only quality button may render.
  ///
  /// True only at the desktop tier (>= [Breakpoints.tablet] in this file's
  /// own three-tier scheme). This is a real overflow-budget lever, not a
  /// platform check in disguise: `onQualityTap` being non-null is a *web*
  /// signal (native builds never pass it — see `player_screen.dart`), but
  /// whether the resulting 4th 40px button actually *fits* is a *width*
  /// question, so the gate belongs here, next to the rest of the per-tier
  /// budget, rather than on `SecondaryCluster` (which has no business
  /// knowing about platforms) or on a bare `kIsWeb` check at the call site.
  ///
  /// A 4th button raises `SecondaryCluster`'s own floor from 120px (3
  /// buttons, 0 gap) to 160px (4 buttons) each side. At the tablet and mobile
  /// tiers that is not closeable by any padding/width-factor combination —
  /// 600px would need the *entire* viewport as panel — so the button is
  /// simply not shown there; a narrow web window falls back to the same
  /// 3-button layout native mobile/tablet already use. Desktop closes with
  /// real margin once its own width factor is widened (see the desktop
  /// branch of [PanelMetrics.forWidth] and `chrome_panel_overflow_test.dart`'s
  /// `quality: true` cases).
  final bool showQuality;

  /// Horizontal padding on both sides of the panel. Previously a single
  /// global constant on [ChromePanel] itself; now tier-dependent, so it
  /// lives here alongside the other per-tier values.
  ///
  /// 12px on the mobile and tablet tiers, 20px on desktop. This is a real
  /// overflow-budget lever, not a cosmetic tweak: at the 650px tablet width
  /// (episode-nav wired, `SecondaryCluster` at its 40px-button floor), 20px
  /// of padding each side left `SecondaryCluster` 8px short of fitting in
  /// its equal-flex slot — see `chrome_panel_overflow_test.dart` for the
  /// full per-width budget. Desktop keeps 20px: it was never short of room,
  /// and this wasn't asked to change there.
  final double horizontalPadding;

  const PanelMetrics({
    required this.maxWidth,
    required this.bottomOffset,
    required this.showVolume,
    required this.touchTargets,
    required this.showQuality,
    required this.horizontalPadding,
  });

  /// Resolve metrics for a viewport [width], using the breakpoints in
  /// `core/layout/breakpoints.dart` (mobile < 600, tablet 600–899,
  /// desktop >= 900).
  factory PanelMetrics.forWidth(double width) {
    if (width >= Breakpoints.tablet) {
      return PanelMetrics(
        // 0.70, not the original 0.60: with the web-only quality button
        // wired (see [showQuality]), `SecondaryCluster`'s floor rises from
        // 120px to 160px each side. At the tightest desktop width, 900px,
        // 0.60 left `avail` at 500 against a 576px need (256 transport +
        // 2*160) — 38px short, the whole fullscreen button clipped. 0.70
        // gives 630 -> avail 590 -> eachSide 167 >= 160, with real margin.
        // The `min(720, …)` cap is untouched, so nothing changes above
        // ~1029px, where both factors already saturate at 720 — see
        // `chrome_panel_test.dart`'s "70% of width" case and
        // `chrome_panel_overflow_test.dart`'s `quality: true` matrix.
        maxWidth: math.min(720.0, width * 0.70),
        bottomOffset: 48,
        showVolume: true,
        touchTargets: false,
        showQuality: true,
        horizontalPadding: 20,
      );
    }
    if (width >= Breakpoints.mobile) {
      return PanelMetrics(
        // 0.9, not the original 0.8: at 600px (the tightest point of this
        // branch, with episode-nav wired) 0.8 left this tier's equal-flex
        // slot 28px short of `SecondaryCluster`'s 120px floor — closeable
        // only by widening the panel itself, since neither the padding nor
        // gap levers reach a shortfall that size. See
        // `chrome_panel_overflow_test.dart`'s budget table.
        maxWidth: math.min(640.0, width * 0.90),
        bottomOffset: 32,
        showVolume: true,
        touchTargets: false,
        showQuality: false,
        horizontalPadding: 12,
      );
    }
    return PanelMetrics(
      // Clamp: below a 32px-wide viewport this would otherwise go negative,
      // which trips BoxConstraints' normalization assert downstream.
      maxWidth: math.max(0.0, width - 32),
      bottomOffset: 24,
      showVolume: false,
      touchTargets: true,
      showQuality: false,
      horizontalPadding: 12,
    );
  }
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
  static const double rowGap = 18.0;

  /// Vertical padding above row 1 and below row 2. Public so tests (e.g.
  /// `glass_legibility_test`) can derive real panel-geometry fractions
  /// instead of hand-rounded literals.
  static const double verticalPadding = 16.0;

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
