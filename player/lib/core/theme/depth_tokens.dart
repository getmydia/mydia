import 'package:flutter/material.dart';

/// Mydia Depth / Material Tokens
///
/// The single source of truth for the player's liquid-glass depth model
/// (plan R1/R2). Every converted surface — sidebar, bars, video controls,
/// posters, ambient backdrop — derives its tones, blur, shadow, rim, and motion
/// from the `static const` values here instead of one-off literals. A later
/// surface picks up the look simply by reading the same module.
///
/// A flat `static const` module for the values that do not change between
/// theme presets (blur, shadow, rim, motion, OSD). Surface tones, which do
/// change, live in `MydiaPalette` (palette.dart).
abstract final class DepthTokens {
  // Surface tones moved to `MydiaPalette` (palette.dart): they change with
  // the theme preset. `palette.surfaceTones` keeps the rising order.

  // ---------------------------------------------------------------------------
  // Blur sigmas (R8)
  //
  // Gaussian blur strengths for live [BackdropFilter] chrome and the
  // pre-blurred ambient backdrop. Seeded from the existing 2/8/10/40 values in
  // `GlassSurface`/`AmbientBackdrop`. Real blur is confined to the surfaces
  // these serve (chrome + backdrop); scrolling content uses [blurNone].
  // ---------------------------------------------------------------------------

  /// Faux-glass: no live blur. Scrolling-quantity surfaces (rails, grids) use
  /// this so no per-card [BackdropFilter] pass is created.
  static const double blurNone = 0.0;

  /// Media-card hover overlay blur.
  static const double blurHoverOverlay = 2.0;

  /// Modal / sheet glass blur.
  static const double blurModal = 8.0;

  /// Chrome glass blur — sidebar, top bars, video controls.
  static const double blurChrome = 10.0;

  /// Ambient backdrop pre-blur (applied once to the artwork image layer, never
  /// a live full-screen pass behind scroll).
  static const double blurAmbient = 40.0;

  // ---------------------------------------------------------------------------
  // Shadow profiles (R7)
  //
  // Resting + hover-lift shadow tuples for the solid, always-elevated posters,
  // plus a layered chrome shadow. Colors are const black alphas (e.g. 0.15 ->
  // 0x26) so the whole `BoxShadow` stays `const`.
  // ---------------------------------------------------------------------------

  /// Always-on resting shadow for posters — depth at rest, not only on hover
  /// (R7). Replaces the inline `media_card`/`media_poster` resting shadows.
  static const List<BoxShadow> posterResting = <BoxShadow>[
    BoxShadow(
      color: Color(0x26000000), // black @ 0.15
      blurRadius: 8,
      offset: Offset(0, 4),
    ),
  ];

  /// Hover shadow for posters — a barely-there deepening over [posterResting]
  /// at the same offset, so the poster firms up slightly without lifting or
  /// "floating" (R11). The poster does not translate on hover.
  static const List<BoxShadow> posterHover = <BoxShadow>[
    BoxShadow(
      color: Color(0x2E000000), // black @ 0.18
      blurRadius: 10,
      offset: Offset(0, 4),
    ),
  ];

  /// Layered drop shadow for glass chrome panels (sidebar, floating bars) so
  /// they read as elevated over the ambient backdrop. Matches the mobile bottom
  /// nav's existing shadow composition.
  static const List<BoxShadow> chrome = <BoxShadow>[
    BoxShadow(
      color: Color(0x1A000000), // black @ 0.10
      blurRadius: 16,
      spreadRadius: 2,
      offset: Offset(0, 4),
    ),
  ];

  // ---------------------------------------------------------------------------
  // Rim / edge treatment (R4/R6)
  //
  // A subtle light rim that defines a glass panel's edge and gives it a crisp,
  // modern read. A light (white) low-alpha hairline, kept `const`.
  // ---------------------------------------------------------------------------

  /// Light rim color — a faint white edge highlight for glass chrome.
  static const Color rimColor = Color(0x14FFFFFF); // white @ ~0.08

  /// Rim / hairline width.
  static const double rimWidth = 1.0;

  // ---------------------------------------------------------------------------
  // Poster geometry
  //
  // The corner radius shared by the poster-shaped surfaces that have adopted
  // it: library grid, library list, home rails, and search results. Before
  // this token the grid used 8 and the rails used 12, and a new surface picked
  // whichever it happened to copy. The movie and show detail screens still
  // render their poster artwork at a hand-rolled radius 12 with their own
  // BoxShadows — they have not been converted to PosterFrame yet.
  // ---------------------------------------------------------------------------

  /// Corner radius for every poster surface that composes [PosterFrame]. Read
  /// via [PosterFrame], which is the only widget that should apply it
  /// directly.
  static const double radiusPoster = 8.0;

  // ---------------------------------------------------------------------------
  // Glass fill (R4/R10)
  //
  // Translucent fill opacities for glass chrome and the legibility floor that
  // guarantees nav labels / controls / text stay readable over any backdrop
  // color (R10). [glassLegibilityFloor] is the minimum fill alpha any chrome
  // surface may resolve to; converted chrome asserts its fill clears it.
  // ---------------------------------------------------------------------------

  /// Default chrome glass fill opacity (sidebar, app bars, video controls).
  static const double chromeFillOpacity = 0.8;

  /// Modal / sheet glass fill opacity.
  static const double modalFillOpacity = 0.6;

  /// Minimum glass fill opacity for any chrome surface — the R10 legibility
  /// floor. Chrome fills at or above this keep text legible over worst-case
  /// bright artwork behind the live blur.
  static const double glassLegibilityFloor = 0.6;

  // ---------------------------------------------------------------------------
  // Motion (R11)
  //
  // Durations and curves for the small resting-depth accents. Seeded from the
  // existing 150/200/600ms timings. Hover collapses to a small lift / gentle
  // brightness shift; no scale, parallax, or specular sheen.
  // ---------------------------------------------------------------------------

  /// Fast accent (hover lift, brightness shift).
  static const Duration motionFast = Duration(milliseconds: 150);

  /// Medium accent (overlay fades).
  static const Duration motionMedium = Duration(milliseconds: 200);

  /// Slow transition (ambient backdrop crossfade).
  static const Duration motionSlow = Duration(milliseconds: 600);

  /// Standard easing for entering accents.
  static const Curve curveStandard = Curves.easeOutCubic;

  /// Emphasized easing for crossfades / symmetric transitions.
  static const Curve curveEmphasized = Curves.easeInOut;

  // ---------------------------------------------------------------------------
  // OSD material
  //
  // The one material every on-screen-display surface uses: the playback
  // panel, the top-bar pills, up next, skip segment, the stats panel, and the
  // pickers opened from them. A dense dark card over a light frost, with a
  // uniform hairline and a soft drop shadow, identical on every platform.
  //
  // The fill alone carries legibility. Over a pure-white frame it composites
  // to ~#303030, where textSecondary measures ~4.6:1 (at 0.80 it would be
  // ~3.8:1). `osd_legibility_test.dart` computes this from these tokens.
  // ---------------------------------------------------------------------------

  /// Fixed for every theme preset: the OSD sits over video, not the app
  /// ground, and osd_legibility_test measures against this value.
  static const Color osdTint = Color(0xFF0B0B0C);

  /// Opacity of the OSD fill.
  static const double osdFillOpacity = 0.85;

  /// Backdrop blur sigma. Light on purpose: the fill does the legibility
  /// work, and the blur only turns the ~15% of video that shows through into
  /// soft colour instead of faint detail.
  static const double osdBlurSigma = 20.0;

  /// Uniform hairline around every OSD surface (white @ ~0.10).
  static const Color osdHairline = Color(0x1AFFFFFF);

  /// Divider between sections inside an OSD surface (white @ ~0.08).
  static const Color osdDivider = Color(0x14FFFFFF);

  /// Elevation for panel-sized OSD surfaces: the control panel, up next, the
  /// stats panel and dialogs.
  static const List<BoxShadow> osdShadowPanel = <BoxShadow>[
    BoxShadow(
      color: Color(0x80000000), // black @ ~0.50
      blurRadius: 36,
      offset: Offset(0, 10),
    ),
  ];

  /// Elevation for OSD pills (36-44px tall). The panel shadow would put a
  /// dark cloud around something this small.
  static const List<BoxShadow> osdShadowPill = <BoxShadow>[
    BoxShadow(
      color: Color(0x59000000), // black @ ~0.35
      blurRadius: 16,
      offset: Offset(0, 4),
    ),
  ];

  /// Corner radius for panel-sized OSD surfaces.
  static const double radiusOsdPanel = 16.0;

  /// Corner radius for OSD pills, fully rounded at the 36px default height.
  static const double radiusOsdPill = 18.0;

  /// Corner radius for OSD bottom sheets (top corners) and dialogs.
  static const double radiusOsdSheet = 20.0;

  // ---------------------------------------------------------------------------
  // Liquid Glass (iOS and macOS)
  //
  // The floating control layer's material on Apple platforms: a light blur,
  // refraction along the edge band, a saturation and brightness lift, a
  // darkened outer edge and a specular rim. Read by `LiquidGlassUniforms` and
  // `GlassSurface`. Lengths are logical pixels; the uniforms scale them by
  // the device pixel ratio. Never used by the OSD.
  // ---------------------------------------------------------------------------

  /// Blur applied before the shader bends the backdrop.
  static const double liquidBlurSigma = 14.0;

  /// Width of the band along the edge where the backdrop is bent.
  static const double liquidEdgeBand = 22.0;

  /// How far the backdrop is displaced at the very rim.
  static const double liquidRefraction = 14.0;

  /// Extra displacement of red over blue, as a fraction of the refraction.
  static const double liquidDispersion = 0.12;

  /// Saturation multiplier for the backdrop (1 leaves it unchanged).
  static const double liquidSaturation = 1.6;

  /// Brightness added to the backdrop, 0..1.
  static const double liquidBrightness = 0.04;

  /// Specular rim intensity at rest.
  static const double liquidSpecular = 0.85;

  /// Extra specular while hovered (macOS) or pressed.
  static const double liquidHoverSpecularBoost = 0.2;
  static const double liquidPressSpecularBoost = 0.35;

  /// How much the outermost pixels darken (the iOS 27 edge).
  static const double liquidEdgeShade = 0.5;

  /// Width of the specular rim.
  static const double liquidRimWidth = 1.5;

  /// Width of the darkened edge, inward from the rim.
  static const double liquidEdgeShadeWidth = 6.0;

  /// Light added across the edge band on the side facing the light: the
  /// glass's thickness.
  static const double liquidInnerGlow = 0.12;

  /// Backdrop luma range over which the tint rises from its base alpha to
  /// its adaptive max (smoothstep).
  static const double liquidAdaptiveLumaLow = 0.35;
  static const double liquidAdaptiveLumaHigh = 0.9;

  /// Spacing of the local luma taps the adaptive tint reads (logical px).
  /// The shader takes the brightest of a 3x3 grid this far apart, centred
  /// on each pixel.
  static const double liquidAdaptiveRadius = 12.0;

  /// Glow under the finger while pressed, and its radius as a fraction of
  /// the surface's shorter side.
  static const double liquidPressGlow = 0.18;
  static const double liquidPressGlowRadius = 0.9;

  /// Resting light position, as a fraction of the surface (top-left).
  static const Offset liquidLightRest = Offset(0.25, 0.0);

  // Base tint per role (over a dark backdrop) and the adaptive max the
  // shader raises it to over a bright one. The adaptive max must clear
  // [glassLegibilityFloor]; `liquid_glass_legibility_test.dart` checks text
  // and icon contrast for every preset over grey backdrops from black to
  // white in steps of 0.05, since the tint is lowest at mid luma. The luma
  // is the brightest nearby, so it is the worst case under a glyph.
  static const double liquidChromeTintOpacity = 0.5;
  static const double liquidModalTintOpacity = 0.55;
  static const double liquidControlTintOpacity = 0.3;
  static const double liquidChromeAdaptiveMax = 0.85;
  static const double liquidModalAdaptiveMax = 0.85;
  static const double liquidControlAdaptiveMax = 0.65;

  /// The primary Play button's accent glass.
  static const double liquidAccentTintOpacity = 0.55;
  static const double liquidAccentAdaptiveMax = 0.9;

  /// The toolbar's scroll edge band: a plain blur under a ground gradient,
  /// opaque enough for the title at the top, clearer where the chips sit.
  static const double liquidScrollEdgeBlurSigma = 20.0;
  static const double liquidScrollEdgeTopOpacity = 0.8;
  static const double liquidScrollEdgeBottomOpacity = 0.35;

  /// The lift under a floating glass control.
  static const List<BoxShadow> liquidControlShadow = [
    BoxShadow(color: Color(0x2E000000), blurRadius: 12, offset: Offset(0, 4)),
  ];

  /// The prominent button's white tint (the design system's primary pill).
  static const double liquidProminentTintOpacity = 0.85;

  /// Added to the tint opacity when Increase Contrast is on.
  static const double liquidHighContrastTintBoost = 0.15;

  /// Rim alpha drawn as a border when Increase Contrast is on.
  static const double liquidHighContrastRimAlpha = 0.6;

  /// Press feedback: scale, drag stretch, and timing.
  static const double liquidPressScale = 1.04;
  static const double liquidPressStretch = 2.0;
  static const Duration liquidPressDuration = Duration(milliseconds: 180);

  /// Easing for the press swell: a slight overshoot before it settles.
  static const Curve liquidPressCurve = Curves.easeOutBack;

  /// Diameter of a floating glass icon button: 44, Apple's minimum touch
  /// target.
  static const double liquidIconButtonSize = 44.0;

  /// Clearance kept above and below a glass icon button in a short row.
  static const double liquidIconButtonInset = 4.0;

  /// Corner radius of glass dialogs and popovers.
  static const double liquidDialogRadius = 28.0;

  /// Minimum width of a glass dialog, matching Material's AlertDialog.
  static const double liquidDialogMinWidth = 280.0;

  static const double liquidPopoverRadius = 16.0;
}

/// How far an OSD surface lifts off the video.
enum OsdElevation {
  panel(DepthTokens.osdShadowPanel),
  pill(DepthTokens.osdShadowPill),

  /// Bottom sheets: the modal barrier already separates them from the video.
  none(<BoxShadow>[]);

  const OsdElevation(this.shadows);

  final List<BoxShadow> shadows;
}
