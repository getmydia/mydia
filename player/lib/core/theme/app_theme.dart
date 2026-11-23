import 'package:material_ui/material_ui.dart';

import '../player/input_capabilities.dart';
import 'colors.dart';
import 'liquid_glass/glass_style.dart';
import 'palette.dart';
import 'surface_roles.dart';

/// Mydia Design System Theme
///
/// Deep cinematic theme optimized for media browsing.
/// See docs/architecture/design.md for complete design guidelines.

/// The app's typeface, bundled under this family name. Text drawn outside
/// material_ui's theme (media_kit's subtitles) names it explicitly.
const String kAppFontFamily = 'Inter';

class AppTheme {
  // Design system constants
  static const String displayFamily = 'Outfit';

  static const double radiusButton = 16.0; // Buttons
  static const double radiusCard = 18.0; // Cards, modals
  static const double radiusSettingsCard = 14.0; // Settings groups
  static const double radiusHeroPoster = 22.0; // Home and detail hero poster
  static const double radiusChip = 8.0; // Tag and metadata chips
  static const double radiusNavItem = 12.0; // Items inside a pill or rail
  static const double radiusRail = 22.0; // Floating navigation rail
  static const double radiusBottomBar = 24.0; // Phone floating bottom bar
  static const double radiusBadge = 30.0; // Badges (pill shape)
  static const double radiusInput = 10.0; // Input fields
  static const double radiusSheet = 20.0; // Bottom sheets

  /// Frosted button heights (primary and secondary).
  static const double primaryButtonHeight = 44;
  static const double secondaryButtonHeight = 40;

  /// Secondary button fill: white at 14%, over any ground.
  static const Color secondaryButtonFill = Color(0x24FFFFFF);

  /// The default preset's theme, for tests and callers outside the app root.
  static ThemeData get darkTheme =>
      build(Palettes.projectionBooth, liquid: false);

  static ThemeData build(MydiaPalette p, {required bool liquid}) {
    // Liquid Glass: content buttons take the capsule shape and an
    // Apple-style highlight instead of the Material ripple, to sit beside
    // the glass controls. See player/docs/liquid-glass.md.
    final OutlinedBorder buttonShape = liquid
        ? const StadiumBorder()
        : RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusButton),
          );
    final InteractiveInkFeatureFactory? buttonSplash = liquid
        ? NoSplash.splashFactory
        : null;
    final roles = SurfaceRoles.fromPalette(p);
    final strongSide = BorderSide(color: roles.hairlineStrong);
    final inputRadius = BorderRadius.circular(
      liquid ? radiusInput : roles.radiusControl,
    );
    final OutlinedBorder frostedShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(roles.radiusControl),
    );
    RoundedRectangleBorder hairlineShape(double radius) =>
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: roles.hairline),
        );
    const frostedButtonText = TextStyle(
      fontFamily: kAppFontFamily,
      fontSize: 15,
      fontWeight: FontWeight.w600,
    );
    // Frosted feedback: no ripple; a faint wash on hover, a dim on press,
    // no wash on focus. Focus shows as a side instead: a 2px primary one off
    // the television tier (below), the accent ring of [withTvFocus] on it.
    Color? frostedOverlayFor(Set<WidgetState> states, {Color? focused}) {
      if (states.contains(WidgetState.pressed)) return roles.pressOverlay;
      if (states.contains(WidgetState.hovered)) return roles.hoverOverlay;
      if (states.contains(WidgetState.focused)) return focused;
      return Colors.transparent;
    }

    final WidgetStateProperty<Color?> frostedOverlay =
        WidgetStateProperty.resolveWith(
          (states) => frostedOverlayFor(states, focused: Colors.transparent),
        );
    // Keyboard focus off the television tier. On it [withTvFocus] replaces
    // the side, so a TV button never draws both rings.
    WidgetStateProperty<BorderSide?>? frostedFocusSide(BorderSide? rest) =>
        InputCapabilities.directionalPrimary
        ? null
        : WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? BorderSide(color: p.primary, width: 2)
                : rest,
          );
    ButtonStyle frosted(
      ButtonStyle style, {
      double? height,
      BorderSide? rest,
    }) => style.copyWith(
      splashFactory: NoSplash.splashFactory,
      overlayColor: frostedOverlay,
      side: frostedFocusSide(rest),
      shape: WidgetStatePropertyAll(frostedShape),
      textStyle: const WidgetStatePropertyAll(frostedButtonText),
      minimumSize: height == null
          ? null
          : WidgetStatePropertyAll(Size(64, height)),
    );
    ButtonStyle styled(ButtonStyle style, {double? height, BorderSide? rest}) =>
        liquid ? style : frosted(style, height: height, rest: rest);
    // Tabular figures so timecodes, durations, sizes and bitrates line up.
    TextStyle figures(TextStyle t) => liquid
        ? t
        : t.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    // On a television the only cue for where focus is. Material's focus
    // overlay is a faint tint, invisible on the white fills these buttons
    // use, so a focused button gets an accent border. Elsewhere the buttons
    // keep their style; the outlined one keeps its borderless look.
    ButtonStyle withTvFocus(ButtonStyle style, {BorderSide? rest}) =>
        InputCapabilities.directionalPrimary
        ? style.copyWith(
            side: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.focused)
                  ? BorderSide(color: p.primary, width: 3)
                  : rest,
            ),
          )
        : style;
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      splashFactory: liquid ? null : NoSplash.splashFactory,
      // InkWell surfaces (rows, list tiles, menu items) dim like buttons
      // instead of flashing Material's light grey highlight.
      highlightColor: liquid ? null : roles.pressOverlay,
      hoverColor: liquid ? null : roles.hoverOverlay,
      splashColor: liquid ? null : Colors.transparent,
      extensions: [
        p,
        GlassStyle(liquid: liquid),
        roles,
      ],

      // Font family - matches web app
      fontFamily: kAppFontFamily,

      // Color scheme - Full Material 3 surface hierarchy.
      // The surface tones come from the palette, so each preset keeps its own
      // layered depth hierarchy.
      colorScheme: ColorScheme.dark(
        surface: p.background,
        surfaceDim: p.surfaceDim,
        surfaceContainerLowest: p.background,
        surfaceContainerLow: p.surfaceLow,
        surfaceContainer: p.surface,
        surfaceContainerHigh: p.surfaceHigh,
        surfaceContainerHighest: p.surfaceVariant,
        surfaceBright: p.surfaceBright,
        primary: p.primary,
        primaryContainer: p.primaryFocus,
        secondary: p.primary,
        secondaryContainer: p.primaryFocus,
        tertiary: p.primary,
        tertiaryContainer: p.primaryFocus,
        error: AppColors.error,
        onSurface: p.textPrimary,
        onSurfaceVariant: p.textSecondary,
        onPrimary: p.onPrimary,
        onSecondary: p.onPrimary,
        onTertiary: p.onPrimary,
        onError: AppColors.onError,
        outline: p.border,
        outlineVariant: p.divider,
      ),

      // AppBar - flush with page background
      appBarTheme: AppBarTheme(
        backgroundColor: p.background,
        foregroundColor: p.textPrimary,
        elevation: 0,
        centerTitle: false,
        surfaceTintColor: Colors.transparent,
      ),

      // Card - allow subtle Material 3 tinting
      cardTheme: CardThemeData(
        color: p.surface,
        elevation: 0,
        surfaceTintColor: liquid ? null : Colors.transparent,
        shape: liquid
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radiusCard),
              )
            : hairlineShape(roles.radiusMenu),
      ),

      // Typography - refined spacing with letterSpacing and height
      textTheme: TextTheme(
        // Page titles - text-3xl (30px)
        displayLarge: TextStyle(
          fontFamily: displayFamily,
          fontSize: 30,
          fontWeight: FontWeight.w700,
          color: p.textPrimary,
          letterSpacing: -0.75,
          height: 1.15,
        ),
        // Section headers - text-2xl (24px)
        displayMedium: TextStyle(
          fontFamily: displayFamily,
          fontSize: 24,
          fontWeight: FontWeight.w600,
          color: p.textPrimary,
          letterSpacing: -0.5,
          height: 1.2,
        ),
        // Card titles - text-xl (20px)
        displaySmall: TextStyle(
          fontFamily: displayFamily,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: p.textPrimary,
          letterSpacing: -0.3,
          height: 1.25,
        ),
        // Subheadings - text-lg (18px)
        headlineLarge: TextStyle(
          fontFamily: displayFamily,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: p.textPrimary,
          letterSpacing: -0.2,
          height: 1.3,
        ),
        headlineMedium: TextStyle(
          fontFamily: displayFamily,
          fontSize: 18,
          fontWeight: FontWeight.w500,
          color: p.textPrimary,
          letterSpacing: -0.2,
          height: 1.3,
        ),
        headlineSmall: TextStyle(
          fontFamily: displayFamily,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: p.textPrimary,
          letterSpacing: -0.15,
          height: 1.35,
        ),
        // Default body - text-base (16px)
        titleLarge: TextStyle(
          fontFamily: displayFamily,
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: p.textPrimary,
          height: 1.35,
        ),
        titleMedium: TextStyle(
          fontFamily: displayFamily,
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: p.textPrimary,
          height: 1.35,
        ),
        // Secondary text - text-sm (14px)
        titleSmall: TextStyle(
          fontFamily: displayFamily,
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: p.textPrimary,
          height: 1.35,
        ),
        bodyLarge: figures(
          TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w400,
            color: p.textPrimary,
            height: 1.5,
          ),
        ),
        bodyMedium: figures(
          TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: p.textPrimary,
            height: 1.45,
          ),
        ),
        // Meta info, captions - text-xs (12px)
        bodySmall: figures(
          TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w400,
            color: p.textSecondary,
            letterSpacing: 0.1,
            height: 1.4,
          ),
        ),
        labelLarge: figures(
          TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: p.textPrimary,
            letterSpacing: 0.15,
            height: 1.3,
          ),
        ),
        labelMedium: figures(
          TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: p.textPrimary,
            letterSpacing: 0.2,
            height: 1.3,
          ),
        ),
        labelSmall: figures(
          TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: p.textSecondary,
            letterSpacing: 0.3,
            height: 1.3,
          ),
        ),
      ),

      // Elevated Button
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: withTvFocus(
          styled(
            ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: p.background,
              elevation: 0,
              textStyle: const TextStyle(
                fontFamily: displayFamily,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: buttonShape,
              splashFactory: buttonSplash,
            ),
            height: primaryButtonHeight,
          ),
        ),
      ),

      // Text Button
      textButtonTheme: TextButtonThemeData(
        style: withTvFocus(
          styled(
            TextButton.styleFrom(
              foregroundColor: p.textPrimary,
              textStyle: const TextStyle(
                fontFamily: displayFamily,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: buttonShape,
              splashFactory: buttonSplash,
            ),
          ),
        ),
      ),

      // Outlined Button
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: withTvFocus(
          rest: liquid ? BorderSide.none : strongSide,
          styled(
            rest: strongSide,
            OutlinedButton.styleFrom(
              foregroundColor: p.textPrimary,
              backgroundColor: liquid
                  ? secondaryButtonFill
                  : const Color(0x12FFFFFF),
              side: liquid ? BorderSide.none : strongSide,
              textStyle: const TextStyle(
                fontFamily: displayFamily,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: buttonShape,
              splashFactory: buttonSplash,
            ),
            height: secondaryButtonHeight,
          ),
        ),
      ),

      // Icon Button
      iconButtonTheme: IconButtonThemeData(
        style: liquid
            ? IconButton.styleFrom(foregroundColor: p.textSecondary)
            : IconButton.styleFrom(
                foregroundColor: p.textSecondary,
                splashFactory: NoSplash.splashFactory,
              ).copyWith(
                // Same hover and press as the buttons. Focus resolves to
                // null so Material's own focus layer still shows: icon
                // buttons have no themed ring on or off the television.
                overlayColor: WidgetStateProperty.resolveWith(
                  (states) => frostedOverlayFor(states),
                ),
              ),
      ),

      // Filled Button (for primary actions)
      filledButtonTheme: FilledButtonThemeData(
        style: withTvFocus(
          styled(
            FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: p.background,
              elevation: 0,
              textStyle: const TextStyle(
                fontFamily: displayFamily,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: buttonShape,
              splashFactory: buttonSplash,
            ),
            height: primaryButtonHeight,
          ),
        ),
      ),

      // Input Decoration - uses radiusInput
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: liquid ? p.surfaceVariant : p.surfaceLow,
        border: OutlineInputBorder(
          borderRadius: inputRadius,
          borderSide: BorderSide(color: liquid ? p.border : roles.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: inputRadius,
          borderSide: BorderSide(color: liquid ? p.border : roles.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: inputRadius,
          borderSide: BorderSide(color: p.primary, width: liquid ? 2 : 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: inputRadius,
          borderSide: const BorderSide(color: AppColors.error),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
        hintStyle: TextStyle(color: p.textSecondary),
      ),

      // Chip (for badges)
      chipTheme: ChipThemeData(
        backgroundColor: p.surfaceVariant,
        labelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: p.textPrimary,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusBadge),
        ),
        side: BorderSide.none,
      ),

      // Bottom Sheet - uses radiusSheet
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(radiusSheet),
          ),
        ),
      ),

      // Dialog - allow subtle Material 3 tinting
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusCard),
        ),
        // Frosted: every showDialog gets the scrim without its caller
        // passing a barrierColor.
        barrierColor: liquid ? null : roles.scrim,
      ),

      // Divider
      dividerTheme: DividerThemeData(color: p.divider, thickness: 1, space: 1),

      // Icon
      iconTheme: IconThemeData(color: p.textSecondary, size: 24),

      // Slider (for video controls) - refined track and thumb
      sliderTheme: SliderThemeData(
        activeTrackColor: p.primary,
        inactiveTrackColor: p.surfaceVariant,
        thumbColor: p.primary,
        overlayColor: p.primary.withValues(alpha: 0.2),
        trackHeight: 4.5,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      ),

      // Progress Indicator
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.primary,
        linearTrackColor: p.surfaceVariant,
      ),

      // Tooltip
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: liquid ? p.surface : p.surfaceHigh,
          borderRadius: BorderRadius.circular(liquid ? radiusButton : 8),
          border: liquid ? null : Border.all(color: roles.hairline),
        ),
        textStyle: TextStyle(color: p.textPrimary, fontSize: 12),
      ),

      // Popup Menu
      popupMenuTheme: PopupMenuThemeData(
        color: liquid ? p.surface : p.surfaceHigh,
        surfaceTintColor: Colors.transparent,
        shape: liquid
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radiusButton),
              )
            : hairlineShape(roles.radiusMenu),
        elevation: liquid ? null : 8,
        shadowColor: liquid ? null : Colors.black,
        iconColor: liquid ? null : p.textSecondary,
        iconSize: liquid ? null : 18,
        labelTextStyle: liquid
            ? null
            : WidgetStatePropertyAll(
                TextStyle(
                  fontFamily: kAppFontFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: p.textPrimary,
                ),
              ),
      ),

      // List Tile
      listTileTheme: ListTileThemeData(
        textColor: p.textPrimary,
        iconColor: p.textSecondary,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        shape: liquid ? null : frostedShape,
      ),

      // Switch
      switchTheme: SwitchThemeData(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        thumbIcon: WidgetStateProperty.all<Icon?>(null),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (!liquid) return Colors.white;
          if (states.contains(WidgetState.selected)) {
            return p.primary;
          }
          return p.textDisabled;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return liquid ? p.primary.withValues(alpha: 0.5) : p.primary;
          }
          return liquid ? p.surfaceVariant : p.border;
        }),
        trackOutlineColor: liquid
            ? null
            : const WidgetStatePropertyAll(Colors.transparent),
      ),

      // Checkbox
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return p.primary;
          }
          return Colors.transparent;
        }),
        checkColor: WidgetStateProperty.all(p.onPrimary),
        side: liquid
            ? BorderSide(color: p.border, width: 2)
            : BorderSide(color: roles.hairlineStrong, width: 1.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(liquid ? 4 : 5),
        ),
      ),

      // Radio
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return p.primary;
          }
          return p.textSecondary;
        }),
      ),

      // Page Transitions - Material 3 style (slide + fade)
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          // FadeForwardsPageTransitionsBuilder for every platform: a smooth
          // slide-in from the right with a fade. Used uniformly (rather than
          // CupertinoPageTransitionsBuilder on Apple platforms) because that
          // builder moved from material.dart to cupertino.dart across Flutter
          // versions, and FadeForwards lives in material.dart on all of them.
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.fuchsia: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}
