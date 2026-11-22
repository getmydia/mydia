import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_result.dart';

void main() {
  group('ConnectionType', () {
    test('has direct value', () {
      expect(ConnectionType.direct, isNotNull);
      expect(ConnectionType.direct.name, equals('direct'));
    });

    test('has p2p value', () {
      expect(ConnectionType.p2p, isNotNull);
      expect(ConnectionType.p2p.name, equals('p2p'));
    });

    test('has exactly 2 values', () {
      expect(ConnectionType.values.length, equals(2));
    });
  });

  group('ConnectionResult', () {
    group('direct factory', () {
      test('creates successful direct connection', () {
        final result = ConnectionResult.direct(url: 'https://example.com');

        expect(result.success, isTrue);
        expect(result.type, equals(ConnectionType.direct));
        expect(result.connectedUrl, equals('https://example.com'));
        expect(result.error, isNull);
      });

      test('isDirect returns true', () {
        final result = ConnectionResult.direct(url: 'https://example.com');
        expect(result.isDirect, isTrue);
      });

      test('isP2P returns false', () {
        final result = ConnectionResult.direct(url: 'https://example.com');
        expect(result.isP2P, isFalse);
      });
    });

    group('p2p factory', () {
      test('creates successful P2P connection', () {
        final result = ConnectionResult.p2p();

        expect(result.success, isTrue);
        expect(result.type, equals(ConnectionType.p2p));
        expect(result.connectedUrl, isNull);
        expect(result.error, isNull);
      });

      test('isDirect returns false', () {
        final result = ConnectionResult.p2p();
        expect(result.isDirect, isFalse);
      });

      test('isP2P returns true', () {
        final result = ConnectionResult.p2p();
        expect(result.isP2P, isTrue);
      });
    });

    group('error factory', () {
      test('creates failed connection', () {
        final result = ConnectionResult.error('Connection failed');

        expect(result.success, isFalse);
        expect(result.type, isNull);
        expect(result.connectedUrl, isNull);
        expect(result.error, equals('Connection failed'));
      });

      test('isDirect returns false', () {
        final result = ConnectionResult.error('Error');
        expect(result.isDirect, isFalse);
      });

      test('isP2P returns false', () {
        final result = ConnectionResult.error('Error');
        expect(result.isP2P, isFalse);
      });

      test('preserves detailed error messages', () {
        const detailedError =
            'Failed to connect: SSL handshake failed with certificate mismatch';
        final result = ConnectionResult.error(detailedError);
        expect(result.error, equals(detailedError));
      });
    });

    group('success getter', () {
      test('returns true for direct connection', () {
        final result = ConnectionResult.direct(url: 'https://example.com');
        expect(result.success, isTrue);
      });

      test('returns true for P2P connection', () {
        final result = ConnectionResult.p2p();
        expect(result.success, isTrue);
      });

      test('returns false for error', () {
        final result = ConnectionResult.error('Error');
        expect(result.success, isFalse);
      });
    });

    group('type getter', () {
      test('returns direct for direct connection', () {
        final result = ConnectionResult.direct(url: 'https://example.com');
        expect(result.type, equals(ConnectionType.direct));
      });

      test('returns p2p for P2P connection', () {
        final result = ConnectionResult.p2p();
        expect(result.type, equals(ConnectionType.p2p));
      });

      test('returns null for error', () {
        final result = ConnectionResult.error('Error');
        expect(result.type, isNull);
      });
    });

    group('connectedUrl getter', () {
      test('returns URL for direct connection', () {
        final result = ConnectionResult.direct(
          url: 'https://mydia.example.com:4443',
        );
        expect(result.connectedUrl, equals('https://mydia.example.com:4443'));
      });

      test('returns null for P2P connection', () {
        final result = ConnectionResult.p2p();
        expect(result.connectedUrl, isNull);
      });

      test('returns null for error', () {
        final result = ConnectionResult.error('Error');
        expect(result.connectedUrl, isNull);
      });
    });
  });
}
