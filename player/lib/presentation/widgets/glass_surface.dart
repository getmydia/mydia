import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/player/platform_features.dart';
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
/// [GlassSurface.hoverOverlay], [GlassSurface.faux]) to reproduce the
/// established visual treatments; the unnamed constructor is available for
/// bespoke surfaces.
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

  /// Backdrop saturation multiplier applied *before* the blur. `1.0` means no
  /// colour matrix is composed, which is the default and leaves every existing
  /// call site unchanged.
  final double saturation;

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
    this.saturation = 1.0,
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

  /// The playback chrome material.
  ///
  /// Unlike the browse-UI chrome, this sits over live video — the one backdrop
  /// that justifies a real [BackdropFilter] and can carry genuine transparency.
  /// It differs from [GlassSurface.appBar] in four ways: a much higher blur
  /// sigma, a much lower fill opacity, a saturation boost, and a *directional*
  /// rim (light on top, dark on the bottom) rather than a uniform border.
  ///
  /// [tier] defaults to [PlatformFeatures.playerGlassTier]; pass it explicitly
  /// in golden tests so images do not vary with the host platform.
  GlassSurface.playerChrome({
    Key? key,
    BorderRadius? borderRadius,
    PlayerGlassTier? tier,
    Widget? child,
  }) : this(
          key: key,
          blurSigma:
              (tier ?? PlatformFeatures.playerGlassTier) == PlayerGlassTier.faux
                  ? DepthTokens.blurNone
                  : DepthTokens.blurPlayerChrome,
          live: (tier ?? PlatformFeatures.playerGlassTier) !=
              PlayerGlassTier.faux,
          saturation:
              (tier ?? PlatformFeatures.playerGlassTier) == PlayerGlassTier.full
                  ? DepthTokens.playerChromeSaturation
                  : 1.0,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              DepthTokens.playerChromeTint.withValues(
                // The faux tier has no blur to hide the backdrop, so it
                // compensates with a denser fill.
                alpha: (tier ?? PlatformFeatures.playerGlassTier) ==
                        PlayerGlassTier.faux
                    ? 0.70
                    : DepthTokens.playerChromeFillTopAlpha,
              ),
              DepthTokens.playerChromeTint.withValues(
                alpha: (tier ?? PlatformFeatures.playerGlassTier) ==
                        PlayerGlassTier.faux
                    ? 0.70
                    : DepthTokens.playerChromeFillBottomAlpha,
              ),
            ],
          ),
          borderRadius: borderRadius ??
              const BorderRadius.all(
                Radius.circular(DepthTokens.radiusPlayerPanel),
              ),
          border: const Border(
            top: BorderSide(color: DepthTokens.playerRimTop),
            bottom: BorderSide(color: DepthTokens.playerRimBottom),
          ),
          child: child,
        );

  @override
  Widget build(BuildContext context) {
    // Faux-glass: no BackdropFilter at all (R8).
    if (!live) {
      return RepaintBoundary(
        child: ClipRRect(
          borderRadius: borderRadius,
          child: _fill(),
        ),
      );
    }

    final blur = ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma);
    final filter = saturation == 1.0
        ? blur
        : ImageFilter.compose(
            outer: blur,
            inner: ColorFilter.matrix(_saturationMatrix(saturation)),
          );
    final backdrop = grouped
        ? BackdropFilter.grouped(filter: filter, child: _fill())
        : BackdropFilter(filter: filter, child: _fill());

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: borderRadius,
        child: backdrop,
      ),
    );
  }

  Widget _fill() {
    // Flutter's `Border.paint` refuses to combine a non-zero `borderRadius`
    // with a border whose visible sides aren't all one color (it throws "A
    // borderRadius can only be given on borders with uniform colors."). The
    // directional playerChrome rim (light top, dark bottom) is deliberately
    // non-uniform, so for that case only, this decoration's own borderRadius
    // is dropped; the enclosing ClipRRect (built with the real borderRadius,
    // see build()) still clips the fill and border to rounded corners, so the
    // rendered result is unaffected. Every existing call site's border is
    // uniform (or absent), so this is a no-op for them.
    final effectiveBorder = border;
    final radius =
        effectiveBorder is Border && !_hasUniformVisibleColor(effectiveBorder)
            ? BorderRadius.zero
            : borderRadius;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: gradient == null ? fillColor : null,
        gradient: gradient,
        borderRadius: radius,
        border: border,
      ),
      child: child,
    );
  }
}

/// Whether every side of [border] that is actually painted (i.e. not
/// [BorderStyle.none]) shares the same color. See [GlassSurface._fill] for
/// why this matters.
bool _hasUniformVisibleColor(Border border) {
  final visibleSides = <BorderSide>[
    border.top,
    border.right,
    border.bottom,
    border.left,
  ].where((side) => side.style != BorderStyle.none);
  if (visibleSides.isEmpty) return true;
  final firstColor = visibleSides.first.color;
  return visibleSides.every((side) => side.color == firstColor);
}

/// A 4x5 colour matrix that scales saturation by [s] while preserving
/// luminance, using the Rec. 709 coefficients.
///
/// This is what separates real vibrancy from a plain Gaussian blur: blurring
/// alone averages a video frame toward grey, while boosting saturation first
/// keeps the backdrop's colour reading through the glass.
List<double> _saturationMatrix(double s) {
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final ir = (1 - s) * lr, ig = (1 - s) * lg, ib = (1 - s) * lb;
  return <double>[
    ir + s, ig, ib, 0, 0, //
    ir, ig + s, ib, 0, 0, //
    ir, ig, ib + s, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
}
