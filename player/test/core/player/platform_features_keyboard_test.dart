// Guards PlatformFeatures.supportsKeyboardShortcuts' logic directly via its
// pure, @visibleForTesting predicate: `kIsWeb` is a compile-time constant
// baked in per build target, so a single `flutter test` run (always
// non-web, and — on this native macOS/Linux/Windows host — always
// `isDesktop: true`) can never actually observe the real getter evaluate to
// `false` or differ across platforms. Testing the extracted boolean logic
// with explicit inputs is the only way to verify "web has a keyboard too"
// without a browser test target.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/platform_features.dart';

void main() {
  group('PlatformFeatures.computeSupportsKeyboardShortcuts', () {
    test('true on native desktop', () {
      expect(
        PlatformFeatures.computeSupportsKeyboardShortcuts(
          isDesktop: true,
          isWeb: false,
        ),
        isTrue,
      );
    });

    test(
        'true on web, even though isDesktop is false there — the actual '
        'defect this fixes: a narrowed desktop *or web* window loses the '
        'in-bar episode-nav buttons (viewport-width-gated, not platform-'
        'gated), and web previously had no keyboard fallback either', () {
      expect(
        PlatformFeatures.computeSupportsKeyboardShortcuts(
          isDesktop: false,
          isWeb: true,
        ),
        isTrue,
      );
    });

    test('false on mobile (neither native desktop nor web)', () {
      expect(
        PlatformFeatures.computeSupportsKeyboardShortcuts(
          isDesktop: false,
          isWeb: false,
        ),
        isFalse,
      );
    });

    test('the real getter matches the pure predicate on this (non-web) host',
        () {
      expect(
        PlatformFeatures.supportsKeyboardShortcuts,
        PlatformFeatures.computeSupportsKeyboardShortcuts(
          isDesktop: PlatformFeatures.isDesktop,
          isWeb: PlatformFeatures.isWeb,
        ),
      );
    });
  });
}
