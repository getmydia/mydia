import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Whether the Liquid Glass shader loaded, resolved once at startup.
///
/// Answers only whether the material can render. Whether a tree draws Liquid
/// Glass at all is `GlassStyle`, set from the `GlassMaterial` setting.
///
/// Follows `NativeTabBarSupport`: [initialize] is awaited from `_startApp` in
/// `main.dart`, and the getters are read synchronously in `build`
/// afterwards. `flutter test` never calls [initialize] (and has no Impeller),
/// so tests see the frosted path unless they set [debugOverride].
abstract final class LiquidGlassSupport {
  static const String assetKey = 'shaders/liquid_glass.frag';

  static ui.FragmentProgram? _program;

  /// Forces [available] in tests. Reset to null in `tearDown`.
  @visibleForTesting
  static bool? debugOverride;

  @visibleForTesting
  static void debugReset() => _program = null;

  /// Installs a loaded shader in tests, to drive the lens path's layers.
  /// `flutter test` can load the program but cannot render it. Reset to
  /// null in `tearDown`.
  @visibleForTesting
  static set debugProgram(ui.FragmentProgram? program) => _program = program;

  /// Whether the shader loaded, so `GlassSurface` may take the Liquid Glass
  /// recipe. [program] can still be null under [debugOverride].
  static bool get available => debugOverride ?? _program != null;

  static ui.FragmentProgram? get program => _program;

  /// Loads the shader once, on every platform, whatever the current
  /// `GlassMaterial` setting, so switching to Liquid Glass needs no restart.
  /// Never throws: missing shader filter support or a load failure leaves
  /// [available] false and every surface on its frosted recipe.
  static Future<void> initialize() async {
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
