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
  static const Color surfaceBase = AppColors.background; // 0xFF0A1120

  /// One step above base; M3 `surfaceDim`.
  static const Color surfaceDim = Color(0xFF0D1724);

  /// Low container tone; M3 `surfaceContainerLow`.
  static const Color surfaceLow = Color(0xFF101B2C);

  /// Default container tone; M3 `surfaceContainer`.
  static const Color surfaceContainer = AppColors.surface; // 0xFF131C2E

  /// High container tone; M3 `surfaceContainerHigh`.
  static const Color surfaceHigh = Color(0xFF182436);

  /// Elevated surface tone; M3 `surfaceContainerHighest`.
  static const Color surfaceVariant = AppColors.surfaceVariant; // 0xFF1E293B

  /// Brightest surface tone; M3 `surfaceBright`.
  static const Color surfaceBright = Color(0xFF253550);

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
  /// endpoints below. Deliberately under [glassLegibilityFloor]: legibility is
  /// bought with blur strength and gradient weighting instead of flat fill.
  ///
  /// Mean of [playerChromeFillTopAlpha] (0.68) and [playerChromeFillBottomAlpha]
  /// (0.38) — see [playerChromeFillTopAlpha] for why the dense end is at the
  /// top.
  static const double playerChromeFillOpacity = 0.53;

  /// Fill alpha at the top edge of the playback panel — the dense end.
  ///
  /// [ChromePanel] puts the control row (row 1: volume/transport/secondary)
  /// at the top of the panel and the scrubber (row 2) below it, so density
  /// follows the content that needs legibility: the controls are the
  /// high-contrast-critical row, and the scrubber below reads fine as a
  /// white track over less fill. This was originally 0.38 (the *sheer*
  /// value, swapped from [playerChromeFillBottomAlpha] below) on the mistaken
  /// assumption that the control row sat at the bottom; `glass_legibility_test`
  /// samples ~30% down the panel (the control row's actual position) and
  /// measured only 3.38:1 there at 0.52 — under the 4.5:1 floor — so this was
  /// raised in the same file's prescribed 0.04 increments (0.52 -> 0.56 ->
  /// ... -> 0.68) until the measured contrast cleared it (4.90:1 at 0.68).
  static const double playerChromeFillTopAlpha = 0.68;

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

  /// Neutral near-black tint. Unlike [AppColors.background] (`#0A1120`) this
  /// carries no blue cast, so backdrop colour survives the fill.
  static const Color playerChromeTint = Color(0xFF0B0E14);

  /// Top-edge rim — a white highlight. Glass catches light on its upper edge.
  static const Color playerRimTop = Color(0x24FFFFFF); // white @ ~0.14

  /// Bottom-edge rim — a dark shade. Together with [playerRimTop] this reads as
  /// a lit edge rather than a uniform border.
  static const Color playerRimBottom = Color(0x33000000); // black @ 0.20

  /// Corner radius for the playback panel.
  static const double radiusPlayerPanel = 16.0;

  /// Corner radius for the 36px-tall top-bar pills (fully rounded).
  static const double radiusPlayerPill = 18.0;
}
