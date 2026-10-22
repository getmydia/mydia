import 'dart:ui';

import 'package:flutter/material.dart';
import '../../core/theme/ambient_tint/ambient_tint.dart';
import '../../core/theme/depth_tokens.dart';
import '../../core/theme/liquid_glass/glass_accessibility.dart';
import '../../core/theme/liquid_glass/glass_style.dart';
import '../../core/theme/liquid_glass/liquid_glass_profile.dart';
import '../../core/theme/liquid_glass/liquid_glass_support.dart';
import '../../core/theme/palette.dart';
import 'glass/liquid_glass_filter.dart';

/// Which ambient tint colour a glass surface fills with.
enum GlassTint { ground, surface }

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
/// [GlassSurface.chrome], [GlassSurface.sidebar], [GlassSurface.control],
/// [GlassSurface.hoverOverlay], [GlassSurface.faux], [GlassSurface.osd]) to
/// reproduce the established visual treatments; the unnamed constructor is
/// available for bespoke surfaces.
///
/// When several real-blur surfaces are visible at once, wrap them in a
/// [BackdropGroup] and pass `grouped: true` so they share a single backdrop
/// rendering pass (uses [BackdropFilter.grouped]). Faux surfaces ignore
/// [grouped] — there is no backdrop pass to share.
///
/// [GlassSurface.appBar], [GlassSurface.modal], [GlassSurface.chrome] and
/// [GlassSurface.sidebar] follow the ambient tint ([AmbientTint]); faux,
/// hoverOverlay and osd do not.
///
/// On Liquid Glass, [GlassSurface.appBar], [GlassSurface.chrome],
/// [GlassSurface.sidebar], [GlassSurface.modal] and [GlassSurface.control]
/// take the Liquid Glass recipe (`LiquidGlassFilter`) when
/// `LiquidGlassSupport.available`, and an opaque fill when Reduce
/// Transparency is on. [GlassSurface.modal] and [GlassSurface.sidebar] take
/// the panel profile (`LiquidGlassProfile.panel`), the rest the lens.
/// Chrome, sidebar, modal and control tints adapt
/// to the backdrop up to a per-role maximum ([liquidAdaptiveMax]); a white
/// prominent control never adapts. On Liquid Glass a surface with no
/// [shadows] casts its profile's shadow ([LiquidGlassProfile.shadow]). The
/// app bar is not glass but Apple's scroll edge: a plain blur under a ground
/// gradient ([liquidScrollEdge]).
/// See `player/docs/liquid-glass.md`.
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

  /// When set and [border] is null, a one-pixel border in the theme palette's
  /// border colour at this alpha. Resolved in [build] so it follows the
  /// active preset.
  final double? paletteBorderAlpha;

  /// Whether to participate in an enclosing [BackdropGroup] for a shared
  /// rendering pass. Requires a [BackdropGroup] ancestor. No-op when [live] is
  /// false.
  final bool grouped;

  /// Drop shadow painted *outside* the clip, so it is not cut off. Empty
  /// (the default for every constructor except [GlassSurface.osd]) paints
  /// nothing and adds no widget.
  final List<BoxShadow> shadows;

  /// When set and [fillColor] and [gradient] are null, the fill is this
  /// colour of the nearest [AmbientTint] at [tintOpacity].
  final GlassTint? tint;
  final double tintOpacity;

  /// Tint opacity on the Liquid Glass recipe. Null means this surface never
  /// takes it: only [GlassSurface.appBar], [GlassSurface.chrome],
  /// [GlassSurface.sidebar], [GlassSurface.modal] and [GlassSurface.control]
  /// set it, so the OSD, faux and hover overlay are excluded by construction.
  final double? liquidTintOpacity;

  /// Upper bound the Liquid Glass tint may adapt to; null keeps it fixed.
  final double? liquidAdaptiveMax;

  /// Paint the Liquid Glass branch as a scroll edge band (blur plus ground
  /// gradient) instead of the glass shader.
  final bool liquidScrollEdge;

  /// The Liquid Glass material: the lens for controls and pills, the panel
  /// for dialogs, sheets and the floating sidebar. Ignored off Liquid Glass.
  final LiquidGlassProfile liquidProfile;

  final Widget? child;

  const GlassSurface({
    super.key,
    required this.blurSigma,
    this.live = true,
    this.fillColor,
    this.gradient,
    this.borderRadius = BorderRadius.zero,
    this.border,
    this.paletteBorderAlpha,
    this.grouped = false,
    this.shadows = const <BoxShadow>[],
    this.tint,
    this.tintOpacity = DepthTokens.chromeFillOpacity,
    this.liquidTintOpacity,
    this.liquidAdaptiveMax,
    this.liquidScrollEdge = false,
    this.liquidProfile = LiquidGlassProfile.lens,
    this.child,
  });

  /// App-bar chrome glass: chrome blur sigma, the ambient ground fill at the
  /// chrome fill opacity, no border, square corners. Pass [opacity] to override
  /// the fill alpha (0.85 for the library/downloads bars, the chrome token
  /// elsewhere). The default fill clears the R10 legibility floor.
  const GlassSurface.appBar({
    Key? key,
    double opacity = DepthTokens.chromeFillOpacity,
    bool grouped = false,
    Widget? child,
  }) : this(
          key: key,
          blurSigma: DepthTokens.blurChrome,
          tint: GlassTint.ground,
          tintOpacity: opacity,
          liquidTintOpacity: DepthTokens.liquidChromeTintOpacity,
          liquidScrollEdge: true,
          grouped: grouped,
          child: child,
        );

  /// Modal / sheet glass: modal blur sigma, the ambient surface at the modal
  /// fill opacity, the palette border @0.2 border, radius 20. Takes the panel
  /// Liquid Glass profile.
  GlassSurface.modal({
    Key? key,
    BorderRadius? borderRadius,
    bool grouped = false,
    Widget? child,
  }) : this(
          key: key,
          blurSigma: DepthTokens.blurModal,
          tint: GlassTint.surface,
          tintOpacity: DepthTokens.modalFillOpacity,
          liquidTintOpacity: DepthTokens.liquidModalTintOpacity,
          liquidAdaptiveMax: DepthTokens.liquidModalAdaptiveMax,
          liquidProfile: LiquidGlassProfile.panel,
          borderRadius: borderRadius ?? BorderRadius.circular(20),
          paletteBorderAlpha: 0.2,
          grouped: grouped,
          child: child,
        );

  /// Chrome glass that follows the ambient tint: the bottom dock pill and the
  /// cast pill. Fill is the tint's surface at [opacity].
  const GlassSurface.chrome({
    Key? key,
    double opacity = DepthTokens.chromeFillOpacity,
    BorderRadius borderRadius = BorderRadius.zero,
    BoxBorder? border,
    List<BoxShadow> shadows = const <BoxShadow>[],
    bool grouped = false,
    Widget? child,
  }) : this(
          key: key,
          blurSigma: DepthTokens.blurChrome,
          tint: GlassTint.surface,
          tintOpacity: opacity,
          liquidTintOpacity: DepthTokens.liquidChromeTintOpacity,
          liquidAdaptiveMax: DepthTokens.liquidChromeAdaptiveMax,
          borderRadius: borderRadius,
          border: border,
          shadows: shadows,
          grouped: grouped,
          child: child,
        );

  /// The floating sidebar and drawer: [GlassSurface.chrome]'s recipe on the
  /// panel Liquid Glass profile, so a full-height pane reads as frosted glass
  /// rather than a lit lens. Keep its tint, opacity and blur in step with
  /// [GlassSurface.chrome].
  const GlassSurface.sidebar({
    Key? key,
    double opacity = DepthTokens.chromeFillOpacity,
    BorderRadius borderRadius = BorderRadius.zero,
    BoxBorder? border,
    List<BoxShadow> shadows = const <BoxShadow>[],
    bool grouped = false,
    Widget? child,
  }) : this(
          key: key,
          blurSigma: DepthTokens.blurChrome,
          tint: GlassTint.surface,
          tintOpacity: opacity,
          liquidTintOpacity: DepthTokens.liquidChromeTintOpacity,
          liquidAdaptiveMax: DepthTokens.liquidChromeAdaptiveMax,
          liquidProfile: LiquidGlassProfile.panel,
          borderRadius: borderRadius,
          border: border,
          shadows: shadows,
          grouped: grouped,
          child: child,
        );

  /// A floating control: a circle or capsule over content (back, close,
  /// cast, Play; the white prominent pill with [prominentColor]). Casts the
  /// lens shadow on Liquid Glass. Only used on Liquid Glass; the
  /// control widgets render Material elsewhere.
  GlassSurface.control({
    Key? key,
    required BorderRadius borderRadius,
    Color? prominentColor,
    bool grouped = false,
    Widget? child,
  }) : this(
          key: key,
          blurSigma: DepthTokens.blurChrome,
          fillColor: prominentColor?.withValues(
              alpha: DepthTokens.liquidProminentTintOpacity),
          tint: prominentColor == null ? GlassTint.surface : null,
          // The frosted fallback cannot adapt, so it fills at the alpha white
          // control labels are rated at over pure white.
          tintOpacity: DepthTokens.liquidControlAdaptiveMax,
          liquidTintOpacity: prominentColor != null
              ? DepthTokens.liquidProminentTintOpacity
              : DepthTokens.liquidControlTintOpacity,
          liquidAdaptiveMax: prominentColor != null
              ? null
              : DepthTokens.liquidControlAdaptiveMax,
          borderRadius: borderRadius,
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
  ///
  /// On web the video is an `HtmlElementView`, and this blur does not reach
  /// it: web renders the unblurred card. Verified in Chromium on 2026-09-19.
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
  Widget build(BuildContext context) {
    final base = _baseColor(context);
    final liquidOpacity = liquidTintOpacity;
    final alpha = paletteBorderAlpha;
    final resolvedBorder = border ??
        (alpha == null
            ? null
            : Border.all(
                color: context.palette.border.withValues(alpha: alpha),
              ));
    if (liquidOpacity != null && base != null) {
      final access = GlassAccessibilityScope.of(context);
      if (access.reduceTransparency) {
        return _withShadow(
            _solid(base.withValues(alpha: 1), resolvedBorder), shadows);
      }
      if (GlassStyle.of(context) && LiquidGlassSupport.available) {
        if (liquidScrollEdge) {
          return _withShadow(_scrollEdge(context, base, access), shadows);
        }
        return _withShadow(
          _liquid(context, base, liquidOpacity, access),
          shadows.isEmpty ? liquidProfile.shadow : shadows,
        );
      }
    }
    final fill = fillColor ??
        (gradient != null ? null : base?.withValues(alpha: tintOpacity));
    return _withShadow(_surface(fill, resolvedBorder), shadows);
  }

  /// The surface's colour before opacity: [fillColor] or the ambient tint.
  Color? _baseColor(BuildContext context) {
    final fill = fillColor;
    if (fill != null) return fill.withValues(alpha: 1);
    final tint = this.tint;
    if (tint == null || gradient != null) return null;
    return switch (tint) {
      GlassTint.ground => AmbientTint.of(context).ground,
      GlassTint.surface => AmbientTint.of(context).surface,
    };
  }

  /// Reduce Transparency: an opaque fill, no backdrop pass.
  Widget _solid(Color color, BoxBorder? border) => ClipRRect(
        borderRadius: borderRadius,
        child: _fill(color, border),
      );

  Widget _liquid(
    BuildContext context,
    Color base,
    double opacity,
    GlassAccessibility access,
  ) {
    final boost =
        access.increaseContrast ? DepthTokens.liquidHighContrastTintBoost : 0.0;
    final adaptiveMax = liquidAdaptiveMax;
    final alpha = (opacity + boost).clamp(0.0, 1.0);
    final rim = access.increaseContrast
        ? Border.all(
            color: context.palette.textPrimary
                .withValues(alpha: DepthTokens.liquidHighContrastRimAlpha),
            width: DepthTokens.rimWidth,
          )
        : null;
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: borderRadius,
        child: LiquidGlassFilter(
          radius: borderRadius.topLeft.x,
          tint: base.withValues(alpha: alpha),
          adaptiveTintMax: adaptiveMax == null
              ? null
              : (adaptiveMax + boost).clamp(0.0, 1.0),
          grouped: grouped,
          profile: liquidProfile,
          // The shader paints the tint; this box only carries the rim
          // and the child.
          child: DecoratedBox(
            decoration: BoxDecoration(borderRadius: borderRadius, border: rim),
            child: child,
          ),
        ),
      ),
    );
  }

  /// The toolbar on Liquid Glass: Apple's hard scroll edge. A plain blur
  /// under a ground gradient, opaque enough at the top for the title and
  /// clearer at the bottom so the glass chips there see the content.
  Widget _scrollEdge(
      BuildContext context, Color base, GlassAccessibility access) {
    final boost =
        access.increaseContrast ? DepthTokens.liquidHighContrastTintBoost : 0.0;
    double a(double v) => (v + boost).clamp(0.0, 1.0);
    final top =
        base.withValues(alpha: a(DepthTokens.liquidScrollEdgeTopOpacity));
    final filter = ImageFilter.blur(
      sigmaX: DepthTokens.liquidScrollEdgeBlurSigma,
      sigmaY: DepthTokens.liquidScrollEdgeBlurSigma,
    );
    final fill = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0.0, 0.6, 1.0],
          colors: [
            top,
            top,
            base.withValues(
                alpha: a(DepthTokens.liquidScrollEdgeBottomOpacity)),
          ],
        ),
      ),
      child: child,
    );
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: borderRadius,
        child: grouped
            ? BackdropFilter.grouped(filter: filter, child: fill)
            : BackdropFilter(filter: filter, child: fill),
      ),
    );
  }

  Widget _withShadow(Widget surface, List<BoxShadow> shadows) {
    if (shadows.isEmpty) return surface;
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: borderRadius, boxShadow: shadows),
      child: surface,
    );
  }

  Widget _surface(Color? fill, BoxBorder? border) {
    // Faux-glass: no BackdropFilter at all (R8).
    if (!live) {
      return RepaintBoundary(
        child:
            ClipRRect(borderRadius: borderRadius, child: _fill(fill, border)),
      );
    }

    final filter = ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma);
    final backdrop = grouped
        ? BackdropFilter.grouped(filter: filter, child: _fill(fill, border))
        : BackdropFilter(filter: filter, child: _fill(fill, border));

    return RepaintBoundary(
      child: ClipRRect(borderRadius: borderRadius, child: backdrop),
    );
  }

  Widget _fill(Color? fill, BoxBorder? border) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: gradient == null ? fill : null,
        gradient: gradient,
        borderRadius: borderRadius,
        border: border,
      ),
      child: child,
    );
  }
}
