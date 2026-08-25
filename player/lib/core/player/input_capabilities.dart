import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

import 'input_capabilities_native.dart'
    if (dart.library.js_interop) 'input_capabilities_web.dart' as probe;
import 'platform_features.dart';
import 'tv_probe_native.dart' if (dart.library.js_interop) 'tv_probe_web.dart'
    as tv;

/// What the viewer is pointing with, as opposed to what the build target is.
///
/// Split out from [PlatformFeatures] because that class answers "which build
/// is this", and every one of its getters short-circuits `if (kIsWeb) return
/// false`. That is correct for a build-target question and wrong for an input
/// question: a phone browser has fingers whether or not the Dart build target
/// knows it is a phone.
///
/// Keyed on pointer rather than viewport on purpose. A phone in landscape is
/// around 800px wide, which is exactly when someone is watching video, so any
/// width-based rule would drop out of the touch tier at the worst possible
/// moment. Viewport stays the right axis for layout, and
/// `core/layout/breakpoints.dart` keeps that job.
class InputCapabilities {
  /// Developer override that forces the directional tier on.
  ///
  /// Exists so the television path can be exercised on a phone, a desktop
  /// host, or an emulator that does not declare leanback. Auto-detection is
  /// the default and this is never an end-user setting.
  static const bool forcedTv = bool.fromEnvironment('MYDIA_FORCE_TV');

  /// Cached answer from the leanback probe, filled by [initialize].
  ///
  /// Starts false so every getter has a safe answer before startup reaches
  /// [initialize], and so `flutter test` (which never calls it) sees the
  /// phone and desktop behaviour unchanged.
  static bool _hasLeanback = false;

  /// Resolves the television probe once, for [directionalPrimary] to read
  /// synchronously afterwards.
  ///
  /// Called from `_startApp` in `main.dart`. Async because the platform
  /// answer is, and this class is synchronous everywhere else because it is
  /// read inside `build` methods. Never throws: the probe swallows its own
  /// failures and answers false.
  static Future<void> initialize() async {
    _hasLeanback = await tv.probeLeanback();
  }

  /// Whether the viewer is driving the app with a directional pad.
  ///
  /// True on Android TV and Google TV, including Chromecast with Google TV.
  /// Consumers use this to decide between pointer affordances and focus
  /// affordances, not to decide layout.
  static bool get directionalPrimary => computeDirectionalPrimary(
        isNativeAndroid: PlatformFeatures.isAndroid,
        hasLeanback: _hasLeanback,
        forcedTv: forcedTv,
      );

  /// Pure predicate behind [directionalPrimary], exposed separately for the
  /// same reason [computeTouchPrimary] is: the platform branches are
  /// compile-time per build target, so a regression that deleted one would
  /// pass every test unless the logic is tested independently.
  @visibleForTesting
  static bool computeDirectionalPrimary({
    required bool isNativeAndroid,
    required bool hasLeanback,
    required bool forcedTv,
  }) =>
      forcedTv || (isNativeAndroid && hasLeanback);

  /// Whether the primary pointer is a finger.
  static bool get touchPrimary => computeTouchPrimary(
        isNativeMobile: PlatformFeatures.isMobile,
        isWeb: kIsWeb,
        coarsePointer: probe.coarsePointer,
        directionalPrimary: directionalPrimary,
      );

  /// Pure predicate behind [touchPrimary], exposed separately so it can be
  /// unit-tested for every platform combination without running on each.
  /// `kIsWeb` is compile-time per build target and always false under
  /// `flutter test`, so a regression that deleted the web branch would pass
  /// every test unless the logic is tested independently. Mirrors
  /// `PlatformFeatures.computeSupportsKeyboardShortcuts`, which exists for
  /// exactly the same reason.
  ///
  /// [directionalPrimary] subtracts rather than adds. Android TV reports
  /// `isNativeMobile` true, so without that term a television would install
  /// tap and double-tap playback gestures for a viewer holding a remote,
  /// while `PlatformFeatures.supportsKeyboardShortcuts` (desktop and web
  /// only) denied it the key handler. Gestures on, keys off, which is the
  /// exact inverse of what a remote needs.
  @visibleForTesting
  static bool computeTouchPrimary({
    required bool isNativeMobile,
    required bool isWeb,
    required bool coarsePointer,
    required bool directionalPrimary,
  }) =>
      !directionalPrimary && (isNativeMobile || (isWeb && coarsePointer));

  /// Whether tap and double-tap playback gestures should be wired.
  ///
  /// Moved off `PlatformFeatures`, where it read `isMobile` and was therefore
  /// false on every phone browser.
  static bool get supportsGestureControls => touchPrimary;
}
