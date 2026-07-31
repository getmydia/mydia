import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/player/player_screen.dart';

void main() {
  group('shouldOfferResume', () {
    test('offers resume for a normal mid-movie position', () {
      expect(
        shouldOfferResume(
          savedPositionSeconds: 2700,
          realDuration: const Duration(seconds: 5400),
        ),
        isTrue,
      );
    });

    test('declines when there is no saved position', () {
      expect(
        shouldOfferResume(
          savedPositionSeconds: null,
          realDuration: const Duration(seconds: 5400),
        ),
        isFalse,
      );
    });

    test('declines below the 30 second minimum', () {
      expect(
        shouldOfferResume(
          savedPositionSeconds: 12,
          realDuration: const Duration(seconds: 5400),
        ),
        isFalse,
      );
    });

    test('declines within the last 60 seconds', () {
      // Previously there was no upper bound at all, so a finished movie still
      // offered to resume at 99%.
      expect(
        shouldOfferResume(
          savedPositionSeconds: 5370,
          realDuration: const Duration(seconds: 5400),
        ),
        isFalse,
      );
    });

    test('declines past the 90% watched threshold', () {
      expect(
        shouldOfferResume(
          savedPositionSeconds: 4900,
          realDuration: const Duration(seconds: 5400),
        ),
        isFalse,
      );
    });

    test('declines when the real duration is unknown', () {
      // Better to start from the beginning than to show a fabricated
      // percentage computed against a partial playlist length.
      expect(
        shouldOfferResume(
          savedPositionSeconds: 2700,
          realDuration: null,
        ),
        isFalse,
      );
    });
  });
}
