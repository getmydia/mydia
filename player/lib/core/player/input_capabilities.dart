import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

import 'input_capabilities_native.dart'
    if (dart.library.js_interop) 'input_capabilities_web.dart' as probe;
import 'platform_features.dart';

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
  /// Whether the primary pointer is a finger.
  static bool get touchPrimary => computeTouchPrimary(
        isNativeMobile: PlatformFeatures.isMobile,
        isWeb: kIsWeb,
        coarsePointer: probe.coarsePointer,
      );

  /// Pure predicate behind [touchPrimary], exposed separately so it can be
  /// unit-tested for every platform combination without running on each.
  /// `kIsWeb` is compile-time per build target and always false under
  /// `flutter test`, so a regression that deleted the web branch would pass
  /// every test unless the logic is tested independently. Mirrors
  /// `PlatformFeatures.computeSupportsKeyboardShortcuts`, which exists for
  /// exactly the same reason.
  ///
  /// Safe to annotate here, unlike `resolveWebMode`: this is called from
  /// [touchPrimary] in the same library file.
  @visibleForTesting
  static bool computeTouchPrimary({
    required bool isNativeMobile,
    required bool isWeb,
    required bool coarsePointer,
  }) =>
      isNativeMobile || (isWeb && coarsePointer);

  /// Whether tap and double-tap playback gestures should be wired.
  ///
  /// Moved off `PlatformFeatures`, where it read `isMobile` and was therefore
  /// false on every phone browser.
  static bool get supportsGestureControls => touchPrimary;
}
