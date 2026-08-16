import 'dart:ui';

import 'package:flutter/material.dart';
// Prefixed, and imported *only* here. This file is the seam that keeps the
// dependency swappable (see the `liquid_glass_widgets` entry in
// `pubspec.yaml`): nothing else in the app may import it, and a rollback to a
// plain `BackdropFilter` is a revert of this one file. The prefix also keeps
// the package's large export surface — GlassCard, GlassButton, GlassScaffold,
// and dozens more we do not use — out of this library's namespace.
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as lg;

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

  /// Gradient stroked around the rounded-rect silhouette ([borderRadius]),
  /// painted on top of the fill/blur once both are clipped. Null (the
  /// default, used by every existing named constructor) paints no rim at
  /// all. [GlassSurface.playerChrome] uses this instead of [border] for its
  /// directional rim: a gradient-shaded stroke traces the rounded corners
  /// exactly, whereas a [Border] with different per-side colors cannot be
  /// combined with a non-zero [borderRadius] (Flutter's `Border.paint`
  /// rejects it) and a same-color-only border would have to stop short of
  /// the corners to avoid that.
  final Gradient? rimGradient;

  /// When non-null, this surface renders the *refracting* playback-chrome
  /// material for the given tier instead of the plain
  /// blur-and-fill composition every other constructor uses.
  ///
  /// Only [GlassSurface.playerChrome] sets this. Null (every other named
  /// constructor, and the unnamed one) leaves [build] on the original
  /// `BackdropFilter` path, so no existing surface changes behaviour.
  ///
  /// [PlayerGlassTier.faux] is deliberately *not* excluded here: [build]
  /// routes it back to the no-live-blur path, because there is no point
  /// paying for a refraction shader on a tier whose entire premise is that
  /// the device cannot afford one.
  final PlayerGlassTier? playerTier;

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
    this.rimGradient,
    this.playerTier,
    this.child,
  });

  /// Pre-compiles the glass fragment shaders.
  ///
  /// Call once from `main()` before `runApp`. Without it the first frame that
  /// mounts playback chrome pays the shader compile inline — the package
  /// documents 100-800ms on mid-range Android GLES hardware — and that first
  /// frame is exactly when the OSD appears at playback start. The renderer
  /// degrades to a tinted passthrough rather than throwing while the shader
  /// is missing, so a skipped or failed warm-up is a visible pop, not a
  /// crash.
  ///
  /// Wrapped here rather than called directly from `main.dart` so this file
  /// stays the only importer of `liquid_glass_widgets`; see the import
  /// comment at the top.
  static Future<void> warmUpShaders() => lg.LiquidGlassWidgets.initialize();

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
  /// A factory rather than a redirecting constructor so the tier is resolved
  /// exactly once: a redirecting constructor's initializer list cannot hold a
  /// local, which is what forced `tier ?? PlatformFeatures.playerGlassTier` to
  /// be repeated per field — and left a new tier-dependent field free to
  /// resolve it a second, divergent way.
  factory GlassSurface.playerChrome({
    Key? key,
    BorderRadius? borderRadius,
    PlayerGlassTier? tier,
    Widget? child,
  }) {
    final resolvedTier = tier ?? PlatformFeatures.playerGlassTier;
    final faux = resolvedTier == PlayerGlassTier.faux;

    // The faux tier has no blur to hide the backdrop, so it compensates with
    // a denser fill.
    final fillTopAlpha = faux ? 0.70 : DepthTokens.playerChromeFillTopAlpha;
    final fillBottomAlpha =
        faux ? 0.70 : DepthTokens.playerChromeFillBottomAlpha;

    return GlassSurface(
      key: key,
      blurSigma: faux ? DepthTokens.blurNone : DepthTokens.blurPlayerChrome,
      live: !faux,
      saturation: resolvedTier == PlayerGlassTier.full
          ? DepthTokens.playerChromeSaturation
          : 1.0,
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          DepthTokens.playerChromeTint.withValues(alpha: fillTopAlpha),
          DepthTokens.playerChromeTint.withValues(alpha: fillBottomAlpha),
        ],
      ),
      borderRadius: borderRadius ??
          const BorderRadius.all(
            Radius.circular(DepthTokens.radiusPlayerPanel),
          ),
      rimGradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [DepthTokens.playerRimTop, DepthTokens.playerRimBottom],
      ),
      playerTier: resolvedTier,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Faux-glass: no BackdropFilter at all (R8). Checked before [playerTier]
    // so PlayerGlassTier.faux keeps landing here rather than paying for a
    // refraction shader (see [playerTier]'s dartdoc).
    if (!live) {
      return RepaintBoundary(
        child: ClipRRect(
          borderRadius: borderRadius,
          child: _withRim(_fill()),
        ),
      );
    }

    final tier = playerTier;
    if (tier != null) return _buildLensed(tier);

    final blur = ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma);
    final filter = saturation == 1.0
        ? blur
        : ImageFilter.compose(
            outer: blur,
            inner: ColorFilter.matrix(saturationColorMatrix(saturation)),
          );
    final backdrop = grouped
        ? BackdropFilter.grouped(filter: filter, child: _fill())
        : BackdropFilter(filter: filter, child: _fill());

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: borderRadius,
        child: _withRim(backdrop),
      ),
    );
  }

  /// The refracting playback-chrome material.
  ///
  /// Differs from the [BackdropFilter] path above in what it does to the
  /// backdrop: that one only blurs, this one also *bends*, sampling the video
  /// behind the panel at displaced coordinates so the rim reads as a lens
  /// rather than a frosted rectangle.
  ///
  /// The fill stays ours. `glassColor` is fully transparent so the package
  /// contributes no tint of its own, and [_fill]'s gradient
  /// ([DepthTokens.playerChromeFillTopAlpha] -> `...BottomAlpha`) remains the
  /// only thing standing between the controls and the video. That is
  /// deliberate and load-bearing: `glass_legibility_test.dart` derives the
  /// panel's WCAG contrast analytically from those two tokens, and the
  /// package has no gradient fill at all (`LiquidGlassSettings.glassColor` is
  /// a single [Color]). Letting it own the fill would flatten the gradient to
  /// one alpha *and* move the contrast contract out of our tests.
  ///
  /// That analytic model survives this change. Over the spatially uniform
  /// worst-case backdrop it assumes, refraction and chromatic aberration are
  /// both the identity — displaced samples of a constant field are that same
  /// constant — exactly as blur and the saturation matrix already were. The
  /// one genuinely new term is the specular highlight, which *adds* light and
  /// so lowers contrast for white glyphs wherever it lands. It is confined to
  /// the lit edge, and [ChromePanel] holds row 1 a further
  /// `ChromePanel.verticalPadding` (10px) inboard of that edge, so it falls
  /// on padding rather than on any glyph. Narrow the padding, raise
  /// [DepthTokens.playerChromeLightIntensity], or put content flush to the
  /// top edge and that stops being true.
  Widget _buildLensed(PlayerGlassTier tier) {
    final settings = lg.LiquidGlassSettings(
      // Transparent: see above. The package must add no tint of its own.
      glassColor: const Color(0x00000000),
      blur: blurSigma,
      saturation: saturation,
      thickness: DepthTokens.playerChromeThickness,
      refractiveIndex: DepthTokens.playerChromeRefractiveIndex,
      chromaticAberration: DepthTokens.playerChromeChromaticAberration,
      lightIntensity: DepthTokens.playerChromeLightIntensity,
      lightAngle: DepthTokens.playerChromeLightAngle,
      specularSharpness: lg.GlassSpecularSharpness.medium,
    );

    return RepaintBoundary(
      // The iOS 27 darkened outer edge, painted by us. The package's own
      // `shadow`/`shadowElevation` are documented "has no effect in dark
      // mode" in three separate places in `LiquidGlassSettings`, and this
      // player's theme is dark-only and never switches, so passing them
      // would be a silent no-op.
      //
      // A painter rather than a `DecoratedBox(boxShadow:)` for the reason in
      // DepthTokens.playerChromeEdgeShadowColor's dartdoc: a box shadow would
      // paint behind the translucent fill and darken it. It also keeps this
      // from becoming the first DecoratedBox under the surface, which is how
      // several tests locate the *fill*.
      child: CustomPaint(
        painter: PlayerChromeEdgeShadowPainter(borderRadius: borderRadius),
        child: lg.GlassContainer(
          shape: lg.LiquidRoundedSuperellipse(
            borderRadius: borderRadius.topLeft.x,
          ),
          settings: settings,
          // premium captures a backdrop texture for true refraction and is
          // Impeller-only; standard runs the lightweight single-pass shader,
          // which still pushes a BackdropFilterLayer (so web keeps the blur
          // and saturation it has today) but cannot lens without that
          // texture. faux never reaches here.
          quality: tier == PlayerGlassTier.full
              ? lg.GlassQuality.premium
              : lg.GlassQuality.standard,
          // Required, not cosmetic: playback chrome sits over the video
          // surface, and on hybrid composition a live BackdropFilter is the
          // only path that blurs a PlatformView at all. Without this the
          // panel renders over unblurred video.
          platformViewBackdrop: true,
          child: _withRim(_fill()),
        ),
      ),
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

  /// Paints [rimGradient] as a gradient-shaded stroke around the
  /// [borderRadius] silhouette, on top of [content]. No-op (returns [content]
  /// unchanged) when [rimGradient] is null — the case for every existing
  /// named constructor, so this only ever adds a paint pass for
  /// [GlassSurface.playerChrome].
  Widget _withRim(Widget content) {
    final rim = rimGradient;
    if (rim == null) return content;
    return CustomPaint(
      foregroundPainter: PlayerChromeRimPainter(
        borderRadius: borderRadius,
        gradient: rim,
      ),
      child: content,
    );
  }
}

/// Strokes a rounded-rect outline with a gradient shader, tracing
/// [borderRadius] exactly — including the corners — rather than
/// approximating it with per-side [BorderSide]s. A [Border] with differing
/// side colors cannot be combined with a non-zero [BoxDecoration.borderRadius]
/// (Flutter's `Border.paint` throws "A borderRadius can only be given on
/// borders with uniform colors."), and even a same-color border would have to
/// stop short of the corners to stay inside the [ClipRRect]. Painting the
/// stroke directly with [Canvas.drawRRect] sidesteps both problems: the rim
/// follows the curve continuously, with [gradient] free to vary color along
/// it.
///
/// Used by [GlassSurface.playerChrome] for its directional (light top, dark
/// bottom) rim; see [GlassSurface._withRim]. Public (rather than
/// library-private) so tests can assert on its fields directly instead of
/// re-deriving them from painted pixels.
@visibleForTesting
class PlayerChromeRimPainter extends CustomPainter {
  const PlayerChromeRimPainter({
    required this.borderRadius,
    required this.gradient,
    this.strokeWidth = DepthTokens.rimWidth,
  });

  final BorderRadius borderRadius;
  final Gradient gradient;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // A centered stroke straddles the RRect boundary; since this painter
    // sits inside the same ClipRRect that defines that boundary, the outer
    // half would otherwise be clipped away, thinning the visible line.
    // Deflating first keeps the whole stroke width inside the clip.
    final rrect = borderRadius.toRRect(rect).deflate(strokeWidth / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..shader = gradient.createShader(rect);
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant PlayerChromeRimPainter oldDelegate) {
    return oldDelegate.borderRadius != borderRadius ||
        oldDelegate.gradient != gradient ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

/// Paints the playback panel's darkened outer edge (iOS 27) strictly
/// *outside* the [borderRadius] silhouette.
///
/// [BlurStyle.outer] is the whole point. The obvious implementation, a
/// [BoxDecoration] with a [BoxShadow], paints behind its child — and this
/// panel's fill is deliberately translucent (see
/// [DepthTokens.playerChromeFillTopAlpha]), so that shadow would read through
/// the glass and darken it. Beyond looking wrong, it would move the panel's
/// real contrast away from what `glass_legibility_test.dart` computes, with
/// nothing in that test changing to reveal it. Painting outer-only leaves
/// every pixel inside the silhouette untouched.
///
/// Public rather than library-private so tests can assert on its fields
/// directly instead of re-deriving them from painted pixels, matching
/// [PlayerChromeRimPainter].
@visibleForTesting
class PlayerChromeEdgeShadowPainter extends CustomPainter {
  const PlayerChromeEdgeShadowPainter({
    required this.borderRadius,
    this.color = DepthTokens.playerChromeEdgeShadowColor,
    this.sigma = DepthTokens.playerChromeEdgeShadowSigma,
  });

  final BorderRadius borderRadius;
  final Color color;
  final double sigma;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = borderRadius.toRRect(Offset.zero & size);
    final paint = Paint()
      ..color = color
      ..maskFilter = MaskFilter.blur(BlurStyle.outer, sigma);
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant PlayerChromeEdgeShadowPainter oldDelegate) {
    return oldDelegate.borderRadius != borderRadius ||
        oldDelegate.color != color ||
        oldDelegate.sigma != sigma;
  }
}

/// A 4x5 colour matrix that scales saturation by [s] while preserving
/// luminance, using the Rec. 709 coefficients. `s == 1.0` yields the identity
/// matrix (no change); `s == 0.0` yields full desaturation (grayscale).
///
/// This is what separates real vibrancy from a plain Gaussian blur: blurring
/// alone averages a video frame toward grey, while boosting saturation first
/// keeps the backdrop's colour reading through the glass.
///
/// Public (rather than library-private) so its numeric coefficients — the
/// actual defect this task fixes — can be unit-tested directly (identity at
/// `s = 1.0`, luminance preservation for arbitrary `s`) rather than only
/// verified indirectly through the composed [ImageFilter].
@visibleForTesting
List<double> saturationColorMatrix(double s) {
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final ir = (1 - s) * lr, ig = (1 - s) * lg, ib = (1 - s) * lb;
  return <double>[
    ir + s, ig, ib, 0, 0, //
    ir, ig + s, ib, 0, 0, //
    ir, ig, ib + s, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
}
