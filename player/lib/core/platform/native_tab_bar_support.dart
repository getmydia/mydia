import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Which native chrome the Runner installed.
enum NativeTabBarMode {
  none,

  /// iPhone: the tab bar and the cast accessory.
  bar,

  /// iPad: the sidebar, which iPadOS turns into a tab bar at compact width.
  sidebar,
}

/// Which native chrome (iOS 26 or macOS) is installed, resolved once at startup.
///
/// Follows `InputCapabilities`: [initialize] is awaited from `_startApp` in
/// `main.dart`, and [mode] is read synchronously inside `build`
/// afterwards. `flutter test` never calls [initialize], so every test sees
/// none unless it sets [debugOverride].
class NativeTabBarSupport {
  /// Answered by `NativeTabBarPlugin` in the iOS and macOS Runners.
  static const MethodChannel channel = MethodChannel('mydia/native-tab-bar');

  static NativeTabBarMode _mode = NativeTabBarMode.none;

  /// Forces [supported] in tests: true means the bar, false means none.
  /// Reset to null in `tearDown`.
  @visibleForTesting
  static bool? debugOverride;

  /// Clears the cached probe answer in tests.
  @visibleForTesting
  static void debugReset() => _mode = NativeTabBarMode.none;

  /// Forces [mode] in tests. Wins over [debugOverride].
  @visibleForTesting
  static NativeTabBarMode? debugOverrideMode;

  static NativeTabBarMode get mode =>
      debugOverrideMode ??
      switch (debugOverride) {
        true => NativeTabBarMode.bar,
        false => NativeTabBarMode.none,
        null => _mode,
      };

  static bool get supported => mode != NativeTabBarMode.none;

  /// Asks the native side once. Never throws and never hangs: the probe is
  /// bounded by a 2 second timeout, and a timeout, a missing plugin or any
  /// error is logged and answers none, so the Flutter dock stays.
  static Future<void> initialize() async {
    final platform = defaultTargetPlatform;
    if (kIsWeb ||
        (platform != TargetPlatform.iOS && platform != TargetPlatform.macOS)) {
      _mode = NativeTabBarMode.none;
      return;
    }
    try {
      final answer = await channel
          .invokeMethod<String>('mode')
          .timeout(const Duration(seconds: 2));
      _mode = switch (answer) {
        'bar' => NativeTabBarMode.bar,
        'sidebar' => NativeTabBarMode.sidebar,
        _ => NativeTabBarMode.none,
      };
    } on TimeoutException {
      debugPrint('[NativeTabBar] probe timed out, using the Flutter dock');
      _mode = NativeTabBarMode.none;
    } on MissingPluginException catch (e) {
      debugPrint('[NativeTabBar] plugin missing, using the Flutter dock: $e');
      _mode = NativeTabBarMode.none;
    } on PlatformException catch (e) {
      debugPrint('[NativeTabBar] probe failed, using the Flutter dock: $e');
      _mode = NativeTabBarMode.none;
    } on Object catch (e) {
      debugPrint('[NativeTabBar] probe error, using the Flutter dock: $e');
      _mode = NativeTabBarMode.none;
    }
  }
}
