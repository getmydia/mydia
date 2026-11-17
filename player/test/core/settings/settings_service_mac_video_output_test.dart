import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_service.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  test('the legacy video output is off until the viewer turns it on', () async {
    final service = SettingsService(storage: MockAuthStorage());

    expect(await service.getLegacyMacVideoOutput(), isFalse);
  });

  test('the legacy choice round-trips through storage', () async {
    final storage = MockAuthStorage();
    final service = SettingsService(storage: storage);

    await service.setLegacyMacVideoOutput(true);
    expect(await service.getLegacyMacVideoOutput(), isTrue);
    expect(storage.contents, {'legacy_mac_video_output': 'true'});

    await service.setLegacyMacVideoOutput(false);
    expect(await service.getLegacyMacVideoOutput(), isFalse);
  });

  test('no surface failure is recorded by default', () async {
    final service = SettingsService(storage: MockAuthStorage());

    expect(await service.getMacSurfaceFailedVersion(), isNull);
  });

  test('the failed version round-trips through storage', () async {
    final storage = MockAuthStorage();
    final service = SettingsService(storage: storage);

    await service.setMacSurfaceFailedVersion('1.5.0');
    expect(await service.getMacSurfaceFailedVersion(), '1.5.0');
    expect(storage.contents, {'mac_surface_failed_version': '1.5.0'});
  });
}
