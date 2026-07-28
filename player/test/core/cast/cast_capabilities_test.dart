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
}
