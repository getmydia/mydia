import 'package:flutter/material.dart';

import 'colors.dart';

/// Mydia Depth / Material Tokens
///
/// The single source of truth for the player's liquid-glass depth model
/// (plan R1/R2). Every converted surface — sidebar, bars, video controls,
/// posters, ambient backdrop — derives its tones, blur, shadow, rim, and motion
/// from the `static const` values here instead of one-off literals. A later
/// surface picks up the look simply by reading the same module.
///
/// This mirrors the existing colors-only [AppColors] and the
/// `AppTheme.radius*` doubles: a flat `static const` module, *not* a
/// `ThemeExtension`. The theme is Material 3 and dark-only (R3) and never
/// switches, so `ThemeExtension`'s `lerp`/`copyWith` interpolation buys nothing.
///
/// All values reference [AppColors] or neutral black/white alphas — no new hues
/// are introduced, so the cinematic dark palette is preserved (R3).
abstract final class DepthTokens {
  // ---------------------------------------------------------------------------
  // Surface tones (R1)
  //
  // A layered step hierarchy analogous to the web app's base-100/200/300, but
  // expressed in the player's cinematic dark palette. Steps are seeded from
  // [AppColors.background]/[AppColors.surface]/[AppColors.surfaceVariant] plus
  // the inline `surfaceContainer*` literals previously hard-coded in
  // `app_theme.dart`. Luminance increases monotonically from [surfaceBase] up
  // to [surfaceBright] so the hierarchy reads as real depth, not three
  // near-identical greys (asserted in depth_tokens_test).
  // ---------------------------------------------------------------------------

  /// Deepest layer — the shell background and ambient-backdrop base.
  static const Color surfaceBase = AppColors.background; // 0xFF0B0B0C

  /// One step above base; M3 `surfaceDim`.
  static const Color surfaceDim = Color(0xFF0E0E10);

  /// Low container tone; M3 `surfaceContainerLow`.
  static const Color surfaceLow = Color(0xFF111113);

  /// Default container tone; M3 `surfaceContainer`.
  static const Color surfaceContainer = AppColors.surface; // 0xFF141416

  /// High container tone; M3 `surfaceContainerHigh`.
  static const Color surfaceHigh = Color(0xFF191A1D);

  /// Elevated surface tone; M3 `surfaceContainerHighest`.
  static const Color surfaceVariant = AppColors.surfaceVariant; // 0xFF1E1E21

  /// Brightest surface tone; M3 `surfaceBright`.
  static const Color surfaceBright = Color(0xFF26272B);

  /// The surface tones in increasing-luminance order. Lets callers pick a
  /// layer by index and lets tests assert the hierarchy is monotonic.
  static const List<Color> surfaceTones = <Color>[
    surfaceBase,
    surfaceDim,
    surfaceLow,
    surfaceContainer,
    surfaceHigh,
    surfaceVariant,
    surfaceBright,
  ];

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
  // Player chrome glass
  //
  // A separate material from the browse-UI chrome tokens above. The playback
  // panel sits over live video, which is the one backdrop that justifies a real
  // BackdropFilter and can carry genuine transparency. Browse chrome sits over
  // static artwork and keeps its denser fill, so these are additive: nothing
  // above changes.
  // ---------------------------------------------------------------------------

  /// Blur sigma for playback chrome. Far above [blurChrome] — at this strength
  /// no high-frequency detail survives, only average luminance, which is what
  /// makes the low fill opacity below legible.
  static const double blurPlayerChrome = 28.0;

  /// Nominal fill opacity for playback chrome — the mean of the gradient
  /// endpoints below, for reference only. **No production code reads this
  /// token** — `GlassSurface.playerChrome` reads [playerChromeFillTopAlpha]
  /// and [playerChromeFillBottomAlpha] directly, and the panel's actual,
  /// rendered density is whichever of those two is in effect at a given
  /// point, not their mean. Do not use this value to argue the panel clears
  /// (or misses) [glassLegibilityFloor] — assert on [playerChromeFillTopAlpha]
  /// directly (see `depth_tokens_test.dart`), since that is the dense end
  /// that actually has to carry the claim.
  static const double playerChromeFillOpacity = 0.47;

  /// Fill alpha at the top edge of the playback panel — the dense end.
  ///
  /// [ChromePanel] puts the control row (row 1: volume/transport/secondary)
  /// at the top of the panel and the scrubber (row 2) below it, so density
  /// follows the content that needs legibility most: the controls are here.
  ///
  /// Deliberately kept **under** [glassLegibilityFloor] (0.60) — the
  /// redesign's whole differentiation from browse-UI chrome is that this
  /// panel can afford more transparency, and a value at or above the floor
  /// would quietly erase that. An earlier iteration pushed this to 0.68 to
  /// make a single-point legibility test pass; that made the panel read as
  /// dense as browse chrome and, per WCAG 2.1 SC 1.4.3 (text contrast,
  /// 4.5:1) measured across the *edges* of row 1's icons (not just its
  /// center), still didn't reliably clear 4.5:1 there without an even higher
  /// fill — while failing the transparency claim outright. Icons/glyphs are
  /// graphical objects, not text, so they're correctly held to WCAG 2.1 SC
  /// 1.4.11 (non-text contrast, 3:1) instead — `glass_legibility_test`
  /// verifies fill-alone clears 3:1 across row 1's full icon band at this
  /// value, with real margin (not a near-miss).
  ///
  /// The row-2 timecodes (12–13px text, held to the stricter 4.5:1 text
  /// standard) cannot clear that bar from fill alone at any value under the
  /// floor — buying the rest of the way with more fill is exactly the
  /// flat-slab look this redesign removes. Per the human-ruled direction,
  /// that gap is closed with a small, targeted text shadow on the timecodes
  /// only (not on any icon), implemented alongside the timecodes themselves
  /// (`_ScrubberRow` in `playback_chrome.dart`) rather than here —
  /// `glass_legibility_test`
  /// models that shadow's contribution analytically so the combined
  /// fill+shadow contract is locked in and verified even though the shadow
  /// paint code lives elsewhere.
  static const double playerChromeFillTopAlpha = 0.56;

  /// Fill alpha at the bottom edge of the playback panel — the sheer end.
  ///
  /// The panel's bottom edge sits nearest the screen's own bottom edge (or,
  /// in a smaller panel, under the scrubber only), so it can afford to stay
  /// the most transparent part of the gradient.
  static const double playerChromeFillBottomAlpha = 0.38;

  /// Backdrop saturation multiplier. Real vibrancy boosts saturation before
  /// blurring; without it, blurred video reads as grey mush rather than
  /// transmitted colour.
  static const double playerChromeSaturation = 1.8;

  /// Neutral near-black tint for the playback panel's fill.
  ///
  /// This was a separate literal (`#0B0E14`) only while [AppColors.background]
  /// carried a blue cast that would have drained backdrop colour through the
  /// fill. The ground is neutral now, so there is nothing left to work around
  /// and the two are the same colour.
  static const Color playerChromeTint = AppColors.background;

  /// Top-edge rim — a white highlight. Glass catches light on its upper edge.
  static const Color playerRimTop = Color(0x24FFFFFF); // white @ ~0.14

  /// Bottom-edge rim — a dark shade. Together with [playerRimTop] this reads as
  /// a lit edge rather than a uniform border.
  static const Color playerRimBottom = Color(0x33000000); // black @ 0.20

  /// Corner radius for the playback panel.
  static const double radiusPlayerPanel = 16.0;

  /// Corner radius for the 36px-tall top-bar pills (fully rounded).
  static const double radiusPlayerPill = 18.0;

  // ---------------------------------------------------------------------------
  // Player chrome lensing (iOS 26 / 27 material)
  //
  // Parameters for the refracting glass material behind
  // `GlassSurface.playerChrome`. Everything above this block describes a
  // surface that only *blurs* its backdrop; these describe one that also
  // *bends* it, which is the difference between frosted plastic and glass.
  //
  // Deliberately expressed as bare doubles and Flutter types, never as
  // `liquid_glass_widgets` enums, even where the underlying knob is an enum
  // (specular sharpness). `glass_surface.dart` is the single file allowed to
  // import that package (see the dependency's comment in `pubspec.yaml`), and
  // that seam is what makes a rollback to a plain `BackdropFilter` a one-file
  // revert. A package type in this module would quietly spread the dependency
  // into the token layer and every test that reads it.
  //
  // These are inert on tiers that render no shader; see
  // `GlassSurface.playerChrome`.
  // ---------------------------------------------------------------------------

  /// Index of refraction for the panel's rim.
  ///
  /// 1.0 is a vacuum (no bending at all) and real glass is ~1.5. The package
  /// defaults to 1.2, which barely reads at this panel's size. 1.4 sits near
  /// real glass while stopping short of the fishbowl distortion that starts
  /// to warp the control glyphs sitting on top of the lens.
  static const double playerChromeRefractiveIndex = 1.4;

  /// Apparent thickness of the glass slab, in logical pixels.
  ///
  /// Governs how wide the refracted band at the panel's edge is. Held just
  /// under [radiusPlayerPanel] (16) so the lensing stays inside the corner
  /// curve and does not intrude on the control row, which begins
  /// `ChromePanel.verticalPadding` (10px) in from the top edge.
  static const double playerChromeThickness = 14.0;

  /// Per-channel dispersion at the refracted edge.
  ///
  /// Real lenses split colour slightly at their edges, and its total absence
  /// is part of why a plain blur reads as synthetic. Kept at the package
  /// default: this panel sits over video whose own colour is the subject, and
  /// visible fringing on chrome would compete with it.
  static const double playerChromeChromaticAberration = 0.01;

  /// Specular highlight intensity along the lit edge.
  ///
  /// Raised well above the package default of 0.5, following the brighter
  /// specular highlights iOS 27 introduced. This is the cue that survives on
  /// the tiers that cannot refract, so it carries the material's read on web
  /// as well as native.
  static const double playerChromeLightIntensity = 0.8;

  /// Direction of the virtual light, in radians, clockwise from +x.
  ///
  /// `-pi / 2` puts the source directly overhead, matching [playerRimTop]'s
  /// premise that glass catches light on its upper edge. Kept consistent with
  /// that rim rather than with the package default so the two treatments
  /// agree about where the light is.
  static const double playerChromeLightAngle = -1.5707963267948966; // -pi/2

  /// Darkened outer edge, painted *outside* the panel silhouette (iOS 27).
  ///
  /// iOS 27 added a dark edge around glass elements for separation from busy
  /// backdrops. This is ours to paint: `liquid_glass_widgets` exposes
  /// `shadow`/`shadowElevation`, but both are documented "has no effect in
  /// dark mode" in three places in `LiquidGlassSettings`, and this player's
  /// theme is dark-only and never switches (see the note at the top of this
  /// module). Passing them would silently do nothing.
  ///
  /// Tight and near-opaque rather than soft and wide: the goal is a defining
  /// edge, not a floating drop shadow. [chrome] above is the latter, and this
  /// panel deliberately does not use it.
  ///
  /// Expressed as a colour plus a blur sigma rather than a [BoxShadow],
  /// because it is painted with `MaskFilter.blur(BlurStyle.outer, ...)` and
  /// not by a [BoxDecoration]. That distinction is load-bearing rather than
  /// stylistic: a [BoxShadow] paints *behind* its child, and this panel's
  /// fill is translucent by design, so the shadow would show through and
  /// darken it. That would silently shift the backdrop that
  /// `glass_legibility_test.dart` models as uniform, moving the panel's
  /// measured contrast without anything in that test changing.
  /// [BlurStyle.outer] paints strictly outside the silhouette, so the fill is
  /// untouched and the contrast contract holds.
  static const Color playerChromeEdgeShadowColor = Color(0x4D000000); // 0.30

  /// Blur sigma for [playerChromeEdgeShadowColor].
  ///
  /// Small on purpose. Wide enough and this stops reading as an edge and
  /// starts reading as elevation, which is [chrome]'s job, not this one's.
  static const double playerChromeEdgeShadowSigma = 2.0;
}
