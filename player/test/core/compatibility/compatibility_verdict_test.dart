import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/compatibility/compatibility.dart';
import 'package:player/core/compatibility/compatibility_verdict.dart';
import 'package:player/core/update/version_comparator.dart';

/// A server on 0.9.0 whose floors are both 0.9.0, matching the shipped baseline.
ServerCompatibilityInfo server({
  String version = '0.9.0',
  String min = '0.9.0',
  String recommended = '0.9.0',
}) =>
    ServerCompatibilityInfo(
      version: version,
      minPlayerVersion: min,
      recommendedPlayerVersion: recommended,
    );

void main() {
  group('evaluateCompatibility', () {
    test('a matching pair is compatible', () {
      expect(
        evaluateCompatibility(playerVersion: '0.9.0', server: server()),
        CompatibilityVerdict.compatible,
      );
    });

    test('a null server means unknown', () {
      expect(
        evaluateCompatibility(playerVersion: '0.9.0', server: null),
        CompatibilityVerdict.unknown,
      );
    });

    test('an unparseable version means unknown, not a banner', () {
      expect(
        evaluateCompatibility(playerVersion: 'garbage', server: server()),
        CompatibilityVerdict.unknown,
      );
      expect(
        evaluateCompatibility(
          playerVersion: '0.9.0',
          server: server(version: 'garbage'),
        ),
        CompatibilityVerdict.unknown,
      );
    });

    test('a player below the server floor is required to update', () {
      expect(
        evaluateCompatibility(
          playerVersion: '0.8.0',
          server: server(version: '0.9.0', min: '0.9.0'),
        ),
        CompatibilityVerdict.playerUpdateRequired,
      );
    });

    test('a player below only the recommended floor is nudged', () {
      expect(
        evaluateCompatibility(
          playerVersion: '0.8.0',
          server: server(version: '0.9.0', min: '0.7.0', recommended: '0.9.0'),
        ),
        CompatibilityVerdict.playerUpdateRecommended,
      );
    });

    test('a server below the player floor is required to update', () {
      // minServerVersion ships as 0.9.0, so a 0.8.0 server is below it.
      expect(
        evaluateCompatibility(
          playerVersion: '0.9.0',
          server: server(version: '0.8.0', min: '0.0.0', recommended: '0.0.0'),
        ),
        CompatibilityVerdict.serverUpdateRequired,
      );
    });

    test('required outranks recommended', () {
      expect(
        evaluateCompatibility(
          playerVersion: '0.8.0',
          server: server(version: '0.9.0', min: '0.9.0', recommended: '0.9.0'),
        ),
        CompatibilityVerdict.playerUpdateRequired,
      );
    });

    test('the player side wins when both directions fire', () {
      // Player 0.8.0 is below the server's 0.9.0 floor, and server 0.8.0 is
      // below the player's shipped 0.9.0 floor. The person holding the phone
      // can act on the player message, so it wins.
      expect(
        evaluateCompatibility(
          playerVersion: '0.8.0',
          server: server(version: '0.8.0', min: '0.9.0', recommended: '0.9.0'),
        ),
        CompatibilityVerdict.playerUpdateRequired,
      );
    });

    test('a prerelease player clears a matching floor', () {
      expect(
        evaluateCompatibility(
          playerVersion: '0.9.0-rc1',
          server: server(version: '0.9.0', min: '0.9.0'),
        ),
        CompatibilityVerdict.compatible,
      );
    });

    test('a master-build server version parses', () {
      expect(
        evaluateCompatibility(
          playerVersion: '0.9.0',
          server: server(version: '0.9.0*abc1234'),
        ),
        CompatibilityVerdict.compatible,
      );
    });

    test('an unversioned dev-build server yields unknown, not a banner', () {
      // mix.exs falls back to "0.0.0-dev" whenever BUILD_VERSION is unset,
      // which covers every local dev server, self-built image, and the
      // published :master image. That must never sort below every floor and
      // raise a non-dismissible banner.
      expect(
        evaluateCompatibility(
          playerVersion: '0.13.2',
          server: server(version: '0.0.0-dev*abc1234'),
        ),
        CompatibilityVerdict.unknown,
      );
    });

    test('a plain 0.0.0 server version yields unknown', () {
      expect(
        evaluateCompatibility(
          playerVersion: '0.13.2',
          server: server(version: '0.0.0'),
        ),
        CompatibilityVerdict.unknown,
      );
    });

    test('an unversioned dev-build player yields unknown, symmetrically', () {
      expect(
        evaluateCompatibility(
          playerVersion: '0.0.0-dev',
          server: server(),
        ),
        CompatibilityVerdict.unknown,
      );
    });

    test('a genuinely old but versioned server still requires an update', () {
      // Sanity check: an over-broad fix for the 0.0.0 case above must not
      // silently disable the feature for real ancient-server mismatches.
      expect(
        evaluateCompatibility(
          playerVersion: '0.13.2',
          server: server(version: '0.8.0', min: '0.0.0', recommended: '0.0.0'),
        ),
        CompatibilityVerdict.serverUpdateRequired,
      );
    });
  });

  group('Compatibility floors', () {
    test('minServerVersion parses as a version', () {
      expect(
        VersionComparator.compareCore(Compatibility.minServerVersion, '0.0.0'),
        isNotNull,
      );
    });

    test('recommendedServerVersion parses as a version', () {
      expect(
        VersionComparator.compareCore(
            Compatibility.recommendedServerVersion, '0.0.0'),
        isNotNull,
      );
    });

    test('recommendedServerVersion is at or above minServerVersion', () {
      final comparison = VersionComparator.compareCore(
        Compatibility.recommendedServerVersion,
        Compatibility.minServerVersion,
      );
      expect(comparison, isNotNull);
      expect(comparison! >= 0, isTrue);
    });
  });

  group('CompatibilityVerdict flags', () {
    test('compatible and unknown show no banner', () {
      expect(CompatibilityVerdict.compatible.showsBanner, isFalse);
      expect(CompatibilityVerdict.unknown.showsBanner, isFalse);
    });

    test('required verdicts show a non-dismissible banner', () {
      expect(CompatibilityVerdict.playerUpdateRequired.showsBanner, isTrue);
      expect(CompatibilityVerdict.playerUpdateRequired.isRequired, isTrue);
      expect(CompatibilityVerdict.playerUpdateRequired.isDismissible, isFalse);
      expect(CompatibilityVerdict.serverUpdateRequired.showsBanner, isTrue);
      expect(CompatibilityVerdict.serverUpdateRequired.isRequired, isTrue);
      expect(CompatibilityVerdict.serverUpdateRequired.isDismissible, isFalse);
    });

    test('recommended verdicts show a dismissible banner', () {
      expect(CompatibilityVerdict.playerUpdateRecommended.showsBanner, isTrue);
      expect(CompatibilityVerdict.playerUpdateRecommended.isRequired, isFalse);
      expect(
          CompatibilityVerdict.playerUpdateRecommended.isDismissible, isTrue);
      expect(
          CompatibilityVerdict.serverUpdateRecommended.isDismissible, isTrue);
    });

    test('isPlayerBehind is true only for the two player-side verdicts', () {
      expect(CompatibilityVerdict.playerUpdateRequired.isPlayerBehind, isTrue);
      expect(
          CompatibilityVerdict.playerUpdateRecommended.isPlayerBehind, isTrue);
      expect(CompatibilityVerdict.serverUpdateRequired.isPlayerBehind, isFalse);
      expect(
          CompatibilityVerdict.serverUpdateRecommended.isPlayerBehind, isFalse);
      expect(CompatibilityVerdict.compatible.isPlayerBehind, isFalse);
      expect(CompatibilityVerdict.unknown.isPlayerBehind, isFalse);
    });
  });
}
