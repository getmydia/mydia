import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/remote/registration_status.dart';

void main() {
  group('RegistrationStatus.describe', () {
    test('reads as off when idle', () {
      expect(
          const RegistrationIdle().describe(), 'Not advertising this device');
    });

    test('names the dependency it is waiting on', () {
      expect(
        const RegistrationWaiting('a server connection').describe(),
        'Waiting for a server connection',
      );
    });

    test('reports the attempt while in flight', () {
      expect(
        const RegistrationInFlight('abc', 2).describe(),
        'Registering with the server (attempt 2)',
      );
    });

    test('confirms success', () {
      expect(
        RegistrationSucceeded('abc', DateTime(2026, 9, 1)).describe(),
        'Discoverable by your other devices',
      );
    });

    test('surfaces the failure reason', () {
      expect(
        RegistrationFailed('server rejected the node id', 3, null).describe(),
        'Not discoverable: server rejected the node id',
      );
    });
  });
}
