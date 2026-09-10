import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_service.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  test('crash reporting is off until the user opts in', () async {
    final service = SettingsService(storage: MockAuthStorage());

    expect(await service.getCrashReportingEnabled(), isFalse);
  });

  test('the choice round-trips through storage', () async {
    final storage = MockAuthStorage();
    final service = SettingsService(storage: storage);

    await service.setCrashReportingEnabled(true);
    expect(await service.getCrashReportingEnabled(), isTrue);
    expect(storage.contents, {'crash_reporting_enabled': 'true'});

    await service.setCrashReportingEnabled(false);
    expect(await service.getCrashReportingEnabled(), isFalse);
  });

  // A device-level choice, not an account preference: signing out of one
  // server must not silently opt the device back out, or in.
  test('clearSettings leaves the crash-reporting choice alone', () async {
    final storage = MockAuthStorage();
    final service = SettingsService(storage: storage);

    await service.setCrashReportingEnabled(true);
    await service.setAutoSkipSegments(true);
    await service.clearSettings();

    expect(storage.contents, {'crash_reporting_enabled': 'true'});
  });
}
