import 'package:flutter/material.dart';
import 'colors.dart';
import 'liquid_glass/glass_style.dart';
import 'palette.dart';

/// Mydia Design System Theme
///
/// Deep cinematic theme optimized for media browsing.
/// See docs/architecture/design.md for complete design guidelines.
class AppTheme {
  // Design system constants
  static const String displayFamily = 'Outfit';

  static const double radiusButton = 16.0; // Buttons
  static const double radiusCard = 18.0; // Cards, modals
  static const double radiusHeroPoster = 22.0; // Home and detail hero poster
  static const double radiusChip = 8.0; // Tag and metadata chips
  static const double radiusNavItem = 12.0; // Items inside a pill or rail
  static const double radiusRail = 22.0; // Floating navigation rail
  static const double radiusBottomBar = 24.0; // Phone floating bottom bar
  static const double radiusBadge = 30.0; // Badges (pill shape)
  static const double radiusInput = 10.0; // Input fields
  static const double radiusSheet = 20.0; // Bottom sheets

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
    final InteractiveInkFeatureFactory? buttonSplash =
        liquid ? NoSplash.splashFactory : null;
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      extensions: [p, GlassStyle(liquid: liquid)],

      // Font family - matches web app
      fontFamily: 'Inter',

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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusCard),
        ),
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
        bodyLarge: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w400,
          color: p.textPrimary,
          height: 1.5,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: p.textPrimary,
          height: 1.45,
        ),
        // Meta info, captions - text-xs (12px)
        bodySmall: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: p.textSecondary,
          letterSpacing: 0.1,
          height: 1.4,
        ),
        labelLarge: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: p.textPrimary,
          letterSpacing: 0.15,
          height: 1.3,
        ),
        labelMedium: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: p.textPrimary,
          letterSpacing: 0.2,
          height: 1.3,
        ),
        labelSmall: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: p.textSecondary,
          letterSpacing: 0.3,
          height: 1.3,
        ),
      ),

      // Elevated Button
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
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
      ),

      // Text Button
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
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

      // Outlined Button
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.textPrimary,
          backgroundColor: secondaryButtonFill,
          side: BorderSide.none,
          textStyle: const TextStyle(
            fontFamily: displayFamily,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: buttonShape,
          splashFactory: buttonSplash,
        ),
      ),

      // Icon Button
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: p.textSecondary,
        ),
      ),

      // Filled Button (for primary actions)
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
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
      ),

      // Input Decoration - uses radiusInput
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusInput),
          borderSide: BorderSide(color: p.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusInput),
          borderSide: BorderSide(color: p.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusInput),
          borderSide: BorderSide(color: p.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusInput),
          borderSide: const BorderSide(color: AppColors.error),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(radiusSheet)),
        ),
      ),

      // Dialog - allow subtle Material 3 tinting
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusCard),
        ),
      ),

      // Divider
      dividerTheme: DividerThemeData(
        color: p.divider,
        thickness: 1,
        space: 1,
      ),

      // Icon
      iconTheme: IconThemeData(
        color: p.textSecondary,
        size: 24,
      ),

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
          color: p.surface,
          borderRadius: BorderRadius.circular(radiusButton),
        ),
        textStyle: TextStyle(
          color: p.textPrimary,
          fontSize: 12,
        ),
      ),

      // Popup Menu
      popupMenuTheme: PopupMenuThemeData(
        color: p.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusButton),
        ),
      ),

      // List Tile
      listTileTheme: ListTileThemeData(
        textColor: p.textPrimary,
        iconColor: p.textSecondary,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),

      // Switch
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return p.primary;
          }
          return p.textDisabled;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return p.primary.withValues(alpha: 0.5);
          }
          return p.surfaceVariant;
        }),
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
        side: BorderSide(color: p.border, width: 2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
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
