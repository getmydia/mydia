import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_capabilities.dart';

void main() {
  group('CastCapabilities', () {
    test('any is false only when both protocols are unavailable', () {
      expect(const CastCapabilities(chromecast: false, dlna: false).any, isFalse);
      expect(const CastCapabilities(chromecast: true, dlna: false).any, isTrue);
      expect(const CastCapabilities(chromecast: false, dlna: true).any, isTrue);
    });

    test('web has no cast capability at all', () {
      expect(const CastCapabilities.web().any, isFalse);
    });

    test('iOS gets Chromecast but not DLNA', () {
      // DLNA discovery is SSDP raw multicast, which iOS blocks without the
      // com.apple.developer.networking.multicast entitlement.
      expect(const CastCapabilities.iOS().chromecast, isTrue);
      expect(const CastCapabilities.iOS().dlna, isFalse);
    });

    test('desktop and Android get both protocols', () {
      expect(const CastCapabilities.full().chromecast, isTrue);
      expect(const CastCapabilities.full().dlna, isTrue);
    });
  });

  group('forPlatform', () {
    // This is the switch that decides whether iOS ever shows a DLNA device,
    // and it can only be exercised for every platform via the injected form —
    // `forCurrentPlatform` can only ever answer for the host running tests.
    test('web loses both protocols even if the iOS flag is somehow set', () {
      final capabilities =
          CastCapabilities.forPlatform(isWeb: true, isIOS: true);

      expect(capabilities.chromecast, isFalse);
      expect(capabilities.dlna, isFalse);
      expect(capabilities.any, isFalse);
    });

    test('iOS keeps Chromecast and loses DLNA', () {
      final capabilities =
          CastCapabilities.forPlatform(isWeb: false, isIOS: true);

      expect(capabilities.chromecast, isTrue);
      expect(capabilities.dlna, isFalse);
    });

    test('everything else gets both', () {
      final capabilities =
          CastCapabilities.forPlatform(isWeb: false, isIOS: false);

      expect(capabilities.chromecast, isTrue);
      expect(capabilities.dlna, isTrue);
    });

    test('forCurrentPlatform answers for the host running the tests', () {
      // The suite runs on desktop (the flutter_test VM is never web or iOS),
      // so this pins that the wiring from the static platform lookups to the
      // pure decision is the right way round.
      final capabilities = CastCapabilities.forCurrentPlatform();

      expect(capabilities.chromecast, isTrue);
      expect(capabilities.dlna, isTrue);
    });
  });
}
