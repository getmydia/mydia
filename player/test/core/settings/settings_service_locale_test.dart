import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_service.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  test('round-trips the language tag under interface_locale', () async {
    final storage = MockAuthStorage();
    final service = SettingsService(storage: storage);
    expect(await service.getLocaleCode(), isNull);
    await service.setLocaleCode('es');
    expect(storage.contents['interface_locale'], 'es');
    expect(await service.getLocaleCode(), 'es');
  });

  test('null clears the choice', () async {
    final storage = MockAuthStorage();
    final service = SettingsService(storage: storage);
    await service.setLocaleCode('es');
    await service.setLocaleCode(null);
    expect(await service.getLocaleCode(), isNull);
  });

  test('clearSettings keeps the device-level language', () async {
    final service = SettingsService(storage: MockAuthStorage());
    await service.setLocaleCode('es');
    await service.clearSettings();
    expect(await service.getLocaleCode(), 'es');
  });
}
