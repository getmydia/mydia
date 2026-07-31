import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/platform_features.dart';

void main() {
  group('PlayerGlassTier', () {
    test('exposes three tiers', () {
      expect(PlayerGlassTier.values, hasLength(3));
      expect(
        PlayerGlassTier.values,
        containsAll(<PlayerGlassTier>[
          PlayerGlassTier.full,
          PlayerGlassTier.reduced,
          PlayerGlassTier.faux,
        ]),
      );
    });

    test('non-web hosts resolve to the full tier', () {
      // These unit tests run on the Dart VM, never on web.
      expect(PlatformFeatures.isWeb, isFalse);
      expect(PlatformFeatures.playerGlassTier, PlayerGlassTier.full);
    });

    test('faux is never auto-selected — it is an opt-in contingency', () {
      expect(PlatformFeatures.playerGlassTier, isNot(PlayerGlassTier.faux));
    });
  });
}
