import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether this build and OS can render Apple's native Liquid Glass
/// (iOS 26+, macOS 26+), resolved once at startup.
///
/// Follows `InputCapabilities`: [initialize] is awaited from `_startApp` in
/// `main.dart`, and [supported] is read synchronously inside `build`
/// afterwards. `flutter test` never calls [initialize], so every test sees
/// false unless it sets [debugOverride].
class NativeGlassSupport {
  /// Answered by `NativeGlassPlugin` in both Apple Runner targets.
  static const MethodChannel channel = MethodChannel('mydia/native-glass');

  static bool _supported = false;

  /// Forces [supported] in tests. Reset to null in `tearDown`.
  @visibleForTesting
  static bool? debugOverride;

  static bool get supported => debugOverride ?? _supported;

  /// Asks the native side once. Never throws: a missing plugin or a platform
  /// error is logged and answers false, so every surface keeps its Flutter
  /// glass.
  static Future<void> initialize() async {
    final apple = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);
    if (!apple) {
      _supported = false;
      return;
    }
    try {
      _supported = await channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException catch (e) {
      debugPrint('[NativeGlass] plugin missing, using Flutter glass: $e');
      _supported = false;
    } on PlatformException catch (e) {
      debugPrint('[NativeGlass] probe failed, using Flutter glass: $e');
      _supported = false;
    }
  }
}
