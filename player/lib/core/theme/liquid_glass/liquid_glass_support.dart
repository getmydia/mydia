import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Whether the Liquid Glass material runs, resolved once at startup.
///
/// Follows `NativeTabBarSupport`: [initialize] is awaited from `_startApp` in
/// `main.dart`, and the getters are read synchronously in `build`
/// afterwards. `flutter test` never calls [initialize] (and has no Impeller),
/// so tests see the frosted path unless they set [debugOverride].
abstract final class LiquidGlassSupport {
  static const String assetKey = 'shaders/liquid_glass.frag';

  /// `--dart-define=MYDIA_LIQUID_GLASS=true` makes every platform eligible,
  /// for the lab on a Linux desktop (Impeller is the default there too).
  static const bool _forced = bool.fromEnvironment('MYDIA_LIQUID_GLASS');

  static ui.FragmentProgram? _program;

  /// Forces [platformEligible] in tests. Reset to null in `tearDown`.
  @visibleForTesting
  static bool? debugPlatformOverride;

  /// Forces [available] in tests. Reset to null in `tearDown`.
  @visibleForTesting
  static bool? debugOverride;

  @visibleForTesting
  static void debugReset() => _program = null;

  /// iOS or macOS (not web). Decides which controls render as glass. Does
  /// not mean the shader loaded; see [available].
  static bool get platformEligible {
    final override = debugPlatformOverride;
    if (override != null) return override;
    if (_forced) return true;
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  /// Whether the shader loaded, so `GlassSurface` may take the Liquid Glass
  /// recipe. [program] can still be null under [debugOverride].
  static bool get available => debugOverride ?? _program != null;

  static ui.FragmentProgram? get program => _program;

  /// Loads the shader once. Never throws: an ineligible platform, missing
  /// shader filter support, or a load failure leaves [available] false and
  /// every surface on its frosted recipe.
  static Future<void> initialize() async {
    if (!platformEligible) return;
    if (!ui.ImageFilter.isShaderFilterSupported) {
      debugPrint('[LiquidGlass] shader filters unsupported, '
          'using frosted glass');
      return;
    }
    try {
      _program = await ui.FragmentProgram.fromAsset(assetKey);
    } on Object catch (e) {
      debugPrint(
          '[LiquidGlass] shader failed to load, using frosted glass: $e');
      _program = null;
    }
  }
}
