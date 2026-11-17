import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/device_profile.dart';
import 'package:player/core/player/hdr_claims.dart';

void main() {
  group('nativeHdrFormats', () {
    test('claims HDR10+, HDR10 and HLG', () {
      expect(nativeHdrFormats, ['hdr10+', 'hdr10', 'hlg']);
    });

    test('never claims Dolby Vision or the legacy hdr10plus token', () {
      expect(nativeHdrFormats, isNot(contains('dolby_vision')));
      expect(nativeHdrFormats, isNot(contains('hdr10plus')));
    });
  });

  test('androidHdrFormats is empty until verified on a device', () {
    expect(androidHdrFormats, isEmpty);
  });

  group('webHdrFormats', () {
    test('no HDR display gives nothing, whatever the decoder says', () {
      expect(
        webHdrFormats(highDynamicRange: false, pq: true, hlg: true),
        isEmpty,
      );
      expect(
        webHdrFormats(highDynamicRange: false, pq: false, hlg: false),
        isEmpty,
      );
    });

    test('HDR display with neither curve gives nothing', () {
      expect(
        webHdrFormats(highDynamicRange: true, pq: false, hlg: false),
        isEmpty,
      );
    });

    test('pq adds hdr10+ and hdr10', () {
      expect(
        webHdrFormats(highDynamicRange: true, pq: true, hlg: false),
        ['hdr10+', 'hdr10'],
      );
    });

    test('hlg alone adds hlg', () {
      expect(
        webHdrFormats(highDynamicRange: true, pq: false, hlg: true),
        ['hlg'],
      );
    });

    test('both curves give all three', () {
      expect(
        webHdrFormats(highDynamicRange: true, pq: true, hlg: true),
        ['hdr10+', 'hdr10', 'hlg'],
      );
    });
  });

  test('copyWith replaces hdrFormats and keeps them when omitted', () {
    const base = DeviceProfile.webDefault();
    final withHdr = base.copyWith(hdrFormats: nativeHdrFormats);
    expect(withHdr.hdrFormats, nativeHdrFormats);
    expect(
        withHdr.copyWith(codecProfiles: const []).hdrFormats, nativeHdrFormats);
  });
}
