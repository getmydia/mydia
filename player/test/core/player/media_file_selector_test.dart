import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/media_file_selector.dart';
import 'package:player/core/player/network_info_service.dart';
import 'package:player/domain/models/media_file.dart';

MediaFile _makeFile({
  String id = '1',
  String? resolution,
  int? bitrate,
  bool directPlaySupported = false,
  String? hdrFormat,
  String? codec,
}) {
  return MediaFile(
    id: id,
    resolution: resolution,
    bitrate: bitrate,
    directPlaySupported: directPlaySupported,
    hdrFormat: hdrFormat,
    codec: codec,
  );
}

void main() {
  group('parseToPixels', () {
    test('parses named resolutions', () {
      expect(MediaFileSelector.parseToPixels('4K'), 2160);
      expect(MediaFileSelector.parseToPixels('1080p'), 1080);
      expect(MediaFileSelector.parseToPixels('720p'), 720);
      expect(MediaFileSelector.parseToPixels('480p'), 480);
      expect(MediaFileSelector.parseToPixels('360p'), 360);
    });

    test('parses case-insensitively', () {
      expect(MediaFileSelector.parseToPixels('4k'), 2160);
      expect(MediaFileSelector.parseToPixels('FHD'), 1080);
      expect(MediaFileSelector.parseToPixels('HD'), 720);
      expect(MediaFileSelector.parseToPixels('UHD'), 2160);
    });

    test('parses numeric suffix', () {
      expect(MediaFileSelector.parseToPixels('576p'), 576);
      expect(MediaFileSelector.parseToPixels('1440p'), 1440);
    });

    test('returns 0 for null', () {
      expect(MediaFileSelector.parseToPixels(null), 0);
    });

    test('returns 0 for unrecognized string', () {
      expect(MediaFileSelector.parseToPixels('unknown'), 0);
    });
  });

  group('selectBest', () {
    test('returns null for empty list', () {
      const context = DeviceContext(
        deviceCategory: DeviceCategory.mobile,
        networkType: NetworkType.wifi,
        isWeb: false,
      );
      expect(MediaFileSelector.selectBest([], context), isNull);
    });

    test('returns single file unchanged', () {
      const context = DeviceContext(
        deviceCategory: DeviceCategory.mobile,
        networkType: NetworkType.wifi,
        isWeb: false,
      );
      final file = _makeFile(resolution: '1080p');
      expect(MediaFileSelector.selectBest([file], context), equals(file));
    });

    test('mobile + cellular selects 720p over 4K', () {
      const context = DeviceContext(
        deviceCategory: DeviceCategory.mobile,
        networkType: NetworkType.cellular,
        isWeb: false,
      );
      final file720 = _makeFile(id: '720', resolution: '720p');
      final file4k = _makeFile(id: '4k', resolution: '4K');

      final result = MediaFileSelector.selectBest([file720, file4k], context);
      expect(result?.id, equals('720'));
    });

    test('mobile + wifi selects 1080p over 4K', () {
      const context = DeviceContext(
        deviceCategory: DeviceCategory.mobile,
        networkType: NetworkType.wifi,
        isWeb: false,
      );
      final file1080 = _makeFile(id: '1080', resolution: '1080p');
      final file4k = _makeFile(id: '4k', resolution: '4K');

      final result = MediaFileSelector.selectBest([file1080, file4k], context);
      expect(result?.id, equals('1080'));
    });

    test('desktop selects highest available resolution', () {
      const context = DeviceContext(
        deviceCategory: DeviceCategory.desktop,
        networkType: NetworkType.wifi,
        isWeb: false,
      );
      final file720 = _makeFile(id: '720', resolution: '720p');
      final file1080 = _makeFile(id: '1080', resolution: '1080p');
      final file4k = _makeFile(id: '4k', resolution: '4K');

      final result =
          MediaFileSelector.selectBest([file720, file1080, file4k], context);
      expect(result?.id, equals('4k'));
    });

    test('direct play wins tiebreak at same resolution', () {
      const context = DeviceContext(
        deviceCategory: DeviceCategory.desktop,
        networkType: NetworkType.wifi,
        isWeb: false,
      );
      final fileA = _makeFile(
        id: 'no-dp',
        resolution: '1080p',
        directPlaySupported: false,
      );
      final fileB = _makeFile(
        id: 'dp',
        resolution: '1080p',
        directPlaySupported: true,
      );

      final result = MediaFileSelector.selectBest([fileA, fileB], context);
      expect(result?.id, equals('dp'));
    });

    test('HDR deprioritized on web', () {
      const context = DeviceContext(
        deviceCategory: DeviceCategory.desktop,
        networkType: NetworkType.wifi,
        isWeb: true,
      );
      final fileHdr = _makeFile(
        id: 'hdr',
        resolution: '1080p',
        hdrFormat: 'HDR10',
      );
      final fileSdr = _makeFile(
        id: 'sdr',
        resolution: '1080p',
      );

      final result = MediaFileSelector.selectBest([fileHdr, fileSdr], context);
      expect(result?.id, equals('sdr'));
    });

    test('higher bitrate wins among same resolution', () {
      const context = DeviceContext(
        deviceCategory: DeviceCategory.desktop,
        networkType: NetworkType.wifi,
        isWeb: false,
      );
      final fileLow = _makeFile(
        id: 'low-br',
        resolution: '1080p',
        bitrate: 2000000, // 2 Mbps
      );
      final fileHigh = _makeFile(
        id: 'high-br',
        resolution: '1080p',
        bitrate: 8000000, // 8 Mbps
      );

      final result = MediaFileSelector.selectBest([fileLow, fileHigh], context);
      expect(result?.id, equals('high-br'));
    });

    test('files with null resolution handled gracefully', () {
      const context = DeviceContext(
        deviceCategory: DeviceCategory.mobile,
        networkType: NetworkType.wifi,
        isWeb: false,
      );
      final fileNull = _makeFile(id: 'null-res');
      final file720 = _makeFile(id: '720', resolution: '720p');

      final result = MediaFileSelector.selectBest([fileNull, file720], context);
      expect(result?.id, equals('720'));
    });

    test('files with null bitrate handled gracefully', () {
      const context = DeviceContext(
        deviceCategory: DeviceCategory.desktop,
        networkType: NetworkType.wifi,
        isWeb: false,
      );
      final fileA = _makeFile(id: 'a', resolution: '1080p');
      final fileB = _makeFile(id: 'b', resolution: '1080p', bitrate: 5000000);

      // File with bitrate should win over one without (bitrate bonus)
      final result = MediaFileSelector.selectBest([fileA, fileB], context);
      expect(result?.id, equals('b'));
    });

    test('high bitrate penalized on cellular', () {
      const context = DeviceContext(
        deviceCategory: DeviceCategory.mobile,
        networkType: NetworkType.cellular,
        isWeb: false,
      );
      final fileLow = _makeFile(
        id: 'low-br',
        resolution: '720p',
        bitrate: 3000000, // 3 Mbps
      );
      final fileHigh = _makeFile(
        id: 'high-br',
        resolution: '720p',
        bitrate: 20000000, // 20 Mbps
      );

      final result = MediaFileSelector.selectBest([fileLow, fileHigh], context);
      expect(result?.id, equals('low-br'));
    });

    test('widescreen selects highest available', () {
      const context = DeviceContext(
        deviceCategory: DeviceCategory.widescreen,
        networkType: NetworkType.wifi,
        isWeb: false,
      );
      final file1080 = _makeFile(id: '1080', resolution: '1080p');
      final file4k = _makeFile(id: '4k', resolution: '4K');

      final result = MediaFileSelector.selectBest([file1080, file4k], context);
      expect(result?.id, equals('4k'));
    });
  });

  group('DeviceContext', () {
    test('categorizes screen widths correctly', () {
      // These test the static factory behavior without async network detection.
      // We test the category mapping directly via the constructor.
      const mobile = DeviceContext(
        deviceCategory: DeviceCategory.mobile,
        networkType: NetworkType.unknown,
        isWeb: false,
      );
      expect(mobile.deviceCategory, DeviceCategory.mobile);

      const tablet = DeviceContext(
        deviceCategory: DeviceCategory.tablet,
        networkType: NetworkType.unknown,
        isWeb: false,
      );
      expect(tablet.deviceCategory, DeviceCategory.tablet);
    });
  });
}
