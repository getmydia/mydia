import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/version_comparator.dart';

void main() {
  group('compareCore', () {
    test('orders by major, minor, then patch', () {
      expect(VersionComparator.compareCore('0.9.0', '0.10.0'), isNegative);
      expect(VersionComparator.compareCore('1.0.0', '0.99.99'), isPositive);
      expect(VersionComparator.compareCore('0.9.1', '0.9.0'), isPositive);
      expect(VersionComparator.compareCore('0.9.0', '0.9.0'), isZero);
    });

    test('strips a leading v', () {
      expect(VersionComparator.compareCore('v0.9.0', '0.9.0'), isZero);
    });

    test('treats a missing patch as zero', () {
      expect(VersionComparator.compareCore('0.9', '0.9.0'), isZero);
    });

    test('strips the *sha suffix a master build carries', () {
      // System.app_version() returns "0.9.0*abc1234" on master builds.
      expect(VersionComparator.compareCore('0.9.0*abc1234', '0.9.0'), isZero);
      expect(
          VersionComparator.compareCore('0.10.0*deadbee', '0.9.0'), isPositive);
    });

    test('ignores prerelease suffixes, unlike isNewer', () {
      // An RC of 0.9.0 carries the 0.9.0 contract, so it must clear a 0.9.0
      // floor. isNewer deliberately sorts it below; compareCore must not.
      expect(VersionComparator.compareCore('0.9.0-rc1', '0.9.0'), isZero);
      expect(VersionComparator.isNewer('0.9.0-rc1', '0.9.0'), isTrue);
    });

    test('returns null when either side is unparseable', () {
      expect(VersionComparator.compareCore('not-a-version', '0.9.0'), isNull);
      expect(VersionComparator.compareCore('0.9.0', ''), isNull);
      expect(VersionComparator.compareCore('0.9.0.1.2', '0.9.0'), isNull);
    });
  });
}
