import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

import 'contrast.dart';
import 'depth_tokens.dart';

/// Every colour that changes between theme presets. Colours that never
/// change (semantic error/warning/info/success, OSD tones, overlays) stay
/// `const` in `AppColors`.
@immutable
class MydiaPalette extends ThemeExtension<MydiaPalette> {
  const MydiaPalette({
    required this.background,
    required this.surfaceDim,
    required this.surfaceLow,
    required this.surface,
    required this.surfaceHigh,
    required this.surfaceVariant,
    required this.surfaceBright,
    required this.primary,
    required this.primaryFocus,
    required this.onPrimary,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDisabled,
    required this.divider,
    required this.border,
    required this.cardHover,
    required this.shimmerBase,
    required this.shimmerHighlight,
    required this.ambientTint,
  });

  /// The shell ground; Material `surface` and `surfaceContainerLowest`.
  final Color background;
  final Color surfaceDim;
  final Color surfaceLow;

  /// Material `surfaceContainer`: cards, sheets, dialogs.
  final Color surface;
  final Color surfaceHigh;

  /// Material `surfaceContainerHighest`: inputs, chips, elevated rows.
  final Color surfaceVariant;
  final Color surfaceBright;
  final Color primary;
  final Color primaryFocus;
  final Color onPrimary;
  final Color textPrimary;
  final Color textSecondary;
  final Color textDisabled;
  final Color divider;
  final Color border;
  final Color cardHover;
  final Color shimmerBase;
  final Color shimmerHighlight;

  /// Whether artwork tints the ground and chrome. Off where the ground is
  /// the point of the preset (OLED black, the macOS window grey).
  final bool ambientTint;

  /// The surface steps in rising luminance (asserted in palette_test).
  List<Color> get surfaceTones => [
        background,
        surfaceDim,
        surfaceLow,
        surface,
        surfaceHigh,
        surfaceVariant,
        surfaceBright,
      ];

  @override
  MydiaPalette copyWith({
    Color? background,
    Color? surfaceDim,
    Color? surfaceLow,
    Color? surface,
    Color? surfaceHigh,
    Color? surfaceVariant,
    Color? surfaceBright,
    Color? primary,
    Color? primaryFocus,
    Color? onPrimary,
    Color? textPrimary,
    Color? textSecondary,
    Color? textDisabled,
    Color? divider,
    Color? border,
    Color? cardHover,
    Color? shimmerBase,
    Color? shimmerHighlight,
    bool? ambientTint,
  }) =>
      MydiaPalette(
        background: background ?? this.background,
        surfaceDim: surfaceDim ?? this.surfaceDim,
        surfaceLow: surfaceLow ?? this.surfaceLow,
        surface: surface ?? this.surface,
        surfaceHigh: surfaceHigh ?? this.surfaceHigh,
        surfaceVariant: surfaceVariant ?? this.surfaceVariant,
        surfaceBright: surfaceBright ?? this.surfaceBright,
        primary: primary ?? this.primary,
        primaryFocus: primaryFocus ?? this.primaryFocus,
        onPrimary: onPrimary ?? this.onPrimary,
        textPrimary: textPrimary ?? this.textPrimary,
        textSecondary: textSecondary ?? this.textSecondary,
        textDisabled: textDisabled ?? this.textDisabled,
        divider: divider ?? this.divider,
        border: border ?? this.border,
        cardHover: cardHover ?? this.cardHover,
        shimmerBase: shimmerBase ?? this.shimmerBase,
        shimmerHighlight: shimmerHighlight ?? this.shimmerHighlight,
        ambientTint: ambientTint ?? this.ambientTint,
      );

  @override
  MydiaPalette lerp(MydiaPalette? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t) ?? b;
    return MydiaPalette(
      background: l(background, other.background),
      surfaceDim: l(surfaceDim, other.surfaceDim),
      surfaceLow: l(surfaceLow, other.surfaceLow),
      surface: l(surface, other.surface),
      surfaceHigh: l(surfaceHigh, other.surfaceHigh),
      surfaceVariant: l(surfaceVariant, other.surfaceVariant),
      surfaceBright: l(surfaceBright, other.surfaceBright),
      primary: l(primary, other.primary),
      primaryFocus: l(primaryFocus, other.primaryFocus),
      onPrimary: l(onPrimary, other.onPrimary),
      textPrimary: l(textPrimary, other.textPrimary),
      textSecondary: l(textSecondary, other.textSecondary),
      textDisabled: l(textDisabled, other.textDisabled),
      divider: l(divider, other.divider),
      border: l(border, other.border),
      cardHover: l(cardHover, other.cardHover),
      shimmerBase: l(shimmerBase, other.shimmerBase),
      shimmerHighlight: l(shimmerHighlight, other.shimmerHighlight),
      ambientTint: t < 0.5 ? ambientTint : other.ambientTint,
    );
  }
}

abstract final class Palettes {
  /// The original cinematic palette: neutral near-black, warm gold.
  static const MydiaPalette projectionBooth = MydiaPalette(
    background: Color(0xFF0B0B0C),
    surfaceDim: Color(0xFF0E0E10),
    surfaceLow: Color(0xFF111113),
    surface: Color(0xFF141416),
    surfaceHigh: Color(0xFF191A1D),
    surfaceVariant: Color(0xFF1E1E21),
    surfaceBright: Color(0xFF26272B),
    primary: Color(0xFFE9A23B),
    primaryFocus: Color(0xFFD08C24),
    onPrimary: Color(0xFF1A1205),
    textPrimary: Color(0xFFF0EFED),
    textSecondary: Color(0xFF9A9894),
    textDisabled: Color(0xFF7A7975),
    divider: Color(0xFF1D1D21),
    border: Color(0xFF2E2E33),
    cardHover: Color(0xFF26272B),
    shimmerBase: Color(0xFF1A1A1D),
    shimmerHighlight: Color(0xFF26272B),
    ambientTint: true,
  );

  /// True black for OLED panels. Same gold and text as Projection Booth.
  static const MydiaPalette oledBlack = MydiaPalette(
    background: Color(0xFF000000),
    surfaceDim: Color(0xFF070708),
    surfaceLow: Color(0xFF0C0C0D),
    surface: Color(0xFF111113),
    surfaceHigh: Color(0xFF17171A),
    surfaceVariant: Color(0xFF1E1E21),
    surfaceBright: Color(0xFF26272B),
    primary: Color(0xFFE9A23B),
    primaryFocus: Color(0xFFD08C24),
    onPrimary: Color(0xFF1A1205),
    textPrimary: Color(0xFFF0EFED),
    textSecondary: Color(0xFF9A9894),
    textDisabled: Color(0xFF7A7975),
    divider: Color(0xFF17171A),
    border: Color(0xFF2E2E33),
    cardHover: Color(0xFF26272B),
    shimmerBase: Color(0xFF141416),
    shimmerHighlight: Color(0xFF1E1E21),
    ambientTint: false,
  );

  /// Cool blue-grey ground with a blue accent.
  static const MydiaPalette slate = MydiaPalette(
    background: Color(0xFF0E1116),
    surfaceDim: Color(0xFF11151B),
    surfaceLow: Color(0xFF141920),
    surface: Color(0xFF171C24),
    surfaceHigh: Color(0xFF1C222B),
    surfaceVariant: Color(0xFF212833),
    surfaceBright: Color(0xFF2A3240),
    primary: Color(0xFF6AA8FF),
    primaryFocus: Color(0xFF4C8FF0),
    onPrimary: Color(0xFF0A1420),
    textPrimary: Color(0xFFEEF1F5),
    textSecondary: Color(0xFF9AA3B0),
    textDisabled: Color(0xFF7C8594),
    divider: Color(0xFF1C222B),
    border: Color(0xFF2C3442),
    cardHover: Color(0xFF252C38),
    shimmerBase: Color(0xFF181D25),
    shimmerHighlight: Color(0xFF252C38),
    ambientTint: true,
  );

  /// macOS's default accent (system blue, dark appearance). Used before the
  /// runner answers and off macOS.
  static const Color macosDefaultAccent = Color(0xFF0A84FF);

  /// The OSD fill over a pure-white frame, the worst case its text sits on.
  static final Color _osdWorstCase = Color.alphaBlend(
    DepthTokens.osdTint.withValues(alpha: DepthTokens.osdFillOpacity),
    const Color(0xFFFFFFFF),
  );

  static const Color _macosBackground = Color(0xFF1E1E1E);

  /// A hair above the 4.5:1 floor, so 8-bit rounding of the lifted colour
  /// cannot land under it.
  static const double _accentTarget = 4.55;

  /// [accent] with its tone raised, in steps of one, until it clears the text
  /// floor on both the macOS window and the OSD fill. Hue and chroma are
  /// kept, so the colour stays the viewer's accent; only its lightness moves.
  /// Accents that already clear it come through unchanged.
  ///
  /// The system's own accent is tuned for controls on the window, and a few
  /// (system blue is the common one) measure about 3.7:1 on the playback
  /// controls, which sit on the OSD fill. The player draws the accent as text
  /// and icon colour there, so it is lifted slightly rather than left
  /// unreadable.
  @visibleForTesting
  static Color legibleAccent(Color accent) {
    bool clears(Color c) =>
        contrastRatio(c, _macosBackground) >= _accentTarget &&
        contrastRatio(c, _osdWorstCase) >= _accentTarget;
    if (clears(accent)) return accent;
    final hct = Hct.fromInt(accent.toARGB32());
    for (var tone = hct.tone.ceilToDouble() + 1; tone <= 100; tone++) {
      final lifted = Color(Hct.from(hct.hue, hct.chroma, tone).toInt());
      if (clears(lifted)) return lifted;
    }
    return accent;
  }

  /// The macOS dark window greys, with the viewer's system accent, lifted
  /// when needed so it stays legible on the playback controls (see
  /// [legibleAccent]).
  static MydiaPalette macos(Color systemAccent) {
    final accent = legibleAccent(systemAccent);
    return _macos(accent);
  }

  static MydiaPalette _macos(Color accent) => MydiaPalette(
        background: _macosBackground,
        surfaceDim: const Color(0xFF212121),
        surfaceLow: const Color(0xFF242424),
        surface: const Color(0xFF282828),
        surfaceHigh: const Color(0xFF2D2D2D),
        surfaceVariant: const Color(0xFF323232),
        surfaceBright: const Color(0xFF3A3A3A),
        primary: accent,
        primaryFocus:
            Color.lerp(accent, const Color(0xFF000000), 0.15) ?? accent,
        onPrimary: onColorFor(accent),
        textPrimary: const Color(0xFFF2F2F2),
        textSecondary: const Color(0xFFABABAB),
        textDisabled: const Color(0xFF8F8F8F),
        divider: const Color(0xFF2A2A2A),
        border: const Color(0xFF3D3D3D),
        cardHover: const Color(0xFF363636),
        shimmerBase: const Color(0xFF2A2A2A),
        shimmerHighlight: const Color(0xFF363636),
        ambientTint: false,
      );
}

extension MydiaPaletteContext on BuildContext {
  /// The active preset's colours. Projection Booth when the theme carries no
  /// palette (a bare `MaterialApp` in a test).
  MydiaPalette get palette =>
      Theme.of(this).extension<MydiaPalette>() ?? Palettes.projectionBooth;
}
