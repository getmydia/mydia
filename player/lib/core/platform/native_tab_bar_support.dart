import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether the native iOS 26 tab bar is installed, resolved once at startup.
///
/// Follows `InputCapabilities`: [initialize] is awaited from `_startApp` in
/// `main.dart`, and [supported] is read synchronously inside `build`
/// afterwards. `flutter test` never calls [initialize], so every test sees
/// false unless it sets [debugOverride].
class NativeTabBarSupport {
  /// Answered by `NativeTabBarPlugin` in the iOS Runner.
  static const MethodChannel channel = MethodChannel('mydia/native-tab-bar');

  static bool _supported = false;

  /// Forces [supported] in tests. Reset to null in `tearDown`.
  @visibleForTesting
  static bool? debugOverride;

  /// Clears the cached probe answer in tests.
  @visibleForTesting
  static void debugReset() => _supported = false;

  static bool get supported => debugOverride ?? _supported;

  /// Asks the native side once. Never throws and never hangs: the probe is
  /// bounded by a 2 second timeout, and a timeout, a missing plugin or any
  /// error is logged and answers false, so the Flutter dock stays.
  static Future<void> initialize() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      _supported = false;
      return;
    }
    try {
      _supported = await channel
              .invokeMethod<bool>('isSupported')
              .timeout(const Duration(seconds: 2)) ??
          false;
    } on TimeoutException {
      debugPrint('[NativeTabBar] probe timed out, using the Flutter dock');
      _supported = false;
    } on MissingPluginException catch (e) {
      debugPrint('[NativeTabBar] plugin missing, using the Flutter dock: $e');
      _supported = false;
    } on PlatformException catch (e) {
      debugPrint('[NativeTabBar] probe failed, using the Flutter dock: $e');
      _supported = false;
    } on Object catch (e) {
      debugPrint('[NativeTabBar] probe error, using the Flutter dock: $e');
      _supported = false;
    }
  }
}
