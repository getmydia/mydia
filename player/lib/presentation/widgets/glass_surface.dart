import 'dart:ui';

import 'package:flutter/material.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/depth_tokens.dart';

/// A single reusable frosted-glass surface that subsumes the player's three
/// ad-hoc `BackdropFilter` variants (app bar, modal, card hover overlay), plus
/// a no-live-blur faux-glass variant for scrolling-quantity content (R8).
///
/// Internally this is `RepaintBoundary > ClipRRect > BackdropFilter > fill` for
/// real-blur chrome, so live blur stays isolated to small fixed-position chrome
/// (R8/R11) and the blur region repaints independently of surrounding content.
/// When [live] is false (see [GlassSurface.faux]) the [BackdropFilter] is
/// omitted entirely — `RepaintBoundary > ClipRRect > fill` — so no blur pass is
/// created for rails, grids, and other content that appears in scrolling
/// quantity.
///
/// All blur sigmas, fill opacities, and rim treatments are sourced from
/// [DepthTokens] (R2) rather than per-call literals.
///
/// Use the named constructors ([GlassSurface.appBar], [GlassSurface.modal],
/// [GlassSurface.hoverOverlay], [GlassSurface.faux], [GlassSurface.osd]) to
/// reproduce the established visual treatments; the unnamed constructor is
/// available for bespoke surfaces.
///
/// When several real-blur surfaces are visible at once, wrap them in a
/// [BackdropGroup] and pass `grouped: true` so they share a single backdrop
/// rendering pass (uses [BackdropFilter.grouped]). Faux surfaces ignore
/// [grouped] — there is no backdrop pass to share.
class GlassSurface extends StatelessWidget {
  /// Gaussian blur sigma applied behind the surface. Ignored when [live] is
  /// false.
  final double blurSigma;

  /// Whether to render a live [BackdropFilter] (real glass) or omit it
  /// (faux-glass, R8). Defaults to true.
  final bool live;

  /// Solid fill painted over the blur. Ignored when [gradient] is set.
  final Color? fillColor;

  /// Optional gradient fill painted over the blur (e.g. the card hover scrim).
  /// Takes precedence over [fillColor] when both are provided.
  final Gradient? gradient;

  /// Corner radius for the clip and border.
  final BorderRadius borderRadius;

  /// Optional border drawn on the fill.
  final BoxBorder? border;

  /// Whether to participate in an enclosing [BackdropGroup] for a shared
  /// rendering pass. Requires a [BackdropGroup] ancestor. No-op when [live] is
  /// false.
  final bool grouped;

  /// Drop shadow painted *outside* the clip, so it is not cut off. Empty
  /// (the default for every constructor except [GlassSurface.osd]) paints
  /// nothing and adds no widget.
  final List<BoxShadow> shadows;

  final Widget? child;

  const GlassSurface({
    super.key,
    required this.blurSigma,
    this.live = true,
    this.fillColor,
    this.gradient,
    this.borderRadius = BorderRadius.zero,
    this.border,
    this.grouped = false,
    this.shadows = const <BoxShadow>[],
    this.child,
  });

  /// App-bar chrome glass: chrome blur sigma, [AppColors.background] fill at the
  /// chrome fill opacity, no border, square corners. Pass [opacity] to override
  /// the fill alpha (0.85 for the library/downloads bars, the chrome token
  /// elsewhere). The default fill clears the R10 legibility floor.
  GlassSurface.appBar({
    Key? key,
    double opacity = DepthTokens.chromeFillOpacity,
    bool grouped = false,
    Widget? child,
  }) : this(
          key: key,
          blurSigma: DepthTokens.blurChrome,
          fillColor: AppColors.background.withValues(alpha: opacity),
          grouped: grouped,
          child: child,
        );

  /// Modal / sheet glass: modal blur sigma, [AppColors.surface] at the modal
  /// fill opacity, [AppColors.border] @0.2 border, radius 20.
  GlassSurface.modal({
    Key? key,
    bool grouped = false,
    Widget? child,
  }) : this(
          key: key,
          blurSigma: DepthTokens.blurModal,
          fillColor:
              AppColors.surface.withValues(alpha: DepthTokens.modalFillOpacity),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppColors.border.withValues(alpha: 0.2),
          ),
          grouped: grouped,
          child: child,
        );

  /// Media-card hover overlay glass: hover blur sigma, vertical black gradient
  /// (0.3 -> 0.6), radius 12.
  GlassSurface.hoverOverlay({
    Key? key,
    BorderRadius? borderRadius,
    bool grouped = false,
    Widget? child,
  }) : this(
          key: key,
          blurSigma: DepthTokens.blurHoverOverlay,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.3),
              Colors.black.withValues(alpha: 0.6),
            ],
          ),
          borderRadius: borderRadius ?? BorderRadius.circular(12),
          grouped: grouped,
          child: child,
        );

  /// Faux-glass: a token-driven translucent surface with **no** live blur
  /// ([BackdropFilter] is omitted). Used for surfaces that appear in scrolling
  /// quantity — rails, grids, per-card overlays — where a live blur pass would
  /// be too expensive on Flutter web (R8). Renders the translucent [fillColor]
  /// (or [gradient]) plus, by default, the light rim token as a 1px edge.
  ///
  /// Pass `showRim: false` to drop the rim (e.g. a darkening scrim over a
  /// poster that should not gain a visible border).
  const GlassSurface.faux({
    Key? key,
    Color? fillColor,
    Gradient? gradient,
    BorderRadius? borderRadius,
    bool showRim = true,
    Widget? child,
  }) : this(
          key: key,
          blurSigma: DepthTokens.blurNone,
          live: false,
          fillColor: fillColor,
          gradient: gradient,
          borderRadius: borderRadius ?? BorderRadius.zero,
          border: showRim
              ? const Border.fromBorderSide(
                  BorderSide(
                    color: DepthTokens.rimColor,
                    width: DepthTokens.rimWidth,
                  ),
                )
              : null,
          child: child,
        );

  /// The on-screen-display material: the playback panel, the top-bar pills,
  /// up next, skip segment, the stats panel, and the pickers opened from
  /// them.
  ///
  /// A dense dark card ([DepthTokens.osdFillOpacity]) over a light backdrop
  /// blur, with a uniform hairline and a drop shadow sized by [elevation].
  /// It renders the same on every platform: no quality tiers and no package
  /// shaders.
  ///
  /// The shadow sits outside the clip and also beneath the translucent fill,
  /// so it darkens the video the blur samples. That is part of the look;
  /// `osd_legibility_test.dart` does not count on it.
  GlassSurface.osd({
    Key? key,
    BorderRadius? borderRadius,
    OsdElevation elevation = OsdElevation.panel,
    Widget? child,
  }) : this(
          key: key,
          blurSigma: DepthTokens.osdBlurSigma,
          fillColor:
              DepthTokens.osdTint.withValues(alpha: DepthTokens.osdFillOpacity),
          borderRadius: borderRadius ??
              const BorderRadius.all(
                Radius.circular(DepthTokens.radiusOsdPanel),
              ),
          border: Border.all(
            color: DepthTokens.osdHairline,
            width: DepthTokens.rimWidth,
          ),
          shadows: elevation.shadows,
          child: child,
        );

  @override
  Widget build(BuildContext context) => _withShadow(_surface());

  Widget _withShadow(Widget surface) {
    if (shadows.isEmpty) return surface;
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: borderRadius, boxShadow: shadows),
      child: surface,
    );
  }

  Widget _surface() {
    // Faux-glass: no BackdropFilter at all (R8).
    if (!live) {
      return RepaintBoundary(
        child: ClipRRect(borderRadius: borderRadius, child: _fill()),
      );
    }

    final filter = ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma);
    final backdrop = grouped
        ? BackdropFilter.grouped(filter: filter, child: _fill())
        : BackdropFilter(filter: filter, child: _fill());

    return RepaintBoundary(
      child: ClipRRect(borderRadius: borderRadius, child: backdrop),
    );
  }

  Widget _fill() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: gradient == null ? fillColor : null,
        gradient: gradient,
        borderRadius: borderRadius,
        border: border,
      ),
      child: child,
    );
  }
}
