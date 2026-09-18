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

  group('isNewer prerelease comparison', () {
    test('a double-digit dev counter is newer than a single digit one', () {
      // Before the fix this compared "dev.9" and "dev.10" as whole strings,
      // where "9" sorts above "10" lexicographically, so a dev install on
      // build 9 was never offered build 10.
      expect(
          VersionComparator.isNewer('0.16.0-dev.9', '0.16.0-dev.10'), isTrue);
    });

    test('a double-digit beta counter is newer than a single digit one', () {
      expect(
          VersionComparator.isNewer('0.15.0-beta.9', '0.15.0-beta.10'), isTrue);
    });

    test('the legacy no-dot form compares its counter numerically too', () {
      // 18 real tags on this repo use "rc13" rather than "rc.13".
      expect(VersionComparator.isNewer('0.8.1-rc2', '0.8.1-rc13'), isTrue);
    });

    test(
        'the maturity bands order dev below alpha below beta below rc '
        'below the plain release', () {
      const dev = '0.15.0-dev.1';
      const alpha = '0.15.0-alpha.1';
      const beta = '0.15.0-beta.1';
      const rc = '0.15.0-rc.1';
      const release = '0.15.0';

      expect(VersionComparator.isNewer(dev, alpha), isTrue);
      expect(VersionComparator.isNewer(alpha, beta), isTrue);
      expect(VersionComparator.isNewer(beta, rc), isTrue);
      expect(VersionComparator.isNewer(rc, release), isTrue);

      // And never backwards.
      expect(VersionComparator.isNewer(alpha, dev), isFalse);
      expect(VersionComparator.isNewer(beta, alpha), isFalse);
      expect(VersionComparator.isNewer(rc, beta), isFalse);
      expect(VersionComparator.isNewer(release, rc), isFalse);
    });

    test(
        'a dev build never offers a stable release from an older core '
        'version', () {
      // The core-version check must still dominate: 0.15.2 is a real
      // release, but it is older than 0.16.0 regardless of what prerelease
      // suffix the running dev build carries.
      expect(VersionComparator.isNewer('0.16.0-dev.7', '0.15.2'), isFalse);
    });
  });
}
