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

  const PanelMetrics({
    required this.maxWidth,
    required this.bottomOffset,
    required this.showVolume,
    required this.touchTargets,
  });

  /// Resolve metrics for a viewport [width], using the breakpoints in
  /// `core/layout/breakpoints.dart` (mobile < 600, tablet 600–899,
  /// desktop >= 900).
  factory PanelMetrics.forWidth(double width) {
    if (width >= Breakpoints.tablet) {
      return PanelMetrics(
        maxWidth: math.min(720.0, width * 0.60),
        bottomOffset: 48,
        showVolume: true,
        touchTargets: false,
      );
    }
    if (width >= Breakpoints.mobile) {
      return PanelMetrics(
        maxWidth: math.min(640.0, width * 0.80),
        bottomOffset: 32,
        showVolume: true,
        touchTargets: false,
      );
    }
    return PanelMetrics(
      // Clamp: below a 32px-wide viewport this would otherwise go negative,
      // which trips BoxConstraints' normalization assert downstream.
      maxWidth: math.max(0.0, width - 32),
      bottomOffset: 24,
      showVolume: false,
      touchTargets: true,
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

  /// Horizontal padding on both sides of the panel.
  static const double horizontalPadding = 20.0;

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
          padding: const EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: verticalPadding,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  // Left and right groups are given equal flex so the
                  // transport stays optically centered regardless of how wide
                  // either side happens to be.
                  //
                  // Each slot's content is wrapped in a scale-down FittedBox:
                  // at generous widths (desktop/tablet) the content already
                  // fits and the FittedBox is a no-op (scale 1.0). Below
                  // roughly 480px, `metrics.maxWidth` leaves each Expanded
                  // slot narrower than a fully-populated `SecondaryCluster`'s
                  // natural width (three 40px glyphs + gaps == 128px), which
                  // — without this — is a real `RenderFlex` overflow: caught
                  // by this task's mobile golden, reachable on most phones in
                  // portrait (see PlaybackChrome's real call site, which
                  // always wires all three SecondaryCluster callbacks on
                  // mobile). Scaling down keeps every glyph visible and
                  // tappable (FittedBox's Transform is hit-test-aware)
                  // instead of silently clipping the rightmost buttons behind
                  // GlassSurface's ClipRRect.
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: _volumeSlot(),
                      ),
                    ),
                  ),
                  transport,
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: secondary ?? const SizedBox.shrink(),
                      ),
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
