import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/remote/registration_status.dart';
import 'package:player/l10n/gen/app_localizations_en.dart';
import 'package:player/l10n/l10n.dart';

void main() {
  final en = AppLocalizationsEn();

  group('registrationStatusText', () {
    test('reads as off when idle', () {
      expect(en.registrationStatusText(const RegistrationIdle()),
          'Not advertising this device');
    });

    test('names the dependency it is waiting on', () {
      expect(
        en.registrationStatusText(
            const RegistrationWaiting(RegistrationDependency.serverConnection)),
        'Waiting for a server connection',
      );
      expect(
        en.registrationStatusText(const RegistrationWaiting(
            RegistrationDependency.remoteControlSetting)),
        'Waiting for the remote control setting',
      );
      expect(
        en.registrationStatusText(
            const RegistrationWaiting(RegistrationDependency.deviceOnline)),
        'Waiting for this device to come online',
      );
    });

    test('reports the attempt while in flight', () {
      expect(
        en.registrationStatusText(const RegistrationInFlight('abc', 2)),
        'Registering with the server (attempt 2)',
      );
    });

    test('confirms success', () {
      expect(
        en.registrationStatusText(
            RegistrationSucceeded('abc', DateTime(2026, 9, 1))),
        'Discoverable by your other devices',
      );
    });

    test('surfaces the failure reason verbatim', () {
      expect(
        en.registrationStatusText(
            const RegistrationFailed('server rejected the node id', 3, null)),
        'Not discoverable: server rejected the node id',
      );
    });
  });
}
