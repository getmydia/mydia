import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/best_file.dart';
import 'package:player/domain/models/media_file.dart';
import 'package:player/domain/sources/item.dart';

MediaFile _file(String id, String resolution) => MediaFile(
      id: id,
      resolution: resolution,
      directPlaySupported: true,
    );

void main() {
  group('pickBestFile', () {
    test('returns null for an empty list', () async {
      expect(await pickBestFile(const [], 1200), isNull);
    });

    test('returns the only file without probing the device', () async {
      final only = _file('a', '480p');
      expect(await pickBestFile([only], 1200), same(only));
    });

    test('prefers the higher resolution on a wide screen', () async {
      final sd = _file('sd', '480p');
      final hd = _file('hd', '1080p');
      final picked = await pickBestFile([sd, hd], 1600);
      expect(picked?.id, 'hd');
    });
  });

  group('pickBestVersionId', () {
    test('null for no versions', () async {
      expect(await pickBestVersionId(const [], 1600), isNull);
    });

    test('not simply the first version', () async {
      const versions = [
        MediaVersion(id: 'sd', height: 480),
        MediaVersion(id: 'hd', height: 1080),
      ];
      expect(await pickBestVersionId(versions, 1600), 'hd');
    });
  });
}
