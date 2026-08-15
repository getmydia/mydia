import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/compatibility/compatibility_verdict.dart';

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
  });
}
