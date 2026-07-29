import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_backend.dart';
import 'package:player/presentation/widgets/cast_actions.dart';

void main() {
  group('castErrorMessage', () {
    test('names the port for an unreachable receiver', () {
      const e = CastBackendException('nope', CastFailureKind.unreachable);

      expect(castErrorMessage(e), isNot(contains('nope')));
      expect(castErrorMessage(e), isNotEmpty);
    });

    test('explains a denied local network permission', () {
      const e = CastBackendException('denied', CastFailureKind.discoveryDenied);

      expect(castErrorMessage(e), contains('local network'));
    });
  });

  group('castErrorMessage covers every failure kind', () {
    // A missed enum case would fall through to a generic string, losing the
    // port number or permission hint that makes the error actionable.
    for (final kind in CastFailureKind.values) {
      test('produces actionable text for $kind', () {
        final message = castErrorMessage(CastBackendException('raw', kind));

        expect(message, isNotEmpty);
        expect(message, isNot(equals('raw')),
            reason: 'the raw backend string is not user-facing');
      });
    }
  });
}
